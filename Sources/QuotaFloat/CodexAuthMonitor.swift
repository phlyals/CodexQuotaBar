import Foundation

struct CodexAuthIdentity: Equatable, Sendable {
  let accountID: String?
  let email: String?
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
    guard
      let data = try? Data(contentsOf: self.fileURL)
    else {
      return nil
    }

    return Self.identity(from: data)
  }

  static func identity(from data: Data) -> CodexAuthIdentity? {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tokens = root["tokens"] as? [String: Any]
    else {
      return nil
    }

    let accountID = Self.trimmedString(tokens["account_id"] ?? tokens["accountId"])
    let email = Self.email(fromIDToken: Self.trimmedString(tokens["id_token"] ?? tokens["idToken"]))
    guard accountID != nil || email != nil else { return nil }
    return CodexAuthIdentity(accountID: accountID, email: email)
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

  private static func trimmedString(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func email(fromIDToken idToken: String?) -> String? {
    guard let idToken else { return nil }
    let parts = idToken.split(separator: ".")
    guard parts.count >= 2 else { return nil }

    var payload = String(parts[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - payload.count % 4) % 4
    payload.append(String(repeating: "=", count: padding))

    guard
      let data = Data(base64Encoded: payload),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return Self.trimmedString(json["email"])
  }
}

@MainActor
final class CodexAuthMonitor {
  private let reader: CodexAuthIdentityReader
  private let interval: TimeInterval
  private let onChange: @MainActor () -> Void
  private var lastIdentity: CodexAuthIdentity?
  private var timer: Timer?

  init(
    reader: CodexAuthIdentityReader = CodexAuthIdentityReader(),
    interval: TimeInterval = 5,
    onChange: @escaping @MainActor () -> Void
  ) {
    self.reader = reader
    self.interval = interval
    self.onChange = onChange
  }

  func start() {
    guard self.timer == nil else { return }
    self.lastIdentity = self.reader.read()
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
    guard let identity = self.reader.read() else { return }
    defer { self.lastIdentity = identity }
    guard let lastIdentity else {
      self.onChange()
      return
    }
    guard identity != lastIdentity else { return }
    self.onChange()
  }
}
