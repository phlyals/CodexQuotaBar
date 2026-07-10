import XCTest
@testable import QuotaFloat

final class StatusBarQuotaFormatterTests: XCTestCase {
  func testTitleShowsPlaceholdersBeforeFirstSync() {
    XCTAssertEqual(
      StatusBarQuotaFormatter.display(for: nil, isRefreshing: false),
      StatusBarQuotaDisplay(sessionLine: "5h --", weeklyLine: "W --", iconRemainingPercent: nil))
  }

  func testTitleShowsCodexSessionAndWeeklyRemainingPercent() {
    let snapshot = QuotaSnapshot(
      provider: .codex,
      session: QuotaWindow(usedPercent: 25, resetsAt: nil, windowMinutes: 300),
      weekly: QuotaWindow(usedPercent: 40, resetsAt: nil, windowMinutes: 10_080),
      resetCredits: nil,
      accountEmail: nil,
      source: "oauth",
      updatedAt: Date(timeIntervalSince1970: 1_000),
      freshness: .fresh,
      message: nil)

    XCTAssertEqual(
      StatusBarQuotaFormatter.display(for: snapshot, isRefreshing: false),
      StatusBarQuotaDisplay(sessionLine: "5h 75%", weeklyLine: "W 60%", iconRemainingPercent: 75))
  }

  func testTitleShowsLoginPromptWhenAuthIsRequired() {
    let snapshot = QuotaSnapshot(
      provider: .codex,
      session: nil,
      weekly: nil,
      resetCredits: nil,
      accountEmail: nil,
      source: "auto",
      updatedAt: Date(timeIntervalSince1970: 1_000),
      freshness: .authRequired,
      message: "登录已失效")

    XCTAssertEqual(
      StatusBarQuotaFormatter.display(for: snapshot, isRefreshing: false),
      StatusBarQuotaDisplay(sessionLine: "Codex", weeklyLine: "登录", iconRemainingPercent: 0))
  }

  func testDisplayCarriesActualSessionRemainingPercentForGradient() {
    let snapshot = QuotaSnapshot(
      provider: .codex,
      session: QuotaWindow(usedPercent: 82, resetsAt: nil, windowMinutes: 300),
      weekly: QuotaWindow(usedPercent: 35, resetsAt: nil, windowMinutes: 10_080),
      resetCredits: nil,
      accountEmail: nil,
      source: "oauth",
      updatedAt: Date(timeIntervalSince1970: 1_000),
      freshness: .fresh,
      message: nil)

    XCTAssertEqual(
      StatusBarQuotaFormatter.display(for: snapshot, isRefreshing: false).iconRemainingPercent,
      18)
  }
}
