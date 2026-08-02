import Foundation
import Security

enum LegacyProviderCredentialCleaner {
  private static let kimiService = "local.channoey.quotafloat.kimi"
  private static let kimiAccount = "coding-plan-api-key"

  static func removeRemnants() throws {
    let status = SecItemDelete(self.keychainQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw NSError(
        domain: NSOSStatusErrorDomain,
        code: Int(status),
        userInfo: [NSLocalizedDescriptionKey: "无法删除旧 Kimi 钥匙串项目（状态码 \(status)）。"])
    }
    if FileManager.default.fileExists(atPath: self.legacyKimiFileURL.path) {
      try FileManager.default.removeItem(at: self.legacyKimiFileURL)
    }
  }

  private static var keychainQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: self.kimiService,
      kSecAttrAccount as String: self.kimiAccount,
    ]
  }

  private static var legacyKimiFileURL: URL {
    let root =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
    return
      root
      .appendingPathComponent("QuotaFloat", isDirectory: true)
      .appendingPathComponent("kimi-code-api-key")
  }
}
