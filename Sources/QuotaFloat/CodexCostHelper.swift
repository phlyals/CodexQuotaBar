import CodexBarCore
import Foundation

struct CodexLocalUsageSnapshot: Codable, Equatable, Sendable {
  struct DailyEntry: Codable, Equatable, Identifiable, Sendable {
    struct ModelBreakdown: Codable, Equatable, Sendable {
      let modelName: String
      let cost: Double?
      let totalTokens: Int?
    }

    let date: String
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
    let totalTokens: Int?
    let totalCost: Double?
    let modelsUsed: [String]?
    let modelBreakdowns: [ModelBreakdown]?

    var id: String { self.date }
  }

  let provider: String
  let source: String
  let updatedAt: Date?
  let currencyCode: String?
  let sessionTokens: Int?
  let sessionCostUSD: Double?
  let historyDays: Int?
  let last30DaysTokens: Int?
  let last30DaysCostUSD: Double?
  let daily: [DailyEntry]

  var topModel: String? {
    var scores: [String: (cost: Double, tokens: Int)] = [:]
    for entry in self.daily {
      if let breakdowns = entry.modelBreakdowns {
        for breakdown in breakdowns {
          var score = scores[breakdown.modelName] ?? (0, 0)
          score.cost += breakdown.cost ?? 0
          score.tokens += breakdown.totalTokens ?? 0
          scores[breakdown.modelName] = score
        }
      } else {
        for model in entry.modelsUsed ?? [] {
          var score = scores[model] ?? (0, 0)
          score.tokens += entry.totalTokens ?? 0
          scores[model] = score
        }
      }
    }
    return scores.max { lhs, rhs in
      lhs.value.cost == rhs.value.cost
        ? lhs.value.tokens < rhs.value.tokens
        : lhs.value.cost < rhs.value.cost
    }?.key
  }

  /// Prefer today's primary model, falling back to the most recent active day, then 30-day topModel.
  func activeModel(now: Date = Date(), calendar: Calendar = .current) -> String? {
    if let today = self.today(now: now, calendar: calendar),
      let model = Self.primaryModel(for: today)
    {
      return model
    }
    for day in self.calendarDays(now: now, calendar: calendar).reversed() {
      if let model = Self.primaryModel(for: day) {
        return model
      }
    }
    return self.topModel
  }

  static func primaryModel(for day: DailyEntry) -> String? {
    if let breakdowns = day.modelBreakdowns, !breakdowns.isEmpty {
      return breakdowns.max { lhs, rhs in
        let lTokens = lhs.totalTokens ?? 0
        let rTokens = rhs.totalTokens ?? 0
        if lTokens == rTokens {
          return (lhs.cost ?? 0) < (rhs.cost ?? 0)
        }
        return lTokens < rTokens
      }?.modelName
    }
    return day.modelsUsed?.first
  }

  func calendarDays(now: Date = Date(), calendar: Calendar = .current) -> [DailyEntry] {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    let today = calendar.startOfDay(for: now)
    let scannedDay = self.updatedAt.map { calendar.startOfDay(for: $0) }
    let firstScanned = scannedDay.flatMap {
      calendar.date(byAdding: .day, value: -(max(1, self.historyDays ?? 30) - 1), to: $0)
    }
    let byDate = Dictionary(
      self.daily.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
    return (-29...0).compactMap { offset in
      guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
      let key = formatter.string(from: day)
      if let entry = byDate[key] { return entry }
      let covered = scannedDay.map { day <= $0 } == true && firstScanned.map { day >= $0 } == true
      return DailyEntry(
        date: key, inputTokens: covered ? 0 : nil, outputTokens: covered ? 0 : nil,
        cacheReadTokens: nil, cacheCreationTokens: nil, totalTokens: covered ? 0 : nil,
        totalCost: covered ? 0 : nil, modelsUsed: [], modelBreakdowns: [])
    }
  }

  var hasPartialPricing: Bool {
    self.daily.contains { day in
      if day.totalTokens ?? 0 > 0, day.totalCost == nil { return true }
      return day.modelBreakdowns?.contains {
        ($0.totalTokens ?? 0) > 0 && $0.cost == nil
      } == true
    }
  }

  func today(now: Date = Date(), calendar: Calendar = .current) -> DailyEntry? {
    self.calendarDays(now: now, calendar: calendar).last
  }

  func totalCost(now: Date = Date()) -> Double? {
    let days = self.calendarDays(now: now)
    let active = days.filter { ($0.totalTokens ?? 0) > 0 }
    if !active.isEmpty, active.allSatisfy({ $0.totalCost == nil }) { return nil }
    let values = days.compactMap(\.totalCost)
    return values.isEmpty ? nil : values.reduce(0, +)
  }

  func totalTokens(now: Date = Date()) -> Int? {
    let values = self.calendarDays(now: now).compactMap(\.totalTokens)
    return values.isEmpty ? nil : values.reduce(0, +)
  }
}

protocol CodexLocalUsageFetching: Sendable {
  func fetch(forceRefresh: Bool) async throws -> CodexLocalUsageSnapshot
}

struct CodexCostHelper: CodexLocalUsageFetching {
  private struct ErrorPayload: Decodable {
    let message: String?
  }

