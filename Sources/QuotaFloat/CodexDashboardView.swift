import Charts
import SwiftUI

struct CodexDashboardView: View {
  @ObservedObject var store: CodexDashboardStore
  @State private var hoveredDayID: String?
  @State private var pinnedDayID: String?

  private var quota: QuotaSnapshot? { self.store.quota }
  private var usage: CodexLocalUsageSnapshot? { self.store.localUsage }
  private let accent = Color(red: 0.23, green: 0.60, blue: 0.66)
  private let track = Color.primary.opacity(0.10)

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      self.accountHeader
      Divider()
      self.quotaSection
      Divider()
      self.usageSection
      Divider()
      self.creditsSection
      if self.quota?.freshness != .fresh
        || self.quota.map({ self.store.now.timeIntervalSince($0.updatedAt) >= 300 }) == true
      {
        Text(QuotaDetailsView.freshness(self.quota, now: self.store.now))
          .font(.caption2).foregroundStyle(.orange).padding(.bottom, 3)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 5)
    .frame(width: 300, alignment: .topLeading)
    .background(.ultraThinMaterial)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Codex 额度与本机用量")
    .onChange(of: self.usageDays.map(\.id)) { _, ids in
      if let pinnedDayID, !ids.contains(pinnedDayID) { self.pinnedDayID = nil }
    }
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
      if let sparkWeekly = self.quota?.sparkWeekly {
        self.quotaRow(title: "Codex Spark Weekly", window: sparkWeekly)
      }
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
        if let window, window.isValid, window.remainingPercent > 0 {
          Capsule()
            .fill(self.accent)
            .frame(width: geometry.size.width * window.remainingPercent / 100)
        }
      }
    }
    .frame(height: 5)
  }

  private var usageSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text("本机用量")
          .font(.subheadline.weight(.medium))
        Spacer(minLength: 8)
        if self.store.isLoadingLocalUsage {
          ProgressView()
            .controlSize(.small)
        }
      }

      HStack(spacing: 12) {
        self.metric(
          title: "今日", value: Self.money(self.usage?.today(now: self.store.now)?.totalCost))
        self.metric(title: "30 天估算", value: Self.money(self.usage?.totalCost(now: self.store.now)))
      }

      HStack(spacing: 12) {
        self.metric(
          title: "今日 Token", value: Self.tokens(self.usage?.today(now: self.store.now)?.totalTokens)
        )
        self.metric(
          title: "近 30 天 Token", value: Self.tokens(self.usage?.totalTokens(now: self.store.now)))
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
        Text("费用最高模型")
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Text(self.usage?.topModel ?? "--")
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .font(.caption)

      Text(self.usage?.hasPartialPricing == true ? "本机全部账号 · 部分价格缺失，费用不完整" : "本机全部账号 · 估算费用，不是订阅账单")
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
    self.usage?.calendarDays(now: self.store.now) ?? []
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
        if day.totalCost == nil {
          PointMark(x: .value("日期", day.date), y: .value("估算费用", 0))
            .symbol(.cross).symbolSize(10).foregroundStyle(Color.secondary.opacity(0.5))
        } else if day.totalCost == 0 {
          PointMark(x: .value("日期", day.date), y: .value("估算费用", 0))
            .symbol(.square).symbolSize(3).foregroundStyle(self.accent.opacity(0.5))
        }
      }
      .chartXAxis(.hidden)
      .chartYAxis(.hidden)
      .accessibilityRepresentation {
        VStack {
          ForEach(self.usageDays) { day in
            Button("\(day.date)，\(Self.tokens(day.totalTokens)) Token，\(Self.money(day.totalCost))")
            {
              self.selectDay(day.id)
            }
          }
        }
      }
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
                  self.selectDay(dayID)
                })
        }
      }

      if let selectedDay = self.selectedUsageDay,
        let dayIndex = self.usageDays.firstIndex(where: { $0.id == selectedDay.id })
      {
        self.usageTooltip(for: selectedDay)
          .position(
            x: self.tooltipX(for: dayIndex),
            y: 26
          )
          .allowsHitTesting(false)
      }
    }
    .frame(height: 54)
    .animation(.easeOut(duration: 0.14), value: self.hoveredDayID)
    .animation(.easeOut(duration: 0.14), value: self.pinnedDayID)
  }

  private func barColor(for day: CodexLocalUsageSnapshot.DailyEntry) -> Color {
    guard let selectedID = self.pinnedDayID ?? self.hoveredDayID else {
      return self.accent.opacity(0.72)
    }
    return self.accent.opacity(day.id == selectedID ? 0.95 : 0.32)
  }

  private func selectDay(_ dayID: String) {
    self.pinnedDayID = self.pinnedDayID == dayID ? nil : dayID
    self.hoveredDayID = dayID
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
      Text((self.pinnedDayID == day.id ? "固定 · " : "") + Self.dayDate(day.date))
        .font(.system(size: 10, weight: .semibold))
      HStack(spacing: 3) {
        Text("Token")
          .foregroundStyle(.secondary)
        Spacer(minLength: 2)
        Text(Self.tokens(day.totalTokens))
      }
      .font(.system(size: 10))
      if let totalCost = day.totalCost {
        HStack(spacing: 3) {
          Text("费用")
            .foregroundStyle(.secondary)
          Spacer(minLength: 2)
          Text(Self.money(totalCost))
        }
        .font(.system(size: 10))
      } else {
        Text("费用未知").font(.system(size: 10)).foregroundStyle(.secondary)
      }
      if let model = Self.topModel(for: day) {
        Text(model)
          .font(.system(size: 10))
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
      HStack {
        Text("积分余额").font(.subheadline.weight(.medium))
        Spacer()
        Text(
          self.quota?.creditsUnlimited == true
            ? "无限" : self.quota?.creditsRemaining.map(Self.creditValue) ?? "未提供"
        )
        .font(.caption.monospacedDigit())
      }
      self.resetCreditsRow
    }
    .padding(.vertical, 5)
  }

  private var resetCreditsRow: some View {
    HStack(alignment: .firstTextBaseline) {
      Label("可用重置", systemImage: "arrow.counterclockwise.circle")
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
    self.store.effectiveSubscription
  }

  private var subscriptionPeriodText: String {
    guard let subscription = self.effectiveSubscription else { return "订阅周期未知" }
    if !subscription.isVerified(now: self.store.now) {
      return subscription.activeUntil.map { "记录有效至 \(Self.subscriptionDate($0))" } ?? "订阅周期未知"
    }
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
    switch subscription.status(now: self.store.now) {
    case .expired:
      return "已到期"
    case .expiresToday:
      return "今日到期"
    case .active, .expiringSoon:
      guard let days = subscription.daysRemaining(now: self.store.now) else { return "日期未知" }
      return "剩余\(days)天"
    case .unknown:
      return subscription.verificationText(now: self.store.now)
    }
  }

  private var subscriptionColor: Color {
    guard let subscription = self.effectiveSubscription else { return .secondary }
    switch subscription.status(now: self.store.now) {
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
    guard let credits = self.quota?.resetCredits else { return "未知" }
    if credits.expirationDates.contains(where: { $0 <= self.store.now }) {
      return "\(credits.availableCount) 次 · 待核对"
    }
    return "\(credits.availableCount) 次"
  }

  private func remainingText(_ window: QuotaWindow?) -> String {
    guard let window else { return "--" }
    return "\(Int(window.remainingPercent.rounded()))% 剩余"
  }

  private func resetText(_ window: QuotaWindow?) -> String {
    ResetTimeFormatter.string(window, now: self.store.now)
  }

  private var updatedText: String {
    guard let updatedAt = self.quota?.updatedAt else { return "等待首次同步" }
    return RelativeTimeFormatter.string(from: updatedAt, to: self.store.now) + "更新"
  }

  nonisolated static func money(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "--" }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return "US$\(formatter.string(from: NSNumber(value: value)) ?? "--")"
  }

  nonisolated static func creditValue(_ value: Double) -> String {
    guard value.isFinite else { return "--" }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: value)) ?? "--"
  }

  nonisolated static func subscriptionDate(_ value: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "M/d"
    return formatter.string(from: value)
  }

  nonisolated static func dayDate(_ value: String) -> String {
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.calendar = Calendar(identifier: .gregorian)
    parser.dateFormat = "yyyy-MM-dd"
    guard let date = parser.date(from: value) else { return value }
    return self.subscriptionDate(date)
  }

  nonisolated static func topModel(for day: CodexLocalUsageSnapshot.DailyEntry) -> String? {
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

  nonisolated static func tokens(_ value: Int?) -> String {
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
