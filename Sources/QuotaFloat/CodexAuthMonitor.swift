import Foundation

struct CodexAuthFileFingerprint: Equatable, Sendable {
  let modifiedAt: Date
  let fileSize: UInt64
  let fileIdentifier: UInt64?
}

struct CodexAuthFingerprintReader {
  let fileURL: URL
  private let fileManager: FileManager

  init(
    fileURL: URL = Self.defaultAuthFileURL(),
    fileManager: FileManager = .default
  ) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  func read() -> CodexAuthFileFingerprint? {
    guard
      let attributes = try? self.fileManager.attributesOfItem(atPath: self.fileURL.path),
      let modifiedAt = attributes[.modificationDate] as? Date,
      let fileSize = attributes[.size] as? NSNumber
    else {
      return nil
    }

    let identifier = attributes[.systemFileNumber] as? NSNumber
    return CodexAuthFileFingerprint(
      modifiedAt: modifiedAt,
      fileSize: fileSize.uint64Value,
      fileIdentifier: identifier?.uint64Value)
  }

  static func defaultAuthFileURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
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
  private let reader: CodexAuthFingerprintReader
  private let interval: TimeInterval
  private let onChange: @MainActor () -> Void
  private var lastFingerprint: CodexAuthFileFingerprint?
  private var timer: Timer?

  init(
    reader: CodexAuthFingerprintReader = CodexAuthFingerprintReader(),
    interval: TimeInterval = 5,
    onChange: @escaping @MainActor () -> Void
  ) {
    self.reader = reader
    self.interval = interval
    self.onChange = onChange
  }

  func start() {
    guard self.timer == nil else { return }
    self.lastFingerprint = self.reader.read()
    self.timer = Timer.scheduledTimer(withTimeInterval: self.interval, repeats: true) {
      [weak self] _ in
      Task { @MainActor [weak self] in
        self?.poll()
      }
    }
  }

  func stop() {
    self.timer?.invalidate()
    self.timer = nil
  }

  func poll() {
    let fingerprint = self.reader.read()
    defer { self.lastFingerprint = fingerprint }
    guard let lastFingerprint, let fingerprint else { return }
    guard fingerprint != lastFingerprint else { return }
    self.onChange()
  }
}
