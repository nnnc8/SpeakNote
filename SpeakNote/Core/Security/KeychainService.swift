import Foundation
import Security

protocol APIKeyStoring: Actor {
  func loadAPIKey() throws -> String?
  func saveAPIKey(_ apiKey: String) throws
  func deleteAPIKey() throws
}

enum KeychainError: Error, Equatable, Sendable {
  case invalidValue
  case unexpectedData
  case operationFailed(OSStatus)
}

actor SystemKeychainService: APIKeyStoring {
  nonisolated static let service = "com.nc8.SpeakNote.groq"
  nonisolated static let account = "profile/default"
  private let service: String
  private let account: String

  init(
    service: String = SystemKeychainService.service,
    account: String = SystemKeychainService.account
  ) {
    self.service = service
    self.account = account
  }

  func loadAPIKey() throws -> String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw KeychainError.operationFailed(status)
    }
    guard
      let data = result as? Data,
      let apiKey = String(data: data, encoding: .utf8)
    else {
      throw KeychainError.unexpectedData
    }
    return apiKey
  }

  func saveAPIKey(_ apiKey: String) throws {
    guard !apiKey.isEmpty, let data = apiKey.data(using: .utf8) else {
      throw KeychainError.invalidValue
    }

    let update = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(
      baseQuery as CFDictionary,
      update as CFDictionary
    )

    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainError.operationFailed(updateStatus)
    }

    var item = baseQuery
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] =
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainError.operationFailed(addStatus)
    }
  }

  func deleteAPIKey() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.operationFailed(status)
    }
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
