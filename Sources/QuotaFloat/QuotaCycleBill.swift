import Combine
import Foundation

struct CycleTokenEvent: Sendable, Equatable {
  let id: String
  let at: Date
  let model: String
  let input: Int
  let cached: Int
  let output: Int
  let resets: [Int: Int]
  let cost: Double?
  var tokens: Int { input + output }
}

struct QuotaCycleBill {
  var tokens = 0
  var cached = 0
  var dollars = 0.0
  var requests = 0
  var unpriced = 0

  static func summarize(
    events: [CycleTokenEvent], samples: [QuotaSample], accountKey: String,
    kind: QuotaWindowKind, cycle: QuotaCycle
  ) -> Self {
    var bill = Self()
    for event in matchingEvents(
      events: events, samples: samples, accountKey: accountKey, kind: kind, cycle: cycle)
    {
      bill.requests += 1
      bill.tokens += event.tokens
      bill.cached += event.cached
      if let cost = event.cost { bill.dollars += cost } else { bill.unpriced += 1 }
    }
    return bill
  }

  static func matchingEvents(
    events: [CycleTokenEvent], samples: [QuotaSample], accountKey: String,
    kind: QuotaWindowKind, cycle: QuotaCycle
  ) -> [CycleTokenEvent] {
    let minutes = kind == .weekly ? 10080 : 300
    guard let reset = cycle.resetsAt else { return [] }
    let timestamp = Int(reset.timeIntervalSince1970)
    // A reset timestamp is only an inferred account fingerprint; ambiguous matches are excluded.
    let owners = Set(samples.filter {
      $0.kind == kind && $0.resetsAt.map { Int($0.timeIntervalSince1970) } == timestamp
    }.map(\.accountKey))
    guard owners == [accountKey] else { return [] }
    var seen = Set<String>()
    return events.filter { event in
      event.at > cycle.startedAt
        && event.at <= (cycle.exhaustedAt ?? cycle.lastObservedAt)
        && event.resets[minutes] == timestamp
        && seen.insert(event.id).inserted
    }
  }

  var tokenText: String { requests == 0 ? "尚无匹配记录" : Self.quantity(tokens) + " Token" }
  var costText: String {
    if requests == 0 { return "--" }
    if unpriced == requests { return "价格缺失" }
    return String(format: "$%.2f", dollars) + (unpriced > 0 ? "（部分）" : "")
  }
  static func quantity(_ value: Int) -> String {
    if value >= 1_000_000_000 { return String(format: "%.2fB", Double(value) / 1e9) }
    if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1e6) }
    if value >= 1000 { return String(format: "%.1fK", Double(value) / 1000) }
    return String(value)
  }
}

struct WeeklyUsageEstimate {
  var usedPercent: Double?
  var tokens: Int?
  var dollars: Double?
  var elapsed: TimeInterval?
  var isStale = false

  static func calculate(
    events: [CycleTokenEvent], samples: [QuotaSample], snapshot: QuotaSnapshot?, now: Date,
    recordedThrough: Date? = nil
  ) -> Self {
    guard let snapshot, let key = snapshot.accountKey,
      let window = snapshot.weekly, window.isValid,
      let reset = window.resetsAt, reset > now,
      snapshot.updatedAt <= now.addingTimeInterval(300)
    else { return Self() }
    let minutes = window.windowMinutes ?? 10080
    guard minutes > 0 else { return Self() }
    let nominalStart = reset.addingTimeInterval(-Double(minutes) * 60)
    guard nominalStart <= now else { return Self() }
    var result = Self(
      usedPercent: window.usedPercent,
      elapsed: now.timeIntervalSince(nominalStart),
      isStale: snapshot.freshness != .fresh || now.timeIntervalSince(snapshot.updatedAt) >= 300)
    let cycles = QuotaCycleSummary.cycles(
      samples: samples, accountKey: key, kind: .weekly, now: min(now, snapshot.updatedAt))
    guard let cycle = cycles.first, cycle.resetsAt == reset,
      cycle.plan == snapshot.accountPlan, cycle.startedAt >= nominalStart,
      window.usedPercent >= cycle.maximumUsed
    else {
      if window.usedPercent == 0 { result.tokens = 0; result.dollars = 0 }
      return result
    }
    // An observed reset or plan change can restart consumption before the scheduled week ends.
    if cycles.count > 1, cycles[1].resetsAt == reset {
      result.elapsed = now.timeIntervalSince(cycle.startedAt)
    }
    if window.usedPercent == 0 { result.tokens = 0; result.dollars = 0; return result }
    guard let calibration = QuotaCycleSummary.cycles(
      samples: samples.filter { $0.at >= cycle.startedAt }, accountKey: key, kind: .weekly,
      now: min(now, snapshot.updatedAt, recordedThrough ?? now)).first else { return result }
    // Rounded percentages below two points are too small to extrapolate a partial week's bill.
    guard calibration.consumed > 0,
      calibration.startingUsed == 0 || calibration.consumed >= 2 else { return result }
    let matched = QuotaCycleBill.matchingEvents(
      events: events, samples: samples, accountKey: key, kind: .weekly, cycle: calibration)
    guard !matched.isEmpty else { return result }
    let scale = window.usedPercent / calibration.consumed
    let tokens = matched.reduce(0.0) { $0 + Double($1.tokens) } * scale
    guard tokens > 0, tokens.isFinite, tokens.rounded() < Double(Int.max) else { return result }
    result.tokens = Int(tokens.rounded())
    // Fill a missing request price only from priced requests of that exact model in this period.
    // Never use another model's rate or present a partial sum as a total dollar estimate.
    var cost = 0.0
    for (model, requests) in Dictionary(grouping: matched, by: \.model) {
      let priced = requests.filter { $0.cost.map { $0.isFinite && $0 >= 0 } ?? false }
      let knownCost = priced.reduce(0.0) { $0 + ($1.cost ?? 0) }
      let knownTokens = priced.reduce(0.0) { $0 + Double($1.tokens) }
      let missing = requests.filter { $0.cost.map { !$0.isFinite || $0 < 0 } ?? true }
      if !missing.isEmpty {
        guard model != "unknown", knownTokens > 0 else { return result }
        cost += missing.reduce(0.0) { $0 + Double($1.tokens) } * knownCost / knownTokens
      }
      cost += knownCost
    }
    let scaledCost = cost * scale
    if scaledCost.isFinite { result.dollars = scaledCost }
    return result
  }

