import AppKit
import CodexBarCore
import Combine
import CoreGraphics
import Darwin
import SwiftUI

@MainActor
final class DisplayPreferences: ObservableObject {
  static let configurationVersion = 2
  static let configurationVersionKey = "QuotaFloatDisplayConfigurationVersion"
  static let legacyStorageKey = "QuotaFloatDisplayMode"
  static let alwaysStorageKey = "QuotaFloatAlwaysDisplay"
  static let selectedAppsStorageKey = "QuotaFloatSelectedApps"

  @Published private(set) var alwaysDisplay: Bool
  @Published private(set) var selectedApps: Set<String>
  private let defaults: UserDefaults
  static let terminalBundleIdentifiers: Set<String> = [
    "com.googlecode.iterm2",
    "com.apple.Terminal",
  ]

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if defaults.object(forKey: Self.alwaysStorageKey) != nil {
      self.alwaysDisplay = defaults.bool(forKey: Self.alwaysStorageKey)
      self.selectedApps = Set(
        defaults.stringArray(forKey: Self.selectedAppsStorageKey) ?? [])
    } else {
      let legacyValue = defaults.string(forKey: Self.legacyStorageKey)
      let shouldAlwaysDisplay = legacyValue == nil || legacyValue == "always"
      self.alwaysDisplay = shouldAlwaysDisplay
      self.selectedApps =
        shouldAlwaysDisplay
        ? []
        : ["com.openai.codex"]
      self.save()
    }

    if defaults.integer(forKey: Self.configurationVersionKey) < Self.configurationVersion {
      self.save()
    }
  }

  func isEnabled(_ bundleIdentifier: String) -> Bool {
    self.selectedApps.contains(bundleIdentifier)
  }

  func toggleApp(_ bundleIdentifier: String) {
    self.alwaysDisplay = false
    if self.selectedApps.contains(bundleIdentifier) {
      self.selectedApps.remove(bundleIdentifier)
    } else {
      self.selectedApps.insert(bundleIdentifier)
    }
    self.save()
  }

  var terminalsEnabled: Bool {
    Self.terminalBundleIdentifiers.isSubset(of: self.selectedApps)
  }

  func toggleTerminals() {
    self.alwaysDisplay = false
    if self.terminalsEnabled {
      self.selectedApps.subtract(Self.terminalBundleIdentifiers)
    } else {
      self.selectedApps.formUnion(Self.terminalBundleIdentifiers)
    }
    self.save()
  }

  func selectAlwaysDisplay() {
    self.alwaysDisplay = true
    self.selectedApps.removeAll()
    self.save()
  }

  private func save() {
    self.defaults.set(Self.configurationVersion, forKey: Self.configurationVersionKey)
    self.defaults.set(self.alwaysDisplay, forKey: Self.alwaysStorageKey)
    self.defaults.set(Array(self.selectedApps).sorted(), forKey: Self.selectedAppsStorageKey)
  }
}

@MainActor
final class ContentPreferences: ObservableObject {
  @Published private(set) var singleResetPinned = true
  @Published private(set) var isCollapsed = false

  private static let providerStripWidth: CGFloat = 224
  private static let providerSeparatorWidth: CGFloat = 29
  private static let pinnedResetWidth: CGFloat = 110
  private static let collapsedWidth: CGFloat = 126

  var designSize: NSSize {
    if self.isCollapsed {
      return NSSize(width: Self.collapsedWidth, height: 40)
    }

    let providerWidth =
      Self.providerStripWidth
      + (self.singleResetPinned
        ? 14 + Self.pinnedResetWidth
        : 0)
    return NSSize(
      width: providerWidth + PanelMargins.left + PanelMargins.right,
      height: 40)
  }

  private static let minimumSizeScale: CGFloat = 0.8

  var minimumSize: NSSize {
    let designSize = self.designSize
    return NSSize(
      width: designSize.width * Self.minimumSizeScale,
      height: designSize.height * Self.minimumSizeScale)
  }