  private struct Payload: Decodable {
    let provider: String
    let source: String
    let updatedAt: Date?
    let currencyCode: String?
    let sessionTokens: Int?
    let sessionCostUSD: Double?
    let historyDays: Int?
    let last30DaysTokens: Int?
    let last30DaysCostUSD: Double?
    let daily: [CodexLocalUsageSnapshot.DailyEntry]
    let error: ErrorPayload?
  }

  enum HelperError: LocalizedError {
    case missingHelper
    case missingPayload
    case providerError(String)

    var errorDescription: String? {
      switch self {
      case .missingHelper: "应用包缺少 CodexBarCLI 用量 helper。"
      case .missingPayload: "CodexBarCLI 没有返回 Codex 用量。"
      case .providerError(let message): message
      }
    }
  }

  private let helperURL: URL?
  private let environment: [String: String]

  init(
    helperURL: URL? = CodexCostHelper.defaultHelperURL(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.helperURL = helperURL
    self.environment = environment
  }

  func fetch(forceRefresh: Bool) async throws -> CodexLocalUsageSnapshot {
    guard let helperURL else { throw HelperError.missingHelper }
    var arguments = ["cost", "--provider", "codex", "--format", "json", "--json-only"]
    // Incremental scans remain cheap; --refresh invalidates the helper's scan TTL.
    if forceRefresh { arguments.append("--refresh") }
    var helperEnvironment = self.environment
    // Keep the helper independent from a separately installed CodexBar's config. Older CodexBar
    // config schemas must not prevent QuotaFloat from reading the local Codex session logs.
    helperEnvironment["CODEXBAR_CONFIG"] = Self.isolatedConfigURL().path
    let result = try await SubprocessRunner.run(
      binary: helperURL.path,
      arguments: arguments,
      environment: helperEnvironment,
      timeout: 45,
      label: "codex-local-cost")
    return try Self.decode(result.stdout)
  }

  static func decode(_ json: String) throws -> CodexLocalUsageSnapshot {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payloads = try decoder.decode([Payload].self, from: Data(json.utf8))
    guard let payload = payloads.first(where: { $0.provider == "codex" }) else {
      throw HelperError.missingPayload
    }
    if let error = payload.error {
      throw HelperError.providerError(error.message ?? "Codex 本机用量读取失败。")
    }
    return CodexLocalUsageSnapshot(
      provider: payload.provider,
      source: payload.source,
      updatedAt: payload.updatedAt,
      currencyCode: payload.currencyCode,
      sessionTokens: payload.sessionTokens,
      sessionCostUSD: payload.sessionCostUSD,
      historyDays: payload.historyDays,
      last30DaysTokens: payload.last30DaysTokens,
      last30DaysCostUSD: payload.last30DaysCostUSD,
      daily: payload.daily)
  }

  private static func defaultHelperURL(bundle: Bundle = .main) -> URL? {
    let bundled = bundle.bundleURL.appendingPathComponent(
      "Contents/Helpers/CodexBarCLI", isDirectory: false)
    if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
    if let override = ProcessInfo.processInfo.environment["QUOTAFLOAT_CODEXBAR_CLI"],
      FileManager.default.isExecutableFile(atPath: override)
    {
      return URL(fileURLWithPath: override)
    }
    return nil
  }

  private static func isolatedConfigURL() -> URL {
    let support =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? FileManager.default.temporaryDirectory
    return
      support
      .appendingPathComponent("QuotaFloat", isDirectory: true)
      .appendingPathComponent("CodexBarCLI-config.json", isDirectory: false)
  }
}
