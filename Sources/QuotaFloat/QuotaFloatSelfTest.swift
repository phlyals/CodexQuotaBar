import CodexBarCore
import Foundation

@MainActor
enum QuotaFloatSelfTest {
  enum Failure: LocalizedError {
    case assertion(String)

    var errorDescription: String? {
      switch self {
      case .assertion(let message): message
      }
    }
  }

  static func run() throws {
    try self.check(
      KeychainAccessGate.isDisabled,
      "QuotaFloat must keep CodexBarCore keychain access disabled")

    try self.check(
      !QuotaWindow(usedPercent: -10, resetsAt: nil, windowMinutes: 300).isValid,
      "negative usage must be rejected, not converted to full quota")
    try self.check(
      !QuotaWindow(usedPercent: 140, resetsAt: nil, windowMinutes: 300).isValid,
      "usage above 100 must be rejected")
    try self.check(
      !QuotaWindow(usedPercent: .infinity, resetsAt: nil, windowMinutes: 300).isValid,
      "non-finite usage must stay unknown")

    let paceNow = Date(timeIntervalSince1970: 20_000)
    let halfWindowReset = paceNow.addingTimeInterval(150 * 60)
    try self.check(
      QuotaWindow(
        usedPercent: 45,
        resetsAt: halfWindowReset,
        windowMinutes: 300
      ).paceEvaluation(now: paceNow)?.status == .roomy,
      "+5% remaining delta must be roomy")
    try self.check(
      QuotaWindow(
        usedPercent: 50,
        resetsAt: halfWindowReset,
        windowMinutes: 300
      ).paceEvaluation(now: paceNow)?.status == .normal,
      "zero remaining delta must be normal")
    try self.check(
      QuotaWindow(
        usedPercent: 55,
        resetsAt: halfWindowReset,
        windowMinutes: 300
      ).paceEvaluation(now: paceNow)?.status == .fast,
      "-5% remaining delta must be fast")
    try self.check(
      QuotaWindow(
        usedPercent: 70,
        resetsAt: paceNow.addingTimeInterval(240 * 60),
        windowMinutes: 300
      ).paceEvaluation(now: paceNow)?.status == .fast,
      "-50% remaining delta must still be fast")
    try self.check(
      QuotaWindow(
        usedPercent: 80,
        resetsAt: paceNow.addingTimeInterval(240 * 60),
        windowMinutes: 300
      ).paceEvaluation(now: paceNow)?.status == .urgent,
      "remaining delta below -50% must be urgent")
    try self.check(
      QuotaWindow(
        usedPercent: 100,
        resetsAt: nil,
        windowMinutes: 300
      ).paceEvaluation(now: paceNow)?.status == .exhausted,
      "zero actual remaining must always be exhausted")
    try self.check(
      QuotaWindow(
        usedPercent: 20,
        resetsAt: nil,
        windowMinutes: 300
      ).paceEvaluation(now: paceNow) == nil,
      "pace must stay hidden when reset time is unavailable")

    let updatedAt = Date(timeIntervalSince1970: 1_000)
    let snapshot = QuotaSnapshot(
      provider: .codex,
      session: QuotaWindow(usedPercent: 25, resetsAt: nil, windowMinutes: 300),
      weekly: QuotaWindow(usedPercent: 40, resetsAt: nil, windowMinutes: 10_080),
      resetCredits: QuotaResetCredits(
        availableCount: 2,
        expirationDates: [
          updatedAt.addingTimeInterval(7_200),
          updatedAt.addingTimeInterval(3_600),
        ]),
      accountEmail: "user@example.com",
      source: "oauth",
      updatedAt: updatedAt,
      freshness: .fresh,
      message: nil)
    try self.check(
      snapshot.markingCached(
        now: updatedAt.addingTimeInterval(299),
        staleAfter: 300
      ).freshness == .cached,
      "recent cached snapshot must stay cached")
    try self.check(
      snapshot.markingCached(
        now: updatedAt.addingTimeInterval(300),
        staleAfter: 300
      ).freshness == .stale,
      "old cached snapshot must become stale")
    try self.check(
      snapshot.resetCredits?.availableCount == 2,
      "Codex reset-credit count must survive snapshot mapping")
    try self.check(
      snapshot.resetCredits?.nextExpirationDate == updatedAt.addingTimeInterval(3_600),
      "Codex reset-credit expiration dates must be sorted")

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("QuotaFloatSelfTest-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = QuotaCacheStore(fileURL: directory.appendingPathComponent("quota-cache.json"))
    cache.save([snapshot])
    try self.check(cache.load() == [snapshot], "cache round trip must preserve quota data")

    let weeklyOnly = UsageSnapshot(
      primary: RateWindow(
        usedPercent: 30,
        windowMinutes: 10_080,
        resetsAt: nil,
        resetDescription: nil),
      secondary: nil,
      updatedAt: updatedAt)
    let mapped = CodexBarQuotaFetcher.mapWindows(
      weeklyOnly,
      definition: QuotaProvider.codex.definition)
    try self.check(
      mapped.session == nil, "weekly-only data must not be duplicated into the 5-hour lane")
    try self.check(
      mapped.weekly?.windowMinutes == 10_080, "weekly-only data must stay in the weekly lane")

    try self.check(
      QuotaProviderCatalog.orderedProviders == [.codex, .antigravity],
      "provider catalog must include Codex and Google (Antigravity)")

    let contentPreferences = ContentPreferences()
    try self.check(
      contentPreferences.activeProviders == [.codex], "Codex must be active by default")
    contentPreferences.collapse()
    try self.check(
      contentPreferences.activeProviders.isEmpty,
      "collapsed mode must pause all provider refreshes")
    try self.check(
      contentPreferences.designSize == NSSize(width: 126, height: 40),
      "collapsed mode must use the compact brand size")
    contentPreferences.expandAll()
    try self.check(
      contentPreferences.activeProviders == [.codex],
      "expanding globally must restore Codex")

    try self.check(
      CodexAccountManager.credentialStoreMode(
        in: "cli_auth_credentials_store = \"file\" # keep auth portable") == "file",
      "credential storage mode must parse comments safely")

    let refreshNow = Date(timeIntervalSince1970: 10_000)
    let refreshInterval = QuotaStore.defaultRefreshInterval
    try self.check(refreshInterval == 60, "background quota refresh must run every minute")
    try self.check(
      QuotaRefreshPolicy.isDue(
        lastAttemptAt: nil,
        now: refreshNow,
        refreshInterval: refreshInterval),
      "a provider with no request history must refresh immediately")
    try self.check(
      !QuotaRefreshPolicy.isDue(
        lastAttemptAt: refreshNow.addingTimeInterval(1 - refreshInterval),
        now: refreshNow,
        refreshInterval: refreshInterval),
      "background refresh is not due before one minute")
    try self.check(
      QuotaRefreshPolicy.isDue(
        lastAttemptAt: refreshNow.addingTimeInterval(-refreshInterval),
        now: refreshNow,
        refreshInterval: refreshInterval),
      "background refresh is due after one minute")
  }

  private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw Failure.assertion(message) }
  }
}
