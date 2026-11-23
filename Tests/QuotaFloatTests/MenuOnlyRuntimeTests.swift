import AppKit
import SwiftUI
import XCTest

@testable import QuotaFloat

final class MenuOnlyRuntimeTests: XCTestCase {
  @MainActor
  func testDiscardedMenusCannotClearCurrentHostedViewOwnership() throws {
    let fixture = try MenuOnlyFixture()
    defer { fixture.cleanUp() }
    let controller = StatusBarQuotaController(
      store: fixture.store, accountManager: fixture.accounts,
      googleAccounts: fixture.googleAccounts, assistant: fixture.model, startsAutomatically: false)
    defer { controller.stop() }
    var current = controller.makeMenu(snapshot: nil)
    for _ in 0..<20 {
      autoreleasepool {
        let outgoing = current
        current = controller.makeMenu(snapshot: nil)
        withExtendedLifetime(outgoing) {}
      }
    }
    let items = Self.hostedItems(in: current)
    XCTAssertEqual(items.count, 6)
    for item in items {
      let host = try XCTUnwrap(item.view)
      XCTAssertTrue(
        host.enclosingMenuItem === item,
        "\(item.title): releasing old menus must not clear the current view owner")
    }
  }

  @MainActor
  func testDiscardedMenuCannotRemoveReattachedHostedViews() throws {
    let fixture = try MenuOnlyFixture()
    defer { fixture.cleanUp() }
    let controller = StatusBarQuotaController(
      store: fixture.store, accountManager: fixture.accounts,
      googleAccounts: fixture.googleAccounts, assistant: fixture.model, startsAutomatically: false)
    defer { controller.stop() }
    var current: NSMenu!
    var mounted: [(NSMenuItem, NSView, NSView)] = []
    autoreleasepool {
      let outgoing = controller.makeMenu(snapshot: nil)
      current = controller.makeMenu(snapshot: nil)
      for item in Self.hostedItems(in: current) {
        guard let host = item.view else { continue }
        let container = NSView(frame: host.frame)
        container.addSubview(host)
        mounted.append((item, host, container))
      }
      withExtendedLifetime(outgoing) {}
    }
    XCTAssertEqual(mounted.count, 6)
    for (item, host, container) in mounted {
      XCTAssertTrue(
        host.superview === container,
        "\(item.title): old menu teardown must not remove the view from its new container")
      host.removeFromSuperview()
    }
    withExtendedLifetime(current) {}
  }

  @MainActor
  private static func hostedItems(in menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { item in
      (item.view == nil ? [] : [item]) + (item.submenu.map { hostedItems(in: $0) } ?? [])
    }
  }

