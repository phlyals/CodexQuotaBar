import CodexBarCore
import XCTest

@testable import QuotaFloat

final class CodexQuotaMappingTests: XCTestCase {
  func testResetOnlyAndUnlimitedAreValidResponses() throws {
    let now = Date()
    let credentials = CodexOAuthCredentials(
      accessToken: "fixture", refreshToken: "fixture", idToken: nil, accountId: "a",
      lastRefresh: now)
    let empty = try JSONDecoder().decode(CodexUsageResponse.self, from: Data("{}".utf8))
    let resets = CodexRateLimitResetCreditsSnapshot(credits: [], availableCount: 2, updatedAt: now)
    let result = try CodexBarQuotaFetcher.mapResponse(
      empty, credentials: credentials, resets: resets, accountKey: "a", now: now)
    XCTAssertEqual(result.resetCredits?.availableCount, 2)
    XCTAssertNil(result.creditsRemaining)
    let unlimited = try JSONDecoder().decode(
      CodexUsageResponse.self,
      from: Data(#"{"credits":{"has_credits":true,"unlimited":true,"balance":null}}"#.utf8))
    let mapped = try CodexBarQuotaFetcher.mapResponse(
      unlimited, credentials: credentials, resets: nil, accountKey: "a", now: now)
    XCTAssertTrue(mapped.hasQuotaData)
    XCTAssertEqual(mapped.creditsUnlimited, true)
    XCTAssertNil(mapped.resetCredits)
    XCTAssertNotNil(mapped.message)
  }

  func testResetDetailsSortByExpiryAndKeepScope() throws {
    let now = Date()
    let credits = [72.0, 24.0].map { hours in
      CodexRateLimitResetCredit(
        id: "\(hours)", resetType: "weekly", status: .available,
        grantedAt: now, expiresAt: now.addingTimeInterval(hours * 3600), redeemStartedAt: nil,
        redeemedAt: nil,
        title: nil, description: nil)
    }
    let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data("{}".utf8))
    let credentials = CodexOAuthCredentials(
      accessToken: "fixture", refreshToken: "fixture", idToken: nil, accountId: "a",
      lastRefresh: now)
    let result = try CodexBarQuotaFetcher.mapResponse(
      response, credentials: credentials,
      resets: .init(credits: credits, availableCount: 2, updatedAt: now), accountKey: "a", now: now)
    XCTAssertEqual(result.resetCredits?.details?.map(\.id), ["24.0", "72.0"])
    XCTAssertEqual(result.resetCredits?.details?.first?.scope, "weekly")
  }

  func testSparkOnlyDoesNotInventBaseQuota() throws {
    let response = try JSONDecoder().decode(
      CodexUsageResponse.self,
      from: Data(
        #"{"additional_rate_limits":[{"limit_name":"Spark","metered_feature":"spark","rate_limit":{"secondary_window":{"used_percent":5,"limit_window_seconds":604800,"reset_at":1800000000}}}]}"#
          .utf8))
    let credentials = CodexOAuthCredentials(
      accessToken: "fixture", refreshToken: "fixture", idToken: nil, accountId: "a",
      lastRefresh: Date())
    let result = try CodexBarQuotaFetcher.mapResponse(
      response, credentials: credentials, resets: nil, accountKey: "a")
    XCTAssertEqual(result.sparkWeekly?.remainingPercent, 95)
    XCTAssertNil(result.weekly)
    XCTAssertNil(result.session)
  }
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
