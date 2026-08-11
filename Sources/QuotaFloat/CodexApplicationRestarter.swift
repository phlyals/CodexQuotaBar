import AppKit
import Foundation

@MainActor
protocol CodexRunningApplication: AnyObject {
  var isTerminated: Bool { get }

  @discardableResult
  func terminate() -> Bool

  @discardableResult
  func forceTerminate() -> Bool
}

extension NSRunningApplication: CodexRunningApplication {}

@MainActor
protocol CodexApplicationOpening: AnyObject {
  func openApplication(
    at url: URL,
    configuration: NSWorkspace.OpenConfiguration
  ) async throws -> Bool
}

@MainActor
final class WorkspaceCodexApplicationOpener: CodexApplicationOpening {
  func openApplication(
    at url: URL,
    configuration: NSWorkspace.OpenConfiguration
  ) async throws -> Bool {
    let application = try await NSWorkspace.shared.openApplication(
      at: url,
      configuration: configuration)
    return !application.isTerminated
  }
}

@MainActor
struct CodexApplicationRestarter {
  typealias Sleeper = @MainActor @Sendable (Duration) async throws -> Void

  enum RestartError: LocalizedError, Equatable {
    case terminationRequestRejected
    case forceTerminationRequestRejected
    case terminationTimedOut
    case launchDidNotStart

    var errorDescription: String? {
      switch self {
      case .terminationRequestRejected:
        "无法请求 Codex 退出。"
      case .forceTerminationRequestRejected:
        "Codex 没有正常退出，也无法强制结束。"
      case .terminationTimedOut:
        "Codex 退出超时，因此没有启动新实例。"
      case .launchDidNotStart:
        "macOS 已收到请求，但 Codex 新实例没有成功启动。"
      }
    }
  }

  private let opener: any CodexApplicationOpening
  private let normalExitPollCount: Int
  private let forcedExitPollCount: Int
  private let pollInterval: Duration
  private let sleep: Sleeper

  init(
    opener: any CodexApplicationOpening = WorkspaceCodexApplicationOpener(),
    normalExitPollCount: Int = 100,
    forcedExitPollCount: Int = 50,
    pollInterval: Duration = .milliseconds(100),
    sleep: @escaping Sleeper = { duration in try await Task.sleep(for: duration) }
  ) {
    self.opener = opener
    self.normalExitPollCount = normalExitPollCount
    self.forcedExitPollCount = forcedExitPollCount
    self.pollInterval = pollInterval
    self.sleep = sleep
  }

  func restart(
    application: any CodexRunningApplication,
    appURL: URL
  ) async throws {
    if !application.isTerminated, !application.terminate() {
      throw RestartError.terminationRequestRejected
    }

    if !application.isTerminated,
      !(await self.waitForTermination(application, pollCount: self.normalExitPollCount))
    {
      if !application.forceTerminate() {
        throw RestartError.forceTerminationRequestRejected
      }
      guard await self.waitForTermination(application, pollCount: self.forcedExitPollCount) else {
        throw RestartError.terminationTimedOut
      }
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.createsNewApplicationInstance = true
    configuration.allowsRunningApplicationSubstitution = false
    guard try await self.opener.openApplication(at: appURL, configuration: configuration) else {
      throw RestartError.launchDidNotStart
    }
  }

  private func waitForTermination(
    _ application: any CodexRunningApplication,
    pollCount: Int
  ) async -> Bool {
    guard !application.isTerminated else { return true }
    for _ in 0..<pollCount {
      do {
        try await self.sleep(self.pollInterval)
      } catch {
        return application.isTerminated
      }
      if application.isTerminated { return true }
    }
    return application.isTerminated
  }
}
