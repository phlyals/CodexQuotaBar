import Foundation

enum QuotaProvider: String, Codable, CaseIterable, Identifiable, Sendable {
  case codex
  case antigravity

  var id: String { self.rawValue }

  var displayName: String {
    self.definition.displayName
  }
}

enum QuotaPaceStatus: String, Equatable, Sendable {
  case roomy = "宽裕"
  case normal = "正常"
  case fast = "偏快"
  case urgent = "告急"
  case exhausted = "耗尽"
}

struct QuotaPaceEvaluation: Equatable, Sendable {
  let status: QuotaPaceStatus
  let idealRemainingPercent: Double
  let deltaPercent: Double
}

struct QuotaWindow: Codable, Equatable, Sendable {
  let usedPercent: Double
  let resetsAt: Date?
  let windowMinutes: Int?

  init(usedPercent: Double, resetsAt: Date?, windowMinutes: Int?) {
    self.usedPercent = usedPercent
    self.resetsAt = resetsAt
    self.windowMinutes = windowMinutes
  }

  var remainingPercent: Double {
    max(0, 100 - self.usedPercent)
  }

  var isValid: Bool { self.usedPercent.isFinite && (0...100).contains(self.usedPercent) }

  func paceEvaluation(now: Date) -> QuotaPaceEvaluation? {
    if self.remainingPercent == 0 {
      return QuotaPaceEvaluation(
        status: .exhausted,
        idealRemainingPercent: 0,
        deltaPercent: 0)
    }

    guard
      let resetsAt = self.resetsAt,
      let windowMinutes = self.windowMinutes,
      windowMinutes > 0
    else {
      return nil
    }

    let duration = TimeInterval(windowMinutes) * 60
    let secondsRemaining = resetsAt.timeIntervalSince(now)
    guard secondsRemaining > 0, secondsRemaining <= duration else { return nil }

    let idealRemaining = min(100, max(0, secondsRemaining / duration * 100))
    let delta = self.remainingPercent - idealRemaining
    let status: QuotaPaceStatus
    if delta >= 5 {
      status = .roomy
    } else if delta > -5 {
      status = .normal
    } else if delta >= -50 {
      status = .fast
    } else {
      status = .urgent
    }

    return QuotaPaceEvaluation(
      status: status,
      idealRemainingPercent: idealRemaining,
      deltaPercent: delta)
  }
}

struct QuotaResetCredits: Codable, Equatable, Sendable {
  let availableCount: Int
  let expirationDates: [Date]
  var details: [QuotaResetCredit]? = nil

  init(availableCount: Int, expirationDates: [Date]) {
    self.availableCount = max(0, availableCount)
    self.expirationDates = expirationDates.sorted()
  }

  var nextExpirationDate: Date? {
    self.expirationDates.first
  }
}

struct QuotaResetCredit: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let status: String
  let expiresAt: Date?
  let scope: String

  func isAvailable(now: Date) -> Bool {
    self.status == "available" && (self.expiresAt.map { $0 > now } ?? true)
  }
}

enum QuotaFreshness: String, Codable, Equatable, Sendable {
  case fresh
  case cached
  case stale
  case authRequired
  case unavailable
}

struct QuotaNamedWindow: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let title: String
  let window: QuotaWindow
}

struct QuotaSnapshot: Codable, Equatable, Identifiable, Sendable {
  let provider: QuotaProvider
  let session: QuotaWindow?
  let weekly: QuotaWindow?
  let sparkSession: QuotaWindow?
  let sparkWeekly: QuotaWindow?
  let extraWindows: [QuotaNamedWindow]?
  let creditsRemaining: Double?
  let creditsUnlimited: Bool?
  let creditsUpdatedAt: Date?
  let subscriptionExpiresAt: Date?
  let subscriptionRenewsAt: Date?
  var subscriptionCheck: CodexSubscriptionCheck? = nil
  let resetCredits: QuotaResetCredits?
  let accountEmail: String?
  let accountKey: String?
  let accountPlan: String?
  let source: String
  let updatedAt: Date
  let freshness: QuotaFreshness
  let message: String?

  var id: QuotaProvider { self.provider }

