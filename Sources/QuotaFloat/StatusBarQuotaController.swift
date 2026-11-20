import AppKit
import Combine
import CoreText
import SwiftUI

private struct DashboardMenuSurface: View {
  @ObservedObject var store: CodexDashboardStore
  var body: some View {
    ScrollView(.vertical) {
      CodexDashboardView(store: store)
    }
    .scrollIndicators(.automatic)
    .frame(width: 300, height: 430, alignment: .top)
  }
}

struct StatusBarQuotaDisplay: Equatable {
  let sessionLine: String
  let weeklyLine: String
  let iconRemainingPercent: Double?
  let googleTopLine: String?
  let googleBottomLine: String?
  let googleIconRemainingPercent: Double?

  init(
    sessionLine: String,
    weeklyLine: String,
    iconRemainingPercent: Double?,
    googleTopLine: String? = nil,
    googleBottomLine: String? = nil,
    googleIconRemainingPercent: Double? = nil
  ) {
    self.sessionLine = sessionLine
    self.weeklyLine = weeklyLine
    self.iconRemainingPercent = iconRemainingPercent
    self.googleTopLine = googleTopLine
    self.googleBottomLine = googleBottomLine
    self.googleIconRemainingPercent = googleIconRemainingPercent
  }
}

enum StatusBarQuotaFormatter {
  static func display(for snapshot: QuotaSnapshot?, isRefreshing: Bool) -> StatusBarQuotaDisplay {
    self.display(codex: snapshot, google: nil, isRefreshing: isRefreshing, includeGoogle: false)
  }

  static func display(
    codex snapshot: QuotaSnapshot?,
    google: QuotaSnapshot?,
    isRefreshing: Bool,
    includeGoogle: Bool = true
  ) -> StatusBarQuotaDisplay {
    let googleTop: String?
    let googleBottom: String?
    let googlePct: Double?
    if includeGoogle {
      if let google, google.hasQuotaData {
        let gPrefix: String =
          switch google.freshness {
          case .fresh: ""
          case .cached: "~"
          case .stale, .unavailable, .authRequired: "!"
          }
        googleTop = "\(gPrefix)5h \(Self.percent(google.session))"
        googleBottom = "\(gPrefix)W \(Self.percent(google.weekly))"
        googlePct = google.session?.remainingPercent ?? google.weekly?.remainingPercent
      } else {
        googleTop = "5h --"
        googleBottom = "W --"
        googlePct = nil
      }
    } else {
      googleTop = nil
      googleBottom = nil
      googlePct = nil
    }

    if isRefreshing, snapshot == nil {
      return StatusBarQuotaDisplay(
        sessionLine: "5h --", weeklyLine: "W --", iconRemainingPercent: nil,
        googleTopLine: googleTop, googleBottomLine: googleBottom,
        googleIconRemainingPercent: googlePct)
    }

    guard let snapshot else {
      return StatusBarQuotaDisplay(
        sessionLine: "5h --", weeklyLine: "W --", iconRemainingPercent: nil,
        googleTopLine: googleTop, googleBottomLine: googleBottom,
        googleIconRemainingPercent: googlePct)
    }

    let prefix: String
    switch snapshot.freshness {
    case .fresh:
      prefix = ""
    case .cached:
      prefix = "~"
    case .stale:
      prefix = "!"
    case .authRequired:
      return StatusBarQuotaDisplay(
        sessionLine: "Codex", weeklyLine: "登录", iconRemainingPercent: 0,
        googleTopLine: googleTop, googleBottomLine: googleBottom,
        googleIconRemainingPercent: googlePct)
    case .unavailable:
      prefix = "!"
    }

    return StatusBarQuotaDisplay(
      sessionLine: "\(prefix)5h \(Self.percent(snapshot.session))",
      weeklyLine: "\(prefix)W \(Self.percent(snapshot.weekly))",
      iconRemainingPercent: Self.iconRemainingPercent(for: snapshot),
      googleTopLine: googleTop,
      googleBottomLine: googleBottom,
      googleIconRemainingPercent: googlePct)
  }

