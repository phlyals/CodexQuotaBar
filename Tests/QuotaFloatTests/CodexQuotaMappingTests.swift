import CodexBarCore
import XCTest

@testable import QuotaFloat

final class CodexQuotaMappingTests: XCTestCase {
  func testMapsSparkWindowsByMeaningInsteadOfArrayOrder() {
    let now = Date(timeIntervalSince1970: 10_000)
    let weekly = NamedRateWindow(
      id: "codex-spark-weekly",
      title: "Codex Spark Weekly",
      window: RateWindow(
        usedPercent: 12,
        windowMinutes: 10_080,
        resetsAt: now.addingTimeInterval(10_080 * 60),
        resetDescription: nil))
    let session = NamedRateWindow(
      id: "codex-spark",
      title: "Codex Spark 5-hour",
      window: RateWindow(
        usedPercent: 34,
        windowMinutes: 300,
        resetsAt: now.addingTimeInterval(300 * 60),
        resetDescription: nil))
    let usage = UsageSnapshot(
      primary: nil,
      secondary: nil,
      extraRateWindows: [weekly, session],
      updatedAt: now)

    let mapped = CodexBarQuotaFetcher.mapSparkWindows(usage)

    XCTAssertEqual(mapped.weekly?.usedPercent, 12)
    XCTAssertEqual(mapped.weekly?.windowMinutes, 10_080)
    XCTAssertEqual(mapped.session?.usedPercent, 34)
    XCTAssertEqual(mapped.session?.windowMinutes, 300)
  }

  func testCreditsBalanceStaysSeparateFromResetCreditCount() {
    let snapshot = QuotaSnapshot(
      provider: .codex,
      session: nil,
      weekly: nil,
      creditsRemaining: 2731.73,
      creditsUpdatedAt: Date(timeIntervalSince1970: 10_000),
      resetCredits: QuotaResetCredits(availableCount: 0, expirationDates: []),
      accountEmail: "user@example.com",
      source: "oauth",
      updatedAt: Date(timeIntervalSince1970: 10_000),
      freshness: .fresh,
      message: nil)

    XCTAssertEqual(snapshot.creditsRemaining, 2731.73)
    XCTAssertEqual(snapshot.resetCredits?.availableCount, 0)
    XCTAssertTrue(snapshot.hasQuotaData)
  }
}
