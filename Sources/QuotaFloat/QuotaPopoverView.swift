import AppKit
import Charts
import SwiftUI

enum QuotaPopoverTab: String, CaseIterable, Identifiable {
  case overview = "概览"
  case planning = "规划与账号"
  case settings = "设置"

  var id: String { self.rawValue }
}

struct QuotaPopoverActions {
  let onRefresh: () -> Void
  let onSwitchAccount: (UUID) -> Void
  let onAddAccount: () -> Void
  let onRemoveAccount: (UUID) -> Void
  let onToggleLaunchAtLogin: () -> Void
  let isLaunchAtLoginEnabled: () -> Bool
  let launchAtLoginRequiresApproval: () -> Bool
  let beforeNotificationPermission: @MainActor () async -> Void
  let onNotificationSettings: () -> Void
  let onQuit: () -> Void
}

struct QuotaPopoverView: View {
  @ObservedObject var dashboard: CodexDashboardStore
  @ObservedObject var accounts: CodexAccountManager
  @ObservedObject var history: QuotaHistory
  @ObservedObject var notifications: QuotaNotificationService
  let actions: QuotaPopoverActions

  @State private var selectedTab: QuotaPopoverTab = .overview
  @State private var isAccountDrawerOpen = false
  @State private var showExtraGooglePools = false
  @State private var hoveredDayID: String?
  @State private var pinnedDayID: String?
  @State private var confirmClear = false
  @State private var launchAtLoginOn = false
  @AppStorage("quotaReservePercent") private var reserve = 10.0
  @AppStorage("quotaWorkHours") private var workHours = 3.0

  private let popoverWidth: CGFloat = 328
  private let track = Color.primary.opacity(0.10)

  init(model: QuotaAssistantModel, actions: QuotaPopoverActions) {
    self.dashboard = model.dashboard
    self.accounts = model.accounts
    self.history = model.history
    self.notifications = model.notifications
    self.actions = actions
    self._launchAtLoginOn = State(initialValue: actions.isLaunchAtLoginEnabled())
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      self.headerBar
      if self.isAccountDrawerOpen {
        self.accountDrawer
      }
      self.tabBar
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 12) {
          switch self.selectedTab {
          case .overview:
            self.overviewTab
          case .planning:
            self.planningTab
          case .settings:
            self.settingsTab
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollIndicators(.automatic)
      .frame(maxHeight: 490)
      .fixedSize(horizontal: false, vertical: true)

      Divider()
      self.footerBar
    }
    .frame(width: self.popoverWidth, alignment: .topLeading)
    .background(.ultraThinMaterial)
    .onAppear {
      self.launchAtLoginOn = self.actions.isLaunchAtLoginEnabled()
    }
    .onChange(of: self.usageDays.map(\.id)) { _, ids in
      if let pinnedDayID, !ids.contains(pinnedDayID) { self.pinnedDayID = nil }
    }
  }

  // MARK: - Header & Account Drawer

