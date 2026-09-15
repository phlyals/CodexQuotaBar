import CodexBarCore
import Foundation
import XCTest

@testable import QuotaFloat

final class SubscriptionAndReminderTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testSubscriptionAPIParsesExpiryWithoutInventingPurchaseOrRenewal() throws {
    let metadata = try CodexSubscriptionFetcher.parse(
      Data(#"{"account_id":"a","active_until":"2027-02-01T00:00:00Z"}"#.utf8), accountID: "a",
      now: now)
    XCTAssertEqual(metadata.source, .subscriptionAPI)
    XCTAssertTrue(metadata.isVerified(now: now))
    XCTAssertFalse(metadata.isVerified(now: now.addingTimeInterval(86_400)))
    XCTAssertNil(metadata.activeStart)
    XCTAssertEqual(metadata.activeUntil, ISO8601DateFormatter().date(from: "2027-02-01T00:00:00Z"))
  }

  func testSubscriptionRejectsWrongAccountAndMissingOrMalformedDates() {
    for json in [
      #"{"account_id":"b","active_until":1800086400}"#, #"{"active_until":"invalid"}"#, "{}", "[]",
    ] {
      XCTAssertThrowsError(
        try CodexSubscriptionFetcher.parse(Data(json.utf8), accountID: "a", now: now))
    }
  }

  func testSubscriptionThrottleIsolationFailureAndRecovery() async throws {
    let transport = SubscriptionTransportFixture()
    let fetcher = CodexSubscriptionFetcher(transport: transport)
    let first = try await fetcher.fetch(
      accessToken: "fixture", accountID: "a", accountKey: "a", now: now)
    XCTAssertTrue(first.metadata?.isVerified(now: now) == true)
    _ = try await fetcher.fetch(
      accessToken: "fixture", accountID: "a", accountKey: "a", now: now.addingTimeInterval(60))
    var count = await transport.count
    XCTAssertEqual(count, 1)
    _ = try await fetcher.fetch(accessToken: "fixture", accountID: "b", accountKey: "b", now: now)
    count = await transport.count
    XCTAssertEqual(count, 2)
    await transport.setStatus(403)
    let failed = try await fetcher.fetch(
      accessToken: "fixture", accountID: "a", accountKey: "a", now: now.addingTimeInterval(3600))
    XCTAssertTrue(failed.message?.contains("未授权") == true)
    XCTAssertEqual(failed.metadata?.activeUntil, first.metadata?.activeUntil)
    XCTAssertFalse(failed.metadata?.isVerified(now: now.addingTimeInterval(3600)) == true)
    _ = try await fetcher.fetch(
      accessToken: "fixture", accountID: "a", accountKey: "a", now: now.addingTimeInterval(3650))
    count = await transport.count
    XCTAssertEqual(count, 3)
    await transport.setStatus(200)
    let recovered = try await fetcher.fetch(
      accessToken: "fixture", accountID: "a", accountKey: "a", now: now.addingTimeInterval(4200))
    XCTAssertNil(recovered.message)
    XCTAssertTrue(recovered.metadata?.isVerified(now: now.addingTimeInterval(4200)) == true)
  }