  static func detailLines(for snapshot: QuotaSnapshot?, google: QuotaSnapshot? = nil) -> [String] {
    var lines: [String]
    if let snapshot {
      lines = [
        "Codex 5h：\(Self.percent(snapshot.session))，\(Self.resetText(snapshot.session))",
        "Codex 周额度：\(Self.percent(snapshot.weekly))，\(Self.resetText(snapshot.weekly))",
        "来源：\(snapshot.source)",
        "更新：\(RelativeTimeFormatter.string(from: snapshot.updatedAt, to: Date()))",
      ]
      if let message = snapshot.message {
        lines.append(message)
      }
    } else {
      lines = ["Codex：等待首次同步"]
    }

    if let google {
      if google.hasQuotaData {
        lines.append("Google Gemini 5h：\(Self.percent(google.session))，\(Self.resetText(google.session))")
        lines.append("Google Gemini 周额度：\(Self.percent(google.weekly))，\(Self.resetText(google.weekly))")
      } else if let msg = google.message {
        lines.append("Google：\(msg)")
      }
    }
    return lines
  }

  private static func percent(_ window: QuotaWindow?) -> String {
    guard let window else { return "--" }
    return "\(Int(window.remainingPercent.rounded()))%"
  }

  private static func iconRemainingPercent(for snapshot: QuotaSnapshot) -> Double? {
    switch snapshot.freshness {
    case .authRequired, .unavailable:
      return 0
    case .stale:
      return snapshot.session?.remainingPercent ?? snapshot.weekly?.remainingPercent
    case .fresh, .cached:
      return snapshot.session?.remainingPercent ?? snapshot.weekly?.remainingPercent
    }
  }

  private static func resetText(_ window: QuotaWindow?) -> String {
    ResetTimeFormatter.string(window, now: Date())
  }
}

@MainActor
final class StatusBarQuotaController: NSObject, NSMenuDelegate, NSPopoverDelegate {
  private let store: QuotaStore
  private let accountManager: CodexAccountManager
  private let dashboardStore: CodexDashboardStore
  private let launchAtLoginController: LaunchAtLoginController
  private let onAuthMutation: @MainActor () -> Void
  private let statusItem: NSStatusItem
  private let statusView = StatusBarQuotaView()
  private var cancellables: Set<AnyCancellable> = []
  private var assistant: QuotaAssistantModel!
  private var popover: NSPopover?
  private var popoverHostingController: NSHostingController<QuotaPopoverView>?
  private var dashboardHostingView: NSHostingView<DashboardMenuSurface>!
  private let dashboardMenuItem = NSMenuItem(title: "Codex 额度概览", action: nil, keyEquivalent: "")
  private var detailHostingViews: [QuotaMenuPage: NSHostingView<QuotaDetailsView>] = [:]
  private var detailMenuItems: [QuotaMenuPage: NSMenuItem] = [:]
  private var menuIsOpen = false
  private var wakeObserver: NSObjectProtocol?

