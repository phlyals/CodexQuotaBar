import Combine
import Foundation

enum QuotaWindowKind: String, Codable, CaseIterable, Sendable {
  case session, weekly
  var title: String { self == .session ? "5 小时" : "每周" }
  func window(in snapshot: QuotaSnapshot) -> QuotaWindow? {
    self == .session ? snapshot.session : snapshot.weekly
  }
}

struct QuotaSample: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let accountKey: String
  let kind: QuotaWindowKind
  let at: Date
  let used: Double
  let resetsAt: Date?
  let plan: String?
}

struct QuotaHistoryEvent: Codable, Identifiable, Sendable {
  let id: UUID
  let at: Date
  let accountKey: String
  let kind: QuotaWindowKind
  let reason: String
}

@MainActor
final class QuotaHistory: ObservableObject {
  struct Archive: Codable {
    var samples: [QuotaSample] = []
    var latest: [String: QuotaSnapshot] = [:]
    var events: [QuotaHistoryEvent] = []
  }

  @Published private(set) var archive: Archive
  @Published private(set) var persistenceFailed = false
  private let url: URL

  init(url: URL = LocalPrivateStore.url("quota-history.json"), now: Date = Date()) {
    self.url = url
    self.archive = LocalPrivateStore.load(Archive.self, from: url) ?? Archive()
    self.prune(now: now)
  }

  func record(_ snapshot: QuotaSnapshot, now: Date = Date()) {
    guard snapshot.freshness == .fresh, let key = snapshot.accountKey,
      snapshot.updatedAt <= now.addingTimeInterval(60),
      now.timeIntervalSince(snapshot.updatedAt) < 300,
      self.archive.latest[key].map({ $0.updatedAt < snapshot.updatedAt }) ?? true
    else { return }
    for kind in QuotaWindowKind.allCases {
      guard let window = kind.window(in: snapshot), window.isValid else { continue }
      if let previous = self.archive.samples.last(where: { $0.accountKey == key && $0.kind == kind }
      ),
        window.usedPercent < previous.used - 0.1 || window.resetsAt != previous.resetsAt
      {
        self.archive.events.append(
          QuotaHistoryEvent(
            id: UUID(), at: snapshot.updatedAt, accountKey: key, kind: kind,
            reason: window.usedPercent < previous.used - 0.1 ? "检测到额度恢复，原因未确认" : "窗口重置时间变化"))
      }
      self.archive.samples.append(
        QuotaSample(
          id: UUID(), accountKey: key, kind: kind, at: snapshot.updatedAt,
          used: window.usedPercent, resetsAt: window.resetsAt, plan: snapshot.accountPlan))
    }
    self.archive.latest[key] = snapshot
    self.prune(now: now)
    self.persistenceFailed = !LocalPrivateStore.save(self.archive, to: self.url)
  }

  func clear() {
    self.archive = Archive()
    self.persistenceFailed = !LocalPrivateStore.save(self.archive, to: self.url)
  }

  func diagnosticJSON(now: Date = Date()) -> String {
    struct Export: Encodable {
      let version: Int
      let generatedAt: Date
      let retainedDays: Int
      let sampleCount: Int
      let accountCount: Int
      let events: [Event]
      struct Event: Encodable {
        let at: Date
        let window: String
        let category: String
      }
    }
    let report = Export(
      version: 1, generatedAt: now, retainedDays: 30,
      sampleCount: self.archive.samples.count, accountCount: self.archive.latest.count,
      events: self.archive.events.suffix(100).map {
        .init(
          at: $0.at, window: $0.kind.rawValue,
          category: $0.reason == "窗口重置时间变化" ? "window_changed" : "recovery_observed")
      })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return (try? encoder.encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  }

  private func prune(now: Date) {
    let cutoff = now.addingTimeInterval(-30 * 86_400)
    self.archive.samples = Array(
      self.archive.samples.filter {
        $0.at >= cutoff && $0.at <= now.addingTimeInterval(60) && $0.used.isFinite
          && (0...100).contains($0.used)
      }.suffix(60_000))
    self.archive.events = Array(self.archive.events.filter { $0.at >= cutoff }.suffix(1000))
    self.archive.latest = self.archive.latest.filter {
      $0.value.updatedAt >= cutoff && $0.key == $0.value.accountKey
    }
  }
}

enum LocalPrivateStore {
  static func url(_ name: String) -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("QuotaFloat", isDirectory: true).appendingPathComponent(name)
  }

