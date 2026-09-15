import Foundation
import SwiftUI
@preconcurrency import Translation

enum MessagePresentation {
  static func latest(_ signals: [ResetSignal]) -> [ResetSignal] {
    Array(signals.sorted { $0.publishedAt > $1.publishedAt }.prefix(2))
  }
}

enum PlanningPresentation {
  static func duration(window: QuotaWindow, forecast: QuotaForecast?, reserve: Double, now: Date)
    -> String
  {
    if let reset = window.resetsAt, reset <= now { return "等待额度更新" }
    if window.remainingPercent <= reserve { return reserve == 0 ? "额度已用完" : "已到预留额度" }
    guard let forecast else { return "暂时无法估算" }
    let hours = forecast.hours(reserve: reserve)
    let untilReset = max(0, forecast.resetsAt.timeIntervalSince(now) / 3600)
    if hours.lowerBound >= untilReset { return "可用到下次重置" }
    return String(format: "约 %.1f–%.1f 小时", hours.lowerBound, min(hours.upperBound, untilReset))
  }
}

@MainActor
private enum MessageTranslationCache {
  static let url = LocalPrivateStore.url("message-translations.json")
  static var values = LocalPrivateStore.load([String: String].self, from: url) ?? [:]
  static func save(_ text: String, source: String) {
    if values.count >= 100 { values.removeAll() }
    values[source] = text
    LocalPrivateStore.save(values, to: url)
  }
}

@available(macOS 15.0, *)
struct TranslatedMessageView: View {
  let signal: ResetSignal
  @State private var translated: String?
  @State private var expanded = false
  @State private var showFull = false
  @State private var configuration: TranslationSession.Configuration?
  @State private var failed = false
  @State private var translating = false

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(translated ?? signal.excerpt)
        .lineLimit(showFull ? nil : 6)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      HStack(spacing: 6) {
        Text(translated == nil ? "英文原文" : "机器翻译")
        if !signal.verified { Text("· 内容未核验") }
      }.font(.caption2).foregroundStyle(.secondary)
      if (translated ?? signal.excerpt).count > 180 {
        Button(showFull ? "收起" : "展开全文") { showFull.toggle() }.font(.caption)
      }
      if translated != nil {
        DisclosureGroup("英文原文", isExpanded: $expanded) {
          Text(signal.excerpt).font(.caption).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }.font(.caption)
      } else if translating {
        ProgressView().controlSize(.mini)
      } else {
        Button(failed ? "重试中文翻译" : "中文翻译", systemImage: "character.bubble") {
          failed = false
          translating = true
          if configuration == nil {
            configuration = .init(
              source: .init(identifier: "en"), target: .init(identifier: "zh-Hans"))
          } else {
            configuration?.invalidate()
          }
        }
      }
    }
    .task(id: signal.excerpt) {
      translated = MessageTranslationCache.values[signal.excerpt]
      guard translated == nil else { return }
      let status = await LanguageAvailability().status(
        from: .init(identifier: "en"), to: .init(identifier: "zh-Hans"))
      if status == .installed {
        translating = true
        configuration = .init(source: .init(identifier: "en"), target: .init(identifier: "zh-Hans"))
      }
    }
    .translationTask(configuration) { session in
      do {
        let source = signal.excerpt
        let result = try await session.translate(source)
        try Task.checkCancellation()
        translated = result.targetText
        MessageTranslationCache.save(result.targetText, source: source)
      } catch {
        failed = true
      }
      translating = false
    }
  }
}