  var activeProviders: Set<QuotaProvider> {
    self.isCollapsed ? [] : [.codex]
  }

  var orderedSelectedProviders: [QuotaProvider] {
    [.codex]
  }

  var selectionKey: String {
    "codex"
  }

  func setSelectedProviders(_ providers: Set<QuotaProvider>) {
    _ = providers
  }

  func collapse() {
    self.isCollapsed = true
  }

  func expandAll() {
    self.isCollapsed = false
  }

  func setSingleResetPinned(_ pinned: Bool) {
    self.singleResetPinned = pinned
  }

}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private static let supportedBundleIdentifiers = [
    "com.openai.codex",
    "com.googlecode.iterm2",
    "com.apple.Terminal",
  ]

  private lazy var store = QuotaStore(fetcher: CodexBarQuotaFetcher())
  private lazy var accountManager = CodexAccountManager()
  private lazy var displayPreferences = DisplayPreferences()
  private lazy var contentPreferences = ContentPreferences()
  private var statusBarController: StatusBarQuotaController?
  private var panel: NSPanel?
  private var displayModeObserver: AnyCancellable?
  private var contentModeObserver: AnyCancellable?
  private var workspaceObserver: NSObjectProtocol?
  private var visibilityTimer: Timer?
  private var codexAuthMonitor: CodexAuthMonitor?
  private var activeBundleIdentifier: String?
  private var activeAppHasVisibleWindow = false
  private var isRestoringFrame = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    _ = notification
    KeychainAccessGate.forceDisabledForProcess(
      reason: "QuotaFloat uses file-based OAuth credentials")

    if CommandLine.arguments.contains("--self-test") {
      do {
        try QuotaFloatSelfTest.run()
        print("QuotaFloat self-test passed.")
        exit(EXIT_SUCCESS)
      } catch {
        FileHandle.standardError.write(Data("QuotaFloat self-test failed: \(error)\n".utf8))
        exit(EXIT_FAILURE)
      }
    }

    NSApplication.shared.setActivationPolicy(.accessory)
    self.contentPreferences.setSelectedProviders([.codex, .antigravity])
    self.store.setActiveProviders([.codex, .antigravity])
    self.codexAuthMonitor = CodexAuthMonitor { [weak self] change in
      guard let self else { return }
      self.accountManager.synchronizeLiveCredentials()
      self.accountManager.reload()
      switch change {
      case .accountChanged:
        self.store.invalidateAndRefresh(.codex)
      case .credentialsRotated, .metadataChanged:
        self.store.refresh()
      }
    }
    self.statusBarController = StatusBarQuotaController(
      store: self.store,
      accountManager: self.accountManager,
      onAuthMutation: { [weak self] in
        self?.codexAuthMonitor?.acceptCurrentState()
      })
    self.accountManager.synchronizeLiveCredentials()
    self.store.start()
    self.codexAuthMonitor?.start()
    if CommandLine.arguments.contains("--show-menu")
      || CommandLine.arguments.contains("--show-details")
    {
      self.statusBarController?.showMenu()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    _ = notification
    if let workspaceObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
    }
    self.visibilityTimer?.invalidate()
    self.displayModeObserver?.cancel()
    self.contentModeObserver?.cancel()
    self.codexAuthMonitor?.stop()
    self.statusBarController?.stop()
    self.store.stop()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    self.statusBarController?.showMenu()
    return true
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    _ = sender
    self.contentPreferences.collapse()
    return false
  }

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    let designSize = self.contentPreferences.designSize
    let minimumWidth = self.contentPreferences.minimumSize.width
    let maximumWidth = designSize.width * 10
    let aspectRatio = designSize.width / designSize.height
    let width = min(max(frameSize.width, minimumWidth), maximumWidth)
    return NSSize(width: width, height: width / aspectRatio)
  }

  func windowDidResize(_ notification: Notification) {
    guard let panel = notification.object as? NSPanel else { return }
    self.enforceAllowedSize(panel)
    self.saveFrameForActiveApp()
  }

  func windowDidMove(_ notification: Notification) {
    guard notification.object is NSPanel else { return }
    self.saveFrameForActiveApp()
  }

  private func positionAtTopRight(_ panel: NSPanel) {
    guard let frame = NSScreen.main?.visibleFrame else {
      panel.center()
      return
    }
    let origin = NSPoint(
      x: frame.maxX - panel.frame.width - 24,
      y: frame.maxY - panel.frame.height - 24)
    panel.setFrameOrigin(origin)
  }

  private func enforceAllowedSize(_ panel: NSPanel) {
    let designSize = self.contentPreferences.designSize
    let width = max(panel.frame.width, self.contentPreferences.minimumSize.width)
    let correctedSize = NSSize(
      width: width,
      height: width / (designSize.width / designSize.height))
    guard
      abs(panel.frame.width - correctedSize.width) > 0.5
        || abs(panel.frame.height - correctedSize.height) > 0.5
    else {
      return
    }
    panel.setContentSize(correctedSize)
  }

  private func startApplicationVisibilityTracking() {
    self.refreshActiveApplication()

    self.workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let application =
          notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      else {
        return
      }

      Task { @MainActor [weak self] in
        guard let self else { return }
        if application.bundleIdentifier == Bundle.main.bundleIdentifier {
          return
        }
        self.handleActivatedApplication(application)
        self.updateVisibilityPolling()
        self.updatePanelVisibility()
      }
    }

    self.displayModeObserver = Publishers.CombineLatest(
      self.displayPreferences.$alwaysDisplay,
      self.displayPreferences.$selectedApps
    )
    .removeDuplicates { previous, current in
      previous.0 == current.0 && previous.1 == current.1
    }
    .sink { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.handleActivatedApplication(NSWorkspace.shared.frontmostApplication)
        self.updateVisibilityPolling()
        self.updatePanelVisibility()
      }
    }

    self.contentModeObserver = Publishers.CombineLatest(
      self.contentPreferences.$singleResetPinned,
      self.contentPreferences.$isCollapsed
    )
    .removeDuplicates { previous, current in
      previous.0 == current.0 && previous.1 == current.1
    }
    .dropFirst()
    .sink { [weak self] _ in
      guard let self, !self.isRestoringFrame else { return }
      Task { @MainActor [weak self] in
        self?.contentConfigurationDidChange()
      }
    }

    self.updateVisibilityPolling()
  }

  private func updatePanelVisibility() {
    guard let panel else { return }
    let isSelectedApp =
      self.activeBundleIdentifier.map(self.displayPreferences.isEnabled) ?? false
    let shouldShow =
      self.contentPreferences.isCollapsed
      || self.displayPreferences.alwaysDisplay
      || (isSelectedApp && self.activeAppHasVisibleWindow)

    if shouldShow {
      panel.orderFrontRegardless()
    } else {
      panel.orderOut(nil)
    }
  }

  private func refreshActiveApplication() {
    let frontmostApplication = NSWorkspace.shared.frontmostApplication
    if frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
      self.handleActivatedApplication(frontmostApplication)
    }
  }

  private func refreshActiveAppVisibility() {
    guard let bundleIdentifier = self.activeBundleIdentifier else { return }
    let hasVisibleWindow =
      self.displayPreferences.isEnabled(bundleIdentifier)
      && self.applicationWindowIsVisible(bundleIdentifier: bundleIdentifier)
    guard hasVisibleWindow != self.activeAppHasVisibleWindow else { return }
    self.activeAppHasVisibleWindow = hasVisibleWindow
    self.updatePanelVisibility()
  }

  private func updateVisibilityPolling() {
    let shouldPoll =
      !self.contentPreferences.isCollapsed
      && !self.displayPreferences.alwaysDisplay
      && self.activeBundleIdentifier.map(self.displayPreferences.isEnabled) == true

    if shouldPoll {
      guard self.visibilityTimer == nil else { return }
      self.visibilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
        [weak self] _ in
        Task { @MainActor [weak self] in
          self?.refreshActiveAppVisibility()
        }
      }
    } else {
      self.visibilityTimer?.invalidate()
      self.visibilityTimer = nil
    }
  }

  private func handleActivatedApplication(_ application: NSRunningApplication?) {
    let bundleIdentifier = application?.bundleIdentifier
    guard bundleIdentifier != self.activeBundleIdentifier else {
      if let bundleIdentifier {
        self.activeAppHasVisibleWindow =
          Self.isSupportedApp(bundleIdentifier)
          && self.applicationWindowIsVisible(bundleIdentifier: bundleIdentifier)
      }
      return
    }

    if self.contentPreferences.isCollapsed {
      self.activeBundleIdentifier = bundleIdentifier
      self.activeAppHasVisibleWindow = false
      return
    }

    self.saveFrameForActiveApp()
    self.activeBundleIdentifier = bundleIdentifier
    self.restoreContentSelectionForActiveContext()
    self.store.setActiveProviders(self.contentPreferences.activeProviders)

    self.restoreFrameForActiveContext()

    if let bundleIdentifier {
      self.activeAppHasVisibleWindow =
        self.displayPreferences.isEnabled(bundleIdentifier)
        && self.applicationWindowIsVisible(bundleIdentifier: bundleIdentifier)
    } else {
      self.activeAppHasVisibleWindow = false
    }
  }

  private func applicationWindowIsVisible(bundleIdentifier: String) -> Bool {
    guard
      let targetApplication = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == bundleIdentifier
      }),
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID) as? [[String: Any]]
    else {
      return false
    }

    return windows.contains { window in
      guard
        let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
        ownerPID == targetApplication.processIdentifier,
        let layer = window[kCGWindowLayer as String] as? Int,
        layer == 0,
        let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
      else {
        return false
      }

      return bounds.width >= 200 && bounds.height >= 100
    }
  }

  private func saveFrameForActiveApp() {
    guard
      !self.isRestoringFrame,
      !self.contentPreferences.isCollapsed,
      let panel,
      let contextKey = self.activeContextKey
    else {
      return
    }

    UserDefaults.standard.set(
      NSStringFromRect(panel.frame),
      forKey: Self.frameStorageKey(
        contextKey: contextKey,
        selectionKey: self.contentPreferences.selectionKey))
  }

  private func restoreFrameForActiveContext() {
    guard let contextKey = self.activeContextKey else { return }
    self.restoreFrame(contextKey: contextKey)
  }

  private func restoreFrame(contextKey: String) {
    guard let panel else { return }
    self.isRestoringFrame = true
    defer { self.isRestoringFrame = false }

    if let frameString = UserDefaults.standard.string(
      forKey: Self.frameStorageKey(
        contextKey: contextKey,
        selectionKey: self.contentPreferences.selectionKey))
    {
      let savedFrame = NSRectFromString(frameString)
      let designSize = self.contentPreferences.designSize
      let minimumScale = self.contentPreferences.minimumSize.height / designSize.height
      let scale = max(minimumScale, savedFrame.height / designSize.height)
      let restoredSize = NSSize(
        width: designSize.width * scale,
        height: designSize.height * scale)
      let restoredOrigin = NSPoint(
        x: savedFrame.maxX - restoredSize.width,
        y: savedFrame.origin.y)
      panel.setFrame(
        NSRect(origin: restoredOrigin, size: restoredSize),
        display: true)
    } else {
      panel.setContentSize(self.contentPreferences.designSize)
      self.positionAtTopRight(panel)
    }
  }

  private func contentConfigurationDidChange() {
    self.store.setActiveProviders(self.contentPreferences.activeProviders)
    guard !self.isRestoringFrame, let panel else { return }

    let designSize = self.contentPreferences.designSize
    let oldFrame = panel.frame
    let scale = max(1, oldFrame.height / designSize.height)
    let newSize = NSSize(
      width: designSize.width * scale,
      height: designSize.height * scale)
    let newOrigin = NSPoint(
      x: oldFrame.maxX - newSize.width,
      y: oldFrame.origin.y)

    self.isRestoringFrame = true
    self.applyWindowConstraints(panel)
    panel.setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
    self.isRestoringFrame = false

    self.saveContentSelectionForActiveContext()
    self.saveFrameForActiveApp()
    self.updateVisibilityPolling()
    self.updatePanelVisibility()
  }

  private func restoreContentSelectionForActiveContext() {
    guard let contextKey = self.activeContextKey else { return }
    let defaults = UserDefaults.standard
    let storedProviders = defaults.stringArray(
      forKey: Self.contentSelectionStorageKey(contextKey: contextKey))?
      .compactMap(QuotaProvider.init(rawValue:))
    let selectedProviders: Set<QuotaProvider>
    if let storedProviders, !storedProviders.isEmpty {
      selectedProviders = Set(storedProviders)
    } else {
      let legacyMode = defaults.string(
        forKey: Self.legacyContentModeStorageKey(contextKey: contextKey))
      switch legacyMode {
      case "codex": selectedProviders = [.codex]
      default: selectedProviders = Set(QuotaProviderCatalog.orderedProviders)
      }
    }
    let pinned =
      defaults.object(
        forKey: Self.singleResetPinnedStorageKey(contextKey: contextKey)) as? Bool ?? true
    self.isRestoringFrame = true
    self.contentPreferences.setSelectedProviders(selectedProviders)
    self.contentPreferences.setSingleResetPinned(pinned)
    if let panel {
      self.applyWindowConstraints(panel)
    }
    self.isRestoringFrame = false
  }

  private func saveContentSelectionForActiveContext() {
    guard let contextKey = self.activeContextKey else { return }
    UserDefaults.standard.set(
      self.contentPreferences.orderedSelectedProviders.map(\.rawValue),
      forKey: Self.contentSelectionStorageKey(contextKey: contextKey))
    UserDefaults.standard.set(
      self.contentPreferences.singleResetPinned,
      forKey: Self.singleResetPinnedStorageKey(contextKey: contextKey))
  }

  private func applyWindowConstraints(_ panel: NSPanel) {
    let designSize = self.contentPreferences.designSize
    panel.contentAspectRatio = designSize
    panel.contentMinSize = self.contentPreferences.minimumSize
    panel.minSize = self.contentPreferences.minimumSize
    panel.contentMaxSize = NSSize(
      width: designSize.width * 10,
      height: designSize.height * 10)
    panel.maxSize = panel.contentMaxSize
  }

  private var activeContextKey: String? {
    guard let bundleIdentifier = self.activeBundleIdentifier else {
      return "general"
    }
    return Self.isSupportedApp(bundleIdentifier) ? bundleIdentifier : "general"
  }

  private static func isSupportedApp(_ bundleIdentifier: String) -> Bool {
    Self.supportedBundleIdentifiers.contains(bundleIdentifier)
  }

  private static func frameStorageKey(
    contextKey: String,
    selectionKey: String
  ) -> String {
    "QuotaFloatFrame.\(contextKey).\(selectionKey)"
  }

  private static func contentSelectionStorageKey(contextKey: String) -> String {
    "QuotaFloatContentProviders.\(contextKey)"
  }

  private static func legacyContentModeStorageKey(contextKey: String) -> String {
    "QuotaFloatContentMode.\(contextKey)"
  }

  private static func singleResetPinnedStorageKey(contextKey: String) -> String {
    "QuotaFloatSingleResetPinned.\(contextKey)"
  }

}
