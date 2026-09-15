import Foundation

final class QuotaCacheStore {
  let fileURL: URL

  init(fileURL: URL? = nil) {
    if let fileURL {
      self.fileURL = fileURL
      return
    }

    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
    self.fileURL =
      support
      .appendingPathComponent("QuotaFloat", isDirectory: true)
      .appendingPathComponent("quota-cache.json", isDirectory: false)
  }

  func load() -> [QuotaSnapshot] {
    guard let data = try? Data(contentsOf: self.fileURL) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let cache = try? decoder.decode(QuotaCache.self, from: data),
      (1...2).contains(cache.version)
    else {
      return []
    }
    if cache.version == 1 {
      let backup = self.fileURL.appendingPathExtension("v1-backup")
      if !FileManager.default.fileExists(atPath: backup.path) {
        try? data.write(to: backup, options: .atomic)
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: backup.path)
      }
    }
    return cache.snapshots.filter(\.hasQuotaData)
  }

  func save(_ snapshots: [QuotaSnapshot]) {
    let persistentSnapshots = snapshots.filter(\.hasQuotaData)
    guard !persistentSnapshots.isEmpty else {
      try? FileManager.default.removeItem(at: self.fileURL)
      return
    }

    do {
      try FileManager.default.createDirectory(
        at: self.fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(QuotaCache(snapshots: persistentSnapshots))
      try data.write(to: self.fileURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: self.fileURL.path)
    } catch {
      // Cache failures must never interrupt live quota display.
    }
  }
}
