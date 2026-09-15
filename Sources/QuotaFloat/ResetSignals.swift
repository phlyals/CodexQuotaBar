import Combine
import Foundation

struct ResetSignal: Codable, Equatable, Identifiable, Sendable {
  enum State: String, Codable, Sendable {
    case announced, completed, delayed, withdrawn, banked, unclear
    var title: String {
      switch self {
      case .announced: "预告"
      case .completed: "发布方称已完成"
      case .delayed: "延期"
      case .withdrawn: "撤回"
      case .banked: "重置券消息"
      case .unclear: "待核实"
      }
    }
  }
  let id: String
  var publishedAt: Date
  var discoveredAt: Date
  var excerpt: String
  var state: State
  var deadline: Date?
  var timeAssumption: String
  var scope: String
  var verified: Bool
  var linkedPostID: String?
  var resolutionID: String?
  var url: URL { URL(string: "https://x.com/thsottiaux/status/\(id)")! }

  func status(now: Date) -> String {
    if resolutionID != nil { return "已收到后续消息" }
    if state == .announced, let deadline, deadline < now { return "预计时间已过，待确认" }
    if state == .announced, now.timeIntervalSince(publishedAt) > 172_800 { return "历史预告，状态未确认" }
    return state.title
  }

  static func postID(_ url: URL) -> String? {
    guard url.scheme == "https",
      ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(
        url.host?.lowercased() ?? "")
    else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count == 3, parts[0].lowercased() == "thsottiaux", parts[1] == "status",
      (15...22).contains(parts[2].count), parts[2].allSatisfy(\.isNumber)
    else { return nil }
    return parts[2]
  }
}

enum ResetSignalParser {
  static func parse(
    id: String, text: String, publishedAt: Date, discoveredAt: Date, verified: Bool,
    linkedPostID: String? = nil
  ) -> ResetSignal? {
    let lower = text.lowercased()
    guard lower.contains("reset"), !lower.hasPrefix("rt @"),
      !["just kidding", "only joking", "no reset", "not a reset", "reset password"].contains(
        where: lower.contains)
    else { return nil }
    let state: ResetSignal.State
    if lower.contains("cancelled") || lower.contains("canceled") || lower.contains("withdrawn") {
      state = .withdrawn
    } else if lower.contains("delayed") || lower.contains("postponed") {
      state = .delayed
    } else if lower.contains("banked") || lower.contains("reset credit") {
      state = .banked
    } else if [
      "reset all propagated", "reset has been propagated", "all reset for everyone",
      "have now reset", "reset has landed", "reset is complete",
    ].contains(where: lower.contains) {
      state = .completed
    } else if ["will", "landing", "lands", "by midnight"].contains(where: lower.contains) {
      state = .announced
    } else {
      state = .unclear
    }
    let time = Self.time(text: lower, publishedAt: publishedAt)
    let scope =
      lower.contains("astra users")
      ? "Astra 用户，账号适用性待核对" : lower.contains("all paid") ? "付费订阅，账号适用性待核对" : "范围以原帖为准，账号适用性待核对"
    let sentence =
      text.components(separatedBy: .newlines).last {
        $0.lowercased().contains("reset") && !$0.lowercased().contains("classifier rationale")
      } ?? "重置相关消息，请核对原帖"
    return ResetSignal(
      id: id, publishedAt: publishedAt, discoveredAt: discoveredAt,
      excerpt: String(sentence.prefix(220)), state: state,
      deadline: state == .announced ? time.date : nil, timeAssumption: time.note,
      scope: scope, verified: verified, linkedPostID: linkedPostID, resolutionID: nil)
  }