  init(
    store: QuotaStore,
    accountManager: CodexAccountManager,
    launchAtLoginController: LaunchAtLoginController = LaunchAtLoginController(),
    assistant: QuotaAssistantModel? = nil,
    startsAutomatically: Bool = true,
    onAuthMutation: @escaping @MainActor () -> Void = {}
  ) {
    self.store = store
    self.accountManager = accountManager
    self.onAuthMutation = onAuthMutation
    self.dashboardStore =
      assistant?.dashboard
      ?? CodexDashboardStore(
        quotaStore: store,
        accountManager: accountManager)
    self.launchAtLoginController = launchAtLoginController
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    self.assistant =
      assistant ?? QuotaAssistantModel(dashboard: self.dashboardStore, accounts: accountManager)
    self.dashboardHostingView = NSHostingView(
      rootView: DashboardMenuSurface(store: self.dashboardStore))
    self.dashboardMenuItem.view = self.dashboardHostingView
    self.dashboardMenuItem.setAccessibilityChildren([self.dashboardHostingView!])
    self.dashboardMenuItem.isEnabled = true
    self.configureButton()
    self.configurePopover()
    self.observeStore()
    self.update()
    guard startsAutomatically else { return }
    self.dashboardStore.start()
    self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.accountManager.reload()
        self?.store.refresh()
        self?.dashboardStore.refreshLocalUsage(force: true)
      }
    }
  }

  private func configureButton() {
    self.statusItem.length = StatusBarQuotaView.dualWidth
    guard let button = self.statusItem.button else { return }
    button.title = ""
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleNone
    button.toolTip = "Codex & Google 额度"
    button.target = self
    button.action = #selector(self.togglePopover(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
  }

  private func configurePopover() {
    let actions = QuotaPopoverActions(
      onRefresh: { [weak self] in self?.refresh() },
      onSwitchAccount: { [weak self] id in self?.switchAccount(id: id) },
      onAddAccount: { [weak self] in self?.addAccount() },
      onRemoveAccount: { [weak self] id in self?.removeAccount(id: id) },
      onToggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() },
      isLaunchAtLoginEnabled: { [weak self] in self?.launchAtLoginController.isEnabled ?? false },
      launchAtLoginRequiresApproval: { [weak self] in
        self?.launchAtLoginController.requiresApproval ?? false
      },
      beforeNotificationPermission: { [weak self] in
        await self?.prepareForNotificationPermission()
      },
      onNotificationSettings: { [weak self] in self?.openNotificationSettings() },
      onQuit: { [weak self] in self?.quit() })
    let rootView = QuotaPopoverView(model: self.assistant, actions: actions)
    let hosting = NSHostingController(rootView: rootView)
    hosting.sizingOptions = [.preferredContentSize]
    let popover = NSPopover()
    popover.behavior = .transient
    popover.animates = true
    popover.delegate = self
    popover.contentViewController = hosting
    self.popoverHostingController = hosting
    self.popover = popover
  }

  @objc private func togglePopover(_ sender: AnyObject?) {
    _ = sender
    guard let popover = self.popover, let button = self.statusItem.button else { return }
    if popover.isShown {
      popover.performClose(nil)
    } else {
      self.dashboardStore.tick(menuOpened: true)
      Task { [weak self] in await self?.assistant.notifications.refreshPermission() }
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      popover.contentViewController?.view.window?.makeKey()
    }
  }

  func popoverWillShow(_ notification: Notification) {
    _ = notification
    self.menuIsOpen = true
  }

  func popoverDidClose(_ notification: Notification) {
    _ = notification
    self.menuIsOpen = false
  }

  private func observeStore() {
    self.store.$snapshots
      .combineLatest(self.store.$isRefreshing)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.update()
      }
      .store(in: &self.cancellables)

    self.accountManager.$accounts
      .combineLatest(
        self.accountManager.$isBusy,
        self.accountManager.$currentSystemEmail
      )
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.update() }
      .store(in: &self.cancellables)

    self.accountManager.$currentSubscription
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.update() }
      .store(in: &self.cancellables)
  }

  private func update() {
    let snapshot = self.store.snapshot(for: .codex)
    let google = self.store.snapshot(for: .antigravity)
    self.statusView.update(
      StatusBarQuotaFormatter.display(
        codex: snapshot, google: google, isRefreshing: self.store.isRefreshing))
    self.statusItem.length = self.statusView.currentWidth
    self.statusItem.button?.image = self.statusView.renderedImage()
    self.statusItem.button?.toolTip = StatusBarQuotaFormatter.detailLines(
      for: snapshot, google: google
    ).joined(separator: "\n")
  }

  func menuWillOpen(_ menu: NSMenu) {
    self.menuIsOpen = true
    self.dashboardStore.tick(menuOpened: true)
    Task { [weak self] in await self?.assistant.notifications.refreshPermission() }
  }

  func menuDidClose(_ menu: NSMenu) {
    self.menuIsOpen = false
    Task { @MainActor [weak self] in
      await Task.yield()
      self?.update()
    }
  }

  func stop() {
    self.popover?.performClose(nil)
    self.popover = nil
    self.popoverHostingController = nil
    self.assistant.stop()
    if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    self.cancellables.removeAll()
    self.statusItem.menu = nil
    NSStatusBar.system.removeStatusItem(self.statusItem)
  }

  func makeMenu(snapshot: QuotaSnapshot?) -> NSMenu {
    let menu = NSMenu()
    menu.delegate = self
    menu.autoenablesItems = false
    menu.minimumWidth = 300

    // Keep each host bound to one item: deallocating an old owner detaches even a reused view.
    self.dashboardMenuItem.menu?.removeItem(self.dashboardMenuItem)
    self.dashboardHostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 430)
    menu.addItem(self.dashboardMenuItem)

    menu.addItem(.separator())

    let accountHeader = NSMenuItem(title: "Codex 账号", action: nil, keyEquivalent: "")
    accountHeader.isEnabled = false
    menu.addItem(accountHeader)

    for account in self.accountManager.accounts {
      let subscriptionSnapshot =
        snapshot?.accountKey == account.accountKey
        ? snapshot : account.accountKey.flatMap { assistant.history.archive.latest[$0] }
      let subscription = CodexSubscriptionCheck.resolve(
        record: account.subscription, snapshot: subscriptionSnapshot, accountKey: account.accountKey
      )
      let label = Self.accountMenuLabel(for: account, subscription: subscription)
      let item = NSMenuItem(
        title: label,
        action: #selector(self.switchAccount(_:)),
        keyEquivalent: "")
      item.target = self
      item.representedObject = account.id.uuidString
      item.state = account.isCurrentSystemAccount ? .on : .off
      item.isEnabled = !self.accountManager.isBusy && !account.isCurrentSystemAccount
      item.toolTip = Self.accountMenuTooltip(for: account, subscription: subscription)
      menu.addItem(item)
    }

    let addAccountItem = NSMenuItem(
      title: self.accountManager.isBusy ? "账号操作进行中…" : "添加 Codex 账号…",
      action: #selector(self.addAccount),
      keyEquivalent: "")
    addAccountItem.target = self
    addAccountItem.isEnabled = !self.accountManager.isBusy
    menu.addItem(addAccountItem)

    if !self.accountManager.accounts.isEmpty {
      let manageItem = NSMenuItem(title: "移除已保存账号", action: nil, keyEquivalent: "")
      let removeMenu = NSMenu()
      for account in self.accountManager.accounts where !account.isCurrentSystemAccount {
        let item = NSMenuItem(
          title: account.email,
          action: #selector(self.removeAccount(_:)),
          keyEquivalent: "")
        item.target = self
        item.representedObject = account.id.uuidString
        removeMenu.addItem(item)
      }
      if !removeMenu.items.isEmpty {
        manageItem.submenu = removeMenu
        menu.addItem(manageItem)
      }
    }

    menu.addItem(.separator())

    menu.addItem(self.detailMenuItem(.planning))
    menu.addItem(self.detailMenuItem(.messages))
    menu.addItem(self.detailMenuItem(.overview))
    menu.addItem(self.detailMenuItem(.accounts))
    menu.addItem(self.detailMenuItem(.settings))
    menu.addItem(.separator())

    let refreshItem = NSMenuItem(
      title: self.store.isRefreshing ? "正在刷新…" : "立即刷新",
      action: #selector(self.refresh),
      keyEquivalent: "r")
    refreshItem.target = self
    refreshItem.isEnabled = !self.store.isRefreshing
    menu.addItem(refreshItem)

    let loginItem = NSMenuItem(
      title: self.launchAtLoginController.requiresApproval ? "开机自启动（待系统批准）" : "开机自启动",
      action: #selector(self.toggleLaunchAtLogin),
      keyEquivalent: "")
    loginItem.target = self
    loginItem.state = self.launchAtLoginController.isEnabled ? .on : .off
    menu.addItem(loginItem)

    menu.addItem(.separator())

    let quitItem = NSMenuItem(
      title: "退出 codex额度显示器",
      action: #selector(self.quit),
      keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)

    return menu
  }

  private func detailMenuItem(_ page: QuotaMenuPage) -> NSMenuItem {
    let item = NSMenuItem(title: page.title, action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: page.title)
    submenu.autoenablesItems = false
    let height = min(
      page.preferredHeight, max(180, (NSScreen.main?.visibleFrame.height ?? 700) - 80))
    let host: NSHostingView<QuotaDetailsView>
    if let existing = self.detailHostingViews[page] {
      host = existing
      host.rootView.height = height
    } else {
      host = NSHostingView(
        rootView: QuotaDetailsView(
          model: self.assistant, page: page, height: height,
          onExport: { [weak self] text in self?.exportDiagnostic(text) },
          beforeNotificationPermission: { [weak self] in
            await self?.prepareForNotificationPermission()
          },
          onNotificationSettings: { [weak self] in self?.openNotificationSettings() }))
      self.detailHostingViews[page] = host
    }
    let content: NSMenuItem
    if let existing = self.detailMenuItems[page] {
      content = existing
    } else {
      content = NSMenuItem(title: page.title, action: nil, keyEquivalent: "")
      content.view = host
      content.setAccessibilityChildren([host])
      content.isEnabled = true
      self.detailMenuItems[page] = content
    }
    content.menu?.removeItem(content)
    host.frame = NSRect(x: 0, y: 0, width: 300, height: height)
    submenu.addItem(content)
    item.submenu = submenu
    return item
  }

  func showMenu() {
    Self.scheduleMenuPresentation { [weak self] in
      self?.statusItem.button?.performClick(nil)
    }
  }

  static func scheduleMenuPresentation(_ present: @escaping @MainActor () -> Void) {
    // Menu tracking must not hold a main-queue job open while controls await that same queue.
    RunLoop.main.perform(inModes: [.default]) {
      MainActor.assumeIsolated { present() }
    }
  }

  private func prepareForNotificationPermission() async {
    self.popover?.performClose(nil)
    self.statusItem.menu?.cancelTracking()
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
        continuation.resume()
      }
    }
  }

  private func openNotificationSettings() {
    self.popover?.performClose(nil)
    self.statusItem.menu?.cancelTracking()
    DispatchQueue.main.async {
      guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
      else { return }
      NSWorkspace.shared.open(url)
    }
  }

  private func exportDiagnostic(_ text: String) {
    self.statusItem.menu?.cancelTracking()
    DispatchQueue.main.async { [weak self] in
      let panel = NSSavePanel()
      panel.nameFieldStringValue = "codex-quota-diagnostics.json"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      do {
        try Data(text.utf8).write(to: url, options: .atomic)
      } catch {
        self?.showAccountError(title: "无法导出诊断", error: error)
      }
    }
  }

  private static func accountMenuLabel(
    for account: CodexManagedAccountViewModel, subscription: CodexSubscriptionMetadata?
  ) -> String {
    let dateText = Self.subscriptionShortText(subscription)
    let workspace = account.workspaceLabel.map { " · \($0)" } ?? ""
    let maxEmailLength = workspace.isEmpty ? 25 : 19
    let email = Self.compactEmail(account.email, maxLength: maxEmailLength)
    return "\(email)\(workspace) · \(dateText)"
  }

  private static func accountMenuTooltip(
    for account: CodexManagedAccountViewModel, subscription: CodexSubscriptionMetadata?
  ) -> String {
    var lines = [account.email]
    if let workspaceLabel = account.workspaceLabel, !workspaceLabel.isEmpty {
      lines.append("Workspace：\(workspaceLabel)")
    }
    if let subscription {
      if let activeStart = subscription.activeStart {
        lines.append("本期开始：\(Self.subscriptionDate(activeStart))")
      }
      if let activeUntil = subscription.activeUntil {
        lines.append(
          "有效至：\(QuotaDetailsView.date(activeUntil))（\(subscription.verificationText())）")
      }
      if let lastChecked = subscription.lastChecked {
        lines.append(
          "\(subscription.source == .idToken ? "登录声明时间" : "接口核验时间")：\(Self.subscriptionDateTime(lastChecked))"
        )
      }
    } else {
      lines.append("订阅日期未知")
    }
    return lines.joined(separator: "\n")
  }

  private static func subscriptionShortText(_ subscription: CodexSubscriptionMetadata?) -> String {
    guard let subscription else { return "日期未知" }
    guard subscription.isVerified() else { return subscription.verificationText() }
    switch subscription.status() {
    case .expired:
      return "已到期"
    case .expiresToday:
      return "今日到期"
    case .active, .expiringSoon:
      guard let activeUntil = subscription.activeUntil else { return "日期未知" }
      return Self.subscriptionDate(activeUntil)
    case .unknown:
      return "日期未知"
    }
  }

  private static func compactEmail(_ email: String, maxLength: Int) -> String {
    let characters = Array(email)
    guard characters.count > maxLength, maxLength > 5 else { return email }
    let leftCount = max(2, (maxLength - 1) / 2)
    let rightCount = max(2, maxLength - leftCount - 1)
    return String(characters.prefix(leftCount))
      + "…"
      + String(characters.suffix(rightCount))
  }

  private static func subscriptionDate(_ value: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "M/d"
    return formatter.string(from: value)
  }

  private static func subscriptionDateTime(_ value: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "M/d HH:mm"
    return formatter.string(from: value)
  }

  @objc private func refresh() {
    self.accountManager.reload()
    self.store.refresh()
    self.dashboardStore.refreshLocalUsage(force: true)
    self.update()
  }

  @objc private func addAccount() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await self.accountManager.addAccount()
        self.store.refresh()
        self.dashboardStore.refreshLocalUsage(force: true)
      } catch {
        self.showAccountError(title: "无法添加 Codex 账号", error: error)
      }
    }
  }

  @objc private func switchAccount(_ sender: NSMenuItem) {
    guard let rawID = sender.representedObject as? String, let id = UUID(uuidString: rawID) else {
      return
    }
    self.switchAccount(id: id)
  }

  private func switchAccount(id: UUID) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.store.cancelInFlightRefresh(.codex)
      self.dashboardStore.cancelLocalUsageRefresh()
      do {
        try await self.accountManager.switchSystemAccount(id: id)
        self.onAuthMutation()
        self.store.invalidateAndRefresh(.codex)
        self.dashboardStore.refreshLocalUsage(force: true)
        self.offerCodexRestartIfNeeded()
      } catch {
        self.store.refresh()
        self.dashboardStore.refreshLocalUsage(force: true)
        self.showAccountError(title: "无法切换 Codex 账号", error: error)
      }
    }
  }

  @objc private func removeAccount(_ sender: NSMenuItem) {
    guard let rawID = sender.representedObject as? String, let id = UUID(uuidString: rawID) else {
      return
    }
    self.removeAccount(id: id)
  }

  private func removeAccount(id: UUID) {
    let alert = NSAlert()
    alert.messageText = "移除这个已保存账号？"
    alert.informativeText = "只会删除 QuotaFloat 保存的独立 Codex 登录，不会退出当前系统 Codex 账号。"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "移除")
    alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      try self.accountManager.removeAccount(id: id)
    } catch {
      self.showAccountError(title: "无法移除账号", error: error)
    }
  }

  private func offerCodexRestartIfNeeded() {
    guard
      let running = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.openai.codex"
      ).first
    else {
      return
    }
    let appURL = running.bundleURL
    let alert = NSAlert()
    alert.messageText = "Codex 系统账号已经切换"
    alert.informativeText =
      "新的 CLI 会直接使用新账号。正在运行的 Codex 可能仍缓存旧登录；为确保 Desktop 同步，需要重新打开 Codex。请先确认当前任务已经保存；若 Codex 长时间无法退出，应用会强制结束旧实例。"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "重新打开 Codex")
    alert.addButton(withTitle: "稍后")
    guard alert.runModal() == .alertFirstButtonReturn, let appURL else { return }

    Task { @MainActor [weak self] in
      do {
        try await CodexApplicationRestarter().restart(
          application: running,
          appURL: appURL)
      } catch {
        self?.showAccountError(title: "无法重新打开 Codex", error: error)
      }
    }
  }

  private func showAccountError(title: String, error: Error) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .critical
    alert.addButton(withTitle: "好")
    alert.runModal()
  }

  @objc private func toggleLaunchAtLogin() {
    if self.launchAtLoginController.requiresApproval {
      self.launchAtLoginController.openSystemSettings()
      return
    }
    do {
      _ = try self.launchAtLoginController.toggle()
      self.update()
    } catch {
      self.showLaunchAtLoginError(error)
    }
  }

  private func showLaunchAtLoginError(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "无法更新开机自启动"
    alert.informativeText =
      "请先把 codex额度显示器.app 放入“应用程序”文件夹，然后再打开菜单重试。\n\n\(error.localizedDescription)"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "好")
    alert.runModal()
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }
}

