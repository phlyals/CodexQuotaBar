import XCTest
@testable import QuotaFloat

final class QuotaCacheStoreTests: XCTestCase {
  func testSavingNoSnapshotsClearsExistingCacheFile() {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("QuotaFloatCacheTests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("quota-cache.json", isDirectory: false)
    let store = QuotaCacheStore(fileURL: fileURL)
    let snapshot = QuotaSnapshot(
      provider: .codex,
      session: QuotaWindow(usedPercent: 10, resetsAt: nil, windowMinutes: 300),
      weekly: nil,
      resetCredits: nil,
      accountEmail: "user@example.com",
      source: "oauth",
      updatedAt: Date(timeIntervalSince1970: 1_000),
      freshness: .fresh,
      message: nil)

    store.save([snapshot])
    XCTAssertFalse(store.load().isEmpty)

    store.save([])

    XCTAssertTrue(store.load().isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
  }
}
