import Foundation

@testable import SpeakNote

actor FakeSettingsRepository: SettingsStoring {
  private var storedSettings: AppSettings

  init(settings: AppSettings = .defaultValue) {
    storedSettings = settings
  }

  func load() throws -> AppSettings {
    storedSettings
  }

  func save(_ settings: AppSettings) throws {
    storedSettings = settings
  }

  func reset() {
    storedSettings = .defaultValue
  }

  func inspect() -> AppSettings {
    storedSettings
  }
}

actor FakeAPIKeyStore: APIKeyStoring {
  private var apiKey: String?

  init(apiKey: String? = nil) {
    self.apiKey = apiKey
  }

  func loadAPIKey() throws -> String? {
    apiKey
  }

  func saveAPIKey(_ apiKey: String) throws {
    self.apiKey = apiKey
  }

  func deleteAPIKey() throws {
    apiKey = nil
  }

  func inspect() -> String? {
    apiKey
  }
}

struct FakeTranscriptionEngine: TranscriptionEngine {
  let transcript: Transcript

  func transcribe(
    audioURL: URL,
    configuration: TranscriptionConfiguration
  ) async throws -> Transcript {
    transcript
  }
}
