import AppKit
import CodexBarCore
import CryptoKit
import Foundation

enum GoogleOAuthError: LocalizedError {
  case missingClient, browser, timeout, callback, denied, invalidToken, missingEmail
  case revokedGrant, requestFailed(Int)

  var errorDescription: String? {
    switch self {
    case .missingClient: "未找到 Antigravity 的 Google 登录客户端，请安装或更新 Antigravity 后重试。"
    case .browser: "无法打开浏览器进行 Google 登录。"
    case .timeout: "Google 登录已超时，请重新添加账号。"
    case .callback: "无法接收本机的 Google 登录回调，请重试。"
    case .denied: "Google 授权未完成，请重新添加账号。"
    case .invalidToken: "Google 未返回可用的凭据，请重新授权。"
    case .missingEmail: "无法从 Google 确认账号邮箱，请重新授权。"
    case .revokedGrant: "Google 授权已失效（invalid_grant），请重新绑定账号。"
    case .requestFailed(let status): "Google 授权请求失败（HTTP \(status)），请检查网络或重新授权。"
    }
  }
}

enum GoogleOAuth {
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
  private static let session = URLSession(
    configuration: .ephemeral, delegate: CredentialRedirectGuard(), delegateQueue: nil)
  static let transport: Transport = { try await session.data(for: $0) }

  private struct Token: Decodable {
    let access_token: String
    let refresh_token: String?
    let id_token: String?
    let expires_in: Int?
  }

  private static func resolvedClient() async throws -> AntigravityOAuthClient {
    // Discovery reads installed application resources. Keep it off the menu's main actor.
    guard
      let client = await Task.detached(
        priority: .userInitiated,
        operation: {
          AntigravityOAuthConfig.resolvedClient()
        }
      ).value
    else { throw GoogleOAuthError.missingClient }
    try Task.checkCancellation()
    return client
  }

  @MainActor
  static func login() async throws -> AntigravityOAuthCredentials {
    let client = try await resolvedClient()
    let state = UUID().uuidString
    let verifier = UUID().uuidString + UUID().uuidString
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
      .replacingOccurrences(of: "=", with: "")
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
    let (redirect, code) = try await GoogleOAuthLoopback().authorize(state: state) { callback in
      let url = try authorizationURL(
        client: client, redirect: callback, state: state, challenge: challenge)
      guard NSWorkspace.shared.open(url) else { throw GoogleOAuthError.browser }
    }
    return try await exchange(
      client: client, redirect: redirect, code: code, verifier: verifier, send: transport)
  }

  static func authorizationURL(
    client: AntigravityOAuthClient, redirect: URL, state: String, challenge: String
  ) throws -> URL {
    var components = URLComponents(
      url: AntigravityOAuthConfig.authURL, resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "client_id", value: client.clientID),
      URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: AntigravityOAuthConfig.scopes.joined(separator: " ")),
      URLQueryItem(name: "access_type", value: "offline"),
      URLQueryItem(name: "prompt", value: "select_account consent"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "code_challenge", value: challenge),
    ]
    guard let url = components?.url else { throw GoogleOAuthError.browser }
    return url
  }

  static func exchange(
    client: AntigravityOAuthClient, redirect: URL, code: String, verifier: String, send: Transport
  ) async throws -> AntigravityOAuthCredentials {
    let token = try await requestToken(
      client,
      fields: [
        "code": code, "redirect_uri": redirect.absoluteString, "grant_type": "authorization_code",
        "code_verifier": verifier,
      ], send: send)
    guard let refresh = token.refresh_token, !refresh.isEmpty, let seconds = token.expires_in,
      seconds > 0
    else {
      throw GoogleOAuthError.invalidToken
    }
    let email = try await userEmail(accessToken: token.access_token, send: send)
    return AntigravityOAuthCredentials(
      accessToken: token.access_token, refreshToken: refresh,
      expiryDate: Date().addingTimeInterval(Double(seconds)),
      idToken: token.id_token, email: email, clientID: client.clientID,
      clientSecret: client.clientSecret)
  }

  static func userEmail(accessToken: String) async throws -> String {
    try await userEmail(accessToken: accessToken, send: transport)
  }

  private static func userEmail(accessToken: String, send: Transport) async throws -> String {
    struct UserInfo: Decodable {
      let email: String
      let verified_email: Bool?
    }
    var request = URLRequest(url: AntigravityOAuthConfig.userInfoURL, timeoutInterval: 15)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    let data = try await checkedResponse(request, send: send)
    guard let user = try? JSONDecoder().decode(UserInfo.self, from: data),
      user.verified_email != false
    else { throw GoogleOAuthError.missingEmail }
    let email = user.email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !email.isEmpty else { throw GoogleOAuthError.missingEmail }
    return email
  }

  static func refresh(_ credentials: AntigravityOAuthCredentials) async throws
    -> AntigravityOAuthCredentials
  {
    try await refresh(credentials, send: transport)
  }

  static func refresh(_ credentials: AntigravityOAuthCredentials, send: Transport) async throws
    -> AntigravityOAuthCredentials
  {
    guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
      throw GoogleOAuthError.invalidToken
    }
    let client: AntigravityOAuthClient
    if let id = credentials.clientID, !id.isEmpty, let secret = credentials.clientSecret,
      !secret.isEmpty
    {
      client = AntigravityOAuthClient(clientID: id, clientSecret: secret)
    } else {
      client = try await resolvedClient()
    }
    let token = try await requestToken(
      client, fields: ["grant_type": "refresh_token", "refresh_token": refreshToken], send: send)
    var updated = credentials
    updated.accessToken = token.access_token
    if let rotated = token.refresh_token, !rotated.isEmpty { updated.refreshToken = rotated }
    if let idToken = token.id_token, !idToken.isEmpty { updated.idToken = idToken }
    if let seconds = token.expires_in {
      guard seconds > 0 else { throw GoogleOAuthError.invalidToken }
      updated.expiryDateMilliseconds =
        Date().addingTimeInterval(Double(seconds)).timeIntervalSince1970 * 1000
    }
    return updated
  }

  private static func requestToken(
    _ client: AntigravityOAuthClient, fields: [String: String], send: Transport
  ) async throws -> Token {
    var fields = fields
    fields["client_id"] = client.clientID
    fields["client_secret"] = client.clientSecret
    let unreserved = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let body = try fields.sorted(by: { $0.key < $1.key }).map { key, value in
      guard let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) else {
        throw GoogleOAuthError.invalidToken
      }
      return "\(key)=\(encoded)"
    }.joined(separator: "&")
    var request = URLRequest(url: AntigravityOAuthConfig.tokenURL, timeoutInterval: 30)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(body.utf8)
    let data = try await checkedResponse(request, send: send)
    guard let token = try? JSONDecoder().decode(Token.self, from: data), !token.access_token.isEmpty
    else {
      throw GoogleOAuthError.invalidToken
    }
    return token
  }

  private static func checkedResponse(_ request: URLRequest, send: Transport) async throws -> Data {
    let (data, response) = try await send(request)
    guard let response = response as? HTTPURLResponse else { throw GoogleOAuthError.invalidToken }
    guard response.statusCode == 200 else {
      struct OAuthFailure: Decodable { let error: String }
      if request.url == AntigravityOAuthConfig.tokenURL, response.statusCode == 400,
        (try? JSONDecoder().decode(OAuthFailure.self, from: data))?.error == "invalid_grant"
      {
        throw GoogleOAuthError.revokedGrant
      }
      throw GoogleOAuthError.requestFailed(response.statusCode)
    }
    return data
  }
}