  func testSubscriptionCancellationIsNotCachedAsFailure() async throws {
    let fetcher = CodexSubscriptionFetcher(transport: SubscriptionTransportFixture())
    let now = self.now
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await fetcher.fetch(
        accessToken: "fixture", accountID: "a", accountKey: "a", now: now)
    }
    do {
      _ = try await task.value
      XCTFail("Cancellation must propagate")
    } catch is CancellationError {} catch { XCTFail("Unexpected error") }
  }

  func testSubscriptionCacheRoundTripAndAccountResolution() throws {
    var snapshot = makeSnapshot()
    snapshot.subscriptionCheck = .init(
      metadata: .init(
        activeStart: nil, activeUntil: now.addingTimeInterval(5000), lastChecked: now,
        source: .subscriptionAPI, freshness: .fresh),
      attemptedAt: now, message: nil)
    let restored = try JSONDecoder().decode(
      QuotaSnapshot.self, from: JSONEncoder().encode(snapshot))
    XCTAssertEqual(restored.subscriptionCheck, snapshot.subscriptionCheck)
    XCTAssertEqual(
      restored.markingCached(now: now, staleAfter: 300).subscriptionCheck,
      snapshot.subscriptionCheck)
    XCTAssertNotNil(
      CodexSubscriptionCheck.resolve(record: nil, snapshot: restored, accountKey: "a"))
    XCTAssertNil(CodexSubscriptionCheck.resolve(record: nil, snapshot: restored, accountKey: "b"))
    XCTAssertNil(CodexSubscriptionCheck.resolve(record: nil, snapshot: restored, accountKey: nil))
  }

  func testWeeklyOnlyIconTracksRemainingWithoutInventingSession() {
    let display = StatusBarQuotaFormatter.display(for: makeSnapshot(), isRefreshing: false)
    XCTAssertEqual(display.iconRemainingPercent, 40)
    XCTAssertEqual(display.sessionLine, "5h --")
    XCTAssertEqual(display.weeklyLine, "W 40%")
  }

  @MainActor
  func testSubscriptionFailureAfterRestartPreservesOnlyMatchingAccountHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = QuotaCacheStore(fileURL: root.appendingPathComponent("cache.json"))
    var previous = makeSnapshot()
    previous.subscriptionCheck = .init(
      metadata: .init(
        activeStart: nil, activeUntil: now.addingTimeInterval(5000), lastChecked: now,
        source: .subscriptionAPI, freshness: .fresh), attemptedAt: now, message: nil)
    cache.save([previous])
    var next = makeSnapshot()
    next.subscriptionCheck = .init(
      metadata: nil, attemptedAt: now.addingTimeInterval(60), message: "订阅查询失败")
    let store = QuotaStore(
      fetcher: SubscriptionSnapshotFixture(snapshot: next), cacheStore: cache,
      identityProvider: { "a" })
    defer { store.stop() }
    store.start()
    for _ in 0..<100 {
      if !store.isRefreshing { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let result = try XCTUnwrap(store.snapshot(for: .codex)?.subscriptionCheck)
    XCTAssertEqual(result.metadata?.activeUntil, previous.subscriptionCheck?.metadata?.activeUntil)
    XCTAssertEqual(result.metadata?.freshness, .cached)
    XCTAssertEqual(result.message, "订阅查询失败")
    XCTAssertEqual(cache.load().first?.subscriptionCheck, result)
  }

  func testDelayedSignalsCatchUpOnceAndSurviveLedgerReload() throws {
    var ledger = QuotaNotificationLedger(
      signalMonitoringStartedAt: now.addingTimeInterval(-20 * 3600))
    let signal = makeSignal(age: 8 * 3600)
    let notices = ledger.signalCandidates([signal], now: now)
    XCTAssertEqual(notices.count, 1)
    XCTAssertTrue(notices[0].title.contains("补提醒"))
    ledger.mark(notices[0], at: now)
    let restored = try JSONDecoder().decode(
      QuotaNotificationLedger.self, from: JSONEncoder().encode(ledger))
    XCTAssertTrue(restored.signalCandidates([signal], now: now).isEmpty)
  }

  func testSignalsExcludeHistoryFutureUnverifiedResolvedAndExpiredAnnouncements() {
    let ledger = QuotaNotificationLedger(
      signalMonitoringStartedAt: now.addingTimeInterval(-30 * 3600))
    var unverified = makeSignal(age: 3600)
    unverified.verified = false
    var resolved = makeSignal(age: 3600)
    resolved.resolutionID = "followup"
    var expired = makeSignal(age: 3600)
    expired.state = .announced
    expired.deadline = now.addingTimeInterval(-1)
    XCTAssertTrue(
      ledger.signalCandidates(
        [makeSignal(age: 25 * 3600), makeSignal(age: -10), unverified, resolved, expired], now: now
      ).isEmpty)
    let justEnabled = QuotaNotificationLedger(signalMonitoringStartedAt: now)
    XCTAssertTrue(justEnabled.signalCandidates([makeSignal(age: 60)], now: now).isEmpty)
    XCTAssertTrue(
      QuotaNotificationLedger().signalCandidates([makeSignal(age: 60)], now: now).isEmpty)
  }

  func testBankedResetCreditsAreNotificationCandidates() {
    let ledger = QuotaNotificationLedger(signalMonitoringStartedAt: now.addingTimeInterval(-3600))
    var signal = makeSignal(age: 60)
    signal.state = .banked
    XCTAssertEqual(ledger.signalCandidates([signal], now: now).count, 1)
  }

  func testOldLedgerMigratesWithoutLosingDeliveredNotices() throws {
    let ledger = try JSONDecoder().decode(
      QuotaNotificationLedger.self, from: Data(#"{"delivered":{"existing":0}}"#.utf8))
    XCTAssertNotNil(ledger.delivered["existing"])
    XCTAssertNil(ledger.signalMonitoringStartedAt)
  }

  func testLiveSubscriptionReadOnlySmoke() async throws {
    guard ProcessInfo.processInfo.environment["QUOTAFLOAT_LIVE_SUBSCRIPTION_TEST"] == "1" else {
      throw XCTSkip("Requires explicit read-only live subscription check")
    }
    let credentials = try CodexOAuthCredentialsStore.load()
    let accountID = try XCTUnwrap(credentials.accountId)
    let result = try await CodexSubscriptionFetcher().fetch(
      accessToken: credentials.accessToken, accountID: accountID, accountKey: accountID)
    XCTAssertTrue(result.metadata != nil || result.message != nil)
    print(
      "LIVE_SUBSCRIPTION verified=\(result.metadata?.isVerified() == true) result=\(result.message ?? "subscription API returned date")"
    )
  }

  private func makeSnapshot() -> QuotaSnapshot {
    QuotaSnapshot(
      provider: .codex, session: nil,
      weekly: .init(usedPercent: 60, resetsAt: now.addingTimeInterval(5000), windowMinutes: 10080),
      resetCredits: nil, accountEmail: nil, accountKey: "a", source: "fixture", updatedAt: now,
      freshness: .fresh, message: nil)
  }

  private func makeSignal(age: TimeInterval) -> ResetSignal {
    ResetSignal(
      id: "2098685367058612394", publishedAt: now.addingTimeInterval(-age), discoveredAt: now,
      excerpt: "reset is complete", state: .completed, deadline: nil, timeAssumption: "",
      scope: "unknown", verified: true, linkedPostID: nil, resolutionID: nil)
  }
}

private actor SubscriptionTransportFixture: CodexSubscriptionTransport {
  var count = 0
  var status = 200
  func setStatus(_ status: Int) { self.status = status }
  func read(_ request: URLRequest) async throws -> (Data, Int) {
    count += 1
    return (Data(#"{"active_until":1800086400}"#.utf8), status)
  }
}

private struct SubscriptionSnapshotFixture: QuotaFetching {
  let snapshot: QuotaSnapshot
  func fetch(_ provider: QuotaProvider) async throws -> QuotaSnapshot { snapshot }
}
