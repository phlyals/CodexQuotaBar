import Combine
import Foundation
import UserNotifications

struct QuotaNotice: Equatable, Sendable {
  let id: String
  let title: String
  let body: String
}

protocol QuotaNotificationClient: Sendable {
  func authorizationStatus() async -> UNAuthorizationStatus
  func requestAuthorization() async throws -> Bool
  func add(_ notice: QuotaNotice) async throws
}

struct SystemQuotaNotificationClient: QuotaNotificationClient {
  func authorizationStatus() async -> UNAuthorizationStatus {
    await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
  }

  func requestAuthorization() async throws -> Bool {
    try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
  }

  func add(_ notice: QuotaNotice) async throws {
    let content = UNMutableNotificationContent()
    content.title = notice.title
    content.body = notice.body
    content.sound = .default
    try await UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
  }
}

struct QuotaNotificationLedger: Codable {
  var delivered: [String: Date] = [:]
  var signalMonitoringStartedAt: Date? = nil

  func signalCandidates(_ signals: [ResetSignal], now: Date) -> [QuotaNotice] {
    guard let started = signalMonitoringStartedAt else { return [] }
    return signals.filter { signal in
      signal.verified && signal.resolutionID == nil
        && [.announced, .completed, .delayed, .withdrawn, .banked].contains(signal.state)
        && signal.publishedAt >= started && signal.publishedAt <= now
        && now.timeIntervalSince(signal.publishedAt) < 86_400
        && !(signal.state == .announced && signal.deadline.map { $0 <= now } == true)
    }.sorted { $0.publishedAt < $1.publishedAt }.compactMap { signal in
      let id = "signal.\(signal.id).\(signal.state.rawValue)"
      guard delivered[id] == nil else { return nil }
      let late = now.timeIntervalSince(signal.publishedAt) >= 900
      return QuotaNotice(
        id: id, title: "Codex 重置消息\(late ? "（补提醒）" : "")：\(signal.state.title)",
        body: "@thsottiaux 的重置消息；本账号是否适用或到账仍需核对。")
    }
  }

  func candidates(snapshot: QuotaSnapshot, now: Date) -> [QuotaNotice] {
    guard snapshot.freshness == .fresh, let key = snapshot.accountKey,
      now.timeIntervalSince(snapshot.updatedAt) >= -60,
      now.timeIntervalSince(snapshot.updatedAt) < 300
    else { return [] }
    var results: [QuotaNotice] = []
    for kind in QuotaWindowKind.allCases {
      guard let window = kind.window(in: snapshot), window.isValid, let reset = window.resetsAt,
        reset > now
      else { continue }
      let cycle = "\(key).\(kind.rawValue).\(Int(reset.timeIntervalSince1970))"
      let threshold = window.remainingPercent <= 10 ? 10 : window.remainingPercent <= 20 ? 20 : nil
      if let threshold {
        results.append(
          .init(
            id: "low.\(cycle).\(threshold)", title: "Codex \(kind.title)额度偏低",
            body: "当前账号剩余 \(Int(window.remainingPercent))%。详情中的规划按近期采样估算。"))
      }
      if window.remainingPercent > 20,
        let lastLow = delivered.filter({ $0.key.hasPrefix("low.\(key).\(kind.rawValue).") }).values
          .max(),
        now.timeIntervalSince(lastLow) < 7 * 86_400,
        delivered.filter({ $0.key.hasPrefix("recovered.\(key).\(kind.rawValue).") }).values.max()
          .map({ $0 < lastLow }) ?? true
      {
        results.append(
          .init(
            id: "recovered.\(cycle)", title: "检测到 Codex 额度恢复",
            body: "\(kind.title)窗口已恢复至 \(Int(window.remainingPercent))%。恢复原因仍以服务端为准。"))
      }
    }
    for credit in snapshot.resetCredits?.details ?? [] where credit.isAvailable(now: now) {
      guard let expires = credit.expiresAt else { continue }
      let hours = expires.timeIntervalSince(now) / 3600
      let threshold = hours <= 24 ? 24 : hours <= 72 ? 72 : nil
      if let threshold {
        results.append(
          .init(
            id: "credit.\(key).\(credit.id).\(threshold)", title: "Codex 重置券即将到期",
            body: "一张可用重置券将在 \(Int(ceil(hours))) 小时内到期。请核对详情和官方可用状态。"))
      }
    }
    return results.filter { delivered[$0.id] == nil }
  }

  mutating func mark(_ notice: QuotaNotice, at now: Date) {
    delivered = delivered.filter { now.timeIntervalSince($0.value) < 30 * 86_400 }
    delivered[notice.id] = now
  }

  static func isQuiet(now: Date, start: Int, end: Int, calendar: Calendar = .current) -> Bool {
    guard start != end else { return false }
    let hour = calendar.component(.hour, from: now)
    return start < end ? (start..<end).contains(hour) : hour >= start || hour < end
  }
}

@MainActor
final class QuotaNotificationService: ObservableObject {
  @Published private(set) var enabled: Bool
  @Published private(set) var permission = "尚未请求通知权限"
  @Published private(set) var isRequestingPermission = false
  @Published private(set) var needsSystemSettings = false
  @Published var quietEnabled: Bool {
    didSet { defaults.set(quietEnabled, forKey: "quotaQuietEnabled") }
  }
  @Published var quietStart: Int { didSet { defaults.set(quietStart, forKey: "quotaQuietStart") } }
  @Published var quietEnd: Int { didSet { defaults.set(quietEnd, forKey: "quotaQuietEnd") } }
  private var ledger: QuotaNotificationLedger
  private var pending: Set<String> = []
  private let defaults: UserDefaults
  private let url: URL
  private let client: any QuotaNotificationClient
  private var permissionTask: Task<Void, Never>?
  private var permissionRevision = 0
  private var authorizationFailed = false

