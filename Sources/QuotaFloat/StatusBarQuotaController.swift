import AppKit
import Combine
import CoreText
import SwiftUI

struct StatusBarQuotaDisplay: Equatable {
  let sessionLine: String
  let weeklyLine: String
  let iconRemainingPercent: Double?
}

enum StatusBarQuotaFormatter {
  static func display(for snapshot: QuotaSnapshot?, isRefreshing: Bool) -> StatusBarQuotaDisplay {
    if isRefreshing, snapshot == nil {
      return StatusBarQuotaDisplay(
        sessionLine: "5h --", weeklyLine: "W --", iconRemainingPercent: nil)
    }

    guard let snapshot else {
      return StatusBarQuotaDisplay(
        sessionLine: "5h --", weeklyLine: "W --", iconRemainingPercent: nil)
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
      return StatusBarQuotaDisplay(sessionLine: "Codex", weeklyLine: "登录", iconRemainingPercent: 0)
    case .unavailable:
      prefix = "!"
    }

    return StatusBarQuotaDisplay(
      sessionLine: "\(prefix)5h \(Self.percent(snapshot.session))",
      weeklyLine: "\(prefix)W \(Self.percent(snapshot.weekly))",
      iconRemainingPercent: Self.iconRemainingPercent(for: snapshot))
  }

  static func detailLines(for snapshot: QuotaSnapshot?) -> [String] {
    guard let snapshot else {
      return ["Codex：等待首次同步"]
    }

    var lines = [
      "Codex 5h：\(Self.percent(snapshot.session))，\(Self.resetText(snapshot.session))",
      "Codex 周额度：\(Self.percent(snapshot.weekly))，\(Self.resetText(snapshot.weekly))",
      "来源：\(snapshot.source)",
      "更新：\(RelativeTimeFormatter.string(from: snapshot.updatedAt, to: Date()))",
    ]
    if let message = snapshot.message {
      lines.append(message)
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
      return snapshot.session?.remainingPercent
    case .fresh, .cached:
      return snapshot.session?.remainingPercent
    }
  }

  private static func resetText(_ window: QuotaWindow?) -> String {
    ResetTimeFormatter.string(window, now: Date())
  }
}

@MainActor
final class StatusBarQuotaController: NSObject {
  private let store: QuotaStore
  private let accountManager: CodexAccountManager
  private let dashboardStore: CodexDashboardStore
  private let launchAtLoginController: LaunchAtLoginController
  private let statusItem: NSStatusItem
  private let statusView = StatusBarQuotaView()
  private var cancellables: Set<AnyCancellable> = []

  init(
    store: QuotaStore,
    accountManager: CodexAccountManager,
    launchAtLoginController: LaunchAtLoginController = LaunchAtLoginController()
  ) {
    self.store = store
    self.accountManager = accountManager
    self.dashboardStore = CodexDashboardStore(quotaStore: store)
    self.launchAtLoginController = launchAtLoginController
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    self.configureButton()
    self.observeStore()
    self.update()
    self.dashboardStore.refreshLocalUsage()
  }

  private func configureButton() {
    self.statusItem.length = 64
    guard let button = self.statusItem.button else { return }
    button.title = ""
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleNone
    button.toolTip = "Codex 额度"
  }

  private func observeStore() {
    self.store.$snapshots
      .combineLatest(self.store.$isRefreshing)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.update()
      }
      .store(in: &self.cancellables)