  var usedText: String {
    usedPercent.map { String(format: "本周已用 %.0f%%", $0) } ?? "等待本周额度更新"
  }
  var tokenText: String {
    tokens.map { ($0 == 0 ? "" : "约 ") + QuotaCycleBill.quantity($0) + " Token" } ?? "Token 待估"
  }
  var costText: String {
    dollars.map { ($0 == 0 ? "" : "约 ") + String(format: "$%.2f", $0) } ?? "费用待估"
  }
  var elapsedText: String? {
    elapsed.map { "本轮已过去 " + QuotaCycleSummary.durationText($0) }
  }
}

actor CycleTokenScanner {
  private var files: [URL: (Date, Int, [CycleTokenEvent])] = [:]
  private var pricingData: Data?

  func scan(home: URL, since: Date) -> [CycleTokenEvent] {
    let fm = FileManager.default
    let cache = fm.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Caches/CodexBar/model-pricing/models-dev-v1.json")
    let data = try? Data(contentsOf: cache)
    if data != pricingData { files.removeAll(); pricingData = data }
    let prices = data.flatMap {
      try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
    let catalog = prices?["catalog"] as? [String: Any]
    let providers = catalog?["providers"] as? [String: Any]
    let provider = providers?["openai"] as? [String: Any]
    let models = provider?["models"] as? [String: Any] ?? [:]
    var result: [String: CycleTokenEvent] = [:]
    var conflicts = Set<String>()
    var retained = Set<URL>()
    for directory in ["sessions", "archived_sessions"] {
      guard let paths = fm.enumerator(
        at: home.appendingPathComponent(directory),
        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
        options: [.skipsHiddenFiles]) else { continue }
      for case let url as URL in paths where url.pathExtension == "jsonl" {
        if Task.isCancelled { return [] }
        guard let meta = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
          let date = meta.contentModificationDate, date >= since, let size = meta.fileSize
        else { continue }
        retained.insert(url)
        let events: [CycleTokenEvent]
        if let old = files[url], old.0 == date && old.1 == size {
          events = old.2
        } else {
          events = Self.parse(url: url, models: models)
          files[url] = (date, size, events)
        }
        for event in events where event.at >= since {
          if let old = result[event.id], old != event { conflicts.insert(event.id) }
          result[event.id] = event
        }
      }
    }
    files = files.filter { retained.contains($0.key) }
    return result.values.filter { !conflicts.contains($0.id) }.sorted { $0.at < $1.at }
  }

  static func price(model: [String: Any]?, input: Int, cached: Int, output: Int) -> Double? {
    guard input >= cached, cached >= 0, output >= 0,
      let rates = model?["cost"] as? [String: Any],
      let i = rates["input"] as? Double, let o = rates["output"] as? Double,
      i.isFinite, o.isFinite, i >= 0, o >= 0,
      input <= 200_000 else { return nil }
    let c = rates["cache_read"] as? Double
    guard cached == 0 || (c != nil && c!.isFinite && c! >= 0) else { return nil }
    return (Double(input - cached) * i + Double(cached) * (c ?? 0) + Double(output) * o) / 1e6
  }

  static func parse(url: URL, models: [String: Any]) -> [CycleTokenEvent] {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var buffer = Data()
    var oversized = false
    var modelByTurn: [String: String] = [:]
    var pending: (String, Date, String, Int, Int, Int)?
    var events: [CycleTokenEvent] = []
    let relevant = ["\"turn_context\"", "\"token_usage_record\"", "\"token_count\""].map { Data($0.utf8) }
    func line(_ bytes: Data) {
      guard relevant.contains(where: { bytes.range(of: $0) != nil }) else { return }
      guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
        let type = root["type"] as? String, let p = root["payload"] as? [String: Any]
      else { return }
      if type == "turn_context", let turn = p["turn_id"] as? String,
        let model = p["model"] as? String { modelByTurn[turn] = model }
      guard let stamp = root["timestamp"] as? String,
        let at = formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
      else { return }
      if type == "token_usage_record" {
        pending = nil
        guard let id = p["response_id"] as? String, !id.isEmpty,
          let turn = p["turn_id"] as? String,
          let usage = p["usage"] as? [String: Any],
          let input = usage["input_tokens"] as? Int,
          let output = usage["output_tokens"] as? Int,
          let cached = usage["cached_input_tokens"] as? Int,
          input >= cached, cached >= 0, output >= 0,
          input < 1_000_000_000, output < 1_000_000_000,
          (usage["cache_write_input_tokens"] as? Int ?? 0) == 0
        else { return }
        pending = (id, at, modelByTurn[turn] ?? "unknown", input, cached, output)
      } else if type == "event_msg", p["type"] as? String == "token_count" {
        guard let event = pending else { return }
        pending = nil
        guard (0...5).contains(at.timeIntervalSince(event.1)),
          let info = p["info"] as? [String: Any],
          let last = info["last_token_usage"] as? [String: Any],
          last["input_tokens"] as? Int == event.3,
          last["cached_input_tokens"] as? Int == event.4,
          last["output_tokens"] as? Int == event.5,
          let rate = p["rate_limits"] as? [String: Any],
          rate["limit_id"] as? String == "codex" else { return }
        var resets: [Int: Int] = [:]
        for name in ["primary", "secondary"] {
          if let window = rate[name] as? [String: Any],
            let minutes = window["window_minutes"] as? Int,
            let reset = window["resets_at"] as? Int,
            [300, 10080].contains(minutes) { resets[minutes] = reset }
        }
        guard !resets.isEmpty else { return }
        events.append(CycleTokenEvent(
          id: event.0, at: event.1, model: event.2, input: event.3, cached: event.4,
          output: event.5, resets: resets,
          cost: price(model: models[event.2] as? [String: Any], input: event.3,
            cached: event.4, output: event.5)))
      }
    }
    // Bound memory even when conversation/image lines are very large; never retain their contents.
    while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
      if Task.isCancelled { return [] }
      var start = chunk.startIndex
      while start < chunk.endIndex {
        let end = chunk[start...].firstIndex(of: 10) ?? chunk.endIndex
        if !oversized {
          if buffer.count + end - start <= 524288 { buffer.append(chunk[start..<end]) }
          else { buffer.removeAll(keepingCapacity: true); oversized = true }
        }
        if end < chunk.endIndex {
          if !oversized { line(buffer) }
          buffer.removeAll(keepingCapacity: true)
          oversized = false
        }
        start = end < chunk.endIndex ? end + 1 : end
      }
    }
    return events
  }
}

@MainActor
final class CycleBillStore: ObservableObject {
  @Published private(set) var events: [CycleTokenEvent] = []
  @Published private(set) var recordedThrough: Date?
  private let scanner = CycleTokenScanner()
  private var task: Task<Void, Never>?
  private var lastScan = Date.distantPast
  private let automatic: Bool
  init(events: [CycleTokenEvent] = [], automatic: Bool = true) {
    self.events = events
    self.automatic = automatic
  }
  func refresh(now: Date) {
    guard automatic, task == nil, now.timeIntervalSince(lastScan) >= 60 else { return }
    lastScan = now
    let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    task = Task { [weak self, scanner] in
      let events = await scanner.scan(home: home, since: now.addingTimeInterval(-30 * 86400))
      guard !Task.isCancelled, let self else { return }
      self.recordedThrough = now
      self.events = events
      self.task = nil
    }
  }
  func stop() { task?.cancel(); task = nil }
}
