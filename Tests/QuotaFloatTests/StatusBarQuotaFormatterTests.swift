import AppKit
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

  func testSubscriptionDatesRoundTripWithQuotaSnapshot() {
    let expiry = Date(timeIntervalSince1970: 1_800_000_000)
    let renewal = Date(timeIntervalSince1970: 1_790_000_000)
    let snapshot = QuotaSnapshot(
      provider: .codex,
      session: nil,
      weekly: nil,
      subscriptionExpiresAt: expiry,
      subscriptionRenewsAt: renewal,
      resetCredits: nil,
      accountEmail: nil,
      source: "oauth",
      updatedAt: Date(timeIntervalSince1970: 1_000),
      freshness: .fresh,
      message: nil)

    XCTAssertEqual(snapshot.subscriptionExpiresAt, expiry)
    XCTAssertEqual(snapshot.subscriptionRenewsAt, renewal)
    XCTAssertEqual(
      snapshot.markingFailure("temporary", now: Date(timeIntervalSince1970: 1_100), staleAfter: 300)
        .subscriptionRenewsAt,
      renewal)
  }

  @MainActor
  func testStatusBarViewRendersNativeButtonImageAtNonzeroHeight() {
    let view = StatusBarQuotaView()
    view.update(
      StatusBarQuotaDisplay(
        sessionLine: "5h 75%", weeklyLine: "W 60%", iconRemainingPercent: 75))

    let image = view.renderedImage()

    XCTAssertEqual(image.size, NSSize(width: 64, height: 22))
    let representation = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
    XCTAssertNotNil(representation)

    guard let representation else { return }
    let textRegionStart = representation.pixelsWide / 3
    let containsWhiteTextPixel = (0..<representation.pixelsHigh).contains { y in
      (textRegionStart..<representation.pixelsWide).contains { x in
        guard
          let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        else { return false }
        return color.alphaComponent > 0.25
          && color.redComponent > 0.8
          && color.greenComponent > 0.8
          && color.blueComponent > 0.8
      }
    }
    XCTAssertTrue(containsWhiteTextPixel)
  }
}