  static func time(text: String, publishedAt: Date) -> (date: Date?, note: String) {
    func match(_ pattern: String) -> [String]? {
      guard let expression = try? NSRegularExpression(pattern: pattern),
        let result = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
      else { return nil }
      return (1..<result.numberOfRanges).map {
        Range(result.range(at: $0), in: text).map { String(text[$0]) } ?? ""
      }
    }
    if let parts = match(#"(?:in|within)\s*~?\s*(\d{1,2})\s*hours?"#), let hours = Double(parts[0]),
      hours <= 48
    {
      return (publishedAt.addingTimeInterval(hours * 3600), "按发帖时间推算；约定时间，不保证到账")
    }
    if let parts = match(
      #"(?:at|by|around)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(utc|pst|pdt|pt)\b"#),
      let rawHour = Int(parts[0]), rawHour <= 23,
      let minute = Int(parts[1].isEmpty ? "0" : parts[1]), minute < 60
    {
      let hour =
        parts[2] == "pm" && rawHour < 12
        ? rawHour + 12 : parts[2] == "am" && rawHour == 12 ? 0 : rawHour
      var calendar = Calendar(identifier: .gregorian)
      // PT uses DST rules; literal PST/PDT remains the explicitly stated fixed offset.
      calendar.timeZone =
        parts[3] == "pt"
        ? TimeZone(identifier: "America/Los_Angeles")!
        : TimeZone(
          secondsFromGMT: parts[3] == "pst" ? -8 * 3600 : parts[3] == "pdt" ? -7 * 3600 : 0)!
      let base =
        text.contains("tomorrow")
        ? calendar.date(byAdding: .day, value: 1, to: publishedAt)! : publishedAt
      let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)
      return (date, "原文时区 \(parts[3].uppercased())；截止/约定时刻，可能提前或延后")
    }
    if text.contains("midnight today") || text.contains("end of day") {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
      return (
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: publishedAt)),
        "原文未指定时区；仅假设 America/Los_Angeles 的当天结束"
      )
    }
    return (nil, "没有可确认的时间，不生成倒计时")
  }

  static func merge(_ existing: [ResetSignal], _ incoming: [ResetSignal], now: Date)
    -> [ResetSignal]
  {
    var indexed = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for var item in incoming {
      if let old = indexed[item.id] {
        if old.verified && !item.verified { continue }
        item.discoveredAt = old.discoveredAt
        item.resolutionID = old.resolutionID
      }
      indexed[item.id] = item
    }
    for followup in indexed.values
    where followup.verified && [.completed, .delayed, .withdrawn].contains(followup.state) {
      if let related = followup.linkedPostID, var original = indexed[related],
        original.state == .announced, followup.publishedAt > original.publishedAt
      {
        original.resolutionID = followup.id
        indexed[related] = original
      }
    }
    return Array(
      indexed.values.filter {
        $0.publishedAt > now.addingTimeInterval(-30 * 86_400)
          && $0.publishedAt < now.addingTimeInterval(300)
      }
      .sorted { $0.publishedAt > $1.publishedAt }.prefix(100))
  }
}

// Consume the publisher's public RSS interface, not its opaque classification/probability model.
final class ResetRSSParser: NSObject, XMLParserDelegate {
  struct Item {
    var link = ""
    var description = ""
    var date = ""
  }
  private var items: [Item] = []
  private var current: Item?
  private var field = ""

  static func parse(_ data: Data, now: Date) throws -> [ResetSignal] {
    guard data.count < 1_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
    let delegate = ResetRSSParser()
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    guard parser.parse() else { throw URLError(.cannotParseResponse) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return delegate.items.compactMap { item in
      guard let url = URL(string: item.link.trimmingCharacters(in: .whitespacesAndNewlines)),
        let id = ResetSignal.postID(url),
        let date = formatter.date(from: item.date.trimmingCharacters(in: .whitespacesAndNewlines))
      else { return nil }
      let text = item.description.components(separatedBy: "Classifier Rationale:")[0]
      return ResetSignalParser.parse(
        id: id, text: text, publishedAt: date, discoveredAt: now, verified: false)
    }
  }

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    if elementName == "item" { current = Item() }
    field = elementName
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard current != nil else { return }
    switch field {
    case "link": current?.link += string
    case "description": current?.description += string
    case "pubDate": current?.date += string
    default: break
    }
  }
  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName: String?
  ) {
    if elementName == "item", let item = current {
      items.append(item)
      current = nil
    }
    field = ""
  }
}

protocol ResetSignalFetching: Sendable {
  func fetch(now: Date, known: [ResetSignal]) async throws -> [ResetSignal]
  func importPost(url: URL, now: Date) async throws -> ResetSignal
}

struct PublicResetSignalFetcher: ResetSignalFetching {
  static let feedURL = URL(string: "https://codexreset.vercel.app/api/feed/codex")!

