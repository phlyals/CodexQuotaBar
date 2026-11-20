import CodexBarCore
import Foundation

enum QuotaProviderIcon: Sendable {
  case codex
  case antigravity
}

enum QuotaWindowLane: Sendable {
  case primary
  case secondary
  case tertiary
}

struct QuotaWindowFallback: Sendable {
  let lane: QuotaWindowLane
  let assumedMinutes: Int
}

struct QuotaProviderColor: Sendable {
  let red: Double
  let green: Double
  let blue: Double
}

struct QuotaProviderDefinition: Sendable {
  let id: QuotaProvider
  let displayName: String
  let coreProvider: UsageProvider
  let icon: QuotaProviderIcon
  let color: QuotaProviderColor
  let sessionFallback: QuotaWindowFallback
  let weeklyFallback: QuotaWindowFallback
}

enum QuotaProviderCatalog {
  static let definitions: [QuotaProviderDefinition] = [
    QuotaProviderDefinition(
      id: .codex,
      displayName: "Codex",
      coreProvider: .codex,
      icon: .codex,
      color: QuotaProviderColor(red: 0.42, green: 0.33, blue: 0.96),
      sessionFallback: QuotaWindowFallback(lane: .primary, assumedMinutes: 300),
      weeklyFallback: QuotaWindowFallback(lane: .secondary, assumedMinutes: 10_080)),
    QuotaProviderDefinition(
      id: .antigravity,
      displayName: "Google",
      coreProvider: .antigravity,
      icon: .antigravity,
      color: QuotaProviderColor(red: 0.24, green: 0.72, blue: 0.50),
      sessionFallback: QuotaWindowFallback(lane: .primary, assumedMinutes: 300),
      weeklyFallback: QuotaWindowFallback(lane: .secondary, assumedMinutes: 300)),
  ]

  private static let byID = Dictionary(uniqueKeysWithValues: Self.definitions.map { ($0.id, $0) })

  static func definition(for provider: QuotaProvider) -> QuotaProviderDefinition {
    guard let definition = Self.byID[provider] else {
      preconditionFailure("Missing QuotaFloat provider definition for \(provider.rawValue)")
    }
    return definition
  }

  static var orderedProviders: [QuotaProvider] {
    Self.definitions.map(\.id)
  }
}

extension QuotaProvider {
  var definition: QuotaProviderDefinition {
    QuotaProviderCatalog.definition(for: self)
  }
}
