import AppKit
import Combine
import SwiftUI

@MainActor
final class QuotaAssistantModel: ObservableObject {
  let dashboard: CodexDashboardStore
  let accounts: CodexAccountManager
  let history: QuotaHistory
  let signals: ResetSignalStore
  let notifications: QuotaNotificationService
  let bills: CycleBillStore
  private var cancellables: Set<AnyCancellable> = []

  init(
    dashboard: CodexDashboardStore, accounts: CodexAccountManager,
    history: QuotaHistory = QuotaHistory(), signals: ResetSignalStore = ResetSignalStore(),
    notifications: QuotaNotificationService = QuotaNotificationService(),
    bills: CycleBillStore = CycleBillStore()
  ) {
    self.dashboard = dashboard
    self.accounts = accounts
    self.history = history
    self.signals = signals
    self.notifications = notifications
    self.bills = bills
    dashboard.$quota.receive(on: DispatchQueue.main).sink { [weak self] snapshot in
      guard let self, let snapshot else { return }
      self.history.record(snapshot)
      self.notifications.process(snapshot, signals: self.signals.archive.signals)
    }.store(in: &cancellables)
    dashboard.$now.receive(on: DispatchQueue.main).sink { [weak self] now in
      guard let self else { return }
      self.signals.tick(now: now)
      self.notifications.process(
        self.dashboard.quota, signals: self.signals.archive.signals, now: now)
    }.store(in: &cancellables)
  }

  func stop() {
    bills.stop()
    notifications.stop()
    signals.stop()
    dashboard.stop()
  }
}

enum QuotaMenuPage: String, CaseIterable {
  case overview, planning, messages, accounts, settings

  var preferredHeight: CGFloat {
    switch self {
    case .overview, .settings: 260
    case .planning: 320
    case .accounts: 260
    case .messages: 400
    }
  }

  var title: String {
    switch self {
    case .overview: "订阅与重置券"
    case .planning: "用量规划"
    case .messages: "重置消息"
    case .accounts: "账号用量记录"
    case .settings: "设置"
    }
  }
}

struct QuotaDetailsView: View {
  @ObservedObject var dashboard: CodexDashboardStore
  @ObservedObject var accounts: CodexAccountManager
  @ObservedObject var history: QuotaHistory
  @ObservedObject var signals: ResetSignalStore
  @ObservedObject var notifications: QuotaNotificationService
  @ObservedObject var bills: CycleBillStore
  @AppStorage("quotaReservePercent") private var reserve = 10.0
  @AppStorage("quotaWorkHours") private var workHours = 3.0
  @State private var diagnosticPreview: String?
  @State private var exportMessage: String?
  @State private var confirmClear = false
  let page: QuotaMenuPage
  var height: CGFloat = 440
  private let onExport: (String) -> Void
  private let beforeNotificationPermission: @MainActor () async -> Void
  private let onNotificationSettings: () -> Void

