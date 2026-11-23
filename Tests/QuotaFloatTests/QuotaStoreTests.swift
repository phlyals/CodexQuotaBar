import CodexBarCore
import Foundation
import XCTest

@testable import QuotaFloat

final class QuotaStoreTests: XCTestCase {
  @MainActor
  func testFailuresPreserveSameAccountDataAndSanitizeMessages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for message in ["HTTP 401", "network error: private@example.test /private/path"] {
      let cache = QuotaCacheStore(fileURL: root.appendingPathComponent("cache.json"))
      cache.save([Self.fixture(key: "account-a", updatedAt: Date().addingTimeInterval(-60))])
      let store = QuotaStore(
        fetcher: FailedQuotaFetcher(message: message), cacheStore: cache,
        identityProvider: { "account-a" })
      store.start()
      for _ in 0..<100 {
        if !store.isRefreshing { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      let snapshot = try XCTUnwrap(store.snapshot(for: .codex))
      XCTAssertEqual(snapshot.session?.remainingPercent, 80)
      XCTAssertEqual(snapshot.freshness, message.contains("401") ? .authRequired : .cached)
      XCTAssertFalse(snapshot.message?.contains("private") == true)
      let lastAttempt = store.lastRefreshAttempt
      store.refreshIfStale()
      XCTAssertEqual(store.lastRefreshAttempt, lastAttempt)
      store.stop()
    }
  }

  @MainActor
  func testRefreshIfStaleTracksProvidersIndependentlyAndKeepsInFlightRequests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fetcher = ControlledQuotaFetcher()
    let store = QuotaStore(
      fetcher: fetcher, cacheStore: QuotaCacheStore(fileURL: root.appendingPathComponent("cache.json")),
      refreshInterval: 3600, identityProvider: { "account-a" })
    let dashboard = CodexDashboardStore(quotaStore: store)
    store.setActiveProviders([.codex, .antigravity])
    store.start()
    defer { store.stop() }

    let startedAt = try XCTUnwrap(store.lastRefreshAttempt)
    XCTAssertEqual(store.refreshingProviders, [.codex, .antigravity])
    for _ in 0..<200 {
      if await fetcher.count == 2 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let initialProviders = await fetcher.providers
    let codex = try XCTUnwrap(initialProviders.firstIndex(of: .codex))
    let google = try XCTUnwrap(initialProviders.firstIndex(of: .antigravity))
    XCTAssertTrue(dashboard.isRefreshingCodex)
    XCTAssertTrue(dashboard.isRefreshingGoogle)

    await fetcher.complete(codex, accountKey: "account-a")
    for _ in 0..<200 {
      if !dashboard.isRefreshingCodex { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(dashboard.isRefreshingGoogle)
    XCTAssertEqual(store.refreshingProviders, [.antigravity])

    // The attempt is old enough, but the completion is still within the window.
    store.refreshIfStale(maxAge: Date().timeIntervalSince(startedAt))
    XCTAssertEqual(store.refreshingProviders, [.antigravity])
    store.refreshIfStale(maxAge: 0)
    store.refreshIfStale(maxAge: 0)
    XCTAssertEqual(store.refreshingProviders, [.codex, .antigravity])

    for _ in 0..<200 {
      if await fetcher.count >= 3 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let allProviders = await fetcher.providers
    XCTAssertEqual(allProviders, initialProviders + [.codex])
    await fetcher.complete(google)
    await fetcher.complete(2, accountKey: "account-a")
    for _ in 0..<200 {
      if !dashboard.isRefreshing { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertFalse(dashboard.isRefreshing)
    XCTAssertEqual(store.refreshingProviders, [])
    XCTAssertEqual(store.snapshot(for: .antigravity)?.freshness, .fresh)
  }

  @MainActor
  func testStartupRejectsOtherAccountAndUnboundLegacyCache() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = QuotaCacheStore(fileURL: root.appendingPathComponent("cache.json"))
    for key in [String?.none, "account-a"] {
      cache.save([Self.fixture(key: key)])
      let store = QuotaStore(
        fetcher: SequencedQuotaFetcher(), cacheStore: cache, identityProvider: { "account-b" })
      XCTAssertNil(store.snapshot(for: .codex))
    }
    cache.save([Self.fixture(key: "account-b")])
    let matching = QuotaStore(
      fetcher: SequencedQuotaFetcher(), cacheStore: cache, identityProvider: { "account-b" })
    XCTAssertEqual(matching.snapshot(for: .codex)?.freshness, .cached)
  }

  @MainActor
  func testGoogleCacheRequiresMatchingEmailOrExplicitAmbientSource() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = QuotaCacheStore(fileURL: root.appendingPathComponent("cache.json"))
    let bound = GoogleQuotaBinding.saved(email: "One@example.test")
    for (binding, key, email, source, expected) in [
      (bound, "one@example.test", "One@example.test", "google-oauth-remote", true),
      (bound, "two@example.test", "Two@example.test", "agy-cli-scoped", false),
      (bound, "one@example.test", "Two@example.test", "agy-cli-scoped", false),
      (bound, "one@example.test", "One@example.test", "local", false),
      (bound, "antigravity", nil, "agy-cli-ambient", false),
      (.ambient, "one@example.test", "One@example.test", "google-oauth-remote", false),
      (.ambient, "antigravity", nil, "agy-cli", false),
      (.ambient, "antigravity", nil, "agy-cli-ambient", true),
      (.unreadable, "antigravity", nil, "agy-cli-ambient", false),
    ] {
      cache.save([QuotaSnapshot(
        provider: .antigravity, session: .init(usedPercent: 11, resetsAt: nil, windowMinutes: 300),
        weekly: nil, resetCredits: nil, accountEmail: email, accountKey: key, source: source,
        updatedAt: Date(), freshness: .fresh, message: nil)])
      let store = QuotaStore(cacheStore: cache, googleBinding: { binding })
      XCTAssertEqual(store.snapshot(for: .antigravity) != nil, expected)
    }
  }

  @MainActor
  func testGoogleSwitchClearsMenuAndCacheAndRejectsLateResults() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = FixtureIdentity("One@example.test")
    let accounts = GoogleAccountManager(fileURL: root.appendingPathComponent("google.json")) {
      AntigravityOAuthCredentials(
        accessToken: "fixture", refreshToken: "fixture", expiryDate: .distantFuture,
        email: identity.value)
    }
    let cache = QuotaCacheStore(fileURL: root.appendingPathComponent("cache.json"))
    let fetcher = ControlledQuotaFetcher()
    let store = QuotaStore(fetcher: fetcher, cacheStore: cache,
      googleBinding: { GoogleQuotaBinding(manager: accounts) })
    accounts.onSelectionChange = { store.invalidateAndRefresh(.antigravity) }
    let dashboard = CodexDashboardStore(quotaStore: store)
    store.setActiveProviders([.antigravity])
    XCTAssertEqual(store.retryInterval(.antigravity), 300)
    XCTAssertEqual(store.staleRefreshAge(for: .antigravity, maxAge: 15), 45)
    store.start()
    defer { store.stop() }
    try await fetcher.waitForCount(1)
    try await accounts.addAccount()
    try await fetcher.waitForCount(2)
    XCTAssertEqual(store.retryInterval(.antigravity), 60)
    XCTAssertEqual(store.staleRefreshAge(for: .antigravity, maxAge: 15), 15)
    await fetcher.complete(1, accountKey: "one@example.test")
    for _ in 0..<200 {
      if !store.isRefreshing { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(dashboard.googleQuota?.accountKey, "one@example.test")
    store.refresh()
    try await fetcher.waitForCount(3)
    identity.value = "Two@example.test"
    try await accounts.addAccount()
    XCTAssertNil(dashboard.googleQuota)
    XCTAssertTrue(cache.load().isEmpty)
    try await fetcher.waitForCount(4)
    await fetcher.complete(3, accountKey: "two@example.test")
    await fetcher.complete(2, accountKey: "one@example.test")
    await fetcher.complete(0)
    for _ in 0..<200 {
      if !store.isRefreshing { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(dashboard.googleQuota?.accountKey, "two@example.test")
    XCTAssertEqual(cache.load().first?.accountKey, "two@example.test")
    try accounts.removeAccount(id: XCTUnwrap(accounts.selectedAccountID))
    XCTAssertNil(dashboard.googleQuota)
    XCTAssertTrue(cache.load().isEmpty)
    try await fetcher.waitForCount(5)
    await fetcher.complete(4, accountKey: "two@example.test")
    for _ in 0..<200 {
      if !store.isRefreshing { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(dashboard.googleQuota?.hasQuotaData, false)
    XCTAssertTrue(cache.load().isEmpty)
  }

  @MainActor
  func testTwentyIdentityChangesIgnoreOutOfOrderCompletions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = FixtureIdentity("account-0")
    let fetcher = ControlledQuotaFetcher()
    let store = QuotaStore(
      fetcher: fetcher,
      cacheStore: QuotaCacheStore(fileURL: root.appendingPathComponent("cache.json")),
      refreshInterval: 3600, identityProvider: { identity.value })
    store.start()
    for index in 0...20 {
      if index > 0 {
        identity.value = "account-\(index)"
        store.invalidateAndRefresh(.codex)
      }
      for _ in 0..<100 {
        if await fetcher.count > index { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      let count = await fetcher.count
      XCTAssertEqual(count, index + 1)
    }
    for index in (0...20).reversed() { await fetcher.complete(index) }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(store.snapshot(for: .codex)?.accountKey, "account-20")
    identity.value = "account-external"
    store.refresh()
    XCTAssertNil(store.snapshot(for: .codex))
    for _ in 0..<100 {
      if await fetcher.count >= 22 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    await fetcher.complete(21)
    store.stop()
  }

  @MainActor
  func testLoggedOutDoesNotFetchOrShowCachedQuota() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fetcher = SequencedQuotaFetcher()
    let store = QuotaStore(
      fetcher: fetcher,
      cacheStore: QuotaCacheStore(fileURL: root.appendingPathComponent("cache.json")),
      identityProvider: { nil })
    store.start()
    XCTAssertEqual(store.snapshot(for: .codex)?.freshness, .authRequired)
    XCTAssertNil(store.snapshot(for: .codex)?.session)
    let count = await fetcher.callCount
    XCTAssertEqual(count, 0)
    store.stop()
  }

  private static func fixture(key: String?, updatedAt: Date = Date()) -> QuotaSnapshot {
    QuotaSnapshot(
      provider: .codex, session: QuotaWindow(usedPercent: 20, resetsAt: nil, windowMinutes: 300),
      weekly: nil,
      resetCredits: nil, accountEmail: "fixture@example.test", accountKey: key, source: "fixture",
      updatedAt: updatedAt, freshness: .fresh, message: nil)
  }

  @MainActor
  func testInvalidateAndRefreshCancelsStaleRequest() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("QuotaStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fetcher = SequencedQuotaFetcher()
    let store = QuotaStore(
      fetcher: fetcher,
      cacheStore: QuotaCacheStore(fileURL: root.appendingPathComponent("cache.json")),
      refreshInterval: 3600,
      identityProvider: { "test-account" })

    store.start()
    let firstCallStarted = await fetcher.waitUntilCallCount(1)
    XCTAssertTrue(firstCallStarted)

    store.invalidateAndRefresh(.codex)
    let replacementCallStarted = await fetcher.waitUntilCallCount(2)
    XCTAssertTrue(replacementCallStarted)
    try await Task.sleep(for: .milliseconds(100))

    XCTAssertEqual(store.snapshot(for: .codex)?.accountEmail, "replacement@example.com")
    let calls = await fetcher.callCount
    XCTAssertEqual(calls, 2)
    store.stop()
  }
}

@MainActor
private final class FixtureIdentity {
  var value: String
  init(_ value: String) { self.value = value }
}

private struct FailedQuotaFetcher: QuotaFetching {
  struct Failure: LocalizedError { let errorDescription: String? }
  let message: String
  func fetch(_ provider: QuotaProvider) async throws -> QuotaSnapshot {
    throw Failure(errorDescription: message)
  }
}

private actor ControlledQuotaFetcher: QuotaFetching {
  private(set) var providers: [QuotaProvider] = []
  private var pending: [Int: CheckedContinuation<QuotaSnapshot, Never>] = [:]
  var count: Int { self.providers.count }

  func fetch(_ provider: QuotaProvider) async throws -> QuotaSnapshot {
    let index = self.count
    self.providers.append(provider)
    return await withCheckedContinuation { pending[index] = $0 }
  }

  func waitForCount(_ expected: Int) async throws {
    for _ in 0..<200 {
      if count >= expected { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Missing quota request \(expected)")
  }

  func complete(_ index: Int, accountKey: String? = nil) {
    guard let continuation = self.pending.removeValue(forKey: index) else { return }
    let google = self.providers[index] == .antigravity
    continuation.resume(
      returning: QuotaSnapshot(
        provider: self.providers[index],
        session: QuotaWindow(usedPercent: Double(index), resetsAt: nil, windowMinutes: 300),
        weekly: nil,
        resetCredits: nil, accountEmail: google ? accountKey : "fixture@example.test",
        accountKey: accountKey ?? "account-\(index)",
        source: google ? (accountKey == nil ? "agy-cli-ambient" : "google-oauth-remote") : "fixture", updatedAt: Date(), freshness: .fresh, message: nil))
  }
}

private actor SequencedQuotaFetcher: QuotaFetching {
  private(set) var callCount = 0

  func fetch(_ provider: QuotaProvider) async throws -> QuotaSnapshot {
    _ = provider
    self.callCount += 1
    let call = self.callCount
    if call == 1 {
      try await Task.sleep(for: .seconds(30))
    }

    let window = QuotaWindow(usedPercent: 20, resetsAt: nil, windowMinutes: 300)
    return QuotaSnapshot(
      provider: .codex,
      session: window,
      weekly: window,
      resetCredits: nil,
      accountEmail: call == 1 ? "stale@example.com" : "replacement@example.com",
      source: "test",
      updatedAt: Date(),
      freshness: .fresh,
      message: nil)
  }

  func waitUntilCallCount(_ expected: Int) async -> Bool {
    let deadline = Date().addingTimeInterval(2)
    while self.callCount < expected, Date() < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return self.callCount >= expected
  }
}