  @MainActor
  func testNativeMenuContentRendersAfterOldMenusAreReleased() async throws {
    guard ProcessInfo.processInfo.environment["QUOTAFLOAT_NATIVE_MENU_TEST"] == "1" else {
      throw XCTSkip("Opt-in integration test requires an interactive macOS desktop")
    }
    let fixture = try MenuOnlyFixture(populated: true)
    defer { fixture.cleanUp() }
    try await fixture.accounts.addAccount()
    let controller = StatusBarQuotaController(
      store: fixture.store, accountManager: fixture.accounts,
      googleAccounts: fixture.googleAccounts, assistant: fixture.model, startsAutomatically: false)
    defer { controller.stop() }
    // Drain initial Combine deliveries before exercising menus outside the status item.
    try await Task.sleep(for: .milliseconds(100))
    var current = controller.makeMenu(snapshot: nil)
    for _ in 0..<20 {
      autoreleasepool {
        let outgoing = current
        current = controller.makeMenu(snapshot: nil)
        withExtendedLifetime(outgoing) {}
      }
    }
    // Exercise native menu attachment without starting live account or usage refreshes.
    current.delegate = nil
    let screen = try XCTUnwrap(NSScreen.main)
    let items = Self.hostedItems(in: current)
    XCTAssertEqual(items.count, 6)
    for dark in [false, true] {
      for (index, item) in items.enumerated() {
        let host = try XCTUnwrap(item.view)
        let menu = try XCTUnwrap(item.menu)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var inspected = false
        let inspect: @MainActor () -> Void = {
          defer { menu.cancelTracking() }
          inspected = true
          XCTAssertTrue(host.enclosingMenuItem === item)
          XCTAssertNotNil(host.superview)
          XCTAssertTrue(host.window?.isVisible == true, "\(item.title) must be in a visible menu")
          host.layoutSubtreeIfNeeded()
          do {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // A host snapshot omits the menu's translucent backdrop; composite it for inspection.
            let preview = try XCTUnwrap(
              NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide,
                pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: preview))
            let rect = NSRect(x: 0, y: 0, width: preview.pixelsWide, height: preview.pixelsHigh)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor(white: dark ? 0.15 : 1, alpha: 1).setFill()
            rect.fill()
            let snapshot = NSImage(size: rect.size)
            snapshot.addRepresentation(bitmap)
            snapshot.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            let colors = Set(
              stride(from: 0, to: preview.pixelsWide, by: 5).flatMap { x in
                stride(from: 0, to: preview.pixelsHigh, by: 5).compactMap { y in
                  preview.colorAt(x: x, y: y)?.description
                }
              })
            XCTAssertGreaterThan(colors.count, 10, "\(item.title) must draw inside the native menu")
            if let directory = ProcessInfo.processInfo.environment["QUOTAFLOAT_VISUAL_OUTPUT"] {
              let url = URL(fileURLWithPath: directory).appendingPathComponent(
                "native-menu-\(index)-\(dark ? "dark" : "light").png")
              try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
              try preview.representation(using: .png, properties: [:])?.write(to: url)
            }
          } catch {
            XCTFail("\(item.title): \(error)")
          }
        }
        let timer = Timer(timeInterval: 0.3, repeats: false) { _ in
          MainActor.assumeIsolated { inspect() }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        menu.popUp(
          positioning: nil,
          at: NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 80), in: nil)
        timer.invalidate()
        XCTAssertTrue(inspected, "The native menu must remain open until content inspection")
      }
    }
  }

  @MainActor
  func testOriginalAccountListAndNewPagesRemainInsideNativeMenu() async throws {
    let fixture = try MenuOnlyFixture()
    defer { fixture.cleanUp() }
    try await fixture.accounts.addAccount()
    let controller = StatusBarQuotaController(
      store: fixture.store, accountManager: fixture.accounts,
      googleAccounts: fixture.googleAccounts, assistant: fixture.model, startsAutomatically: false)
    defer { controller.stop() }

    let menu = controller.makeMenu(snapshot: nil)
    let header = try XCTUnwrap(menu.items.first { $0.title == "Codex 账号" })
    XCTAssertNil(header.submenu, "Saved accounts must remain expanded in the original menu")
    let account = try XCTUnwrap(menu.items.first { $0.representedObject is String })
    XCTAssertNotNil(account.action)
    XCTAssertNil(account.submenu)
    XCTAssertLessThan(menu.index(of: header), menu.index(of: account))
    XCTAssertFalse(menu.items.contains { $0.title == "详情与用量规划…" })

    XCTAssertFalse(menu.items.contains { $0.title == "更多信息" })
    for page in QuotaMenuPage.allCases {
      let item = try XCTUnwrap(menu.items.first { $0.title == page.title })
      XCTAssertFalse(
        item.target === controller, "AppKit must own the submenu action, not a window controller")
      let view = try XCTUnwrap(item.submenu?.items.first?.view)
      XCTAssertEqual(view.frame.width, 300)
      XCTAssertLessThanOrEqual(view.frame.height, 440)
    }
    XCTAssertTrue(menu.items.contains { $0.title == "立即刷新" })
    XCTAssertTrue(menu.items.contains { $0.title.hasPrefix("开机自启动") })
    XCTAssertTrue(menu.items.contains { $0.title == "退出 codex额度显示器" })
  }

  @MainActor
  func testNativeSettingsCheckboxesChangeAndPersistWhileOpen() async throws {
    guard ProcessInfo.processInfo.environment["QUOTAFLOAT_NATIVE_MENU_TEST"] == "1" else {
      throw XCTSkip("Opt-in integration test requires an interactive macOS desktop")
    }
    let fixture = try MenuOnlyFixture()
    defer { fixture.cleanUp() }
    let controller = StatusBarQuotaController(
      store: fixture.store, accountManager: fixture.accounts,
      googleAccounts: fixture.googleAccounts, assistant: fixture.model, startsAutomatically: false)
    defer { controller.stop() }
    try await Task.sleep(for: .milliseconds(100))
    let root = controller.makeMenu(snapshot: nil)
    root.delegate = nil
    let menu = try XCTUnwrap(root.items.first { $0.title == "设置" }?.submenu)
    let host = try XCTUnwrap(menu.items.first?.view)
    var phase = 0
    var ticks = 0
    var queuedWorkRan = false
    let inspect: @MainActor () -> Void = {
      ticks += 1
      guard ticks < 40 else {
        if ticks == 40 {
          XCTFail(
            "Checkbox phase \(phase), quiet=\(fixture.model.notifications.quietEnabled), mainQueueRan=\(queuedWorkRan)"
          )
        }
        menu.cancelTracking()
        return
      }
      let buttons = Self.buttons(in: host)
      guard let quiet = buttons.first(where: { $0.identifier?.rawValue == "quota-quiet-toggle" }),
        let reminder = buttons.first(where: {
          $0.identifier?.rawValue == "quota-notifications-toggle"
        })
      else {
        XCTFail("Native settings controls missing")
        menu.cancelTracking()
        return
      }
      let notifications = fixture.model.notifications
      switch phase {
      case 0:
        DispatchQueue.main.async { queuedWorkRan = true }
        quiet.performClick(nil)
        phase = 1
      case 1 where !notifications.quietEnabled:
        XCTAssertFalse(fixture.defaults.bool(forKey: "quotaQuietEnabled"))
        XCTAssertEqual(quiet.state, .off)
        quiet.performClick(nil)
        phase = 2
      case 2 where notifications.quietEnabled:
        XCTAssertTrue(fixture.defaults.bool(forKey: "quotaQuietEnabled"))
        reminder.performClick(nil)
        phase = 3
      case 3 where notifications.enabled && !notifications.isRequestingPermission:
        XCTAssertTrue(fixture.defaults.bool(forKey: "quotaNotificationsEnabled"))
        XCTAssertEqual(reminder.state, .on)
        reminder.performClick(nil)
        phase = 4
      case 4 where !notifications.enabled:
        XCTAssertFalse(fixture.defaults.bool(forKey: "quotaNotificationsEnabled"))
        phase = 5
        menu.cancelTracking()
      default: break
      }
    }
    let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
      MainActor.assumeIsolated { inspect() }
    }
    RunLoop.main.add(timer, forMode: .eventTracking)
    await withCheckedContinuation { continuation in
      StatusBarQuotaController.scheduleMenuPresentation {
        menu.popUp(positioning: nil, at: NSPoint(x: 600, y: 700), in: nil)
        continuation.resume()
      }
    }
    timer.invalidate()
    XCTAssertEqual(phase, 5)
  }

  @MainActor
  private static func buttons(in view: NSView) -> [NSButton] {
    ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
  }

  @MainActor
  func testMenuRebuildReusesDashboardAndDetailStateWithoutCreatingWindows() throws {
    let fixture = try MenuOnlyFixture()
    defer { fixture.cleanUp() }
    let windowCount = NSApplication.shared.windows.filter { $0.styleMask.contains(.titled) }.count
    let controller = StatusBarQuotaController(
      store: fixture.store, accountManager: fixture.accounts,
      googleAccounts: fixture.googleAccounts, assistant: fixture.model, startsAutomatically: false)
    defer { controller.stop() }
    let first = controller.makeMenu(snapshot: nil)
    let dashboard = try XCTUnwrap(first.items.first?.view)
    let planning = try XCTUnwrap(
      first.items.first { $0.title == "用量规划" }?.submenu?.items.first?.view)
    for _ in 0..<20 {
      let menu = controller.makeMenu(snapshot: nil)
      XCTAssertTrue(menu.items.first?.view === dashboard)
      XCTAssertTrue(
        menu.items.first { $0.title == "用量规划" }?.submenu?.items.first?.view === planning)
    }
    XCTAssertEqual(NSApp.windows.filter { $0.styleMask.contains(.titled) }.count, windowCount)
  }

  @MainActor
  func testAllDetailPagesRenderAtMenuWidthInBothAppearances() async throws {
    let fixture = try MenuOnlyFixture(populated: true, localUsageFetcher: MenuCostFixture())
    defer { fixture.cleanUp() }
    try await fixture.accounts.addAccount()
    fixture.model.dashboard.refreshLocalUsage()
    for _ in 0..<100 where fixture.model.dashboard.isLoadingLocalUsage {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNotNil(fixture.model.dashboard.localUsage)
    for dark in [false, true] {
      for page in QuotaMenuPage.allCases {
        let host = NSHostingView(
          rootView: QuotaDetailsView(model: fixture.model, page: page)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(dark ? Color(white: 0.15) : Color.white))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 440)
        let window = NSWindow(
          contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = dark ? .black : .white
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(host.fittingSize.width, 300, accuracy: 1)
        XCTAssertEqual(host.fittingSize.height, 440, accuracy: 1)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let colors = Set(
          stride(from: 0, to: bitmap.pixelsWide, by: 5).flatMap { x in
            stride(from: 0, to: bitmap.pixelsHigh, by: 5).compactMap { y in
              bitmap.colorAt(x: x, y: y)?.description
            }
          })
        XCTAssertGreaterThan(colors.count, 10, "\(page) must render nonblank content")
        if let directory = ProcessInfo.processInfo.environment["QUOTAFLOAT_VISUAL_OUTPUT"] {
          let url = URL(fileURLWithPath: directory).appendingPathComponent(
            "menu-\(page.rawValue)-\(dark ? "dark" : "light").png")
          try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
          try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.contentView = nil
      }
    }
  }
}

@MainActor
private final class MenuOnlyFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let defaults: UserDefaults
  let googleAccounts: GoogleAccountManager
  let accounts: CodexAccountManager
  let store: QuotaStore
  let model: QuotaAssistantModel

  init(
    populated: Bool = false, localUsageFetcher: any CodexLocalUsageFetching = CodexCostHelper()
  ) throws {
    defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
    let payload = try JSONSerialization.data(withJSONObject: [
      "email": "menu-fixture@example.test",
      "https://api.openai.com/auth": ["chatgpt_account_id": "menu-fixture"],
    ]).base64EncodedString()
    let auth = try JSONSerialization.data(withJSONObject: [
      "tokens": [
        "account_id": "menu-fixture", "access_token": "fixture-only",
        "refresh_token": "fixture-only", "id_token": "header.\(payload).signature",
      ]
    ])
    googleAccounts = GoogleAccountManager(fileURL: root.appendingPathComponent("google-accounts.json"))
    accounts = CodexAccountManager(
      paths: .init(
        applicationSupportRoot: root, managedHomesRoot: root.appendingPathComponent("homes"),
        accountStoreURL: root.appendingPathComponent("accounts.json"),
        liveHomeURL: root.appendingPathComponent("live")), environment: [:],
      loginRunner: { home, _ in
        do {
          try auth.write(to: URL(fileURLWithPath: home).appendingPathComponent("auth.json"))
          return .init(outcome: .success, output: "")
        } catch { return .init(outcome: .failed, output: "fixture write failed") }
      })
    let cache = QuotaCacheStore(fileURL: root.appendingPathComponent("quota.json"))
    let accountKey = try XCTUnwrap(CodexAuthIdentityReader.state(from: auth)?.identity?.cacheKey)
    var billEvents: [CycleTokenEvent] = []
    if populated {
      let now = Date()
      billEvents = [CycleTokenEvent(
        id: "bill-fixture", at: now.addingTimeInterval(-200), model: "fixture",
        input: 12_000_000, cached: 8_000_000, output: 300_000,
        resets: [10080: Int(now.addingTimeInterval(86400).timeIntervalSince1970)], cost: 15.75)]
      var credits = QuotaResetCredits(
        availableCount: 2,
        expirationDates: [now.addingTimeInterval(86400), now.addingTimeInterval(172800)])
      credits.details = (1...2).map {
        QuotaResetCredit(
          id: "fixture-\($0)", status: "available",
          expiresAt: now.addingTimeInterval(Double($0) * 86400), scope: "完全重置")
      }
      var snapshot = QuotaSnapshot(
        provider: .codex, session: nil,
        weekly: .init(
          usedPercent: 82, resetsAt: now.addingTimeInterval(86400), windowMinutes: 10080),
        resetCredits: credits, accountEmail: "menu-fixture@example.test",
        accountKey: accountKey,
        accountPlan: "Pro", source: "fixture", updatedAt: now, freshness: .fresh, message: nil)
      snapshot.subscriptionCheck = .init(
        metadata: .init(
          activeStart: nil, activeUntil: now.addingTimeInterval(20 * 86400),
          lastChecked: now, source: .subscriptionAPI, freshness: .fresh), attemptedAt: now,
        message: nil)
      cache.save([snapshot])
      var history = QuotaHistory.Archive()
      history.latest[accountKey] = snapshot
      for (seconds, used, reset) in [
        (-4000.0, 0.0, -2300.0), (-3400, 50, -2300), (-2800, 100, -2300),
        (-2200, 0, -500), (-1600, 50, -500), (-1000, 100, -500),
        (-400, 62, 86400), (-100, 82, 86400),
      ] {
        history.samples.append(
          .init(
            id: UUID(), accountKey: accountKey, kind: .weekly,
            at: now.addingTimeInterval(seconds), used: used,
            resetsAt: now.addingTimeInterval(reset), plan: "Pro"))
      }
      LocalPrivateStore.save(history, to: root.appendingPathComponent("history.json"))
      let messages = [
        "Reset all propagated. Sweet dreams.",
        "And of course, a reset is also landing by midnight today.", "An older message.",
      ]
      let signals = messages.enumerated().map { index, text in
        ResetSignal(
          id: "209868536705861239\(index)",
          publishedAt: now.addingTimeInterval(-Double(index) * 3600),
          discoveredAt: now, excerpt: text, state: .completed, deadline: nil, timeAssumption: "",
          scope: "",
          verified: true, linkedPostID: nil, resolutionID: nil)
      }
      LocalPrivateStore.save(
        ResetSignalStore.Archive(signals: signals, lastSuccess: now),
        to: root.appendingPathComponent("signals.json"))
    }
    store = QuotaStore(cacheStore: cache, identityProvider: { populated ? accountKey : nil })
    let dashboard = CodexDashboardStore(
      quotaStore: store, accountManager: accounts, localUsageFetcher: localUsageFetcher)
    model = QuotaAssistantModel(
      dashboard: dashboard, accounts: accounts,
      history: QuotaHistory(url: root.appendingPathComponent("history.json")),
      signals: ResetSignalStore(
        url: root.appendingPathComponent("signals.json"), defaults: defaults),
      notifications: QuotaNotificationService(
        defaults: defaults, url: root.appendingPathComponent("notices.json"),
        inspectSystemPermission: false, client: NotificationClientFixture()),
      bills: CycleBillStore(events: billEvents, automatic: false))
  }

  func cleanUp() {
    model.stop()
    store.stop()
    defaults.removePersistentDomain(forName: root.lastPathComponent)
    try? FileManager.default.removeItem(at: root)
  }
}

private struct MenuCostFixture: CodexLocalUsageFetching {
  func fetch(forceRefresh: Bool) async throws -> CodexLocalUsageSnapshot {
    let now = Date()
    let date = DateFormatter()
    date.locale = Locale(identifier: "en_US_POSIX")
    date.dateFormat = "yyyy-MM-dd"
    return try CodexCostHelper.decode("""
      [{"provider":"codex","source":"local","updatedAt":"\(ISO8601DateFormatter().string(from: now))",
        "historyDays":30,"daily":[{"date":"\(date.string(from: now))",
        "totalTokens":202420000,"totalCost":395.89}]}]
      """)
  }
}
