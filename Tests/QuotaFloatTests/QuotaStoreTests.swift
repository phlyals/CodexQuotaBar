import Foundation
import XCTest

@testable import QuotaFloat

final class QuotaStoreTests: XCTestCase {
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
      refreshInterval: 3600)

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