  func fetch(now: Date, known: [ResetSignal]) async throws -> [ResetSignal] {
    let data = try await self.read(Self.feedURL)
    var signals = try ResetRSSParser.parse(data, now: now)
    guard !signals.isEmpty else { throw URLError(.cannotParseResponse) }
    let verified = Set(known.filter(\.verified).map(\.id))
    var checked = 0
    for index in signals.indices where !verified.contains(signals[index].id) && checked < 3 {
      checked += 1
      do {
        let original = try await self.importPost(url: signals[index].url, now: now)
        if original.state != .unclear || signals[index].state == .unclear {
          signals[index] = original
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Keep labeled RSS evidence when the public embed is unavailable or truncated.
      }
    }
    return signals
  }

  func importPost(url: URL, now: Date) async throws -> ResetSignal {
    guard let id = ResetSignal.postID(url) else { throw URLError(.unsupportedURL) }
    let data = try await self.read(
      URL(string: "https://cdn.syndication.twimg.com/tweet-result?id=\(id)&lang=en&token=0")!)
    struct Post: Decodable {
      struct User: Decodable {
        let screenName: String
        let idStr: String
      }
      struct Quoted: Decodable { let idStr: String }
      let idStr: String
      let text: String
      let createdAt: String
      let user: User
      let quotedTweet: Quoted?
      let inReplyToStatusIdStr: String?
    }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let post = try decoder.decode(Post.self, from: data)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard post.idStr == id, post.user.screenName.lowercased() == "thsottiaux",
      post.user.idStr == "1953337039510003712",
      let date = formatter.date(from: post.createdAt)
        ?? ISO8601DateFormatter().date(from: post.createdAt),
      let signal = ResetSignalParser.parse(
        id: id, text: post.text, publishedAt: date, discoveredAt: now,
        verified: true, linkedPostID: post.quotedTweet?.idStr ?? post.inReplyToStatusIdStr)
    else { throw URLError(.cannotParseResponse) }
    return signal
  }

  private func read(_ url: URL) async throws -> Data {
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    request.httpShouldHandleCookies = false
    request.setValue("CodexQuotaBar/0.3 public-feed-reader", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 1_000_000
    else { throw URLError(.badServerResponse) }
    return data
  }
}

@MainActor
final class ResetSignalStore: ObservableObject {
  struct Archive: Codable {
    var signals: [ResetSignal] = []
    var lastSuccess: Date?
  }
  @Published private(set) var archive: Archive
  @Published private(set) var isRefreshing = false
  @Published private(set) var message: String?
  @Published private(set) var refreshFeedback: String?
  @Published private(set) var lastAttempt: Date?
  @Published private(set) var enabled: Bool
  private let defaults: UserDefaults
  private let url: URL
  private let fetcher: any ResetSignalFetching
  private var task: Task<Void, Never>?
  private var failures = 0

  init(
    url: URL = LocalPrivateStore.url("reset-signals.json"), defaults: UserDefaults = .standard,
    fetcher: any ResetSignalFetching = PublicResetSignalFetcher()
  ) {
    self.url = url
    self.defaults = defaults
    self.fetcher = fetcher
    self.archive = LocalPrivateStore.load(Archive.self, from: url) ?? Archive()
    self.enabled = defaults.bool(forKey: "resetSignalsEnabled")
  }

  func setEnabled(_ enabled: Bool) {
    self.enabled = enabled
    defaults.set(enabled, forKey: "resetSignalsEnabled")
    if enabled { self.refresh() } else { self.stop() }
  }

  func tick(now: Date = Date()) {
    guard enabled,
      lastAttempt.map({ now.timeIntervalSince($0) >= min(7200, 600 * pow(2, Double(failures))) })
        ?? true
    else { return }
    refresh()
  }

  func refresh(importURL: URL? = nil, manual: Bool = false) {
    guard task == nil, enabled || manual || importURL != nil else { return }
    isRefreshing = true
    lastAttempt = Date()
    message = nil
    refreshFeedback = nil
    let now = Date()
    let known = archive.signals
    let fetcher = self.fetcher
    task = Task { [weak self] in
      do {
        let incoming: [ResetSignal]
        if let importURL {
          incoming = [try await fetcher.importPost(url: importURL, now: now)]
        } else {
          incoming = try await fetcher.fetch(now: now, known: known)
        }
        guard let self, !Task.isCancelled else { return }
        let merged = ResetSignalParser.merge(self.archive.signals, incoming, now: now)
        let changed = merged.contains { candidate in
          !known.contains {
            $0.id == candidate.id && $0.excerpt == candidate.excerpt
              && $0.state == candidate.state && $0.verified == candidate.verified
          }
        }
        self.archive.signals = merged
        self.archive.lastSuccess = Date()
        self.refreshFeedback = changed ? "消息已更新" : "已检查，没有新消息"
        self.failures = 0
        if !LocalPrivateStore.save(self.archive, to: self.url) {
          self.message = "消息已读取，本地缓存写入失败"
          self.refreshFeedback = "已更新，缓存保存失败"
        }
      } catch {
        guard let self, !Task.isCancelled else { return }
        self.failures = min(4, self.failures + 1)
        self.message = "消息读取或原帖核验失败；保留上次记录，不影响额度刷新"
        self.refreshFeedback = "检查失败，稍后重试"
      }
      self?.isRefreshing = false
      self?.task = nil
    }
  }

  func stop() {
    task?.cancel()
    task = nil
    isRefreshing = false
  }
}
