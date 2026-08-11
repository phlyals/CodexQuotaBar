import Charts
import SwiftUI

struct CodexDashboardView: View {
  @ObservedObject var store: CodexDashboardStore
  @State private var hoveredDayID: String?
  @State private var pinnedDayID: String?

  private var quota: QuotaSnapshot? { self.store.quota }
  private var usage: CodexLocalUsageSnapshot? { self.store.localUsage }
  private let accent = Color(red: 0.23, green: 0.60, blue: 0.66)
  private let track = Color.black.opacity(0.09)

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      self.accountHeader
      Divider()
      self.quotaSection
      Divider()
      self.usageSection
      Divider()
      self.creditsSection
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 5)
    .frame(width: 300, alignment: .topLeading)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private var accountHeader: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .top, spacing: 7) {
        Image(systemName: "circle.hexagongrid")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(Color.accentColor)
          .frame(width: 18, height: 20)

        VStack(alignment: .leading, spacing: 1) {
          Text("Codex")
            .font(.subheadline.weight(.semibold))
          Text(self.updatedText)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        Spacer(minLength: 8)

        VStack(alignment: .trailing, spacing: 2) {
          Text(self.accountEmailText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(self.planText)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 170, alignment: .trailing)
      }

      HStack(alignment: .firstTextBaseline) {
        Text(self.subscriptionPeriodText)
        Spacer(minLength: 8)
        Text(self.subscriptionRemainingText)
      }
      .font(.caption2.monospacedDigit())
      .foregroundStyle(self.subscriptionColor)
      .lineLimit(1)
    }
    .padding(.vertical, 4)
  }

  private var quotaSection: some View {
    VStack(alignment: .leading, spacing: 5) {
      self.quotaRow(title: "每周", window: self.quota?.weekly)
      self.quotaRow(title: "5 小时", window: self.quota?.session)
      if let sparkSession = self.quota?.sparkSession {
        self.quotaRow(title: "Codex Spark 5 小时", window: sparkSession)
      }
      self.quotaRow(title: "Codex Spark Weekly", window: self.quota?.sparkWeekly)
    }
    .padding(.vertical, 4)
  }

  private func quotaRow(title: String, window: QuotaWindow?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.subheadline.weight(.medium))

      self.quotaBar(window)

      HStack(alignment: .firstTextBaseline) {
        Text(self.remainingText(window))
          .font(.caption.weight(.medium))
        Spacer(minLength: 8)
        Text(self.resetText(window))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }

  private func quotaBar(_ window: QuotaWindow?) -> some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(self.track)
        if let window {
          Capsule()
            .fill(self.accent)
            .frame(width: max(3, geometry.size.width * window.remainingPercent / 100))
        }
      }
    }
    .frame(height: 5)
  }

  private var usageSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text("用量仪表盘")
          .font(.subheadline.weight(.medium))
        Spacer(minLength: 8)
        if self.store.isLoadingLocalUsage {
          ProgressView()
            .controlSize(.small)
        }
      }

      HStack(spacing: 12) {
        self.metric(title: "今日", value: Self.money(self.usage?.sessionCostUSD))
        self.metric(title: "30d", value: Self.money(self.usage?.last30DaysCostUSD))
      }

      HStack(spacing: 12) {
        self.metric(title: "最近 Token", value: Self.tokens(self.usage?.sessionTokens))
        self.metric(title: "近 30 天 Token", value: Self.tokens(self.usage?.last30DaysTokens))
      }

      if !self.usageDays.isEmpty {
        self.usageChart
      } else {
        RoundedRectangle(cornerRadius: 3)
          .fill(self.track)
          .frame(height: 44)
          .overlay {
            Text("暂无本机用量记录")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
      }

      HStack(alignment: .firstTextBaseline) {
        Text("最常用模型")
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Text(self.usage?.topModel ?? "--")
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .font(.caption)

      Text("根据本机 Token 用量估算，不是订阅账单")
        .font(.caption2)
        .foregroundStyle(.secondary)

      if let message = self.store.localUsageMessage, !message.isEmpty {
        Text(message)
          .font(.caption2)
          .foregroundStyle(.orange)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 5)
  }

  private var usageDays: [CodexLocalUsageSnapshot.DailyEntry] {
    Array(self.usage?.daily.suffix(30) ?? [])
  }

  private var selectedUsageDay: CodexLocalUsageSnapshot.DailyEntry? {
    guard let selectedID = self.pinnedDayID ?? self.hoveredDayID else { return nil }
    return self.usageDays.first { $0.id == selectedID }
  }

  private var usageChart: some View {
    ZStack(alignment: .topLeading) {
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
                self.hoveredDayID = self.dayID(
                  at: location,
                  chartProxy: chartProxy,
                  geometry: geometry)
              case .ended:
                if self.pinnedDayID == nil {
                  self.hoveredDayID = nil
                }
              }
            }
            .gesture(
              SpatialTapGesture()
                .onEnded { value in
                  let dayID = self.dayID(
                    at: value.location,
                    chartProxy: chartProxy,
                    geometry: geometry)
                  guard let dayID else {
                    self.pinnedDayID = nil
                    return
                  }
                  self.pinnedDayID = self.pinnedDayID == dayID ? nil : dayID
                  self.hoveredDayID = dayID
                })
        }
      }

      if let selectedDay = self.selectedUsageDay,
        let dayIndex = self.usageDays.firstIndex(where: { $0.id == selectedDay.id })
      {
        self.usageTooltip(for: selectedDay)
          .position(
            x: self.tooltipX(for: dayIndex),
            y: 17
          )
          .allowsHitTesting(false)
      }
    }
    .frame(height: 44)
    .animation(.easeOut(duration: 0.14), value: self.hoveredDayID)
    .animation(.easeOut(duration: 0.14), value: self.pinnedDayID)
  }

  private func barColor(for day: CodexLocalUsageSnapshot.DailyEntry) -> Color {
    guard let selectedID = self.pinnedDayID ?? self.hoveredDayID else {
      return self.accent.opacity(0.72)
    }
    return self.accent.opacity(day.id == selectedID ? 0.95 : 0.32)
  }

  private func dayID(
    at location: CGPoint,
    chartProxy: ChartProxy,
    geometry: GeometryProxy
  ) -> String? {
    guard !self.usageDays.isEmpty else { return nil }
    guard let plotFrameAnchor = chartProxy.plotFrame else { return nil }
    let plotFrame = geometry[plotFrameAnchor]
    guard plotFrame.width > 0, plotFrame.contains(location) else { return nil }
    let relativeX = min(max(0, location.x - plotFrame.minX), plotFrame.width)
    let ratio = relativeX / plotFrame.width
    let index = min(
      self.usageDays.count - 1,
      max(0, Int((ratio * CGFloat(self.usageDays.count)).rounded(.down))))
    return self.usageDays[index].id
  }

  private func tooltipX(for index: Int) -> CGFloat {
    let width: CGFloat = 268
    let fraction = (CGFloat(index) + 0.5) / CGFloat(max(1, self.usageDays.count))
    return min(max(72, width * fraction), width - 72)
  }

  private func usageTooltip(for day: CodexLocalUsageSnapshot.DailyEntry) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(Self.dayDate(day.date))
        .font(.system(size: 8.5, weight: .semibold))
      HStack(spacing: 3) {
        Text("Token")
          .foregroundStyle(.secondary)
        Spacer(minLength: 2)
        Text(Self.tokens(day.totalTokens))
      }
      .font(.system(size: 8.5))
      if let totalCost = day.totalCost {
        HStack(spacing: 3) {
          Text("费用")
            .foregroundStyle(.secondary)
          Spacer(minLength: 2)
          Text(Self.money(totalCost))
        }
        .font(.system(size: 8.5))
      }
      if let model = Self.topModel(for: day) {
        Text(model)
          .font(.system(size: 8.5))
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .frame(width: 114, alignment: .leading)
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    .shadow(color: .black.opacity(0.16), radius: 4, y: 1)
  }

  private func metric(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.subheadline.weight(.medium))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var creditsSection: some View {
    VStack(alignment: .leading, spacing: 5) {
      if let creditsRemaining = self.quota?.creditsRemaining {
        Text("额度")
          .font(.subheadline.weight(.medium))
        self.creditsBar(creditsRemaining)
        HStack(alignment: .firstTextBaseline) {
          Text("\(Self.creditValue(creditsRemaining)) 剩余")
            .font(.caption.weight(.medium))
          Spacer(minLength: 8)
          Text("1K token")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        if self.quota?.resetCredits?.availableCount ?? 0 > 0 {
          self.resetCreditsRow
        }
      } else {
        self.resetCreditsRow
      }
    }
    .padding(.vertical, 5)
  }

  private func creditsBar(_ remaining: Double) -> some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(self.track)
        Capsule()
          .fill(self.accent)
          .frame(
            width: max(
              3,
              geometry.size.width * min(100, max(0, remaining / 1_000 * 100)) / 100))
      }
    }
    .frame(height: 5)
  }

  private var resetCreditsRow: some View {
    HStack(alignment: .firstTextBaseline) {
      Label("额外额度", systemImage: "plus.circle")
        .font(.subheadline.weight(.medium))
      Spacer(minLength: 8)
      Text(self.resetCreditsText)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var planText: String {
    guard let plan = self.quota?.accountPlan?.trimmingCharacters(in: .whitespacesAndNewlines),
      !plan.isEmpty
    else {
      return "--"
    }
    return plan
  }

  private var accountEmailText: String {
    self.store.currentAccountEmail ?? self.quota?.accountEmail ?? "未识别账号"
  }

  private var effectiveSubscription: CodexSubscriptionMetadata? {
    if let subscription = self.store.subscription {
      return subscription
    }
    guard
      let activeUntil = self.quota?.subscriptionRenewsAt ?? self.quota?.subscriptionExpiresAt
    else {
      return nil
    }
    return CodexSubscriptionMetadata(
      activeStart: nil,
      activeUntil: activeUntil,
      lastChecked: self.quota?.updatedAt,
      source: .quotaFallback,
      freshness: self.quota?.freshness == .fresh ? .fresh : .cached)
  }

  private var subscriptionPeriodText: String {
    guard let subscription = self.effectiveSubscription else { return "订阅周期未知" }
    if let activeStart = subscription.activeStart, let activeUntil = subscription.activeUntil {
      return "本期 \(Self.subscriptionDate(activeStart))–\(Self.subscriptionDate(activeUntil))"
    }
    if let activeUntil = subscription.activeUntil {
      return "有效至 \(Self.subscriptionDate(activeUntil))"
    }
    if let activeStart = subscription.activeStart {
      return "本期开始 \(Self.subscriptionDate(activeStart))"
    }
    return "订阅周期未知"
  }

  private var subscriptionRemainingText: String {
    guard let subscription = self.effectiveSubscription else { return "日期未知" }
    switch subscription.status() {
    case .expired:
      return "已到期"
    case .expiresToday:
      return "今日到期"
    case .active, .expiringSoon:
      guard let days = subscription.daysRemaining() else { return "日期未知" }
      return "剩余\(days)天"
    case .unknown:
      return "日期未知"
    }
  }

  private var subscriptionColor: Color {
    guard let subscription = self.effectiveSubscription else { return .secondary }
    switch subscription.status() {
    case .active:
      return self.accent
    case .expiringSoon, .expiresToday:
      return .orange
    case .expired:
      return .red
    case .unknown:
      return .secondary
    }
  }

  private var resetCreditsText: String {
    guard let credits = self.quota?.resetCredits else { return "--" }
    return "\(credits.availableCount) 次"
  }

  private func remainingText(_ window: QuotaWindow?) -> String {
    guard let window else { return "--" }
    return "\(Int(window.remainingPercent.rounded()))% 剩余"
  }

  private func resetText(_ window: QuotaWindow?) -> String {
    ResetTimeFormatter.string(window, now: Date())
  }

  private var updatedText: String {
    guard let updatedAt = self.quota?.updatedAt else { return "等待首次同步" }
    return RelativeTimeFormatter.string(from: updatedAt, to: Date()) + "更新"
  }

  static func money(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "--" }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return "US$\(formatter.string(from: NSNumber(value: value)) ?? "--")"
  }

  static func creditValue(_ value: Double) -> String {
    guard value.isFinite else { return "--" }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: value)) ?? "--"
  }

  static func subscriptionDate(_ value: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "M/d"
    return formatter.string(from: value)
  }

  static func dayDate(_ value: String) -> String {
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.calendar = Calendar(identifier: .gregorian)
    parser.dateFormat = "yyyy-MM-dd"
    guard let date = parser.date(from: value) else { return value }
    return self.subscriptionDate(date)
  }

  static func topModel(for day: CodexLocalUsageSnapshot.DailyEntry) -> String? {
    if let breakdown = day.modelBreakdowns?.max(by: { lhs, rhs in
      if lhs.cost == rhs.cost {
        return (lhs.totalTokens ?? 0) < (rhs.totalTokens ?? 0)
      }
      return (lhs.cost ?? 0) < (rhs.cost ?? 0)
    }) {
      return breakdown.modelName
    }
    return day.modelsUsed?.first
  }

  static func tokens(_ value: Int?) -> String {
    guard let value else { return "--" }
    if value >= 1_000_000_000 {
      return String(format: "%.1fB", Double(value) / 1_000_000_000)
    }
    if value >= 1_000_000 {
      return String(format: "%.1fM", Double(value) / 1_000_000)
    }
    if value >= 1_000 {
      return String(format: "%.1fK", Double(value) / 1_000)
    }
    return value.formatted()
  }
}
