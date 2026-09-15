import CodexBarCore
import CryptoKit
import Foundation

struct CodexAuthIdentity: Equatable, Sendable {
  let accountID: String?
  let email: String?
  var workspaceID: String? = nil

  var cacheKey: String? {
    guard let accountID, !accountID.isEmpty else { return nil }
    return Self.cacheKey(accountID: accountID, workspaceID: self.workspaceID)
  }

  static func cacheKey(accountID: String, workspaceID: String? = nil) -> String {
    let value = accountID + "\u{0}" + (workspaceID ?? accountID)
    return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

struct CodexAuthIdentityReader {
  let fileURL: URL
  private let fileManager: FileManager

  init(
    fileURL: URL = Self.defaultAuthFileURL(),
    fileManager: FileManager = .default
  ) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  func read() -> CodexAuthIdentity? {
    self.readState()?.identity
  }

  func readState() -> CodexAuthState? {
    guard let data = self.fileManager.contents(atPath: self.fileURL.path), !data.isEmpty else {
      return nil
    }
    return Self.state(
      from: data,
      fingerprint: CodexAuthFingerprint.fingerprint(data: data))
  }

  static func identity(from data: Data) -> CodexAuthIdentity? {
    Self.state(from: data)?.identity
  }

  static func state(from data: Data, fingerprint: String? = nil) -> CodexAuthState? {
    CodexSubscriptionMetadataReader.state(from: data, fingerprint: fingerprint)
  }

  static func defaultAuthFileURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
      return URL(fileURLWithPath: codexHome, isDirectory: true)
        .appendingPathComponent("auth.json", isDirectory: false)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex", isDirectory: true)
      .appendingPathComponent("auth.json", isDirectory: false)
  }
}

@MainActor
final class CodexAuthMonitor {
  private let reader: CodexAuthIdentityReader
  private let interval: TimeInterval
  private let onChange: @MainActor (CodexAuthChange) -> Void
  private var lastState: CodexAuthState?
  private var timer: Timer?

  init(
    reader: CodexAuthIdentityReader = CodexAuthIdentityReader(),
    interval: TimeInterval = 5,
    onChange: @escaping @MainActor (CodexAuthChange) -> Void
  ) {
    self.reader = reader
    self.interval = interval
    self.onChange = onChange
  }

  func start() {
    guard self.timer == nil else { return }
    self.lastState = self.reader.readState()
    let timer = Timer(timeInterval: self.interval, repeats: true) {
      [weak self] _ in
      Task { @MainActor [weak self] in
        self?.poll()
      }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func stop() {
    self.timer?.invalidate()
    self.timer = nil
  }

  func acceptCurrentState() {
    self.lastState = self.reader.readState()
  }

  func poll() {
    guard let state = self.reader.readState() else {
      if self.lastState != nil {
        self.lastState = nil
        self.onChange(.accountChanged)
      }
      return
    }
    guard let lastState = self.lastState else {
      self.lastState = state
      self.onChange(.accountChanged)
      return
    }
    guard let change = CodexAuthChange.classify(previous: lastState, current: state) else {
      return
    }
    self.lastState = state
    self.onChange(change)
  }
}