final class StatusBarQuotaView: NSView {
  static let singleWidth: CGFloat = 64
  static let dualWidth: CGFloat = 128

  private let iconView = QuotaStatusIconView(letter: "C")
  private let googleIconView = QuotaStatusIconView(letter: "G")
  private let sessionLabel = NSTextField(labelWithString: "5h --")
  private let weeklyLabel = NSTextField(labelWithString: "W --")
  private var googleTopText: String?
  private var googleBottomText: String?

  var currentWidth: CGFloat {
    self.googleTopText != nil ? Self.dualWidth : Self.singleWidth
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: NSRect(x: 0, y: 0, width: Self.dualWidth, height: 22))
    self.setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    self.setup()
  }

  private func setup() {
    self.toolTip = "Codex & Google 额度"
    self.wantsLayer = true
  }

  func update(_ display: StatusBarQuotaDisplay) {
    self.sessionLabel.stringValue = display.sessionLine
    self.weeklyLabel.stringValue = display.weeklyLine
    self.iconView.remainingPercent = display.iconRemainingPercent
    self.googleTopText = display.googleTopLine
    self.googleBottomText = display.googleBottomLine
    self.googleIconView.remainingPercent = display.googleIconRemainingPercent
    self.needsDisplay = true
  }

  func renderedImage() -> NSImage {
    let width = self.currentWidth
    let renderBounds = NSRect(x: 0, y: 0, width: width, height: 22)
    let image = NSImage(size: renderBounds.size)
    image.isTemplate = false
    image.lockFocus()
    defer { image.unlockFocus() }

    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 8.6, weight: .semibold),
      .foregroundColor: NSColor.white,
      .paragraphStyle: Self.statusTextParagraphStyle,
    ]

    // Left: Codex ("C" + 5h / W)
    self.iconView.drawIcon(in: NSRect(x: 3, y: 3.5, width: 15, height: 15))
    let codexTextRect = NSRect(x: 20, y: 1, width: 41, height: 20)
    NSAttributedString(string: self.weeklyLabel.stringValue, attributes: attributes)
      .draw(in: NSRect(x: codexTextRect.minX, y: codexTextRect.minY, width: codexTextRect.width, height: 10))
    NSAttributedString(string: self.sessionLabel.stringValue, attributes: attributes)
      .draw(in: NSRect(x: codexTextRect.minX, y: codexTextRect.minY + 10, width: codexTextRect.width, height: 10))

    // Right: Google / Antigravity ("G" + G / C)
    if let googleTop = self.googleTopText, let googleBottom = self.googleBottomText {
      NSColor.white.withAlphaComponent(0.28).setFill()
      NSRect(x: 62.5, y: 4, width: 0.8, height: 14).fill()

      self.googleIconView.drawIcon(in: NSRect(x: 66, y: 3.5, width: 15, height: 15))
      let googleTextRect = NSRect(x: 83, y: 1, width: 44, height: 20)
      NSAttributedString(string: googleBottom, attributes: attributes)
        .draw(in: NSRect(x: googleTextRect.minX, y: googleTextRect.minY, width: googleTextRect.width, height: 10))
      NSAttributedString(string: googleTop, attributes: attributes)
        .draw(in: NSRect(x: googleTextRect.minX, y: googleTextRect.minY + 10, width: googleTextRect.width, height: 10))
    }

    return image
  }

  private static let statusTextParagraphStyle: NSParagraphStyle = {
    let style = NSMutableParagraphStyle()
    style.alignment = .left
    style.lineBreakMode = .byClipping
    style.minimumLineHeight = 9
    style.maximumLineHeight = 10
    return style
  }()
}