  private var headerBar: some View {
    HStack(spacing: 8) {
      ZStack {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(Color.accentColor.opacity(0.15))
        Image(systemName: "circle.hexagongrid")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Color.accentColor)
      }
      .frame(width: 26, height: 26)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 5) {
          Button {
            withAnimation(.easeOut(duration: 0.16)) {
              self.isAccountDrawerOpen.toggle()
            }
          } label: {
            HStack(spacing: 3) {
              Text(self.accountEmailText)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
              Image(systemName: self.isAccountDrawerOpen ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            }
          }
          .buttonStyle(.plain)

          if let plan = self.planBadgeText {
            Text(plan)
              .font(.system(size: 10, weight: .medium))
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .background(Color.accentColor.opacity(0.16), in: Capsule())
              .foregroundStyle(Color.accentColor)
              .fixedSize()
          }
        }

        HStack(spacing: 5) {
          Text(self.updatedText)
            .foregroundStyle(.secondary)
          Text("·")
            .foregroundStyle(.tertiary)
          Text(self.subscriptionSummaryText)
            .foregroundStyle(self.subscriptionColor)
        }
        .font(.system(size: 10.5).monospacedDigit())
        .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button {
        self.actions.onRefresh()
      } label: {
        Group {
          if self.dashboard.isRefreshing {
            ProgressView().controlSize(.mini)
          } else {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 11.5, weight: .medium))
          }
        }
        .frame(width: 26, height: 26)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
      }
      .buttonStyle(.plain)
      .help("立即刷新全部额度 (⌘R)")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .overlay(alignment: .bottom) { Divider() }
  }

  private var accountDrawer: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(self.accounts.accounts) { account in
        HStack(spacing: 6) {
          Button {
            guard !account.isCurrentSystemAccount, !self.accounts.isBusy else { return }
            self.isAccountDrawerOpen = false
            self.actions.onSwitchAccount(account.id)
          } label: {
            HStack(spacing: 6) {
              Image(systemName: account.isCurrentSystemAccount ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundStyle(account.isCurrentSystemAccount ? Color.accentColor : .secondary)
              Text(account.email)
                .font(.system(size: 11.5, weight: account.isCurrentSystemAccount ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
              Spacer(minLength: 4)
              if let snapshot = account.accountKey.flatMap({ self.history.archive.latest[$0] }),
                let weekly = snapshot.weekly, weekly.isValid
              {
                Text("周剩 \(Int(weekly.remainingPercent.rounded()))%")
                  .font(.system(size: 10.5).monospacedDigit())
                  .foregroundStyle(.secondary)
              }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
              account.isCurrentSystemAccount
                ? Color.accentColor.opacity(0.12) : Color.clear,
              in: RoundedRectangle(cornerRadius: 6))
          }
          .buttonStyle(.plain)

          if !account.isCurrentSystemAccount {
            Button {
              self.actions.onRemoveAccount(account.id)
            } label: {
              Image(systemName: "trash")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("移除已保存账号")
          }
        }
      }

      Button {
        self.isAccountDrawerOpen = false
        self.actions.onAddAccount()
      } label: {
        Label(
          self.accounts.isBusy ? "账号操作进行中…" : "添加 Codex 账号…",
          systemImage: "plus.circle"
        )
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
      }
      .buttonStyle(.plain)
      .disabled(self.accounts.isBusy)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(Color.primary.opacity(0.035))
    .overlay(alignment: .bottom) { Divider() }
  }

  private var tabBar: some View {
    Picker("", selection: self.$selectedTab) {
      ForEach(QuotaPopoverTab.allCases) { tab in
        Text(tab.rawValue).tag(tab)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .controlSize(.small)
    .padding(.horizontal, 14)
    .padding(.top, 9)
    .padding(.bottom, 2)
  }

  // MARK: - Tab 1: Overview (Codex + Google + Local Usage)

  private var overviewTab: some View {
    VStack(alignment: .leading, spacing: 11) {
      // Codex Quotas (5h first to match menu bar)
      VStack(alignment: .leading, spacing: 8) {
        self.compactQuotaRow(title: "5 小时窗口", window: self.dashboard.quota?.session)
        self.compactQuotaRow(title: "每周额度", window: self.dashboard.quota?.weekly)
        if let sparkSession = self.dashboard.quota?.sparkSession {
          self.compactQuotaRow(title: "Spark 5 小时", window: sparkSession)
        }
        if let sparkWeekly = self.dashboard.quota?.sparkWeekly {
          self.compactQuotaRow(title: "Spark 周额度", window: sparkWeekly)
        }
        if self.dashboard.quota?.freshness != .fresh
          || self.dashboard.quota.map({ self.dashboard.now.timeIntervalSince($0.updatedAt) >= 300 }) == true
        {
          Text(QuotaDetailsView.freshness(self.dashboard.quota, now: self.dashboard.now))
            .font(.system(size: 10.5))
            .foregroundStyle(.orange)
        }
      }

      // Google (Antigravity) Quotas Card
      self.googleQuotaCard

      // Compact Local Usage Section
      self.localUsageCard
    }
  }

  private var googleQuotaCard: some View {
    let google = self.dashboard.googleQuota
    return VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 6) {
        Image(systemName: "sparkles")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color(red: 0.24, green: 0.72, blue: 0.50))
        Text("Google · Antigravity")
          .font(.system(size: 12, weight: .semibold))
        if let plan = google?.accountPlan, !plan.isEmpty {
          Text(plan)
            .font(.system(size: 9.5, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color(red: 0.24, green: 0.72, blue: 0.50).opacity(0.16), in: Capsule())
            .foregroundStyle(Color(red: 0.24, green: 0.72, blue: 0.50))
            .lineLimit(1)
        }
        Spacer(minLength: 4)
        if let email = google?.accountEmail, !email.isEmpty {
          Text(email)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }

      if let google, google.hasQuotaData {
        if let gemini5h = google.session {
          self.compactQuotaRow(title: "Gemini 5 小时", window: gemini5h)
        }
        if let geminiWeekly = google.weekly {
          self.compactQuotaRow(title: "Gemini 周额度", window: geminiWeekly)
        }
        if let extras = google.extraWindows, !extras.isEmpty {
          Button {
            withAnimation(.easeOut(duration: 0.15)) {
              self.showExtraGooglePools.toggle()
            }
          } label: {
            HStack(spacing: 4) {
              Text(self.showExtraGooglePools ? "收起其他模型池" : "其他模型池（\(extras.count)）")
              Image(systemName: self.showExtraGooglePools ? "chevron.up" : "chevron.down")
                .font(.system(size: 9))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)

          if self.showExtraGooglePools {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(extras) { extra in
                self.compactQuotaRow(title: extra.title, window: extra.window)
              }
            }
            .padding(.top, 2)
          }
        }
        if google.freshness != .fresh, let msg = google.message, !msg.isEmpty {
          Text(msg)
            .font(.system(size: 10))
            .foregroundStyle(.orange)
        }
      } else {
        Text(google?.message ?? "等待同步 Antigravity 额度…")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
    }
  }

  private func compactQuotaRow(title: String, window: QuotaWindow?) -> some View {
    let color = Self.semanticColor(for: window?.remainingPercent)
    return VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(title)
          .font(.system(size: 12, weight: .medium))
          .lineLimit(1)
        Spacer(minLength: 4)
        Text(ResetTimeFormatter.string(window, now: self.dashboard.now))
          .font(.system(size: 10.5).monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(Self.shortPercent(window))
          .font(.system(size: 13, weight: .semibold).monospacedDigit())
          .foregroundStyle(color)
          .frame(minWidth: 34, alignment: .trailing)
      }

      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule().fill(self.track)
          if let window, window.isValid, window.remainingPercent > 0 {
            Capsule()
              .fill(color)
              .frame(width: max(3, geometry.size.width * window.remainingPercent / 100))
          }
        }
      }
      .frame(height: 6)
    }
  }

  private var localUsageCard: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline) {
        Text("本机用量")
          .font(.system(size: 12, weight: .semibold))
        Spacer(minLength: 6)
        if self.dashboard.isLoadingLocalUsage {
          ProgressView().controlSize(.mini)
        }
        if let model = self.dashboard.localUsage?.activeModel(now: self.dashboard.now),
          !model.isEmpty
        {
          Text(model)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Image(systemName: "info.circle")
          .font(.system(size: 10.5))
          .foregroundStyle(.secondary)
          .help(
            self.dashboard.localUsage?.hasPartialPricing == true
              ? "本机全部账号 · 部分价格缺失，费用不完整"
              : "本机全部账号 · API 等价估算费用，不是订阅账单")
      }

      HStack(spacing: 8) {
        self.usageSummaryBox(
          title: "今日",
          cost: CodexDashboardView.money(self.dashboard.localUsage?.today(now: self.dashboard.now)?.totalCost),
          tokens: CodexDashboardView.tokens(self.dashboard.localUsage?.today(now: self.dashboard.now)?.totalTokens)
        )
        self.usageSummaryBox(
          title: "近 30 天",
          cost: CodexDashboardView.money(self.dashboard.localUsage?.totalCost(now: self.dashboard.now)),
          tokens: CodexDashboardView.tokens(self.dashboard.localUsage?.totalTokens(now: self.dashboard.now))
        )
      }

      if !self.usageDays.isEmpty {
        self.usageChartCard
      } else {
        RoundedRectangle(cornerRadius: 7)
          .fill(self.track)
          .frame(height: 40)
          .overlay {
            Text("暂无本机用量记录")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
          }
      }

      if let message = self.dashboard.localUsageMessage, !message.isEmpty {
        Text(message)
          .font(.system(size: 10.5))
          .foregroundStyle(.orange)
          .lineLimit(2)
      }
    }
    .padding(.top, 2)
  }

  private func usageSummaryBox(title: String, cost: String, tokens: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
      Text(cost)
        .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.75)
      Text("\(tokens) Token")
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 9)
    .padding(.vertical, 7)
    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var usageDays: [CodexLocalUsageSnapshot.DailyEntry] {
    self.dashboard.localUsage?.calendarDays(now: self.dashboard.now) ?? []
  }

  private var selectedUsageDay: CodexLocalUsageSnapshot.DailyEntry? {
    guard let selectedID = self.pinnedDayID ?? self.hoveredDayID else { return nil }
    return self.usageDays.first { $0.id == selectedID }
  }

  private var usageChartCard: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        if let day = self.selectedUsageDay {
          let dayLabel =
            (self.pinnedDayID == day.id ? "固定 · " : "") + CodexDashboardView.dayDate(day.date)
          let modelSuffix = CodexLocalUsageSnapshot.primaryModel(for: day).map { " · \($0)" } ?? ""
          Text(dayLabel + modelSuffix)
            .font(.system(size: 10.5, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 4)
          Text("\(CodexDashboardView.tokens(day.totalTokens)) · \(CodexDashboardView.money(day.totalCost))")
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .fixedSize()
        } else {
          Text("近 30 天趋势（悬停查看每日）")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
          Spacer()
          if let peak = self.usageDays.compactMap(\.totalCost).max(), peak > 0 {
            Text("峰值 \(CodexDashboardView.money(peak))")
              .font(.system(size: 10).monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
      }

      Chart(self.usageDays) { day in
        BarMark(
          x: .value("日期", day.date),
          y: .value("估算费用", day.totalCost ?? 0)
        )
        .foregroundStyle(self.barColor(for: day))
        .cornerRadius(2)
      }
      .chartXAxis(.hidden)
      .chartYAxis(.hidden)
      .chartOverlay { chartProxy in
        GeometryReader { geometry in
          Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
              switch phase {
              case .active(let location):
                self.hoveredDayID = self.dayID(at: location, chartProxy: chartProxy, geometry: geometry)
              case .ended:
                if self.pinnedDayID == nil { self.hoveredDayID = nil }
              }
            }
            .gesture(
              SpatialTapGesture().onEnded { value in
                guard let id = self.dayID(at: value.location, chartProxy: chartProxy, geometry: geometry) else {
                  self.pinnedDayID = nil
                  return
                }
                self.pinnedDayID = self.pinnedDayID == id ? nil : id
                self.hoveredDayID = id
              })
        }
      }
      .frame(height: 46)

      HStack {
        Text(self.usageDays.first.map { CodexDashboardView.dayDate($0.date) } ?? "")
        Spacer()
        Text("今天")
      }
      .font(.system(size: 9.5).monospacedDigit())
      .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 7)
    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func barColor(for day: CodexLocalUsageSnapshot.DailyEntry) -> Color {
    let base = Color(red: 0.23, green: 0.60, blue: 0.66)
    guard let selectedID = self.pinnedDayID ?? self.hoveredDayID else {
      return base.opacity(0.75)
    }
    return base.opacity(day.id == selectedID ? 1.0 : 0.30)
  }

  private func dayID(
    at location: CGPoint,
    chartProxy: ChartProxy,
    geometry: GeometryProxy
  ) -> String? {
    guard !self.usageDays.isEmpty, let plotFrameAnchor = chartProxy.plotFrame else { return nil }
    let plotFrame = geometry[plotFrameAnchor]
    guard plotFrame.width > 0, plotFrame.contains(location) else { return nil }
    let ratio = min(max(0, location.x - plotFrame.minX), plotFrame.width) / plotFrame.width
    let index = min(
      self.usageDays.count - 1,
      max(0, Int((ratio * CGFloat(self.usageDays.count)).rounded(.down))))
    return self.usageDays[index].id
  }

  // MARK: - Tab 2: Planning & Accounts

  private var planningTab: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Planning forecast
      VStack(alignment: .leading, spacing: 8) {
        Text("预计还能用多久").font(.system(size: 12.5, weight: .semibold))
        ForEach(QuotaWindowKind.allCases, id: \.self) { kind in
          if let window = self.dashboard.quota.flatMap({ kind.window(in: $0) }) {
            let forecast = self.forecast(kind)
            VStack(alignment: .leading, spacing: 3) {
              HStack {
                Text(kind.title).foregroundStyle(.secondary)
                Spacer()
                Text("剩余 \(Self.shortPercent(window))").monospacedDigit()
              }
              .font(.system(size: 11.5))

              Text(
                PlanningPresentation.duration(
                  window: window, forecast: forecast, reserve: self.reserve, now: self.dashboard.now)
              )
              .font(.system(size: 17, weight: .semibold).monospacedDigit())

              if let forecast {
                let hours = forecast.hours(reserve: self.reserve)
                Text(
                  forecast.resetsAt <= self.dashboard.now.addingTimeInterval(self.workHours * 3600)
                    ? "计划期间将重置"
                    : hours.lowerBound >= self.workHours
                      ? "可覆盖 \(self.workHours.formatted()) 小时计划" : "建议放慢用量，或缩短计划"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
              }
              Text("下次重置 \(QuotaDetailsView.compactDate(window.resetsAt))")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
          }
        }
        if self.dashboard.quota?.session == nil && self.dashboard.quota?.weekly == nil {
          Text("等待额度更新").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }

        HStack(spacing: 8) {
          Text("预留").font(.system(size: 11.5))
          Slider(value: self.$reserve, in: 0...50, step: 5).controlSize(.small)
          Text("\(Int(self.reserve))%").font(.system(size: 11.5).monospacedDigit()).frame(width: 34, alignment: .trailing)
        }
        Stepper(
          "计划使用 \(self.workHours, specifier: "%.1f") 小时",
          value: self.$workHours, in: 0.5...12, step: 0.5
        )
        .font(.system(size: 11.5))
        .controlSize(.small)
      }

      Divider()

      // Accounts weekly usage
      VStack(alignment: .leading, spacing: 7) {
        Text("账号本周已用").font(.system(size: 12.5, weight: .semibold))
        if self.accounts.accounts.isEmpty {
          Text("暂无已保存账号").font(.system(size: 11.5)).foregroundStyle(.secondary)
        } else {
          ForEach(self.accounts.accounts) { account in
            let snapshot = account.accountKey.flatMap { self.history.archive.latest[$0] }
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                  Text(account.email).lineLimit(1).truncationMode(.middle)
                  if account.isCurrentSystemAccount {
                    Image(systemName: "checkmark.circle.fill")
                      .font(.system(size: 10))
                      .foregroundStyle(Color.accentColor)
                  }
                }
                .font(.system(size: 11.5, weight: .medium))
                if let snapshot,
                  snapshot.freshness != .fresh || self.dashboard.now.timeIntervalSince(snapshot.updatedAt) >= 300
                {
                  Text("上次记录").font(.system(size: 10)).foregroundStyle(.secondary)
                }
              }
              Spacer()
              Text(snapshot?.weekly.flatMap { window in
                window.isValid && (window.resetsAt.map { $0 > self.dashboard.now } ?? false)
                  ? String(format: "已用 %.0f%%", window.usedPercent) : nil
              } ?? "待更新")
              .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
            }
            .padding(8)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
          }
        }
      }

      Divider()

      // Subscription & Reset Credits Details (only mention reset credits when available > 0)
      let availableResetDates: [Date] = {
        guard let credits = self.dashboard.quota?.resetCredits, credits.availableCount > 0 else {
          return []
        }
        return credits.details?.filter { $0.isAvailable(now: self.dashboard.now) }
          .compactMap(\.expiresAt).sorted() ?? credits.expirationDates
      }()
      let hasResetCredits = (self.dashboard.quota?.resetCredits?.availableCount ?? 0) > 0

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(hasResetCredits ? "订阅与重置券" : "订阅信息").font(.system(size: 12.5, weight: .semibold))
          Spacer()
          Link("官方用量页 ↗", destination: URL(string: "https://chatgpt.com/codex/settings/usage")!)
            .font(.system(size: 11))
        }
        HStack {
          Text("有效至").foregroundStyle(.secondary)
          Spacer()
          Text(QuotaDetailsView.compactDate(self.dashboard.effectiveSubscription?.activeUntil))
            .monospacedDigit()
        }
        .font(.system(size: 11.5))

        if hasResetCredits, !availableResetDates.isEmpty {
          ForEach(availableResetDates.indices, id: \.self) { idx in
            HStack {
              Text("重置券到期").foregroundStyle(.secondary)
              Spacer()
              Text(QuotaDetailsView.compactDate(availableResetDates[idx])).monospacedDigit()
            }
            .font(.system(size: 11.5))
          }
        }
      }
    }
  }

  private func forecast(_ kind: QuotaWindowKind) -> QuotaForecast? {
    guard let snapshot = self.dashboard.quota else { return nil }
    return QuotaForecaster.forecast(
      samples: self.history.archive.samples, snapshot: snapshot, kind: kind, now: self.dashboard.now)
  }

  // MARK: - Tab 3: Settings

  private var settingsTab: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Preferences
      VStack(alignment: .leading, spacing: 8) {
        Text("偏好设置").font(.system(size: 12.5, weight: .semibold))

        Toggle(
          self.actions.launchAtLoginRequiresApproval() ? "开机自启动（待系统批准）" : "开机自启动",
          isOn: Binding(
            get: { self.launchAtLoginOn },
            set: { _ in
              self.actions.onToggleLaunchAtLogin()
              self.launchAtLoginOn = self.actions.isLaunchAtLoginEnabled()
            })
        )

        Toggle(
          "额度预警提醒",
          isOn: Binding(
            get: { self.notifications.enabled },
            set: {
              self.notifications.setEnabled(
                $0, beforeRequest: self.actions.beforeNotificationPermission)
            })
        )
        .disabled(self.notifications.isRequestingPermission)

        if self.notifications.needsSystemSettings {
          Button("前往系统设置允许通知", systemImage: "arrow.up.right.square") {
            self.actions.onNotificationSettings()
          }
          .controlSize(.small)
        }

        Toggle("夜间静默", isOn: self.$notifications.quietEnabled)
        if self.notifications.quietEnabled {
          HStack {
            Picker("开始", selection: self.$notifications.quietStart) {
              ForEach(0..<24, id: \.self) { Text("\($0):00").tag($0) }
            }
            Picker("结束", selection: self.$notifications.quietEnd) {
              ForEach(0..<24, id: \.self) { Text("\($0):00").tag($0) }
            }
          }
          .controlSize(.small)
        }

        Divider().padding(.vertical, 2)

        if self.confirmClear {
          VStack(alignment: .leading, spacing: 6) {
            Text("清除后需重新积累预测数据，确认清除？")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
            HStack {
              Button("取消") { self.confirmClear = false }.controlSize(.small)
              Button("确认清除", role: .destructive) {
                self.history.clear()
                self.confirmClear = false
              }
              .controlSize(.small)
            }
          }
        } else {
          Button("清除本地用量记录", systemImage: "trash", role: .destructive) {
            self.confirmClear = true
          }
          .controlSize(.small)
        }
      }
      .font(.system(size: 12))
      .toggleStyle(.checkbox)
    }
  }

  // MARK: - Footer Bar

  private var footerBar: some View {
    HStack(spacing: 10) {
      HStack(spacing: 4) {
        Text("积分").foregroundStyle(.secondary)
        Text(self.creditsValueText).fontWeight(.medium).monospacedDigit()
      }
      if let credits = self.dashboard.quota?.resetCredits, credits.availableCount > 0 {
        HStack(spacing: 4) {
          Text("重置券").foregroundStyle(.secondary)
          Text("\(credits.availableCount) 次").fontWeight(.medium).monospacedDigit()
        }
      }
      Spacer()
      Button("退出") {
        self.actions.onQuit()
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .keyboardShortcut("q", modifiers: .command)
    }
    .font(.system(size: 11))
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }

  // MARK: - Helpers

  private var accountEmailText: String {
    self.dashboard.currentAccountEmail ?? self.dashboard.quota?.accountEmail ?? "未识别账号"
  }

  private var planBadgeText: String? {
    guard let plan = self.dashboard.quota?.accountPlan?.trimmingCharacters(in: .whitespacesAndNewlines),
      !plan.isEmpty
    else { return nil }
    return plan
  }

  private var updatedText: String {
    if self.dashboard.isRefreshing { return "正在刷新…" }
    guard let updatedAt = self.dashboard.quota?.updatedAt else { return "等待同步" }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return "\(formatter.string(from: updatedAt)) 更新"
  }

  private var subscriptionSummaryText: String {
    guard let subscription = self.dashboard.effectiveSubscription else { return "订阅未知" }
    if !subscription.isVerified(now: self.dashboard.now) {
      return subscription.activeUntil.map { "至 \(CodexDashboardView.subscriptionDate($0))" } ?? "待核验"
    }
    switch subscription.status(now: self.dashboard.now) {
    case .expired: return "已到期"
    case .expiresToday: return "今日到期"
    case .active, .expiringSoon:
      let until = subscription.activeUntil.map { CodexDashboardView.subscriptionDate($0) } ?? ""
      let days = subscription.daysRemaining(now: self.dashboard.now).map { "剩\($0)天" } ?? ""
      return [until.isEmpty ? nil : "\(until)到期", days.isEmpty ? nil : days].compactMap { $0 }.joined(separator: " · ")
    case .unknown: return "订阅未知"
    }
  }

  private var subscriptionColor: Color {
    guard let subscription = self.dashboard.effectiveSubscription else { return .secondary }
    switch subscription.status(now: self.dashboard.now) {
    case .active: return Color(red: 0.23, green: 0.60, blue: 0.66)
    case .expiringSoon, .expiresToday: return .orange
    case .expired: return .red
    case .unknown: return .secondary
    }
  }

  private var creditsValueText: String {
    if self.dashboard.quota?.creditsUnlimited == true { return "无限" }
    return self.dashboard.quota?.creditsRemaining.map(CodexDashboardView.creditValue) ?? "--"
  }

  private static func shortPercent(_ window: QuotaWindow?) -> String {
    guard let window, window.isValid else { return "--" }
    return "\(Int(window.remainingPercent.rounded()))%"
  }

  private static func semanticColor(for remainingPercent: Double?) -> Color {
    guard let pct = remainingPercent else { return .secondary }
    if pct <= 20 { return Color(red: 0.92, green: 0.30, blue: 0.28) }
    if pct <= 50 { return Color(red: 0.95, green: 0.65, blue: 0.18) }
    return Color(red: 0.20, green: 0.72, blue: 0.45)
  }
}
