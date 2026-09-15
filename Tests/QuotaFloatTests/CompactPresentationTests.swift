import Foundation
import XCTest

@testable import QuotaFloat

final class CompactPresentationTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testMessagesShowOnlyNewestTwoWithoutDroppingArchive() {
    let signals = (0..<5).map { index in
      ResetSignal(
        id: "\(index)", publishedAt: now.addingTimeInterval(Double(index)), discoveredAt: now,
        excerpt: "fixture", state: .completed, deadline: nil, timeAssumption: "", scope: "",
        verified: true, linkedPostID: nil, resolutionID: nil)
    }
    XCTAssertEqual(MessagePresentation.latest(signals).map(\.id), ["4", "3"])
    XCTAssertEqual(signals.count, 5)
    XCTAssertTrue(MessagePresentation.latest([]).isEmpty)
  }

  func testPlanningAnswersDurationInsteadOfTechnicalWarnings() {
    let reset = now.addingTimeInterval(20 * 3600)
    let window = QuotaWindow(usedPercent: 50, resetsAt: reset, windowMinutes: 10080)
    let forecast = QuotaForecast(
      count: 6, from: now.addingTimeInterval(-3600), to: now,
      lowRate: 5, highRate: 10, remaining: 50, resetsAt: reset)
    XCTAssertEqual(
      PlanningPresentation.duration(window: window, forecast: forecast, reserve: 10, now: now),
      "约 4.0–8.0 小时")
    XCTAssertEqual(
      PlanningPresentation.duration(window: window, forecast: nil, reserve: 10, now: now), "暂时无法估算")
    XCTAssertEqual(
      PlanningPresentation.duration(window: window, forecast: forecast, reserve: 50, now: now),
      "已到预留额度")
  }

  func testPlanningDoesNotExtrapolatePastReset() {
    let reset = now.addingTimeInterval(3600)
    let window = QuotaWindow(usedPercent: 50, resetsAt: reset, windowMinutes: 300)
    let forecast = QuotaForecast(
      count: 6, from: now.addingTimeInterval(-3600), to: now,
      lowRate: 5, highRate: 10, remaining: 50, resetsAt: reset)
    XCTAssertEqual(
      PlanningPresentation.duration(window: window, forecast: forecast, reserve: 10, now: now),
      "可用到下次重置")
    XCTAssertEqual(
      PlanningPresentation.duration(window: window, forecast: forecast, reserve: 10, now: reset),
      "等待额度更新")
  }

  func testShortMenusHaveCompactStableDimensions() {
    XCTAssertEqual(QuotaMenuPage.overview.preferredHeight, 260)
    XCTAssertEqual(QuotaMenuPage.settings.preferredHeight, 260)
    for page in QuotaMenuPage.allCases { XCTAssertLessThanOrEqual(page.preferredHeight, 400) }
  }
}