final class QuotaStatusIconView: NSView {
  let letter: String
  var remainingPercent: Double? {
    didSet { self.needsDisplay = true }
  }

  init(letter: String = "C", frame frameRect: NSRect = .zero) {
    self.letter = letter
    super.init(frame: frameRect)
  }

  required init?(coder: NSCoder) {
    self.letter = "C"
    super.init(coder: coder)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    self.drawIcon(in: self.bounds)
  }

  func drawIcon(in rect: NSRect) {
    let font = NSFont.systemFont(ofSize: 14, weight: .black)
    guard let path = Self.letterPath(self.letter, font: font, in: rect.insetBy(dx: 0.5, dy: 0.5)) else {
      return
    }

    NSColor.black.withAlphaComponent(0.18).setStroke()
    path.lineWidth = 0.8
    path.stroke()

    Self.gradient(for: self.remainingPercent).draw(in: path, angle: -35)
  }

  private static func gradient(for remainingPercent: Double?) -> NSGradient {
    guard let remainingPercent else {
      return NSGradient(colors: [
        NSColor(calibratedRed: 0.60, green: 0.64, blue: 0.70, alpha: 1),
        NSColor(calibratedRed: 0.38, green: 0.42, blue: 0.50, alpha: 1),
      ])!
    }

    let base = Self.color(for: remainingPercent)
    let light = base.blended(withFraction: 0.35, of: .white) ?? base
    let dark = base.blended(withFraction: 0.22, of: .black) ?? base
    return NSGradient(colors: [light, base, dark])!
  }

