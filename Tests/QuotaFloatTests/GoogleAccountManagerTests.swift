import CodexBarCore
import Foundation
import XCTest

@testable import QuotaFloat

final class GoogleAccountManagerTests: XCTestCase {
  @MainActor
  private final class LoginFixture {
    var credentials: AntigravityOAuthCredentials
    init(_ credentials: AntigravityOAuthCredentials) { self.credentials = credentials }
  }

  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func fixture(_ email: String, token: String = "first")
    -> AntigravityOAuthCredentials
  {
    AntigravityOAuthCredentials(
      accessToken: token, refreshToken: "refresh", expiryDate: Date(timeIntervalSince1970: 123),
      email: email, projectID: "project", clientID: "client", clientSecret: "local-test")
  }

  @MainActor
  func testAccountSelectionPersistenceReloginAndRemoval() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "store.json")
    let login = LoginFixture(Self.fixture("alice@example.com"))
    let manager = GoogleAccountManager(fileURL: file) { login.credentials }
    var changes = 0
    manager.onSelectionChange = { changes += 1 }
    XCTAssertNil(try manager.accountForFetch())
    try await manager.addAccount()
    let alice = try XCTUnwrap(manager.selectedAccount)
    login.credentials = Self.fixture("bob@example.com", token: "second")
    try await manager.addAccount()
    let bob = try XCTUnwrap(manager.selectedAccount)
    XCTAssertNotEqual(alice.id, bob.id)
    let restored = GoogleAccountManager(fileURL: file)
    XCTAssertEqual(restored.accounts, manager.accounts)
    XCTAssertEqual(try restored.accountForFetch(), bob)
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)

    try manager.selectAccount(id: alice.id)
    XCTAssertEqual(try GoogleAccountManager(fileURL: file).accountForFetch(), alice)
    login.credentials = Self.fixture("ALICE@example.com", token: "reauth")
    try await manager.addAccount()
    XCTAssertEqual(manager.accounts.count, 2)
    XCTAssertEqual(manager.selectedAccount?.id, alice.id)
    XCTAssertEqual(manager.selectedAccount?.addedAt, alice.addedAt)
    XCTAssertEqual(manager.selectedAccount?.credentials, login.credentials)
    XCTAssertEqual(changes, 4)

    try manager.removeAccount(id: bob.id)
    XCTAssertEqual(changes, 4)
    try manager.removeAccount(id: alice.id)
    XCTAssertEqual(changes, 5)
    XCTAssertNil(try GoogleAccountManager(fileURL: file).accountForFetch())
    XCTAssertTrue(manager.accounts.isEmpty)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["store.json"])
  }

  @MainActor
  func testRemovingSelectedAccountReturnsToAutomaticEvenWithAnotherAccount() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "accounts")
    let login = LoginFixture(Self.fixture("alice@example.com"))
    let manager = GoogleAccountManager(fileURL: file) { login.credentials }
    try await manager.addAccount()
    login.credentials = Self.fixture("bob@example.com")
    try await manager.addAccount()
    try manager.removeAccount(id: XCTUnwrap(manager.selectedAccountID))
    let restored = GoogleAccountManager(fileURL: file)
    XCTAssertEqual(restored.accounts.map(\.email), ["alice@example.com"])
    XCTAssertNil(try restored.accountForFetch())
    XCTAssertThrowsError(try manager.selectAccount(id: UUID()))
  }

  @MainActor
  func testRefreshRejectsWrongIdentityAndStaleTokensAndPreservesSelection() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "accounts")
    let alice = Self.fixture("alice@example.com")
    let manager = GoogleAccountManager(fileURL: file) { alice }
    try await manager.addAccount()
    let id = try XCTUnwrap(manager.selectedAccountID)
    var changed = false
    manager.onSelectionChange = { changed = true }
    let refreshed = Self.fixture("alice@example.com", token: "fresh")
    try manager.updateCredentials(for: id, credentials: refreshed, replacing: alice)
    XCTAssertFalse(changed)
    XCTAssertThrowsError(
      try manager.updateCredentials(for: id, credentials: alice, replacing: alice))
    XCTAssertThrowsError(
      try manager.updateCredentials(for: id, credentials: Self.fixture("bob@example.com")))
    XCTAssertEqual(
      try GoogleAccountManager(fileURL: file).accountForFetch()?.credentials, refreshed)
  }

  @MainActor
  func testUnreadableCorruptAndDanglingSelectionDoNotUseAutomaticOrOverwriteData() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "accounts")
    let badStates = [
      "{}", #"{"accounts":[],"selectedAccountID":"00000000-0000-0000-0000-000000000000"}"#,
    ]
    for original in badStates {
      try Data(original.utf8).write(to: file)
      let manager = GoogleAccountManager(fileURL: file) {
        XCTFail("login must stay closed")
        throw GoogleAccountError.unavailable
      }
      XCTAssertNotNil(manager.loadError)
      XCTAssertThrowsError(try manager.accountForFetch())
      XCTAssertThrowsError(try manager.selectAccount(id: nil))
      do {
        try await manager.addAccount()
        XCTFail("expected failure")
      } catch {}
      XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
    }
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    XCTAssertThrowsError(try GoogleAccountManager(fileURL: file).accountForFetch())
  }

  @MainActor
  func testFailedWriteDoesNotPublishNewSelection() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "accounts")
    let manager = GoogleAccountManager(fileURL: file) { Self.fixture("alice@example.com") }
    try await manager.addAccount()
    let id = manager.selectedAccountID
    var changed = false
    manager.onSelectionChange = { changed = true }
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    XCTAssertThrowsError(try manager.selectAccount(id: nil))
    XCTAssertEqual(manager.selectedAccountID, id)
    XCTAssertFalse(changed)
  }

  private static func response(_ json: String, to request: URLRequest, status: Int = 200) throws
    -> (Data, URLResponse)
  {
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: XCTUnwrap(request.url), statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
    )
    return (Data(json.utf8), response)
  }

  func testAuthorizationAndCodeExchangeUseOfflineConsentPKCEFormEncodingAndGoogleEmail()
    async throws
  {
    let client = AntigravityOAuthClient(clientID: "fixture", clientSecret: "test+&=")
    let redirect = try XCTUnwrap(URL(string: "http://127.0.0.1:12345/callback"))
    let authURL = try GoogleOAuth.authorizationURL(
      client: client, redirect: redirect, state: "chosen", challenge: "proof")
    let items = try XCTUnwrap(
      URLComponents(url: authURL, resolvingAgainstBaseURL: false)?.queryItems)
    let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(query["state"], "chosen")
    XCTAssertEqual(query["prompt"], "select_account consent")
    XCTAssertEqual(query["access_type"], "offline")
    XCTAssertEqual(query["code_challenge_method"], "S256")
    XCTAssertEqual(query["code_challenge"], "proof")
    XCTAssertEqual(query["redirect_uri"], redirect.absoluteString)
    XCTAssertNil(query["client_secret"])

    let credentials = try await GoogleOAuth.exchange(
      client: client, redirect: redirect, code: "x+=& %", verifier: "verify"
    ) { request in
      if request.url == AntigravityOAuthConfig.tokenURL {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(body.contains("code=x%2B%3D%26%20%25"))
        XCTAssertTrue(body.contains("client_secret=test%2B%26%3D"))
        XCTAssertTrue(body.contains("code_verifier=verify"))
        return try Self.response(
          #"{"access_token":"token","refresh_token":"refresh","expires_in":3600}"#, to: request)
      }
      XCTAssertEqual(request.url, AntigravityOAuthConfig.userInfoURL)
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
      return try Self.response(
        #"{"email":"google@example.com","verified_email":true}"#, to: request)
    }
    XCTAssertEqual(credentials.email, "google@example.com")
    XCTAssertEqual(credentials.refreshToken, "refresh")
    XCTAssertEqual(credentials.clientID, "fixture")
  }

  func testRevokedRefreshGrantRequiresReauthorization() async throws {
    do {
      _ = try await GoogleOAuth.refresh(Self.fixture("reader@example.test")) { request in
        let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 400,
          httpVersion: nil, headerFields: nil))
        return (Data(#"{"error":"invalid_grant"}"#.utf8), response)
      }
      XCTFail("A revoked grant must not produce credentials")
    } catch GoogleOAuthError.revokedGrant {}
  }

  func testMissingGoogleEmailCannotCreateCredentials() async throws {
    let redirect = try XCTUnwrap(URL(string: "http://127.0.0.1:23456/callback"))
    do {
      _ = try await GoogleOAuth.exchange(
        client: .init(clientID: "client", clientSecret: "test"), redirect: redirect, code: "code",
        verifier: "verify"
      ) { request in
        try Self.response(
          request.url == AntigravityOAuthConfig.tokenURL
            ? #"{"access_token":"token","refresh_token":"refresh","expires_in":3600}"# : "{}",
          to: request)
      }
      XCTFail("expected missing email")
    } catch GoogleOAuthError.missingEmail {}
  }

  func testRefreshPreservesOmittedFieldsAndAcceptsRotatedTokens() async throws {
    var old = Self.fixture("alice@example.com")
    old.idToken = "old-id"
    let next = try await GoogleOAuth.refresh(old) { request in
      XCTAssertEqual(request.url, AntigravityOAuthConfig.tokenURL)
      XCTAssertTrue(
        String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains(
          "grant_type=refresh_token"))
      return try Self.response(#"{"access_token":"new"}"#, to: request)
    }
    var expected = old
    expected.accessToken = "new"
    XCTAssertEqual(next, expected)
    let rotated = try await GoogleOAuth.refresh(next) { request in
      try Self.response(
        #"{"access_token":"rotated","refresh_token":"new-refresh","id_token":"new-id","expires_in":3600}"#,
        to: request)
    }
    XCTAssertEqual(rotated.refreshToken, "new-refresh")
    XCTAssertEqual(rotated.idToken, "new-id")
    XCTAssertGreaterThan(try XCTUnwrap(rotated.expiryDate), Date())
    XCTAssertEqual(rotated.email, old.email)
    XCTAssertEqual(rotated.projectID, old.projectID)
  }

  @MainActor
  func testLoopbackRejectsNoiseAndAcceptsOnlyBoundPortAndMatchingState() async throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    var browser: Task<Void, Error>?
    let (url, code) = try await GoogleOAuthLoopback().authorize(
      state: "active", timeout: .seconds(8)
    ) { url in
      browser = Task {
        for (state, status) in [("stale", 400), ("active", 200)] {
          let request = url.appending(queryItems: [
            .init(name: "code", value: "test-code"), .init(name: "state", value: state),
          ])
          let (_, response) = try await session.data(from: request)
          XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
        }
      }
    }
    try await browser?.value
    XCTAssertEqual(url.host, "127.0.0.1")
    XCTAssertGreaterThan(try XCTUnwrap(url.port), 0)
    XCTAssertEqual(code, "test-code")

    let header = "GET /callback?code=x&state=active HTTP/1.1\r\nHost: 127.0.0.1:12345"
    XCTAssertNil(GoogleOAuthLoopback.parse(header: header, state: "active", port: 23456))
    XCTAssertNil(
      GoogleOAuthLoopback.parse(
        header: header.replacingOccurrences(of: "GET", with: "POST"), state: "active", port: 12345))
    XCTAssertNil(
      GoogleOAuthLoopback.parse(
        header: header.replacingOccurrences(of: "&state=active", with: ""), state: "active",
        port: 12345))
    let denied = header.replacingOccurrences(of: "code=x", with: "error=access_denied")
    let answer = try XCTUnwrap(
      GoogleOAuthLoopback.parse(header: denied, state: "active", port: 12345))
    XCTAssertThrowsError(try answer.get())
  }

  @MainActor
  func testLoopbackTimesOutWithoutBrowserResponse() async throws {
    do {
      _ = try await GoogleOAuthLoopback().authorize(state: "active", timeout: .milliseconds(100)) {
        _ in
      }
      XCTFail("expected timeout")
    } catch GoogleOAuthError.timeout {}
  }
}
