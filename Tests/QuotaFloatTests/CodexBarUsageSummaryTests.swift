import XCTest
@testable import QuotaFloat

final class CodexBarUsageSummaryTests: XCTestCase {
  let now = ISO8601DateFormatter().date(from: "2026-09-15T04:00:00Z")!
  var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    return value
  }
  var weekly: QuotaWindow {
    // Cycle begins September 12 at noon local time; the upstream report is day-granular.
    .init(usedPercent: 81, resetsAt: now.addingTimeInterval(4 * 86400), windowMinutes: 10080)
  }
  func usage(_ daily: String, updated: String = "2026-09-15T04:00:00Z") throws -> CodexLocalUsageSnapshot {
    try CodexCostHelper.decode("""
      [{"provider":"codex","source":"local","updatedAt":"\(updated)",
        "historyDays":30,"daily":\(daily)}]
      """)
  }
  func testSumsCodexBarDaysWithoutQuotaScalingOrAddingCacheAgain() throws {
    let source = try usage("""
      [{"date":"2026-09-11","totalTokens":9000000,"totalCost":999},
       {"date":"2026-09-12","totalTokens":1000000,"cacheReadTokens":900000,"totalCost":10},
       {"date":"2026-09-15","totalTokens":2000000,"totalCost":20},
       {"date":"2026-09-16","totalTokens":9000000,"totalCost":999}]
      """)
    let result = CodexBarUsageSummary.calculate(usage: source, weekly: weekly, now: now, calendar: calendar)
    XCTAssertEqual(result.tokens, 3_000_000)
    XCTAssertEqual(result.dollars, 30)
    XCTAssertEqual(result.dateRange, "2026-09-12 – 2026-09-15")
    XCTAssertEqual(result.tokenText, "3.00M Token")
    XCTAssertEqual(result.costText, "$30.00")
    let other = QuotaWindow(usedPercent: 20, resetsAt: weekly.resetsAt, windowMinutes: 10080)
    XCTAssertEqual(CodexBarUsageSummary.calculate(
      usage: source, weekly: other, now: now, calendar: calendar).tokens, result.tokens)
  }

  func testMissingPriceDoesNotUseAveragePriceOrLookLikeCompleteBill() throws {
    let source = try usage("""
      [{"date":"2026-09-12","totalTokens":1000000,"totalCost":10},
       {"date":"2026-09-15","totalTokens":2000000,
        "modelBreakdowns":[{"modelName":"unknown","totalTokens":2000000}]}]
      """)
    let result = CodexBarUsageSummary.calculate(usage: source, weekly: weekly, now: now, calendar: calendar)
    XCTAssertEqual(result.tokens, 3_000_000)
    XCTAssertEqual(result.dollars, 10)
    XCTAssertTrue(result.partialPricing)
    XCTAssertEqual(result.costText, "$10.00（部分）")
  }

  func testPartialModelPricingSurvivesUpstreamDailyTotal() throws {
    let source = try usage("""
      [{"date":"2026-09-15","totalTokens":2000000,"totalCost":20,
        "modelBreakdowns":[{"modelName":"unknown","totalTokens":1000000}]}]
      """)
    XCTAssertTrue(CodexBarUsageSummary.calculate(
      usage: source, weekly: weekly, now: now, calendar: calendar).partialPricing)
  }

  func testUnpricedActivityDoesNotBecomeZeroDueToEmptyDays() throws {
    let source = try usage("""
      [{"date":"2026-09-15","totalTokens":2000000}]
      """)
    let result = CodexBarUsageSummary.calculate(usage: source, weekly: weekly, now: now, calendar: calendar)
    XCTAssertEqual(result.tokens, 2_000_000)
    XCTAssertNil(result.dollars)
    XCTAssertEqual(result.costText, "价格缺失")
  }

  func testMissingReportOrExpiredWindowDoesNotFabricateZero() {
    XCTAssertNil(CodexBarUsageSummary.calculate(usage: nil, weekly: weekly, now: now).tokens)
    let expired = QuotaWindow(usedPercent: 81, resetsAt: now, windowMinutes: 10080)
    XCTAssertNil(CodexBarUsageSummary.calculate(usage: nil, weekly: expired, now: now).dateRange)
  }

  func testOldScanCannotBecomeNewCycleAndOldScanIsMarked() throws {
    let old = try usage("[]", updated: "2026-09-11T04:00:00Z")
    XCTAssertNil(CodexBarUsageSummary.calculate(
      usage: old, weekly: weekly, now: now, calendar: calendar).tokens)
    let stale = try usage("[]", updated: "2026-09-14T04:00:00Z")
    let result = CodexBarUsageSummary.calculate(usage: stale, weekly: weekly, now: now, calendar: calendar)
    XCTAssertTrue(result.isStale)
    XCTAssertEqual(result.dateRange, "2026-09-12 – 2026-09-14")
  }

  func testDecodeRejectsHelperFailure() {
    XCTAssertThrowsError(try CodexCostHelper.decode("""
      [{"provider":"codex","source":"local","daily":[],"error":{"message":"scan failed"}}]
      """))
  }

  func testLiveBundledHelperReconcilesWithDisplayedTotals() async throws {
    guard ProcessInfo.processInfo.environment["QUOTAFLOAT_LIVE_CODEXBAR_TEST"] == "1" else {
      throw XCTSkip("Opt-in read-only CodexBar helper integration")
    }
    let helper = CodexCostHelper(helperURL: URL(fileURLWithPath:
      "/Applications/codex额度显示器.app/Contents/Helpers/CodexBarCLI"))
    let source = try await helper.fetch(forceRefresh: true)
    let current = Date()
    let window = QuotaWindow(usedPercent: 81, resetsAt: current.addingTimeInterval(4 * 86400),
      windowMinutes: 10080)
    let result = CodexBarUsageSummary.calculate(usage: source, weekly: window, now: current)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    let since = formatter.string(from: window.resetsAt!.addingTimeInterval(-7 * 86400))
    let until = formatter.string(from: current)
    let days = source.daily.filter { $0.date >= since && $0.date <= until }
    XCTAssertFalse(days.isEmpty)
    XCTAssertEqual(result.tokens, days.compactMap(\.totalTokens).reduce(0, +))
    XCTAssertEqual(try XCTUnwrap(result.dollars), days.compactMap(\.totalCost).reduce(0, +), accuracy: 0.000001)
    print("CodexBar reconciliation: \(result.tokenText), \(result.costText), \(result.dateRange ?? "")")
  }
}