  static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url), data.count < 30_000_000 else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  @discardableResult
  static func save<T: Encodable>(_ value: T, to url: URL) -> Bool {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
      try JSONEncoder().encode(value).write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      return true
    } catch { return false }
  }
}

struct QuotaForecast: Equatable, Sendable {
  let count: Int
  let from: Date
  let to: Date
  let lowRate: Double
  let highRate: Double
  let remaining: Double
  let resetsAt: Date

  func budget(reserve: Double) -> Double { max(0, remaining - min(100, max(0, reserve))) }

  func targetRate(reserve: Double, workHours: Double) -> Double? {
    guard workHours.isFinite, workHours > 0 else { return nil }
    return budget(reserve: reserve) / workHours
  }

  func hours(reserve: Double) -> ClosedRange<Double> {
    let budget = self.budget(reserve: reserve)
    return (budget / highRate)...(budget / lowRate)
  }

  func remaining(after hours: Double) -> ClosedRange<Double> {
    max(0, remaining - max(0, hours) * highRate)...max(0, remaining - max(0, hours) * lowRate)
  }
}

enum QuotaForecaster {
  static let version = "clock-v1"
  static func forecast(
    samples: [QuotaSample], snapshot: QuotaSnapshot, kind: QuotaWindowKind, now: Date
  ) -> QuotaForecast? {
    guard snapshot.freshness == .fresh, let key = snapshot.accountKey,
      now.timeIntervalSince(snapshot.updatedAt) >= -60,
      now.timeIntervalSince(snapshot.updatedAt) < 300,
      let window = kind.window(in: snapshot), window.isValid,
      let reset = window.resetsAt, reset > now
    else { return nil }
    let candidates = samples.filter {
      $0.accountKey == key && $0.kind == kind && $0.resetsAt == reset
        && $0.plan == snapshot.accountPlan
        && $0.at >= now.addingTimeInterval(-6 * 3600) && $0.at <= snapshot.updatedAt
        && $0.used.isFinite && (0...100).contains($0.used)
    }.sorted { $0.at < $1.at }
    // A recovery, a long offline gap, or a sudden rate change starts a new observation segment.
    var segment: [QuotaSample] = []
    for sample in candidates {
      if let previous = segment.last,
        sample.used < previous.used - 0.1 || sample.at.timeIntervalSince(previous.at) > 900
      {
        segment.removeAll()
      }
      if segment.last?.at != sample.at { segment.append(sample) }
    }
    guard segment.count >= 6, let first = segment.first, let last = segment.last,
      last.at.timeIntervalSince(first.at) >= 900, now.timeIntervalSince(last.at) < 300
    else { return nil }
    let pairs = Array(zip(segment, segment.dropFirst()))
    guard pairs.filter({ $0.1.used - $0.0.used >= 0.1 }).count >= 2 else { return nil }
    let rate = (last.used - first.used) / (last.at.timeIntervalSince(first.at) / 3600)
    guard rate.isFinite, rate > 0 else { return nil }
    let half = segment[segment.count / 2]
    let recent = (last.used - half.used) / max(0.001, last.at.timeIntervalSince(half.at) / 3600)
    guard recent > 0, recent / rate >= 0.25, recent / rate <= 4 else { return nil }
    return QuotaForecast(
      count: segment.count, from: first.at, to: last.at,
      lowRate: max(0.001, min(rate, recent) * 0.75), highRate: max(rate, recent) * 1.25,
      remaining: window.remainingPercent, resetsAt: reset)
  }
}