  private static func color(for remainingPercent: Double) -> NSColor {
    let value = min(100, max(0, remainingPercent)) / 100
    let red = NSColor(calibratedRed: 0.90, green: 0.18, blue: 0.20, alpha: 1)
    let yellow = NSColor(calibratedRed: 0.96, green: 0.66, blue: 0.16, alpha: 1)
    let green = NSColor(calibratedRed: 0.18, green: 0.70, blue: 0.36, alpha: 1)
    if value < 0.35 {
      return Self.interpolate(from: red, to: yellow, progress: value / 0.35)
    }
    return Self.interpolate(from: yellow, to: green, progress: (value - 0.35) / 0.65)
  }

  private static func interpolate(from start: NSColor, to end: NSColor, progress: Double) -> NSColor
  {
    let start = start.usingColorSpace(.deviceRGB) ?? start
    let end = end.usingColorSpace(.deviceRGB) ?? end
    let t = min(1, max(0, progress))
    return NSColor(
      calibratedRed: start.redComponent + (end.redComponent - start.redComponent) * t,
      green: start.greenComponent + (end.greenComponent - start.greenComponent) * t,
      blue: start.blueComponent + (end.blueComponent - start.blueComponent) * t,
      alpha: 1)
  }

  private static func letterPath(_ string: String, font: NSFont, in rect: NSRect) -> NSBezierPath? {
    let ctFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
    let characters = Array(string.utf16)
    var glyphs = Array(repeating: CGGlyph(), count: characters.count)
    guard CTFontGetGlyphsForCharacters(ctFont, characters, &glyphs, characters.count),
      let cgPath = CTFontCreatePathForGlyph(ctFont, glyphs[0], nil)
    else {
      return nil
    }

    let path = NSBezierPath(cgPath: cgPath)
    let bounds = path.bounds
    let transform = AffineTransform(
      translationByX: rect.midX - bounds.midX,
      byY: rect.midY - bounds.midY - 0.5)
    path.transform(using: transform)
    return path
  }
}
