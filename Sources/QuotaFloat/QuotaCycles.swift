import Foundation

struct QuotaCycle: Identifiable, Equatable {
  let id: UUID
  let startedAt: Date
  var lastObservedAt: Date
  let resetsAt: Date?
  let startingUsed: Double
  let plan: String?
  var maximumUsed: Double
  var exhaustedAt: Date?
  var hasGap = false
  var closed = false

  var isComplete: Bool { startingUsed == 0 && exhaustedAt != nil && !hasGap }
  var isPartial: Bool { startingUsed != 0 || hasGap || (closed && exhaustedAt == nil) }
  var consumed: Double { max(0, maximumUsed - startingUsed) }
  var duration: TimeInterval {
    max(0, (exhaustedAt ?? lastObservedAt).timeIntervalSince(startedAt))
  }
}

enum QuotaCycleSummary {
  static func cycles(samples: [QuotaSample], accountKey: String, kind: QuotaWindowKind, now: Date)
    -> [QuotaCycle]
  {
    let samples = samples.filter {
      $0.accountKey == accountKey && $0.kind == kind && $0.at <= now
        && $0.used.isFinite && (0...100).contains($0.used)
    }.sorted { $0.at < $1.at }
    var result: [QuotaCycle] = []
    var previous: QuotaSample?
    for sample in samples {
      if let previous, sample.at <= previous.at { continue }
      let boundary =
        previous.map {
          sample.used < $0.used - 0.1 || sample.resetsAt != $0.resetsAt || sample.plan != $0.plan
        } ?? true
      if boundary {
        if !result.isEmpty { result[result.count - 1].closed = true }
        result.append(
          QuotaCycle(
            id: sample.id, startedAt: sample.at, lastObservedAt: sample.at,
            resetsAt: sample.resetsAt, startingUsed: sample.used, plan: sample.plan,
            maximumUsed: sample.used,
            exhaustedAt: sample.used == 100 ? sample.at : nil))
      } else if !result.isEmpty, let previous {
        let index = result.count - 1
        if result[index].exhaustedAt == nil && sample.at.timeIntervalSince(previous.at) > 900 {
          result[index].hasGap = true
        }
        result[index].lastObservedAt = sample.at
        result[index].maximumUsed = max(result[index].maximumUsed, sample.used)
        if sample.used == 100 && result[index].exhaustedAt == nil {
          result[index].exhaustedAt = sample.at
        }
      }
      previous = sample
    }
    if let last = result.last, let reset = last.resetsAt, reset <= now {
      result[result.count - 1].closed = true
    }
    return result.reversed()
  }

  static func durationText(_ interval: TimeInterval) -> String {
    let minutes = max(0, Int(interval / 60))
    if minutes < 1 { return "不足 1 分钟" }
    if minutes < 60 { return "\(minutes) 分钟" }
    if minutes < 1440 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟" }
    return "\(minutes / 1440) 天 \((minutes % 1440) / 60) 小时"
  }

  static func averageCompleteDuration(_ cycles: [QuotaCycle]) -> TimeInterval? {
    let complete = Array(cycles.filter(\.isComplete).prefix(3))
    guard !complete.isEmpty else { return nil }
    return complete.map(\.duration).reduce(0, +) / Double(complete.count)
  }
}
