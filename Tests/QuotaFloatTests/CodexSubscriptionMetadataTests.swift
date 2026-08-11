import Foundation
import XCTest

@testable import QuotaFloat

final class CodexSubscriptionMetadataTests: XCTestCase {
  func testReadsNamespacedSubscriptionDatesWithTimezoneAndFractionalSeconds() throws {
    let data = try Self.authJSON(
      accountID: "subscription-account",
      email: "subscription@example.com",
      activeStart: "2026-08-01T09:00:00+08:00",
      activeUntil: "2026-09-01T09:00:00+08:00",
      lastChecked: "2026-08-11T10:00:00.123+08:00")

    let state = CodexAuthIdentityReader.state(from: data)
    let subscription = try XCTUnwrap(state?.subscription)

    XCTAssertEqual(state?.identity?.accountID, "subscription-account")
    XCTAssertEqual(state?.identity?.email, "subscription@example.com")
    XCTAssertEqual(subscription.source, .idToken)
    XCTAssertEqual(subscription.freshness, .fresh)
    XCTAssertEqual(
      subscription.activeStart,
      ISO8601DateFormatter().date(from: "2026-08-01T01:00:00Z"))
    XCTAssertEqual(
      subscription.activeUntil,
      ISO8601DateFormatter().date(from: "2026-09-01T01:00:00Z"))
    XCTAssertNotNil(subscription.lastChecked)
  }

  func testReadsNumericTimestampClaims() throws {
    let payload: [String: Any] = [
      "email": "numeric@example.com",
      "https://api.openai.com/auth": [
        "chatgpt_account_id": "numeric-account",
        "chatgpt_subscription_active_start": 1_800_000_000,
        "chatgpt_subscription_active_until": 1_800_086_400,
      ],
    ]
    let data = try Self.authJSON(accountID: "numeric-account", payload: payload)

    let subscription = try XCTUnwrap(CodexAuthIdentityReader.state(from: data)?.subscription)
    XCTAssertEqual(subscription.activeStart, Date(timeIntervalSince1970: 1_800_000_000))
    XCTAssertEqual(subscription.activeUntil, Date(timeIntervalSince1970: 1_800_086_400))
  }

  func testInvalidRangeDoesNotExposeReversedDates() throws {
    let data = try Self.authJSON(
      accountID: "invalid-account",
      email: "invalid@example.com",
      activeStart: "2026-09-01T00:00:00Z",
      activeUntil: "2026-08-01T00:00:00Z",
      lastChecked: nil)

    let subscription = try XCTUnwrap(CodexAuthIdentityReader.state(from: data)?.subscription)
    XCTAssertNil(subscription.activeStart)
    XCTAssertNil(subscription.activeUntil)
    XCTAssertEqual(subscription.status(), .unknown)
  }

  func testRemainingDaysAndCachedState() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let subscription = CodexSubscriptionMetadata(
      activeStart: now.addingTimeInterval(-86_400),
      activeUntil: now.addingTimeInterval(3 * 86_400 + 1),
      lastChecked: now,
      source: .idToken,
      freshness: .fresh)

    XCTAssertEqual(subscription.daysRemaining(now: now), 4)
    XCTAssertEqual(subscription.status(now: now), .expiringSoon)
    XCTAssertEqual(subscription.markingCached().freshness, .cached)
  }

  func testAuthChangeClassifiesSameAccountTokenRotationSeparately() throws {
    let firstData = try Self.authJSON(
      accountID: "same-account",
      email: "same@example.com",
      activeStart: "2026-08-01T00:00:00Z",
      activeUntil: "2026-09-01T00:00:00Z",
      lastChecked: "2026-08-11T00:00:00Z")
    let secondData = try Self.authJSON(
      accountID: "same-account",
      email: "same@example.com",
      activeStart: "2026-08-01T00:00:00Z",
      activeUntil: "2026-10-01T00:00:00Z",
      lastChecked: "2026-08-11T00:05:00Z")

    let first = try XCTUnwrap(CodexAuthIdentityReader.state(from: firstData, fingerprint: "first"))
    let second = try XCTUnwrap(
      CodexAuthIdentityReader.state(from: secondData, fingerprint: "second"))

    XCTAssertEqual(first.identity, second.identity)
    XCTAssertEqual(CodexAuthChange.classify(previous: first, current: second), .credentialsRotated)
  }

  private static func authJSON(
    accountID: String,
    email: String,
    activeStart: String?,
    activeUntil: String?,
    lastChecked: String?
  ) throws -> Data {
    var auth: [String: Any] = ["chatgpt_account_id": accountID]
    if let activeStart { auth["chatgpt_subscription_active_start"] = activeStart }
    if let activeUntil { auth["chatgpt_subscription_active_until"] = activeUntil }
    if let lastChecked { auth["chatgpt_subscription_last_checked"] = lastChecked }
    return try Self.authJSON(
      accountID: accountID,
      payload: [
        "email": email,
        "https://api.openai.com/auth": auth,
      ])
  }

  private static func authJSON(accountID: String, payload: [String: Any]) throws -> Data {
    let payloadData = try JSONSerialization.data(withJSONObject: payload)
    let encodedPayload = payloadData.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return try JSONSerialization.data(withJSONObject: [
      "tokens": [
        "access_token": "access-\(accountID)",
        "refresh_token": "refresh-\(accountID)",
        "id_token": "header.\(encodedPayload).signature",
        "account_id": accountID,
      ]
    ])
  }
}
