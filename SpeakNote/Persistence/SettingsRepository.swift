import Foundation

protocol SettingsStoring: Actor {
  func load() throws -> AppSettings
  func save(_ settings: AppSettings) throws
  func reset()
}

enum SettingsRepositoryError: Error, Equatable, Sendable {
  case unavailableSuite
  case unreadableData
  case encodingFailed
}

actor SettingsRepository: SettingsStoring {
  nonisolated static let storageKey = "com.nc8.SpeakNote.settings.v1"

  private let defaults: UserDefaults
  private let storageKey: String

  init(storageKey: String = SettingsRepository.storageKey) {
    defaults = .standard
    self.storageKey = storageKey
  }

  init(
    suiteName: String,
    storageKey: String = SettingsRepository.storageKey
  ) throws {
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      throw SettingsRepositoryError.unavailableSuite
    }
    self.defaults = defaults
    self.storageKey = storageKey
  }

  func load() throws -> AppSettings {
    guard let data = defaults.data(forKey: storageKey) else {
      return .defaultValue
    }

    do {
      return try JSONDecoder().decode(AppSettings.self, from: data)
    } catch {
      throw SettingsRepositoryError.unreadableData
    }
  }

  func save(_ settings: AppSettings) throws {
    do {
      defaults.set(try JSONEncoder().encode(settings), forKey: storageKey)
    } catch {
      throw SettingsRepositoryError.encodingFailed
    }
  }

  func reset() {
    defaults.removeObject(forKey: storageKey)
  }
}
