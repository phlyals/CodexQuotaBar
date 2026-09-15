import XCTest
@testable import QuotaFloat

final class QuotaCycleBillTests: XCTestCase {
  let start = Date(timeIntervalSince1970: 1_800_000_000)
  var reset: Date { start.addingTimeInterval(10080 * 60) }
  var cycle: QuotaCycle {
    QuotaCycle(id: UUID(), startedAt: start, lastObservedAt: start.addingTimeInterval(3600),
      resetsAt: reset, startingUsed: 0, plan: "pro", maximumUsed: 82)
  }
  func sample(_ account: String = "a") -> QuotaSample {
    QuotaSample(id: UUID(), accountKey: account, kind: .weekly, at: start,
      used: 0, resetsAt: reset, plan: "pro")
  }
  func event(_ id: String = "r", offset: Double = 600, cost: Double? = 2) -> CycleTokenEvent {
    CycleTokenEvent(id: id, at: start.addingTimeInterval(offset), model: "test",
      input: 1000, cached: 800, output: 100, resets: [10080: Int(reset.timeIntervalSince1970)],
      cost: cost)
  }
  func bill(_ events: [CycleTokenEvent], samples: [QuotaSample]? = nil) -> QuotaCycleBill {
    .summarize(events: events, samples: samples ?? [sample()], accountKey: "a", kind: .weekly, cycle: cycle)
  }
  func testEightyTwoPercentBillUsesActualTokensNotPercentageConversion() {
    let value = bill([event(), event("r2", cost: 3)])
    XCTAssertEqual(cycle.consumed, 82)
    XCTAssertEqual(value.tokens, 2200)
    XCTAssertEqual(value.cached, 1600)
    XCTAssertEqual(value.dollars, 5)
    XCTAssertEqual(cycle.duration, 3600)
  }
  func testDuplicateRequestsAndTimeBoundaries() {
    let value = bill([event(), event(), event("before", offset: 0), event("after", offset: 3601)])
    XCTAssertEqual(value.requests, 1)
  }
  func testAmbiguousAccountNeverGetsSomeoneElsesBill() {
    XCTAssertEqual(bill([event()], samples: [sample(), sample("b")]).requests, 0)
    XCTAssertEqual(bill([event()], samples: [sample("b")]).requests, 0)
  }
  func testUnknownPricingIsNotZeroDollars() {
    XCTAssertEqual(bill([event(cost: nil)]).costText, "价格缺失")
    XCTAssertEqual(bill([event(), event("b", cost: nil)]).costText, "$2.00（部分）")
    XCTAssertEqual(bill([]).costText, "--")
  }
  func testCachedInputCountedAndPricedOnce() throws {
    let model: [String: Any] = ["cost": ["input": 2.0, "cache_read": 0.5, "output": 10.0]]
    let price = try XCTUnwrap(CycleTokenScanner.price(model: model, input: 1000, cached: 800, output: 100))
    XCTAssertEqual(price, 0.0018, accuracy: 0.0000001)
    XCTAssertNil(CycleTokenScanner.price(model: model, input: 300000, cached: 0, output: 100))
    XCTAssertNil(CycleTokenScanner.price(model: nil, input: 1000, cached: 0, output: 100))
  }
  func testParserPairsRequestAndWindowAndIgnoresIncompleteTail() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let rows: [[String: Any]] = [
      ["type": "turn_context", "payload": ["turn_id": "t", "model": "test"]],
      ["type": "token_usage_record", "timestamp": "2027-01-15T08:00:00.000Z", "payload": [
        "response_id": "r", "turn_id": "t", "usage": ["input_tokens": 1000,
          "cached_input_tokens": 800, "output_tokens": 100]]],
      ["type": "event_msg", "timestamp": "2027-01-15T08:00:00.100Z", "payload": [
        "type": "token_count", "info": ["last_token_usage": ["input_tokens": 1000,
          "cached_input_tokens": 800, "output_tokens": 100]], "rate_limits": [
          "limit_id": "codex", "primary": ["window_minutes": 10080, "resets_at": 1800100000]]]]
    ]
    var data = Data()
    for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
    data.append(Data("{unfinished".utf8))
    try data.write(to: url)
    let events = CycleTokenScanner.parse(url: url, models: [:])
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.model, "test")
    XCTAssertEqual(events.first?.tokens, 1100)
    XCTAssertEqual(events.first?.resets[10080], 1800100000)
  }
  @MainActor func testLiveReadOnlyScanner() async throws {
    guard ProcessInfo.processInfo.environment["QUOTAFLOAT_LIVE_CYCLE_TEST"] == "1" else {
      throw XCTSkip("Optional read-only local log integration")
    }
    let scanner = CycleTokenScanner()
    let events = await scanner.scan(
      home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
      since: Date().addingTimeInterval(-30 * 86400))
    XCTAssertFalse(events.isEmpty)
    XCTAssertEqual(Set(events.map(\.id)).count, events.count)
    print("Cycle scan: \(events.count) unique matched-window requests, \(events.filter { $0.cost != nil }.count) priced")
    let archive = try XCTUnwrap(LocalPrivateStore.load(
      QuotaHistory.Archive.self, from: LocalPrivateStore.url("quota-history.json")))
    var matched = 0
    for key in archive.latest.keys {
      for kind in QuotaWindowKind.allCases {
        guard let current = QuotaCycleSummary.cycles(
          samples: archive.samples, accountKey: key, kind: kind, now: Date()).first else { continue }
        let bill = QuotaCycleBill.summarize(
          events: events, samples: archive.samples, accountKey: key, kind: kind, cycle: current)
        if bill.requests > 0 { matched += 1 }
      }
    }
    print("Cycle scan: \(matched) latest account windows have bill records")
    XCTAssertGreaterThan(matched, 0)
    let weekly = archive.latest.values.map {
      WeeklyUsageEstimate.calculate(events: events, samples: archive.samples, snapshot: $0, now: Date())
    }
    print("Weekly estimates: \(weekly.filter { $0.tokens != nil }.count) token totals, \(weekly.filter { $0.dollars != nil }.count) dollar totals")
    XCTAssertTrue(weekly.contains { ($0.tokens ?? 0) > 0 })
  }
}
