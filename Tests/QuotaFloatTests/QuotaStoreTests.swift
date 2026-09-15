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
      cache.save([Self.fixture(key: "account-a")])
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
      store.stop()
    }
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

  private static func fixture(key: String?) -> QuotaSnapshot {
    QuotaSnapshot(
      provider: .codex, session: QuotaWindow(usedPercent: 20, resetsAt: nil, windowMinutes: 300),
      weekly: nil,
      resetCredits: nil, accountEmail: "fixture@example.test", accountKey: key, source: "fixture",
      updatedAt: Date(), freshness: .fresh, message: nil)
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
  var count = 0
  var pending: [Int: CheckedContinuation<QuotaSnapshot, Never>] = [:]
  func fetch(_ provider: QuotaProvider) async throws -> QuotaSnapshot {
    let index = count
    count += 1
    return await withCheckedContinuation { pending[index] = $0 }
  }
  func complete(_ index: Int) {
    pending.removeValue(forKey: index)?.resume(
      returning: QuotaSnapshot(
        provider: .codex,
        session: QuotaWindow(usedPercent: Double(index), resetsAt: nil, windowMinutes: 300),
        weekly: nil,
        resetCredits: nil, accountEmail: "fixture@example.test", accountKey: "account-\(index)",
        source: "fixture", updatedAt: Date(), freshness: .fresh, message: nil))
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
