import Charts
import SwiftUI

struct CodexDashboardView: View {
  @ObservedObject var store: CodexDashboardStore

  private var quota: QuotaSnapshot? { self.store.quota }
  private var usage: CodexLocalUsageSnapshot? { self.store.localUsage }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      self.header
      Divider()
      self.quotaSection
      Divider()
      self.usageSection
      Divider()
      self.creditsSection
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(width: 350, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var header: some View {
    VStack(spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        Text("Codex")
          .font(.title3.bold())
        Spacer()
        Text(self.quota?.accountEmail ?? "未识别账号")
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      HStack {
        Text(self.updatedText)
          .foregroundStyle(.secondary)
        Spacer()
        if let plan = self.quota?.accountPlan, !plan.isEmpty {
          Text(plan)
            .foregroundStyle(.secondary)
        }
      }
      .font(.subheadline)
    }
  }

  private var quotaSection: some View {
    VStack(alignment: .leading, spacing: 9) {
      self.quotaRow(title: "5 小时", window: self.quota?.session)
      self.quotaRow(title: "每周", window: self.quota?.weekly)
      if let message = self.quota?.message, !message.isEmpty {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func quotaRow(title: String, window: QuotaWindow?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.headline)
      if let window {
        ProgressView(value: window.remainingPercent / 100)
          .tint(.cyan)
      } else {
        Capsule()
          .fill(Color(nsColor: .separatorColor).opacity(0.45))
          .frame(height: 8)
      }
      HStack {
        Text(window.map { "\(Int($0.remainingPercent.rounded()))% 剩余" } ?? "--")
          .fontWeight(.medium)
        Spacer()
        Text(ResetTimeFormatter.string(window, now: Date()))
          .foregroundStyle(.secondary)
      }
      .font(.subheadline)
    }
  }

  private var usageSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("本机用量")
          .font(.headline)
        Spacer()
        if self.store.isLoadingLocalUsage {
          ProgressView().controlSize(.small)
        }
      }

      HStack(spacing: 20) {
        self.metric(title: "今日", value: Self.money(self.usage?.sessionCostUSD))
        self.metric(title: "30 天", value: Self.money(self.usage?.last30DaysCostUSD))
      }
      HStack(spacing: 20) {
        self.metric(title: "今日 Token", value: Self.tokens(self.usage?.sessionTokens))
        self.metric(title: "近 30 天 Token", value: Self.tokens(self.usage?.last30DaysTokens))
      }

      if let usage, !usage.daily.isEmpty {
        Chart(usage.daily.suffix(30)) { day in
          BarMark(
            x: .value("日期", day.date),
            y: .value("估算费用", day.totalCost ?? 0)
          )
          .foregroundStyle(.cyan.opacity(0.7))
          .cornerRadius(2)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 54)
      }

      HStack {
        Text("最常用模型：")
          .foregroundStyle(.secondary)
        Text(self.usage?.topModel ?? "--")
      }
      .font(.subheadline)

      Text("根据本机 Token 用量估算，不是订阅账单")
        .font(.caption)
        .foregroundStyle(.secondary)

      if let message = self.store.localUsageMessage, !message.isEmpty {
        Text(message)
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(2)
      }
    }
  }

  private func metric(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.title3.bold())
        .monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var creditsSection: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("额外重置额度")
        .fontWeight(.semibold)
      if let credits = self.quota?.resetCredits {
        Spacer()
        Text("\(credits.availableCount) 次")
        if let expiry = credits.nextExpirationDate {
          Text("· \(expiry.formatted(date: .abbreviated, time: .omitted)) 到期")
        }
      } else {
        Spacer()
        Text("暂无")
      }
    }
    .font(.subheadline)
    .foregroundStyle(.secondary)
  }

  private var updatedText: String {
    guard let updatedAt = self.quota?.updatedAt else { return "等待首次同步" }
    return RelativeTimeFormatter.string(from: updatedAt, to: Date()) + "更新"
  }

  static func money(_ value: Double?) -> String {
    guard let value else { return "--" }
    return value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
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
