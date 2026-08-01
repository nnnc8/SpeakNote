import Combine
import Foundation

@MainActor
final class SettingsCoordinator: ObservableObject {
  @Published var settings: AppSettings
  @Published var apiKeyDraft = ""
  @Published private(set) var hasStoredAPIKey = false
  @Published private(set) var localTranscriptionCapability: ProviderTranscriptionCapability =
    .unavailable(.providerNotConfigured)
  @Published private(set) var isBusy = false
  @Published var errorMessage: String?

  private let settingsRepository: any SettingsStoring
  private let keychainService: any APIKeyStoring
  private let appleSpeechCapability: (any TranscriptionProviderCapabilityChecking)?

  init(
    settingsRepository: any SettingsStoring,
    keychainService: any APIKeyStoring,
    appleSpeechCapability:
      (any TranscriptionProviderCapabilityChecking)? = nil
  ) {
    self.settingsRepository = settingsRepository
    self.keychainService = keychainService
    self.appleSpeechCapability = appleSpeechCapability
    settings = .defaultValue
  }

  func load() async {
    isBusy = true
    defer { isBusy = false }

    do {
      settings = try await settingsRepository.load()
    } catch {
      SecureLogger.error(.settingsLoadFailed)
      errorMessage = String(localized: "Settings could not be loaded.")
    }

    do {
      hasStoredAPIKey = try await keychainService.loadAPIKey() != nil
    } catch {
      SecureLogger.error(.keychainReadFailed)
      errorMessage = String(localized: "The API key status could not be read.")
    }

    await refreshLocalTranscriptionCapability()
  }

  func saveSettings() async {
    let transcriptionModelID = settings.transcriptionModelID
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let textProcessingModelID = settings.textProcessingModelID
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let structuredTextModelID = settings.structuredTextModelID
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !transcriptionModelID.isEmpty else {
      errorMessage = String(localized: "The transcription model cannot be empty.")
      return
    }
    guard !textProcessingModelID.isEmpty else {
      errorMessage = String(localized: "The text-processing model cannot be empty.")
      return
    }
    guard !structuredTextModelID.isEmpty else {
      errorMessage = String(localized: "The structured-note model cannot be empty.")
      return
    }
    guard
      !settings.localOnly || settings.transcriptionProviderID == .appleSpeech
    else {
      errorMessage = String(
        localized: "Choose Apple Speech before enabling local-only transcription."
      )
      return
    }
    let recognitionLanguageCode = normalizedLanguageCode(
      settings.recognitionLanguageCode
    )
    let outputLanguageCode = normalizedLanguageCode(settings.outputLanguageCode)
    guard isValidLanguageCode(recognitionLanguageCode),
      isValidLanguageCode(outputLanguageCode)
    else {
      errorMessage = String(
        localized:
          "Use a valid BCP-47 language code, or leave the field empty for automatic."
      )
      return
    }

    isBusy = true
    defer { isBusy = false }
    settings.transcriptionModelID = transcriptionModelID
    settings.textProcessingModelID = textProcessingModelID
    settings.structuredTextModelID = structuredTextModelID
    settings.recognitionLanguageCode = recognitionLanguageCode
    settings.outputLanguageCode = outputLanguageCode

    do {
      try await settingsRepository.save(settings)
      await refreshLocalTranscriptionCapability()
    } catch {
      SecureLogger.error(.settingsSaveFailed)
      errorMessage = String(localized: "Settings could not be saved.")
    }
  }

  func refreshLocalTranscriptionCapability(
    duration: TimeInterval = 0
  ) async {
    guard let appleSpeechCapability else {
      localTranscriptionCapability = .unavailable(.providerNotConfigured)
      return
    }
    localTranscriptionCapability = await appleSpeechCapability.providerCapability(
      for: TranscriptionCapabilityRequest(
        duration: duration,
        languageCode: settings.recognitionLanguageCode
      )
    )
  }

  var isLocalTranscriptionAvailable: Bool {
    if case .available = localTranscriptionCapability {
      return true
    }
    return false
  }

  func saveAPIKey() async {
    let apiKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !apiKey.isEmpty else {
      errorMessage = String(localized: "Enter an API key before saving.")
      return
    }
    guard settings.hasAcknowledgedGroqCloudProcessing else {
      errorMessage =
        String(
          localized:
            "Acknowledge the Groq cloud-processing disclosure before saving the API key."
        )
      return
    }

    isBusy = true
    defer { isBusy = false }

    do {
      try await keychainService.saveAPIKey(apiKey)
      try await settingsRepository.save(settings)
      apiKeyDraft = ""
      hasStoredAPIKey = true
    } catch {
      SecureLogger.error(.keychainWriteFailed)
      errorMessage = String(localized: "The API key could not be saved to Keychain.")
    }
  }

  func deleteAPIKey() async {
    isBusy = true
    defer { isBusy = false }

    do {
      try await keychainService.deleteAPIKey()
      apiKeyDraft = ""
      hasStoredAPIKey = false
    } catch {
      SecureLogger.error(.keychainDeleteFailed)
      errorMessage = String(
        localized: "The API key could not be deleted from Keychain."
      )
    }
  }

  private func normalizedLanguageCode(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func isValidLanguageCode(_ value: String?) -> Bool {
    guard let value else { return true }
    guard value.utf8.count <= 35 else { return false }
    return value.unicodeScalars.allSatisfy {
      (65...90).contains($0.value)
        || (97...122).contains($0.value)
        || (48...57).contains($0.value)
        || $0.value == 45
    }
  }
}