  init(
    defaults: UserDefaults = .standard,
    url: URL = LocalPrivateStore.url("notification-ledger.json"),
    inspectSystemPermission: Bool = true,
    client: any QuotaNotificationClient = SystemQuotaNotificationClient()
  ) {
    self.defaults = defaults
    self.url = url
    self.client = client
    defaults.register(defaults: [
      "quotaQuietEnabled": true, "quotaQuietStart": 23, "quotaQuietEnd": 8,
    ])
    enabled = defaults.bool(forKey: "quotaNotificationsEnabled")
    quietEnabled = defaults.bool(forKey: "quotaQuietEnabled")
    quietStart = defaults.integer(forKey: "quotaQuietStart")
    quietEnd = defaults.integer(forKey: "quotaQuietEnd")
    ledger = LocalPrivateStore.load(QuotaNotificationLedger.self, from: url) ?? .init()
    if enabled, ledger.signalMonitoringStartedAt == nil {
      ledger.signalMonitoringStartedAt = Date()
      LocalPrivateStore.save(ledger, to: url)
    }
    if inspectSystemPermission { Task { await self.refreshPermission() } }
  }

  func setEnabled(
    _ value: Bool, beforeRequest: @escaping @MainActor () async -> Void = {}
  ) {
    if !value {
      stop()
      authorizationFailed = false
      persistEnabled(false)
      permission = "提醒已关闭"
      return
    }
    guard !isRequestingPermission else { return }
    authorizationFailed = false
    permissionRevision += 1
    let revision = permissionRevision
    isRequestingPermission = true
    needsSystemSettings = false
    permission = "正在检查通知权限…"
    permissionTask = Task {
      defer {
        if revision == permissionRevision {
          isRequestingPermission = false
          permissionTask = nil
        }
      }
      var status = await client.authorizationStatus()
      guard revision == permissionRevision, !Task.isCancelled else { return }
      if status == .notDetermined {
        permission = "请在系统提示中允许通知"
        await beforeRequest()
        guard revision == permissionRevision, !Task.isCancelled else { return }
        do {
          let granted = try await client.requestAuthorization()
          guard revision == permissionRevision, !Task.isCancelled else { return }
          status = await client.authorizationStatus()
          guard revision == permissionRevision, !Task.isCancelled else { return }
          persistEnabled(granted && Self.isAllowed(status))
        } catch {
          guard revision == permissionRevision, !Task.isCancelled else { return }
          persistEnabled(false)
          authorizationFailed = true
          needsSystemSettings = true
          permission = "通知授权失败，请重试或检查系统通知设置"
          return
        }
      } else {
        persistEnabled(Self.isAllowed(status))
      }
      applyPermission(status)
    }
  }

  func stop() {
    permissionRevision += 1
    permissionTask?.cancel()
    permissionTask = nil
    isRequestingPermission = false
  }

  private func persistEnabled(_ value: Bool) {
    if value && !enabled {
      ledger.signalMonitoringStartedAt = Date()
      LocalPrivateStore.save(ledger, to: url)
    }
    enabled = value
    defaults.set(value, forKey: "quotaNotificationsEnabled")
  }

  func process(_ snapshot: QuotaSnapshot?, signals: [ResetSignal], now: Date = Date()) {
    guard enabled,
      !quietEnabled || !QuotaNotificationLedger.isQuiet(now: now, start: quietStart, end: quietEnd)
    else { return }
    var candidates = snapshot.map { ledger.candidates(snapshot: $0, now: now) } ?? []
    candidates += ledger.signalCandidates(signals, now: now)
    for notice in candidates where !pending.contains(notice.id) {
      pending.insert(notice.id)
      let revision = permissionRevision
      Task {
        defer { pending.remove(notice.id) }
        let status = await client.authorizationStatus()
        guard enabled, revision == permissionRevision else { return }
        guard Self.isAllowed(status) else {
          persistEnabled(false)
          applyPermission(status)
          return
        }
        do {
          try await client.add(notice)
          ledger.mark(notice, at: now)
          LocalPrivateStore.save(ledger, to: url)
        } catch {
          if revision == permissionRevision { permission = "通知投递失败；额度仍正常刷新" }
        }
      }
    }
  }

  func refreshPermission() async {
    guard !isRequestingPermission else { return }
    let revision = permissionRevision
    let status = await client.authorizationStatus()
    guard revision == permissionRevision, !isRequestingPermission else { return }
    if !Self.isAllowed(status) { persistEnabled(false) }
    applyPermission(status)
  }

  private static func isAllowed(_ status: UNAuthorizationStatus) -> Bool {
    status == .authorized || status == .provisional
  }

  private func applyPermission(_ status: UNAuthorizationStatus) {
    // Reopening the menu must not erase an authorization error before the user can read it.
    if authorizationFailed && status == .notDetermined { return }
    authorizationFailed = false
    needsSystemSettings = status == .denied
    permission =
      switch status {
      case .authorized, .provisional, .ephemeral:
        enabled ? "提醒已开启；免打扰由 macOS 管理" : "系统通知已允许，提醒未开启"
      case .denied: "系统未允许通知，请在系统通知设置中开启后重新勾选"
      case .notDetermined: "尚未请求通知权限"
      @unknown default: "通知权限未知"
      }
  }
}
