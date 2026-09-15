import XCTest

@testable import QuotaFloat

final class QuotaCycleTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testCompleteRoundStopsClockAtFirstExhaustion() throws {
    let rows = summary([sample(0, 0), sample(600, 50), sample(1200, 100), sample(3600, 100)])
    let cycle = try XCTUnwrap(rows.first)
    XCTAssertTrue(cycle.isComplete)
    XCTAssertEqual(cycle.duration, 1200)
    XCTAssertEqual(cycle.consumed, 100)
    XCTAssertEqual(QuotaCycleSummary.averageCompleteDuration(rows), 1200)
  }

  func testMidCycleStartReportsOnlyObservedConsumption() throws {
    let rows = summary([sample(0, 40), sample(600, 60), sample(1200, 100)])
    let cycle = try XCTUnwrap(rows.first)
    XCTAssertTrue(cycle.isPartial)
    XCTAssertEqual(cycle.consumed, 60)
    XCTAssertNil(QuotaCycleSummary.averageCompleteDuration(rows))
  }

  func testRecoveryStartsNewRoundEvenWithoutChangedDeadline() {
    let rows = summary([sample(0, 0), sample(600, 80), sample(1200, 0), sample(1800, 30)])
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows[0].consumed, 30)
    XCTAssertFalse(rows[0].closed)
    XCTAssertTrue(rows[1].closed)
    XCTAssertEqual(rows[1].consumed, 80)
  }

  func testDeadlineAndPlanChangesSplitRounds() {
    let rows = summary([
      sample(0, 20), sample(600, 25, reset: 30000), sample(1200, 30, reset: 30000, plan: "Other"),
    ])
    XCTAssertEqual(rows.count, 3)
    XCTAssertTrue(rows[1].closed)
    XCTAssertTrue(rows[2].closed)
  }

  func testOfflineGapExcludesRoundFromAverage() throws {
    let rows = summary([sample(0, 0), sample(1800, 50), sample(2400, 100)])
    XCTAssertTrue(try XCTUnwrap(rows.first).hasGap)
    XCTAssertNil(QuotaCycleSummary.averageCompleteDuration(rows))
  }

  func testAccountAndWindowIsolationAndOutOfOrderSamples() {
    var samples = [sample(600, 50), sample(0, 0), sample(1200, 100)]
    samples.append(
      .init(
        id: UUID(), accountKey: "other", kind: .weekly, at: now, used: 80, resetsAt: nil, plan: nil)
    )
    samples.append(
      .init(
        id: UUID(), accountKey: "a", kind: .session, at: now, used: 80, resetsAt: nil, plan: nil))
    let rows = summary(samples)
    XCTAssertEqual(rows.count, 1)
    XCTAssertTrue(rows[0].isComplete)
  }

  func testPastDeadlineClosesLastObservedRoundWithoutInventingConsumption() {
    let rows = summary([sample(0, 0, reset: 1000), sample(600, 60, reset: 1000)])
    XCTAssertTrue(rows[0].closed)
    XCTAssertEqual(rows[0].consumed, 60)
    XCTAssertEqual(rows[0].duration, 600)
    XCTAssertFalse(rows[0].isComplete)
  }

  func testDuplicateTimestampsAndInvalidValuesAreIgnored() {
    let rows = summary([
      sample(0, 0), sample(0, 0), sample(300, .nan), sample(400, 101), sample(600, 50),
    ])
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].consumed, 50)
  }

  func testReadableDuration() {
    XCTAssertEqual(QuotaCycleSummary.durationText(0), "不足 1 分钟")
    XCTAssertEqual(QuotaCycleSummary.durationText(120), "2 分钟")
    XCTAssertEqual(QuotaCycleSummary.durationText(3900), "1 小时 5 分钟")
    XCTAssertEqual(QuotaCycleSummary.durationText(90000), "1 天 1 小时")
  }

  private func sample(
    _ seconds: Double, _ used: Double, reset: Double = 20000, plan: String = "Pro"
  ) -> QuotaSample {
    .init(
      id: UUID(), accountKey: "a", kind: .weekly, at: now.addingTimeInterval(seconds), used: used,
      resetsAt: now.addingTimeInterval(reset), plan: plan)
  }
  private func summary(_ samples: [QuotaSample]) -> [QuotaCycle] {
    QuotaCycleSummary.cycles(
      samples: samples, accountKey: "a", kind: .weekly, now: now.addingTimeInterval(5000))
  }
}
