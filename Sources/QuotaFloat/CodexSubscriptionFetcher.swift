import Foundation

struct CodexSubscriptionCheck: Codable, Equatable, Sendable {
  let metadata: CodexSubscriptionMetadata?
  let attemptedAt: Date
  let message: String?

  static func resolve(
    record: CodexSubscriptionMetadata?, snapshot: QuotaSnapshot?, accountKey: String?
  ) -> CodexSubscriptionMetadata? {
    guard let accountKey, snapshot?.accountKey == accountKey,
      let check = snapshot?.subscriptionCheck
    else { return record }
    return check.metadata ?? record
  }
}

protocol CodexSubscriptionTransport: Sendable {
  func read(_ request: URLRequest) async throws -> (Data, Int)
}

final class CredentialRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

struct SystemCodexSubscriptionTransport: CodexSubscriptionTransport {
  func read(_ request: URLRequest) async throws -> (Data, Int) {
    let session = URLSession(
      configuration: .ephemeral, delegate: CredentialRedirectGuard(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, data.count < 1_000_000 else {
      throw URLError(.badServerResponse)
    }
    return (data, http.statusCode)
  }
}

actor CodexSubscriptionFetcher {
  static let shared = CodexSubscriptionFetcher()
  private let transport: any CodexSubscriptionTransport
  private var checks: [String: CodexSubscriptionCheck] = [:]

  init(transport: any CodexSubscriptionTransport = SystemCodexSubscriptionTransport()) {
    self.transport = transport
  }

  func fetch(accessToken: String, accountID: String, accountKey: String, now: Date = Date())
    async throws -> CodexSubscriptionCheck
  {
    try Task.checkCancellation()
    if let previous = checks[accountKey], now >= previous.attemptedAt,
      now.timeIntervalSince(previous.attemptedAt) < (previous.message == nil ? 3600 : 600)
    {
      return previous
    }
    var components = URLComponents(string: "https://chatgpt.com/backend-api/subscriptions")!
    components.queryItems = [URLQueryItem(name: "account_id", value: accountID)]
    var request = URLRequest(
      url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
    let check: CodexSubscriptionCheck
    do {
      let (data, status) = try await transport.read(request)
      try Task.checkCancellation()
      guard status == 200 else { throw SubscriptionError.http(status) }
      check = CodexSubscriptionCheck(
        metadata: try Self.parse(data, accountID: accountID, now: now), attemptedAt: now,
        message: nil)
    } catch {
      try Task.checkCancellation()
      let reason = (error as? SubscriptionError)?.message ?? "订阅查询失败，稍后自动重试"
      check = CodexSubscriptionCheck(
        metadata: checks[accountKey]?.metadata?.markingCached(), attemptedAt: now, message: reason)
    }
    checks[accountKey] = check
    return check
  }

  static func parse(_ data: Data, accountID: String, now: Date) throws -> CodexSubscriptionMetadata
  {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw SubscriptionError.missingDate
    }
    if let returnedID = CodexJWTDecoder.string(from: json["account_id"]), returnedID != accountID {
      throw SubscriptionError.accountMismatch
    }
    guard let until = CodexJWTDecoder.date(from: json["active_until"] ?? json["expires_at"]) else {
      throw SubscriptionError.missingDate
    }
    // The API's active period is not the original purchase or a promised renewal date.
    return CodexSubscriptionMetadata(
      activeStart: nil, activeUntil: until, lastChecked: now,
      source: .subscriptionAPI, freshness: .fresh)
  }

  private enum SubscriptionError: Error {
    case http(Int)
    case missingDate, accountMismatch
    var message: String {
      switch self {
      case .http(401), .http(403): "订阅接口未授权；不影响额度读取"
      case .http(429): "订阅查询限流，稍后自动重试"
      case .http: "订阅接口暂不可用，稍后自动重试"
      case .missingDate: "订阅接口未提供有效期"
      case .accountMismatch: "订阅账号不匹配，已忽略返回日期"
      }
    }
  }
}