  init(
    model: QuotaAssistantModel, page: QuotaMenuPage, height: CGFloat = 440,
    onExport: @escaping (String) -> Void = { _ in },
    beforeNotificationPermission: @escaping @MainActor () async -> Void = {},
    onNotificationSettings: @escaping () -> Void = {}
  ) {
    dashboard = model.dashboard
    accounts = model.accounts
    history = model.history
    signals = model.signals
    notifications = model.notifications
    bills = model.bills
    self.page = page
    self.height = height
    self.onExport = onExport
    self.beforeNotificationPermission = beforeNotificationPermission
    self.onNotificationSettings = onNotificationSettings
  }

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 10) {
        switch page {
        case .overview: self.overview.labeledContentStyle(CompactMenuLabeledStyle())
        case .planning: self.planning
        case .messages: self.messages
        case .accounts: self.accountOverview
        case .settings: self.settings
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollIndicators(.automatic)
    .font(.system(size: 12))
    .controlSize(.small)
    .toggleStyle(.checkbox)
    .frame(width: 300, height: height, alignment: .top)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(page.title)
  }

  private var overview: some View {
    VStack(alignment: .leading, spacing: 14) {
      CompactMenuSection("订阅") {
        LabeledContent("套餐", value: dashboard.quota?.accountPlan ?? "--")
        LabeledContent("有效至", value: Self.compactDate(dashboard.effectiveSubscription?.activeUntil))
        if let subscription = dashboard.effectiveSubscription,
          !subscription.isVerified(now: dashboard.now)
        {
          Text("历史日期，等待更新").font(.caption).foregroundStyle(.secondary)
        } else if dashboard.effectiveSubscription == nil {
          Text("暂未获取订阅时间").font(.caption).foregroundStyle(.secondary)
        }
      }
      CompactMenuSection("重置券") {
        LabeledContent(
          "可用次数", value: dashboard.quota?.resetCredits.map { "\($0.availableCount) 次" } ?? "--")
        if let credits = dashboard.quota?.resetCredits {
          if let details = credits.details {
            ForEach(
              details.filter { $0.isAvailable(now: dashboard.now) }
                .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
            ) { credit in
              LabeledContent("到期时间", value: Self.compactDate(credit.expiresAt))
            }
          } else {
            ForEach(credits.expirationDates.indices, id: \.self) { index in
              LabeledContent("到期时间", value: Self.compactDate(credits.expirationDates[index]))
            }
          }
        }
      }
      Link("官方用量页", destination: URL(string: "https://chatgpt.com/codex/settings/usage")!)
    }
  }

  private var planning: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("预计还能用多久").font(.headline)
      ForEach(QuotaWindowKind.allCases, id: \.self) { kind in
        if let window = dashboard.quota.flatMap({ kind.window(in: $0) }) {
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Text(kind.title).foregroundStyle(.secondary)
              Spacer()
              Text("剩余 \(Self.percent(window))").monospacedDigit()
            }
            Text(
              PlanningPresentation.duration(
                window: window, forecast: forecast(kind), reserve: reserve, now: dashboard.now)
            )
            .font(.system(size: 20, weight: .semibold)).monospacedDigit()
            if let forecast = forecast(kind) {
              let hours = forecast.hours(reserve: reserve)
              Text(
                forecast.resetsAt <= dashboard.now.addingTimeInterval(workHours * 3600)
                  ? "计划期间将重置"
                  : hours.lowerBound >= workHours
                    ? "可覆盖 \(workHours.formatted()) 小时计划" : "建议放慢用量，或缩短计划"
              )
              .font(.caption).foregroundStyle(.secondary)
            }
            Text("下次重置 \(Self.compactDate(window.resetsAt))")
              .font(.caption).foregroundStyle(.secondary)
            if let key = dashboard.quota?.accountKey,
              let average = QuotaCycleSummary.averageCompleteDuration(
                QuotaCycleSummary.cycles(
                  samples: history.archive.samples, accountKey: key, kind: kind, now: dashboard.now
                )
                .filter { $0.plan == dashboard.quota?.accountPlan }
              )
            {
              Text("满额用完平均 \(QuotaCycleSummary.durationText(average))")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          Divider()
        }
      }
      if dashboard.quota?.session == nil && dashboard.quota?.weekly == nil {
        Text("等待额度更新").foregroundStyle(.secondary)
      }
      HStack {
        Text("预留")
        Slider(value: $reserve, in: 0...50, step: 5)
        Text("\(Int(reserve))%").monospacedDigit().frame(width: 34)
      }
      Stepper(
        "计划使用 \(workHours, specifier: "%.1f") 小时",
        value: $workHours, in: 0.5...12, step: 0.5)
    }
  }

  private func forecast(_ kind: QuotaWindowKind) -> QuotaForecast? {
    guard let snapshot = dashboard.quota else { return nil }
    return QuotaForecaster.forecast(
      samples: history.archive.samples, snapshot: snapshot, kind: kind, now: dashboard.now)
  }

  private var messages: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Tibo 动态").font(.headline)
        Spacer()
        NativeMessageRefreshButton(isRefreshing: signals.isRefreshing) {
          signals.refresh(manual: true)
        }.frame(width: 28, height: 24)
      }
      if !signals.enabled { Text("自动更新未开启").font(.caption).foregroundStyle(.secondary) }
      if signals.isRefreshing {
        HStack(spacing: 6) {
          ProgressView().controlSize(.mini)
          Text("正在检查新消息…").font(.caption).foregroundStyle(.secondary)
        }
      } else if let feedback = signals.refreshFeedback {
        Text(feedback).font(.caption).foregroundStyle(.secondary)
      }
      if signals.archive.signals.isEmpty { Text("暂无消息").foregroundStyle(.secondary) }
      ForEach(MessagePresentation.latest(signals.archive.signals)) { signal in
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(Self.compactDate(signal.publishedAt)).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Link(destination: signal.url) { Image(systemName: "arrow.up.right.square") }.help(
              "查看原帖")
          }
          if #available(macOS 15.0, *) {
            TranslatedMessageView(signal: signal).id(signal.excerpt)
          } else {
            Text(signal.excerpt).textSelection(.enabled)
          }
        }
      }
    }
  }

  private var accountOverview: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("账号额度").font(.headline)
      ForEach(accounts.accounts) { account in
        let snapshot = account.accountKey.flatMap { history.archive.latest[$0] }
        VStack(alignment: .leading, spacing: 7) {
          HStack {
            Text(account.email).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            if account.isCurrentSystemAccount {
              Image(systemName: "checkmark").foregroundStyle(.secondary)
            }
          }
          HStack {
            Text(snapshot?.weekly.flatMap { window in
              window.isValid && (window.resetsAt.map { $0 > dashboard.now } ?? false)
                ? String(format: "本周已用 %.0f%%", window.usedPercent) : nil
            } ?? "等待额度更新")
              .font(.system(size: 16, weight: .semibold)).monospacedDigit()
            Spacer()
            if let snapshot,
              snapshot.freshness != .fresh || dashboard.now.timeIntervalSince(snapshot.updatedAt) >= 300 {
              Text("上次记录").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        Divider()
      }
      if accounts.accounts.isEmpty { Text("暂无已保存账号").foregroundStyle(.secondary) }
      let summary = CodexBarUsageSummary.calculate(
        usage: dashboard.localUsage, weekly: dashboard.quota?.weekly, now: dashboard.now)
      HStack {
        Text("本机用量").font(.headline)
        Spacer()
        if dashboard.isLoadingLocalUsage {
          ProgressView().controlSize(.mini)
        } else if summary.isStale {
          Text("上次统计").font(.caption).foregroundStyle(.secondary)
        }
        Text("CodexBar").font(.caption).foregroundStyle(.secondary)
      }
      if let range = summary.dateRange {
        Text(range).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        HStack {
          Text(summary.tokenText)
          Spacer()
          Text(summary.costText)
        }.fontWeight(.medium).monospacedDigit()
        Text("当前周额度所在日期，含首日全天；本机全部账号。")
          .font(.caption2).foregroundStyle(.secondary)
        Text("美元为 API 等价估值。")
          .font(.caption2).foregroundStyle(.secondary)
      } else {
        Text(dashboard.isLoadingLocalUsage ? "正在读取用量…" : "等待周期与用量数据")
          .foregroundStyle(.secondary)
      }
      if let message = dashboard.localUsageMessage {
        Text(message).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var settings: some View {
    VStack(alignment: .leading, spacing: 14) {
      CompactMenuSection("提醒") {
        NativeMenuCheckbox(
          title: "额度与重置消息提醒", identifier: "quota-notifications-toggle",
          isOn: Binding(
            get: { notifications.enabled },
            set: { notifications.setEnabled($0, beforeRequest: beforeNotificationPermission) })
        )
        .disabled(notifications.isRequestingPermission)
        if notifications.isRequestingPermission {
          ProgressView().controlSize(.small)
        }
        if notifications.needsSystemSettings {
          Button("允许系统通知", systemImage: "arrow.up.right.square", action: onNotificationSettings)
        }
        NativeMenuCheckbox(
          title: "夜间静默", identifier: "quota-quiet-toggle", isOn: $notifications.quietEnabled)
        if notifications.quietEnabled {
          HStack {
            Picker("开始", selection: $notifications.quietStart) {
              ForEach(0..<24) { Text("\($0):00").tag($0) }
            }
            Picker("结束", selection: $notifications.quietEnd) {
              ForEach(0..<24) { Text("\($0):00").tag($0) }
            }
          }
        }
      }
      CompactMenuSection("Tibo 动态") {
        NativeMenuCheckbox(
          title: "每 10 分钟自动更新", identifier: "quota-messages-toggle",
          isOn: Binding(get: { signals.enabled }, set: { signals.setEnabled($0) }))
      }
      Button("清除用量记录", systemImage: "trash", role: .destructive) { confirmClear = true }
      if confirmClear {
        Text("清除后需重新积累预测数据。").font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("取消") { confirmClear = false }
          Button("确认清除", role: .destructive) {
            history.clear()
            confirmClear = false
          }
        }
      }
    }
  }

  static func compactDate(_ date: Date?) -> String {
    guard let date else { return "--" }
    let formatter = DateFormatter()
    formatter.dateFormat = "MM/dd HH:mm"
    return formatter.string(from: date)
  }

  static func date(_ date: Date?) -> String {
    guard let date else { return "未知" }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
    return formatter.string(from: date)
  }

  static func percent(_ window: QuotaWindow?) -> String {
    guard let window, window.isValid else { return "--" }
    return "\(Int(window.remainingPercent.rounded()))%"
  }

  static func freshness(_ snapshot: QuotaSnapshot?, now: Date) -> String {
    guard let snapshot else { return "等待首次同步" }
    if snapshot.freshness == .authRequired { return "需要重新登录" }
    if now.timeIntervalSince(snapshot.updatedAt) >= 300 { return "已过期，显示上次成功数据" }
    return snapshot.freshness == .fresh ? "服务端最新采样" : "缓存，等待刷新"
  }
}

private struct NativeMenuCheckbox: NSViewRepresentable {
  let title: String
  let identifier: String
  @Binding var isOn: Bool
  @Environment(\.isEnabled) private var isEnabled

  func makeCoordinator() -> Coordinator { Coordinator(binding: $isOn) }

  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(
      checkboxWithTitle: title, target: context.coordinator,
      action: #selector(Coordinator.toggle(_:)))
    button.font = .systemFont(ofSize: 12)
    button.controlSize = .small
    button.alignment = .left
    button.identifier = NSUserInterfaceItemIdentifier(identifier)
    button.setAccessibilityIdentifier(identifier)
    return button
  }

  func updateNSView(_ button: NSButton, context: Context) {
    context.coordinator.binding = $isOn
    button.title = title
    button.state = isOn ? .on : .off
    button.isEnabled = isEnabled
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: 18)
  }

  @MainActor
  final class Coordinator: NSObject {
    var binding: Binding<Bool>
    init(binding: Binding<Bool>) { self.binding = binding }
    @objc func toggle(_ button: NSButton) { binding.wrappedValue = button.state == .on }
  }
}

private struct CompactMenuSection<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 12, weight: .semibold))
      content
      Divider().padding(.top, 4)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct CompactMenuLabeledStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .top, spacing: 8) {
      configuration.label.font(.caption).foregroundStyle(.secondary)
        .frame(width: 78, alignment: .leading)
      configuration.content.fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }
}
