import Foundation

/// Presentation only: token counting and pricing belong to the bundled CodexBar helper.
struct CodexBarUsageSummary {
  var tokens: Int?
  var dollars: Double?
  var partialPricing = false
  var dateRange: String?
  var isStale = false

  static func calculate(
    usage: CodexLocalUsageSnapshot?, weekly: QuotaWindow?, now: Date,
    calendar: Calendar = .current
  ) -> Self {
    guard let usage, usage.provider == "codex", let scanned = usage.updatedAt,
      scanned <= now.addingTimeInterval(300), let weekly, weekly.isValid,
      let reset = weekly.resetsAt, reset > now
    else { return Self() }
    let minutes = weekly.windowMinutes ?? 10080
    guard minutes > 0, minutes <= 30 * 1440 else { return Self() }
    let start = reset.addingTimeInterval(-Double(minutes) * 60)
    guard start <= now, scanned >= start else { return Self() }
    let firstDay = calendar.startOfDay(for: start)
    let lastDay = calendar.startOfDay(for: min(now, scanned))
    guard let coveredStart = calendar.date(
      byAdding: .day, value: -(max(1, usage.historyDays ?? 30) - 1),
      to: calendar.startOfDay(for: scanned)), coveredStart <= firstDay
    else { return Self() }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    let firstKey = formatter.string(from: firstDay)
    let lastKey = formatter.string(from: lastDay)
    let days = usage.calendarDays(now: min(now, scanned), calendar: calendar).filter {
      $0.date >= firstKey && $0.date <= lastKey
    }
    var result = Self(
      dateRange: "\(firstKey) – \(lastKey)",
      isStale: now.timeIntervalSince(scanned) >= 300)
    guard !days.isEmpty else { return result }
    if days.allSatisfy({ ($0.totalTokens ?? -1) >= 0 }) {
      var total = 0
      for day in days {
        let next = total.addingReportingOverflow(day.totalTokens!)
        guard !next.overflow else { return result }
        total = next.partialValue
      }
      result.tokens = total
    }
    let costs = days.compactMap(\.totalCost).filter { $0.isFinite && $0 >= 0 }
    result.partialPricing = days.contains { day in
      let validCost = day.totalCost.map { $0.isFinite && $0 >= 0 } ?? false
      return !validCost || day.modelBreakdowns?.contains {
        ($0.totalTokens ?? 0) > 0 && !($0.cost.map { $0.isFinite && $0 >= 0 } ?? false)
      } == true
    }
    let activeDays = days.filter { ($0.totalTokens ?? 0) > 0 }
    let hasPricedActivity = activeDays.contains { day in
      day.totalCost.map { $0.isFinite && $0 >= 0 } ?? false
    }
    if !costs.isEmpty && (activeDays.isEmpty || hasPricedActivity) {
      let total = costs.reduce(0, +)
      if total.isFinite { result.dollars = total }
    }
    return result
  }

  var tokenText: String {
    tokens.map { QuotaCycleBill.quantity($0) + " Token" } ?? "暂无统计"
  }
  var costText: String {
    dollars.map { String(format: "$%.2f", $0) + (partialPricing ? "（部分）" : "") }
      ?? "价格缺失"
  }
}
