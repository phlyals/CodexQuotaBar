import XCTest
@testable import QuotaFloat

final class WeeklyUsageEstimateTests: XCTestCase {
  let start = Date(timeIntervalSince1970: 1_800_000_000)
  var now: Date { start.addingTimeInterval(3600) }
  var reset: Date { start.addingTimeInterval(7 * 86400) }

  func sample(_ offset: Double, _ used: Double, account: String = "a", plan: String = "pro") -> QuotaSample {
    .init(id: UUID(), accountKey: account, kind: .weekly, at: start.addingTimeInterval(offset),
      used: used, resetsAt: reset, plan: plan)
  }
  func snapshot(_ used: Double = 82, reset: Date? = nil) -> QuotaSnapshot {
    QuotaSnapshot(provider: .codex, session: nil,
      weekly: .init(usedPercent: used, resetsAt: reset ?? self.reset, windowMinutes: 10080),
      resetCredits: nil, accountEmail: "fixture@example.test", accountKey: "a", accountPlan: "pro",
      source: "fixture", updatedAt: now, freshness: .fresh, message: nil)
  }
  func event(_ id: String = "r", at: Double = 900, model: String = "test", cost: Double? = 10) -> CycleTokenEvent {
    .init(id: id, at: start.addingTimeInterval(at), model: model, input: 900_000,
      cached: 800_000, output: 100_000, resets: [10080: Int(reset.timeIntervalSince1970)], cost: cost)
  }
  func estimate(_ samples: [QuotaSample], events: [CycleTokenEvent] = [], used: Double = 82) -> WeeklyUsageEstimate {
    .calculate(events: events, samples: samples, snapshot: snapshot(used), now: now)
  }

  func testMidWeekTwentyPointsEstimateAllEightyTwoPoints() throws {
    let value = estimate([sample(600, 62), sample(1800, 82)], events: [event()])
    XCTAssertEqual(value.usedPercent, 82)
    XCTAssertEqual(value.tokens, 4_100_000)
    XCTAssertEqual(try XCTUnwrap(value.dollars), 41, accuracy: 0.00001)
    XCTAssertEqual(value.elapsed, 3600)
    XCTAssertEqual(value.usedText, "本周已用 82%")
    XCTAssertEqual(value.tokenText, "约 4.10M Token")
    XCTAssertEqual(value.costText, "约 $41.00")
  }
  func testFullWeekRecordedDoesNotScaleOrIncludeCachedTokensTwice() {
    let value = estimate([sample(0, 0), sample(1800, 82)], events: [event()])
    XCTAssertEqual(value.tokens, 1_000_000)
    XCTAssertEqual(value.dollars, 10)
  }
  func testNoConsumptionAndTinyPartialDeltaDoNotDivideByZeroOrInventTotals() {
    XCTAssertNil(estimate([sample(0, 82), sample(1800, 82)], events: [event()]).tokens)
    XCTAssertNil(estimate([sample(0, 81), sample(1800, 82)], events: [event()]).tokens)
    let empty = estimate([sample(0, 0)], used: 0)
    XCTAssertEqual(empty.tokens, 0)
    XCTAssertEqual(empty.dollars, 0)
  }
  func testUnknownModelPriceDoesNotBorrowAnUnrelatedModelsCost() {
    let samples = [sample(0, 62), sample(1800, 82)]
    let missing = estimate(samples, events: [event(cost: nil)])
    XCTAssertEqual(missing.tokens, 4_100_000)
    XCTAssertNil(missing.dollars)
    let mixed = estimate(samples, events: [event(), event("b", model: "unknown-model", cost: nil)])
    XCTAssertEqual(mixed.tokens, 8_200_000)
    XCTAssertNil(mixed.dollars)
  }
  func testMissingPriceCanUseSameModelsObservedCostPerToken() throws {
    let value = estimate([sample(0, 62), sample(1800, 82)],
      events: [event(), event("b", cost: nil)])
    XCTAssertEqual(try XCTUnwrap(value.dollars), 82, accuracy: 0.00001)
  }
  func testDifferentAccountAndAmbiguousWindowNeverBecomeCurrentAccountEstimates() {
    XCTAssertNil(estimate([sample(0, 62, account: "b"), sample(1800, 82, account: "b")],
      events: [event()]).tokens)
    XCTAssertNil(estimate([sample(0, 62), sample(1800, 82), sample(0, 0, account: "b")],
      events: [event()]).tokens)
  }
  func testResetInSameWindowExcludesPreviousRoundAndRestartsElapsedTime() {
    let value = estimate([
      sample(0, 60), sample(500, 100), sample(600, 0), sample(1800, 20)
    ], events: [event("old", at: 300, cost: 100), event()], used: 20)
    XCTAssertEqual(value.tokens, 1_000_000)
    XCTAssertEqual(value.dollars, 10)
    XCTAssertEqual(value.elapsed, 3000)
  }
  func testExpiredOrNewWindowNeverReusesPreviousWeek() {
    let samples = [sample(0, 62), sample(1800, 82)]
    let expired = WeeklyUsageEstimate.calculate(events: [event()], samples: samples,
      snapshot: snapshot(reset: now), now: now)
    XCTAssertNil(expired.usedPercent)
    let newWeek = WeeklyUsageEstimate.calculate(events: [event()], samples: samples,
      snapshot: snapshot(reset: reset.addingTimeInterval(3600)), now: now)
    XCTAssertNil(newWeek.tokens)
    XCTAssertNil(estimate([sample(0, 62, plan: "other"), sample(1800, 82, plan: "other")],
      events: [event()]).tokens)
  }
  func testDuplicatesAndOutsidePeriodEventsDoNotInflateEstimate() {
    let value = estimate([sample(600, 62), sample(1800, 82)], events: [
      event(), event(), event("before", at: 500), event("after", at: 1801)
    ])
    XCTAssertEqual(value.tokens, 4_100_000)
  }
  func testLatestPercentageScalesFromAvailableHistoryRatherThanIgnoringIt() {
    let value = estimate([sample(0, 60), sample(1800, 80)], events: [event()])
    XCTAssertEqual(value.tokens, 4_100_000)
  }
  func testNewQuotaSamplesDoNotDiluteOlderScanCalibration() {
    let value = WeeklyUsageEstimate.calculate(events: [event()],
      samples: [sample(0, 60), sample(1800, 80), sample(3600, 82)],
      snapshot: snapshot(), now: now, recordedThrough: start.addingTimeInterval(1800))
    XCTAssertEqual(value.tokens, 4_100_000)
  }
  func testResetAfterLastScanCannotReuseOldRoundsRatio() {
    let value = WeeklyUsageEstimate.calculate(events: [event()],
      samples: [sample(0, 60), sample(1800, 80), sample(2400, 0), sample(3600, 82)],
      snapshot: snapshot(), now: now, recordedThrough: start.addingTimeInterval(1800))
    XCTAssertNil(value.tokens)
    XCTAssertNil(value.dollars)
  }
  func testStaleDataAndNonFinitePriceAreNotPresentedAsFreshTotals() {
    let value = WeeklyUsageEstimate.calculate(events: [event(cost: .infinity)],
      samples: [sample(0, 62), sample(1800, 82)], snapshot: snapshot(),
      now: now.addingTimeInterval(600))
    XCTAssertTrue(value.isStale)
    XCTAssertNil(value.dollars)
  }
}
