import XCTest

@testable import QuotaFloat

final class CodexAuthIdentityReaderTests: XCTestCase {
  @MainActor
  func testFirstLoginDeletionAndRotationEmitOnce() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("auth.json")
    var changes: [CodexAuthChange] = []
    let monitor = CodexAuthMonitor(reader: .init(fileURL: url), onChange: { changes.append($0) })
    monitor.poll()
    XCTAssertTrue(changes.isEmpty)
    try Self.authJSON(accountID: "a", idToken: "one").write(to: url)
    monitor.poll()
    monitor.poll()
    XCTAssertEqual(changes, [.accountChanged])
    try Self.authJSON(accountID: "a", idToken: "two").write(to: url)
    monitor.poll()
    monitor.poll()
    XCTAssertEqual(changes.last, .credentialsRotated)
    try FileManager.default.removeItem(at: url)
    monitor.poll()
    monitor.poll()
    XCTAssertEqual(changes, [.accountChanged, .credentialsRotated, .accountChanged])
  }
  func testDefaultAuthURLUsesCodexHomeWhenPresent() {
    let url = CodexAuthIdentityReader.defaultAuthFileURL(
      environment: ["CODEX_HOME": "/tmp/custom-codex"])

    XCTAssertEqual(url.path, "/tmp/custom-codex/auth.json")
  }

  func testDefaultAuthURLFallsBackToDotCodexAuthJSON() {
    let url = CodexAuthIdentityReader.defaultAuthFileURL(environment: [:])

    XCTAssertTrue(url.path.hasSuffix("/.codex/auth.json"))
  }

  func testIdentityIgnoresTokenChangesForSameAccount() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("QuotaFloatAuthMonitorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("auth.json")
    let reader = CodexAuthIdentityReader(fileURL: fileURL)
    try Self.authJSON(accountID: "acct-1", idToken: "token-a").write(to: fileURL)
    let first = reader.read()

    try Self.authJSON(accountID: "acct-1", idToken: "token-b").write(to: fileURL)
    let second = reader.read()

    XCTAssertNotNil(first)
    XCTAssertNotNil(second)
    XCTAssertEqual(first, second)
  }

  func testIdentityChangesWhenAccountIDChanges() throws {
    let first = CodexAuthIdentityReader.identity(
      from: Self.authJSON(accountID: "acct-1", idToken: "token-a"))
    let second = CodexAuthIdentityReader.identity(
      from: Self.authJSON(accountID: "acct-2", idToken: "token-a"))

    XCTAssertNotEqual(first, second)
  }

  private static func authJSON(accountID: String, idToken: String) -> Data {
    Data(
      """
      {
        "tokens": {
          "account_id": "\(accountID)",
          "id_token": "\(idToken)",
          "access_token": "\(UUID().uuidString)"
        }
      }
      """.utf8)
  }
}
