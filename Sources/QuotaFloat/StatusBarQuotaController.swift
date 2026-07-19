import AppKit
import Combine
import CoreText

struct StatusBarQuotaDisplay: Equatable {
  let sessionLine: String
  let weeklyLine: String
  let iconRemainingPercent: Double?
}

enum StatusBarQuotaFormatter {
  static func display(for snapshot: QuotaSnapshot?, isRefreshing: Bool) -> StatusBarQuotaDisplay {
    if isRefreshing, snapshot == nil {
      return StatusBarQuotaDisplay(sessionLine: "5h --", weeklyLine: "W --", iconRemainingPercent: nil)
    }

    guard let snapshot else {
      return StatusBarQuotaDisplay(sessionLine: "5h --", weeklyLine: "W --", iconRemainingPercent: nil)
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
  private let launchAtLoginController: LaunchAtLoginController
  private let statusItem: NSStatusItem
  private let statusView = StatusBarQuotaView()
  private var cancellables: Set<AnyCancellable> = []

  init(store: QuotaStore, launchAtLoginController: LaunchAtLoginController = LaunchAtLoginController()) {
    self.store = store
    self.launchAtLoginController = launchAtLoginController
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    self.configureButton()
    self.observeStore()
    self.update()
  }

  private func configureButton() {
    self.statusItem.length = 64
    guard let button = self.statusItem.button else { return }
    button.title = ""
    button.image = nil
    button.toolTip = "Codex 额度"
    button.addSubview(self.statusView)
    self.statusView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      self.statusView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
      self.statusView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
      self.statusView.topAnchor.constraint(equalTo: button.topAnchor),
      self.statusView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
    ])
  }

  private func observeStore() {
    self.store.$snapshots
      .combineLatest(self.store.$isRefreshing)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.update()
      }
      .store(in: &self.cancellables)
  }

  private func update() {
    let snapshot = self.store.snapshot(for: .codex)
    self.statusView.update(
      StatusBarQuotaFormatter.display(for: snapshot, isRefreshing: self.store.isRefreshing))
    self.statusItem.menu = self.makeMenu(snapshot: snapshot)
  }

  private func makeMenu(snapshot: QuotaSnapshot?) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false

    for line in StatusBarQuotaFormatter.detailLines(for: snapshot) {
      let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
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
    self.store.refresh()
    self.update()
  }

  @objc private func toggleLaunchAtLogin() {
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
    alert.informativeText = "请先把 codex额度显示器.app 放入“应用程序”文件夹，然后再打开菜单重试。\n\n\(error.localizedDescription)"
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
      label.textColor = .labelColor
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

  override func hitTest(_ point: NSPoint) -> NSView? {
    _ = point
    return nil
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

  private static func interpolate(from start: NSColor, to end: NSColor, progress: Double) -> NSColor {
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
