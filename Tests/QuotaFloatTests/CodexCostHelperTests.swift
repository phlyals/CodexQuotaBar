import XCTest

@testable import QuotaFloat

final class CodexCostHelperTests: XCTestCase {
  func testDecodesCodexBarCostPayloadAndFindsTopModel() throws {
    let json = #"""
      [
        {
          "provider": "codex",
          "source": "local",
          "updatedAt": "2026-08-02T12:00:00Z",
          "currencyCode": "USD",
          "sessionTokens": 41000000,
          "sessionCostUSD": 31.04,
          "historyDays": 30,
          "last30DaysTokens": 2600000000,
          "last30DaysCostUSD": 2066.34,
          "daily": [
            {
              "date": "2026-08-02",
              "totalTokens": 41000000,
              "totalCost": 31.04,
              "modelsUsed": ["gpt-5.6-sol"],
              "modelBreakdowns": [
                {"modelName": "gpt-5.6-sol", "cost": 31.04, "totalTokens": 41000000}
              ]
            }
          ],
          "totals": null,
          "error": null
        }
      ]
      """#

    let snapshot = try CodexCostHelper.decode(json)

    XCTAssertEqual(snapshot.sessionTokens, 41_000_000)
    XCTAssertEqual(snapshot.last30DaysCostUSD, 2066.34)
    XCTAssertEqual(snapshot.daily.first?.totalCost, 31.04)
    XCTAssertEqual(snapshot.topModel, "gpt-5.6-sol")
  }

  func testSurfacesProviderError() {
    let json = #"""
      [{"provider":"codex","source":"local","daily":[],"error":{"message":"scan failed"}}]
      """#

    XCTAssertThrowsError(try CodexCostHelper.decode(json)) {
      XCTAssertEqual($0.localizedDescription, "scan failed")
    }
  }
}