    self.accountManager.$accounts
      .combineLatest(
        self.accountManager.$isBusy,
        self.accountManager.$currentSystemEmail
      )
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.update() }
      .store(in: &self.cancellables)
  }

  private func update() {
    let snapshot = self.store.snapshot(for: .codex)
    self.statusView.update(
      StatusBarQuotaFormatter.display(for: snapshot, isRefreshing: self.store.isRefreshing))
    self.statusItem.button?.image = self.statusView.renderedImage()
    self.statusItem.menu = self.makeMenu(snapshot: snapshot)
  }

  private func makeMenu(snapshot: QuotaSnapshot?) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false

    let dashboardItem = NSMenuItem()
    let dashboardView = CodexDashboardView(store: self.dashboardStore)
    let hostingView = NSHostingView(rootView: dashboardView)
    hostingView.frame = NSRect(x: 0, y: 0, width: 350, height: 460)
    dashboardItem.view = hostingView
    dashboardItem.isEnabled = true
    menu.addItem(dashboardItem)

    menu.addItem(.separator())

    let accountHeader = NSMenuItem(title: "Codex 账号", action: nil, keyEquivalent: "")
    accountHeader.isEnabled = false
    menu.addItem(accountHeader)

    for account in self.accountManager.accounts {
      let label = account.workspaceLabel.map { "\(account.email) · \($0)" } ?? account.email
      let item = NSMenuItem(
        title: label,
        action: #selector(self.switchAccount(_:)),
        keyEquivalent: "")
      item.target = self
      item.representedObject = account.id.uuidString
      item.state = account.isCurrentSystemAccount ? .on : .off
      item.isEnabled = !self.accountManager.isBusy && !account.isCurrentSystemAccount
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

    let refreshItem = NSMenuItem(
      title: self.store.isRefreshing ? "正在刷新…" : "立即刷新",
      action: #selector(self.refresh),
      keyEquivalent: "r")
    refreshItem.target = self
    refreshItem.isEnabled = !self.store.isRefreshing
    menu.addItem(refreshItem)

    let loginItem = NSMenuItem(
      title: "开机自启动",
      action: #selector(self.toggleLaunchAtLogin),
      keyEquivalent: "")
    loginItem.target = self
    loginItem.state = self.launchAtLoginController.isEnabled ? .on : .off
    menu.addItem(loginItem)

    let cleanupItem = NSMenuItem(
      title: "清理旧版本凭据…",
      action: #selector(self.cleanLegacyKimiCredential),
      keyEquivalent: "")
    cleanupItem.target = self
    menu.addItem(cleanupItem)

    menu.addItem(.separator())

    let quitItem = NSMenuItem(
      title: "退出 codex额度显示器",
      action: #selector(self.quit),
      keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)

    return menu
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
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await self.accountManager.switchSystemAccount(id: id)
        self.store.invalidateAndRefresh(.codex)
        self.dashboardStore.refreshLocalUsage(force: true)
        self.offerCodexRestartIfNeeded()
      } catch {
        self.showAccountError(title: "无法切换 Codex 账号", error: error)
      }
    }
  }

  @objc private func removeAccount(_ sender: NSMenuItem) {
    guard let rawID = sender.representedObject as? String, let id = UUID(uuidString: rawID) else {
      return
    }
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
    do {
      _ = try self.launchAtLoginController.toggle()
      self.update()
    } catch {
      self.showLaunchAtLoginError(error)
    }
  }

  @objc private func cleanLegacyKimiCredential() {
    let alert = NSAlert()
    alert.messageText = "删除旧 Kimi 凭据？"
    alert.informativeText =
      "新版本不再支持或读取 Kimi。此操作会永久删除 QuotaFloat 旧版本保存的 Kimi 钥匙串项目和旧密钥文件。"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "删除")
    alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      try LegacyProviderCredentialCleaner.removeRemnants()
      self.update()
    } catch {
      self.showAccountError(title: "无法删除旧 Kimi 凭据", error: error)
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
  private let iconView = QuotaStatusIconView()
  private let sessionLabel = NSTextField(labelWithString: "5h --")
  private let weeklyLabel = NSTextField(labelWithString: "W --")

  override init(frame frameRect: NSRect) {
    super.init(frame: NSRect(x: 0, y: 0, width: 64, height: 22))
    self.setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    self.setup()
  }

  private func setup() {
    self.toolTip = "Codex 额度"
    self.wantsLayer = true

    self.iconView.translatesAutoresizingMaskIntoConstraints = false
    self.sessionLabel.translatesAutoresizingMaskIntoConstraints = false
    self.weeklyLabel.translatesAutoresizingMaskIntoConstraints = false

    for label in [self.sessionLabel, self.weeklyLabel] {
      label.font = .monospacedSystemFont(ofSize: 9.2, weight: .semibold)
      label.textColor = .white
      label.alignment = .left
      label.lineBreakMode = .byClipping
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    let textStack = NSStackView(views: [self.sessionLabel, self.weeklyLabel])
    textStack.orientation = .vertical
    textStack.spacing = -1
    textStack.alignment = .leading
    textStack.translatesAutoresizingMaskIntoConstraints = false

    self.addSubview(self.iconView)
    self.addSubview(textStack)

    NSLayoutConstraint.activate([
      self.iconView.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 3),
      self.iconView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      self.iconView.widthAnchor.constraint(equalToConstant: 15),
      self.iconView.heightAnchor.constraint(equalToConstant: 15),

      textStack.leadingAnchor.constraint(equalTo: self.iconView.trailingAnchor, constant: 3),
      textStack.trailingAnchor.constraint(lessThanOrEqualTo: self.trailingAnchor, constant: -2),
      textStack.centerYAnchor.constraint(equalTo: self.centerYAnchor),
    ])
  }

  func update(_ display: StatusBarQuotaDisplay) {
    self.sessionLabel.stringValue = display.sessionLine
    self.weeklyLabel.stringValue = display.weeklyLine
    self.iconView.remainingPercent = display.iconRemainingPercent
    self.needsDisplay = true
  }

  func renderedImage() -> NSImage {
    let renderBounds = NSRect(x: 0, y: 0, width: 64, height: 22)
    self.frame = renderBounds
    self.layoutSubtreeIfNeeded()

    guard let representation = self.bitmapImageRepForCachingDisplay(in: renderBounds) else {
      return NSImage(size: renderBounds.size)
    }
    self.cacheDisplay(in: renderBounds, to: representation)

    let image = NSImage(size: renderBounds.size)
    image.addRepresentation(representation)
    image.isTemplate = false
    return image
  }
}

final class QuotaStatusIconView: NSView {
  var remainingPercent: Double? {
    didSet { self.needsDisplay = true }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let font = NSFont.systemFont(ofSize: 14, weight: .black)
    guard let path = Self.letterPath("C", font: font, in: self.bounds.insetBy(dx: 0.5, dy: 0.5))
    else { return }

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
