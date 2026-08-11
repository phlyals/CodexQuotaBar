import XCTest

@testable import QuotaFloat

final class CodexDashboardViewTests: XCTestCase {
  func testFormatsChartDayForCompactTooltip() {
    XCTAssertEqual(CodexDashboardView.dayDate("2026-08-10"), "8/10")
    XCTAssertEqual(CodexDashboardView.dayDate("unknown"), "unknown")
  }

  func testFindsMostExpensiveModelForChartTooltip() {
    let day = CodexLocalUsageSnapshot.DailyEntry(
      date: "2026-08-10",
      inputTokens: nil,
      outputTokens: nil,
      cacheReadTokens: nil,
      cacheCreationTokens: nil,
      totalTokens: 2_000_000,
      totalCost: 4.5,
      modelsUsed: ["fallback-model"],
      modelBreakdowns: [
        .init(modelName: "small-model", cost: 1.2, totalTokens: 1_000_000),
        .init(modelName: "large-model", cost: 3.3, totalTokens: 1_000_000),
      ])

    XCTAssertEqual(CodexDashboardView.topModel(for: day), "large-model")
  }
}
