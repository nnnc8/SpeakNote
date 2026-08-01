import Foundation
import OSLog

enum SecureLogEvent: String, Sendable {
  case settingsLoadFailed = "settings_load_failed"
  case settingsSaveFailed = "settings_save_failed"
  case keychainReadFailed = "keychain_read_failed"
  case keychainWriteFailed = "keychain_write_failed"
  case keychainDeleteFailed = "keychain_delete_failed"
  case hotkeySetupFailed = "hotkey_setup_failed"
  case storageInitializationFailed = "storage_initialization_failed"
}

enum SecureLogger {
  private static let logger = Logger(
    subsystem: "com.nc8.SpeakNote",
    category: "application"
  )

  static func error(_ event: SecureLogEvent) {
    logger.error("\(event.rawValue, privacy: .public)")
  }
}
