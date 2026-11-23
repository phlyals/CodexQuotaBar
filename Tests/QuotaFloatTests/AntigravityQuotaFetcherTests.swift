import CodexBarCore
import XCTest

@testable import QuotaFloat

@MainActor
final class AntigravityQuotaFetcherTests: XCTestCase {
  private let email = "Reader@example.test"

  func testCompleteRemoteBucketsUseSelectedGrantAndSaveRefreshAndProject() async throws {
    let root = try self.directory()
    let manager = try await self.manager(at: root, expired: true)
    var fetcher = AntigravityQuotaFetcher(environment: [
      "ANTIGRAVITY_CLI_PATH": root.appending(path: "no-agy").path,
      "ANTIGRAVITY_OAUTH_CREDENTIALS_JSON": "ambient-fixture-not-for-this-request",
    ])
    fetcher.userEmail = { token in
      XCTAssertEqual(token, "refreshed-fixture")
      return "reader@example.test"
    }
    fetcher.refresh = { old in
      XCTAssertEqual(old.accessToken, "access-fixture")
      var next = old
      next.accessToken = "refreshed-fixture"
      next.refreshToken = "rotated-fixture"
      next.expiryDateMilliseconds = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
      return next
    }
    fetcher.dataLoader = Self.remote(buckets: Self.bothBuckets, token: "refreshed-fixture")

    let snapshot = try await fetcher.fetch(manager: manager)

    XCTAssertEqual(snapshot.source, "google-oauth-remote")
    XCTAssertEqual(snapshot.accountEmail, self.email)
    XCTAssertEqual(snapshot.accountKey, self.email.lowercased())
    XCTAssertEqual(snapshot.accountPlan, "Google AI Pro")
    XCTAssertEqual(snapshot.session?.remainingPercent, 42)
    XCTAssertEqual(snapshot.weekly?.remainingPercent, 50)
    XCTAssertEqual(manager.selectedAccount?.credentials.refreshToken, "rotated-fixture")
    XCTAssertEqual(manager.selectedAccount?.credentials.projectID, "fixture-project")
  }

