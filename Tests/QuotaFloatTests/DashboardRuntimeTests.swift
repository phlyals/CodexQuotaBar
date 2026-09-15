import AppKit
import SwiftUI
import XCTest

@testable import QuotaFloat

final class DashboardRuntimeTests: XCTestCase {
  @MainActor
  func testUsageRefreshesIndependentlyAndMergesConcurrentScans() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let quotaStore = QuotaStore(
      cacheStore: QuotaCacheStore(fileURL: root.appendingPathComponent("cache")),
      identityProvider: { nil })
    let helper = CountingCostFixture()
    let dashboard = CodexDashboardStore(quotaStore: quotaStore, localUsageFetcher: helper)
    dashboard.start()
    dashboard.refreshLocalUsage(force: true)
    try await Task.sleep(for: .milliseconds(100))
    let first = await helper.count
    XCTAssertEqual(first, 1)
    dashboard.tick(now: Date().addingTimeInterval(121))
    try await Task.sleep(for: .milliseconds(100))
    let second = await helper.count
    XCTAssertEqual(second, 2)
    XCTAssertNotNil(dashboard.localUsage)
    XCTAssertNil(quotaStore.lastRefreshAttempt)
    dashboard.stop()
  }

  @MainActor
  func testCompactDashboardFitsAndRendersLightAndDark() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    let cache = QuotaCacheStore(fileURL: root.appendingPathComponent("cache"))
    let window = QuotaWindow(
      usedPercent: 100, resetsAt: now.addingTimeInterval(7200), windowMinutes: 300)
    cache.save([
      QuotaSnapshot(
        provider: .codex, session: window, weekly: window,
        sparkSession: window, sparkWeekly: window, creditsRemaining: 2731.73,
        resetCredits: QuotaResetCredits(
          availableCount: 2, expirationDates: [now.addingTimeInterval(86400)]),
        accountEmail: "very-long-account-address-for-layout@example.test", accountKey: "fixture",
        accountPlan: "Pro", source: "fixture", updatedAt: now, freshness: .fresh, message: nil)
    ])
    let quotaStore = QuotaStore(cacheStore: cache, identityProvider: { "fixture" })
    let dashboard = CodexDashboardStore(
      quotaStore: quotaStore, localUsageFetcher: CountingCostFixture())
    dashboard.refreshLocalUsage()
    try await Task.sleep(for: .milliseconds(100))
    for dark in [false, true] {
      let view = NSHostingView(
        rootView: CodexDashboardView(store: dashboard).environment(
          \.colorScheme, dark ? .dark : .light))
      view.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
      let window = NSWindow(
        contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = view
      view.layoutSubtreeIfNeeded()
      XCTAssertEqual(view.fittingSize.width, 300, accuracy: 1)
      XCTAssertLessThan(
        view.fittingSize.height, 600, "All extra windows remain within the scrollable surface")
      let renderer = ImageRenderer(
        content: CodexDashboardView(store: dashboard).environment(
          \.colorScheme, dark ? .dark : .light))
      renderer.scale = 2
      let image = try XCTUnwrap(renderer.cgImage)
      XCTAssertEqual(image.width, 600)
      XCTAssertGreaterThan(image.height, 300)
      let bitmap = NSBitmapImageRep(cgImage: image)
      let colors = Set(
        stride(from: 0, to: bitmap.pixelsWide, by: 12).flatMap { x in
          stride(from: 0, to: bitmap.pixelsHigh, by: 12).compactMap { y in
            bitmap.colorAt(x: x, y: y)?.description
          }
        })
      XCTAssertGreaterThan(colors.count, 15, "Rendered panel must not be blank")
      if let directory = ProcessInfo.processInfo.environment["QUOTAFLOAT_VISUAL_OUTPUT"] {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(
          dark ? "dashboard-dark.png" : "dashboard-light.png")
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
      }
      window.contentView = nil
    }
    dashboard.stop()
  }
}

private actor CountingCostFixture: CodexLocalUsageFetching {
  var count = 0
  func fetch(forceRefresh: Bool) async throws -> CodexLocalUsageSnapshot {
    count += 1
    try await Task.sleep(for: .milliseconds(20))
    let day = DateFormatter()
    day.dateFormat = "yyyy-MM-dd"
    let iso = ISO8601DateFormatter().string(from: Date())
    return try CodexCostHelper.decode(
      """
      [{"provider":"codex","source":"fixture","updatedAt":"\(iso)","historyDays":30,
      "daily":[{"date":"\(day.string(from: Date()))","totalCost":12.5,"totalTokens":110,
      "modelBreakdowns":[{"modelName":"fixture-model","cost":12.5,"totalTokens":110}]}]}]
      """)
  }
}
