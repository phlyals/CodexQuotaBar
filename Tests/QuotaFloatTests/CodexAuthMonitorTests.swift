import XCTest
@testable import QuotaFloat

final class CodexAuthFingerprintReaderTests: XCTestCase {
  func testDefaultAuthURLUsesCodexHomeWhenPresent() {
    let url = CodexAuthFingerprintReader.defaultAuthFileURL(
      environment: ["CODEX_HOME": "/tmp/custom-codex"])

    XCTAssertEqual(url.path, "/tmp/custom-codex/auth.json")
  }

  func testDefaultAuthURLFallsBackToDotCodexAuthJSON() {
    let url = CodexAuthFingerprintReader.defaultAuthFileURL(environment: [:])

    XCTAssertTrue(url.path.hasSuffix("/.codex/auth.json"))
  }

  func testFingerprintChangesWhenAuthFileChanges() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("QuotaFloatAuthMonitorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("auth.json")
    let reader = CodexAuthFingerprintReader(fileURL: fileURL)
    try Data("old".utf8).write(to: fileURL)
    let first = reader.read()

    try Data("new-auth-json".utf8).write(to: fileURL)
    let second = reader.read()

    XCTAssertNotNil(first)
    XCTAssertNotNil(second)
    XCTAssertNotEqual(first, second)
  }
}
