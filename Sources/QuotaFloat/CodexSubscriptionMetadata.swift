import CodexBarCore
import Foundation

enum CodexSubscriptionSource: String, Codable, Equatable, Sendable {
  case idToken
  case quotaFallback
}

enum CodexSubscriptionFreshness: String, Codable, Equatable, Sendable {
  case fresh
  case cached
  case unknown
}

enum CodexSubscriptionStatus: Equatable, Sendable {
  case active
  case expiringSoon
  case expiresToday
  case expired
  case unknown
}

struct CodexSubscriptionMetadata: Codable, Equatable, Sendable {
  let activeStart: Date?
  let activeUntil: Date?
  let lastChecked: Date?
  let source: CodexSubscriptionSource
  let freshness: CodexSubscriptionFreshness

  func markingCached() -> CodexSubscriptionMetadata {
    CodexSubscriptionMetadata(
      activeStart: self.activeStart,
      activeUntil: self.activeUntil,
      lastChecked: self.lastChecked,
      source: self.source,
      freshness: .cached)
  }

  func status(now: Date = Date(), calendar: Calendar = .current) -> CodexSubscriptionStatus {
    guard let activeUntil = self.activeUntil else { return .unknown }
    if activeUntil <= now { return .expired }
    if calendar.isDate(activeUntil, inSameDayAs: now) { return .expiresToday }
    let remainingDays = Int(ceil(activeUntil.timeIntervalSince(now) / 86_400))
    return remainingDays <= 7 ? .expiringSoon : .active
  }

  func daysRemaining(now: Date = Date()) -> Int? {
    guard let activeUntil = self.activeUntil else { return nil }
    guard activeUntil > now else { return 0 }
    return max(1, Int(ceil(activeUntil.timeIntervalSince(now) / 86_400)))
  }
}

struct CodexAuthState: Equatable, Sendable {
  let identity: CodexAuthIdentity?
  let fingerprint: String?
  let subscription: CodexSubscriptionMetadata?
}

enum CodexAuthChange: Equatable, Sendable {
  case accountChanged
  case credentialsRotated
  case metadataChanged

  static func classify(previous: CodexAuthState, current: CodexAuthState) -> CodexAuthChange? {
    if previous.identity != current.identity { return .accountChanged }
    if previous.fingerprint != current.fingerprint { return .credentialsRotated }
    if previous.subscription != current.subscription { return .metadataChanged }
    return nil
  }
}

enum CodexJWTDecoder {
  static func payload(from token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }

    var encoded = String(parts[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - encoded.count % 4) % 4
    encoded.append(String(repeating: "=", count: padding))

    guard let data = Data(base64Encoded: encoded) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  static func date(from value: Any?) -> Date? {
    if let string = value as? String {
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = fractional.date(from: string) { return date }

      let standard = ISO8601DateFormatter()
      standard.formatOptions = [.withInternetDateTime]
      return standard.date(from: string)
    }

    if let number = value as? NSNumber {
      let raw = number.doubleValue
      guard raw.isFinite, raw > 0 else { return nil }
      return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1_000 : raw)
    }

    return nil
  }

  static func string(from value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

enum CodexSubscriptionMetadataReader {
  static func read(authFileURL: URL) -> CodexAuthState? {
    guard let data = try? Data(contentsOf: authFileURL), !data.isEmpty else { return nil }
    return self.state(from: data, fingerprint: CodexAuthFingerprint.fingerprint(data: data))
  }

  static func state(from data: Data, fingerprint: String? = nil) -> CodexAuthState? {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tokens = root["tokens"] as? [String: Any]
    else {
      return nil
    }

    let idToken = CodexJWTDecoder.string(
      from: tokens["id_token"] ?? tokens["idToken"])
    let payload = idToken.flatMap(CodexJWTDecoder.payload(from:))
    let auth = payload?["https://api.openai.com/auth"] as? [String: Any]

    let accountID =
      CodexJWTDecoder.string(
        from: tokens["account_id"] ?? tokens["accountId"])
      ?? CodexJWTDecoder.string(from: auth?["chatgpt_account_id"])
      ?? CodexJWTDecoder.string(from: payload?["chatgpt_account_id"])
    let email = CodexJWTDecoder.string(from: payload?["email"])
    let identity: CodexAuthIdentity?
    if accountID != nil || email != nil {
      identity = CodexAuthIdentity(accountID: accountID, email: email)
    } else {
      identity = nil
    }

    let activeStart = CodexJWTDecoder.date(
      from: auth?["chatgpt_subscription_active_start"]
        ?? payload?["chatgpt_subscription_active_start"])
    let activeUntil = CodexJWTDecoder.date(
      from: auth?["chatgpt_subscription_active_until"]
        ?? payload?["chatgpt_subscription_active_until"])
    let lastChecked = CodexJWTDecoder.date(
      from: auth?["chatgpt_subscription_last_checked"]
        ?? payload?["chatgpt_subscription_last_checked"])

    let subscription: CodexSubscriptionMetadata?
    if activeStart == nil, activeUntil == nil, lastChecked == nil {
      subscription = nil
    } else {
      let normalizedStart: Date?
      let normalizedUntil: Date?
      if let activeStart, let activeUntil, activeUntil < activeStart {
        normalizedStart = nil
        normalizedUntil = nil
      } else {
        normalizedStart = activeStart
        normalizedUntil = activeUntil
      }
      subscription = CodexSubscriptionMetadata(
        activeStart: normalizedStart,
        activeUntil: normalizedUntil,
        lastChecked: lastChecked,
        source: .idToken,
        freshness: .fresh)
    }

    guard identity != nil || subscription != nil else { return nil }
    return CodexAuthState(
      identity: identity,
      fingerprint: fingerprint,
      subscription: subscription)
  }
}