  var hasQuotaData: Bool {
    self.session != nil
      || self.weekly != nil
      || self.sparkSession != nil
      || self.sparkWeekly != nil
      || !(self.extraWindows?.isEmpty ?? true)
      || self.creditsRemaining != nil
      || self.creditsUnlimited == true
      || self.resetCredits != nil
  }

  init(
    provider: QuotaProvider,
    session: QuotaWindow?,
    weekly: QuotaWindow?,
    sparkSession: QuotaWindow? = nil,
    sparkWeekly: QuotaWindow? = nil,
    extraWindows: [QuotaNamedWindow]? = nil,
    creditsRemaining: Double? = nil,
    creditsUnlimited: Bool? = nil,
    creditsUpdatedAt: Date? = nil,
    subscriptionExpiresAt: Date? = nil,
    subscriptionRenewsAt: Date? = nil,
    resetCredits: QuotaResetCredits?,
    accountEmail: String?,
    accountKey: String? = nil,
    accountPlan: String? = nil,
    source: String,
    updatedAt: Date,
    freshness: QuotaFreshness,
    message: String?
  ) {
    self.provider = provider
    self.session = session.flatMap { $0.isValid ? $0 : nil }
    self.weekly = weekly.flatMap { $0.isValid ? $0 : nil }
    self.sparkSession = sparkSession.flatMap { $0.isValid ? $0 : nil }
    self.sparkWeekly = sparkWeekly.flatMap { $0.isValid ? $0 : nil }
    let validExtras = extraWindows?.filter { $0.window.isValid }
    self.extraWindows = (validExtras?.isEmpty ?? true) ? nil : validExtras
    self.creditsRemaining = creditsRemaining.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    self.creditsUnlimited = creditsUnlimited
    self.creditsUpdatedAt = creditsUpdatedAt
    self.subscriptionExpiresAt = subscriptionExpiresAt
    self.subscriptionRenewsAt = subscriptionRenewsAt
    self.resetCredits = resetCredits
    self.accountEmail = accountEmail
    self.accountKey = accountKey
    self.accountPlan = accountPlan
    self.source = source
    self.updatedAt = updatedAt
    self.freshness = freshness
    self.message = message
  }

  func markingCached(now: Date = Date(), staleAfter: TimeInterval) -> QuotaSnapshot {
    let age = max(0, now.timeIntervalSince(self.updatedAt))
    return self.replacing(
      freshness: age >= staleAfter ? .stale : .cached,
      message: age >= staleAfter ? "数据超过 5 分钟未更新" : "正在显示上次成功数据")
  }

  func markingFailure(
    _ message: String,
    now: Date = Date(),
    staleAfter: TimeInterval
  ) -> QuotaSnapshot {
    let age = max(0, now.timeIntervalSince(self.updatedAt))
    return self.replacing(
      freshness: age >= staleAfter ? .stale : .cached,
      message: message)
  }

  func replacing(
    freshness: QuotaFreshness, message: String?, accountKey: String? = nil
  ) -> QuotaSnapshot {
    var result = QuotaSnapshot(
      provider: self.provider,
      session: self.session,
      weekly: self.weekly,
      sparkSession: self.sparkSession,
      sparkWeekly: self.sparkWeekly,
      extraWindows: self.extraWindows,
      creditsRemaining: self.creditsRemaining,
      creditsUnlimited: self.creditsUnlimited,
      creditsUpdatedAt: self.creditsUpdatedAt,
      subscriptionExpiresAt: self.subscriptionExpiresAt,
      subscriptionRenewsAt: self.subscriptionRenewsAt,
      resetCredits: self.resetCredits,
      accountEmail: self.accountEmail,
      accountKey: accountKey ?? self.accountKey,
      accountPlan: self.accountPlan,
      source: self.source,
      updatedAt: self.updatedAt,
      freshness: freshness,
      message: message)
    result.subscriptionCheck = self.subscriptionCheck
    return result
  }
}

struct QuotaCache: Codable, Sendable {
  let version: Int
  let snapshots: [QuotaSnapshot]

  init(snapshots: [QuotaSnapshot]) {
    self.version = 2
    self.snapshots = snapshots
  }
}