  func testNonGeminiRemoteWindowsFallBackToPrivateCLIAndPersistVerifiedRotation() async throws {
    let root = try self.directory()
    let homeLog = root.appending(path: "staged-home")
    let manager = try await self.manager(at: root)
    let binary = try self.script(
      in: root,
      body: """
        echo "$HOME" > '\(homeLog.path)'
        [ "$PWD" = "$HOME" ] && [ "$(pwd -P)" = "$(cd "$HOME" && pwd -P)" ] || exit 1
        [ "$SSH_TTY" = "quotafloat-scoped" ] && [ "$BROWSER" = "/usr/bin/false" ] || exit 2
        [ "$AGY_CLI_DISABLE_AUTO_UPDATE" = true ] && [ "$HTTPS_PROXY" = "fixture-proxy" ] || exit 3
        [ -z "$GOOGLE_APPLICATION_CREDENTIALS$GEMINI_API_KEY$ANTIGRAVITY_OAUTH_CREDENTIALS_JSON$XDG_CONFIG_HOME" ] || exit 4
        [ "$(command -v open)" = "$HOME/open" ] && [ "$(command -v xdg-open)" = "$HOME/xdg-open" ] || exit 5
        open && exit 6
        xdg-open && exit 7
        token="$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
        [ "$(/usr/bin/stat -f %Lp "$HOME")" = 700 ] && [ "$(/usr/bin/stat -f %Lp "$token")" = 600 ] || exit 8
        /usr/bin/grep -q '"auth_method":"consumer"' "$token" && /usr/bin/grep -q '"token_type":"Bearer"' "$token" || exit 9
        /usr/bin/grep -q '"access_token":"access-fixture"' "$token" || exit 10
        /usr/bin/sed -i '' 's/access-fixture/effective-fixture/g;s/refresh-fixture/rotated-fixture/g' "$token"
        echo '\(Self.cliOutput)'
        """)
    var fetcher = AntigravityQuotaFetcher(environment: [
      "ANTIGRAVITY_CLI_PATH": binary.path, "PATH": "/usr/bin:/bin", "HOME": root.path,
      "GOOGLE_APPLICATION_CREDENTIALS": "excluded", "GEMINI_API_KEY": "excluded",
      "ANTIGRAVITY_OAUTH_CREDENTIALS_JSON": "excluded", "XDG_CONFIG_HOME": "excluded",
      "HTTPS_PROXY": "fixture-proxy",
    ])
    fetcher.dataLoader = Self.remote(buckets: Self.otherBuckets)
    fetcher.userEmail = { token in
      XCTAssertEqual(token, "effective-fixture")
      return "reader@example.test"
    }

    let snapshot = try await fetcher.fetch(manager: manager)

    XCTAssertEqual(snapshot.source, "agy-cli-scoped")
    XCTAssertEqual(snapshot.accountPlan, "Google AI Pro")
    XCTAssertEqual(snapshot.accountKey, self.email.lowercased())
    XCTAssertEqual(snapshot.session?.remainingPercent, 31)
    XCTAssertEqual(snapshot.weekly?.remainingPercent, 18)
    XCTAssertEqual(manager.selectedAccount?.credentials.accessToken, "effective-fixture")
    XCTAssertEqual(manager.selectedAccount?.credentials.refreshToken, "rotated-fixture")
    let staged = try self.read(homeLog)
    XCTAssertNotEqual(staged, root.path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: staged))
  }

  func testQuotaRefreshDoesNotEnrollAnUnprovisionedAccount() async throws {
    let root = try self.directory()
    let manager = try await self.manager(at: root)
    var fetcher = AntigravityQuotaFetcher(environment: ["ANTIGRAVITY_CLI_PATH": "/missing-agy"])
    let fixture = Self.remote(buckets: Self.bothBuckets)
    actor FirstLookup {
      var seen = false
      func isFirst() -> Bool { defer { seen = true }; return !seen }
    }
    let lookup = FirstLookup()
    fetcher.dataLoader = { request in
      let url = try XCTUnwrap(request.url)
      XCTAssertNotEqual(url.path, "/v1internal:onboardUser")
      if url.path == "/v1internal:loadCodeAssist", await lookup.isFirst() {
        let body = #"{"allowedTiers":[{"id":"standard-tier","isDefault":true}]}"#
        return (Data(body.utf8), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200,
          httpVersion: nil, headerFields: nil)))
      }
      return try await fixture(request)
    }
    let snapshot = try await fetcher.fetch(manager: manager)
    XCTAssertEqual(snapshot.accountKey, email.lowercased())
  }

  func testRemoteRequiresUserinfoForRestoredAndRotatedBearer() async throws {
    for expired in [false, true] {
      let root = try self.directory()
      let created = try await self.manager(at: root, expired: expired)
      let original = created.selectedAccount?.credentials
      let manager = GoogleAccountManager(fileURL: root.appending(path: "accounts.json"))
      var fetcher = AntigravityQuotaFetcher(environment: ["ANTIGRAVITY_CLI_PATH": "/missing-agy"])
      fetcher.userEmail = { _ in "different@example.test" }
      fetcher.refresh = { old in
        var new = old
        new.accessToken = "other-bearer"
        return new
      }
      fetcher.dataLoader = { _ in XCTFail("Cannot query quota before proof of identity"); throw CancellationError() }
      do { _ = try await fetcher.fetch(manager: manager); XCTFail("Unexpected quota") }
      catch GoogleAccountError.invalidIdentity {}
      XCTAssertEqual(manager.selectedAccount?.credentials, original)
    }
  }

  func testScopedCLIRejectsAnExplicitDifferentMailbox() throws {
    XCTAssertThrowsError(try CodexBarQuotaFetcher.parseAgyUsageJSON("}diagnostic{", email: self.email))
    for wrong in [
      Self.cliOutput.replacingOccurrences(of: #""status":"SUCCESS""#, with: #""status":"SUCCESS","account_email":"other@example.test""#),
      Self.cliOutput.replacingOccurrences(of: #""groups":["#, with: #""email":"other@example.test","groups":["#),
    ] {
      XCTAssertThrowsError(try CodexBarQuotaFetcher.parseAgyUsageJSON(wrong, email: self.email)) {
        guard case GoogleAccountError.invalidIdentity = $0 else { return XCTFail("Unexpected error") }
      }
    }
  }

  func testOutdatedCLIIsNotAskedToRunUsage() async throws {
    let root = try self.directory()
    let marker = root.appending(path: "usage-started")
    let binary = try self.script(in: root, version: "1.1.10", body: "touch '\(marker.path)'")
    let fetcher = AntigravityQuotaFetcher(environment: ["ANTIGRAVITY_CLI_PATH": binary.path])
    do { _ = try await fetcher.fetch(manager: nil); XCTFail("Expected unsupported CLI") }
    catch QuotaFetchError.unsupportedAgyVersion {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testComplementaryWindowsComeFromTheSameAccount() async throws {
    let root = try self.directory()
    let manager = try await self.manager(at: root)
    let sessionOnly = Self.cliOutput.replacingOccurrences(of: "gemini-weekly", with: "other-weekly")
    let binary = try self.script(in: root, body: "echo '\(sessionOnly)'")
    var fetcher = AntigravityQuotaFetcher(environment: ["ANTIGRAVITY_CLI_PATH": binary.path])
    fetcher.dataLoader = Self.remote(buckets: Self.weeklyBucket)
    fetcher.userEmail = { _ in "reader@example.test" }
    let snapshot = try await fetcher.fetch(manager: manager)
    XCTAssertEqual(snapshot.source, GoogleQuotaSource.remoteAndScopedCLI)
    XCTAssertEqual(snapshot.weekly?.remainingPercent, 50)
    XCTAssertEqual(snapshot.session?.remainingPercent, 31)
  }

  func testPartialRemoteSurvivesCLIFailureWithoutInventingSecondWindow() async throws {
    let root = try self.directory()
    let manager = try await self.manager(at: root)
    let homeLog = root.appending(path: "failed-home")
    let binary = try self.script(in: root, body: "echo \"$HOME\" > '\(homeLog.path)'\nexit 1")
    var fetcher = AntigravityQuotaFetcher(environment: ["ANTIGRAVITY_CLI_PATH": binary.path])
    fetcher.dataLoader = Self.remote(buckets: Self.weeklyBucket + "," + Self.otherBuckets)

    let snapshot = try await fetcher.fetch(manager: manager)

    XCTAssertEqual(snapshot.source, "google-oauth-remote")
    XCTAssertNil(snapshot.session)
    XCTAssertEqual(snapshot.weekly?.remainingPercent, 50)
    XCTAssertEqual(snapshot.accountPlan, "Google AI Pro")
    XCTAssertFalse(FileManager.default.fileExists(atPath: try self.read(homeLog)))
  }

  func testAccountSwitchDiscardsRemoteResultAndNeverLaunchesAmbientCLI() async throws {
    let root = try self.directory()
    let manager = try await self.manager(at: root)
    let cliLog = root.appending(path: "cli-started")
    let binary = try self.script(in: root, body: "touch '\(cliLog.path)'\nexit 1")
    let fixture = Self.remote(buckets: Self.bothBuckets)
    var fetcher = AntigravityQuotaFetcher(environment: ["ANTIGRAVITY_CLI_PATH": binary.path])
    fetcher.dataLoader = { request in
      if request.url?.path.hasSuffix("retrieveUserQuotaSummary") == true {
        try await manager.selectAccount(id: nil)
      }
      return try await fixture(request)
    }
    do {
      _ = try await fetcher.fetch(manager: manager)
      XCTFail("Published a stale result after switching accounts")
    } catch is CancellationError {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: cliLog.path))
  }

  func testMismatchRejectsScopedCLIAndDoesNotStoreChangedToken() async throws {
    let root = try self.directory()
    let manager = try await self.manager(at: root)
    let binary = try self.script(
      in: root,
      body: """
        token="$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
        /usr/bin/sed -i '' 's/access-fixture/mismatch-fixture/g' "$token"
        echo '\(Self.cliOutput)'
        """)
    var fetcher = AntigravityQuotaFetcher(environment: ["ANTIGRAVITY_CLI_PATH": binary.path])
    fetcher.dataLoader = { _ in throw URLError(.notConnectedToInternet) }
    fetcher.userEmail = { token in
      XCTAssertEqual(token, "mismatch-fixture")
      return "other@example.test"
    }
    do {
      _ = try await fetcher.fetch(manager: manager)
      XCTFail("Published a CLI result from the wrong account")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("账号"))
    }
    XCTAssertEqual(manager.selectedAccount?.credentials.accessToken, "access-fixture")
  }

  func testConcurrentCLIProbesHaveSeparateHomesAndCleanUpAfterCancellation() async throws {
    let root = try self.directory()
    let manager = try await self.manager(at: root)
    let homeLog = root.appending(path: "homes")
    let binary = try self.script(
      in: root, body: "echo \"$HOME\" >> '\(homeLog.path)'\nexec /bin/sleep 30")
    let fetcher = AntigravityQuotaFetcher(
      environment: ["ANTIGRAVITY_CLI_PATH": binary.path],
      dataLoader: { _ in throw URLError(.notConnectedToInternet) })
    let tasks = (0..<2).map { _ in Task { try await fetcher.fetch(manager: manager) } }
    defer { tasks.forEach { $0.cancel() } }
    let deadline = Date().addingTimeInterval(5)
    var homes: [String] = []
    while Date() < deadline {
      homes = (try? self.read(homeLog).components(separatedBy: "\n")) ?? []
      if homes.count == 2 { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    tasks.forEach { $0.cancel() }
    for task in tasks {
      do {
        _ = try await task.value
        XCTFail("Cancelled CLI returned a snapshot")
      } catch is CancellationError {}
    }
    XCTAssertEqual(Set(homes).count, 2)
    XCTAssertTrue(homes.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
  }

  func testAmbientUsesOnlyTheConfiguredCLIAndDoesNotClaimAnAccount() async throws {
    let root = try self.directory()
    let binary = try self.script(
      in: root,
      body: """
        [ "$HOME" = '\(root.path)' ] && [ "$BROWSER" = /usr/bin/false ] || exit 1
        open && exit 2
        echo '\(Self.cliOutput)'
        """)
    let fetcher = CodexBarQuotaFetcher(environment: [
      "HOME": root.path, "PATH": "/usr/bin:/bin", "ANTIGRAVITY_CLI_PATH": binary.path,
    ])
    let snapshot = try await fetcher.fetch(.antigravity)
    XCTAssertEqual(snapshot.source, "agy-cli-ambient")
    XCTAssertNil(snapshot.accountEmail)
    XCTAssertNil(snapshot.accountPlan)
  }

  private nonisolated static let weeklyBucket =
    #"{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.4997}"#
  private nonisolated static let bothBuckets =
    weeklyBucket + "," + #"{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.4212}"#
  private nonisolated static let otherBuckets =
    #"{"bucketId":"3p-weekly","window":"weekly","remainingFraction":1},{"bucketId":"gemini-argon-5h","window":"5h","remainingFraction":1},{"bucketId":"gemini-5h","window":"5h","remainingFraction":1,"disabled":true}"#
  private nonisolated static let cliOutput =
    #"{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini","buckets":[{"id":"gemini-5h","name":"5h","window":"5h","remaining_fraction":0.31},{"id":"gemini-weekly","name":"weekly","window":"weekly","remaining_fraction":0.18}]}]}}}"#

  private static func remote(buckets: String, token: String = "access-fixture")
    -> GoogleOAuth.Transport
  {
    { request in
      let url = try XCTUnwrap(request.url)
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
      let json: String
      switch url.path {
      case "/v1internal:loadCodeAssist":
        json =
          #"{"paidTier":{"id":"standard-tier","name":"Google AI Pro"},"cloudaicompanionProject":"fixture-project"}"#
      case "/v1internal:retrieveUserQuotaSummary":
        json = #"{"groups":[{"displayName":"Gemini Models","buckets":["# + buckets + "]}]}"
      default:
        XCTFail("Unexpected request " + url.path)
        throw URLError(.unsupportedURL)
      }
      let response = try XCTUnwrap(
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
      return (Data(json.utf8), response)
    }
  }

  private func manager(at root: URL, expired: Bool = false) async throws -> GoogleAccountManager {
    let credentials = AntigravityOAuthCredentials(
      accessToken: "access-fixture", refreshToken: "refresh-fixture",
      expiryDate: Date().addingTimeInterval(expired ? -100 : 3600), email: self.email)
    let manager = GoogleAccountManager(
      fileURL: root.appending(path: "accounts.json"), login: { credentials })
    try await manager.addAccount()
    return manager
  }

  private func directory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "QuotaFloat-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }

  private func script(in root: URL, version: String = "1.5.14", body: String) throws -> URL {
    let binary = root.appending(path: "agy-fixture")
    let versionProbe = #"if [ "$1" = "--version" ]; then echo '\#(version)'; exit 0; fi"#
    try ("#!/bin/sh\n" + versionProbe + "\n" + body + "\n").write(to: binary, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    return binary
  }

  private func read(_ file: URL) throws -> String {
    try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
