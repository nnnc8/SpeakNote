import Combine
import Foundation

@MainActor
final class SettingsCoordinator: ObservableObject {
  @Published var settings: AppSettings
  @Published var apiKeyDraft = ""
  @Published private(set) var hasStoredAPIKey = false
  @Published private(set) var localTranscriptionCapability: ProviderTranscriptionCapability =
    .unavailable(.providerNotConfigured)
  @Published private(set) var breezeModelState: BreezeModelState = .notDownloaded
  @Published private(set) var recognitionLanguageOptions = ProviderLanguageCatalog.groq
  @Published private(set) var outputLanguageOptions = ProviderLanguageCatalog.groq
  @Published private(set) var transcriptionModelOptions =
    GroqTranscriptionModelCatalog.options
  @Published private(set) var textProcessingModelOptions = GroqTextModelCatalog.options
  @Published private(set) var structuredTextModelOptions = GroqTextModelCatalog.options
  @Published private(set) var isBusy = false
  @Published var errorMessage: String?

  private let settingsRepository: any SettingsStoring
  private let keychainService: any APIKeyStoring
  private let appleSpeechCapability: (any TranscriptionProviderCapabilityChecking)?
  private let breezeCapability: (any TranscriptionProviderCapabilityChecking)?
  private let breezeModelManager: (any BreezeModelManaging)?
  private var breezeDownloadProgressTask: Task<Void, Never>?

  init(
    settingsRepository: any SettingsStoring,
    keychainService: any APIKeyStoring,
    appleSpeechCapability:
      (any TranscriptionProviderCapabilityChecking)? = nil,
    breezeCapability: (any TranscriptionProviderCapabilityChecking)? = nil,
    breezeModelManager: (any BreezeModelManaging)? = nil
  ) {
    self.settingsRepository = settingsRepository
    self.keychainService = keychainService
    self.appleSpeechCapability = appleSpeechCapability
    self.breezeCapability = breezeCapability
    self.breezeModelManager = breezeModelManager
    settings = .defaultValue
  }

  func load() async {
    isBusy = true
    defer { isBusy = false }

    do {
      settings = try await settingsRepository.load()
      let changed = await refreshProviderOptions()
      if changed {
        try await settingsRepository.save(settings)
      }
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
    await refreshBreezeModelState()
  }

  func saveSettings() async {
    _ = await refreshProviderOptions()
    let transcriptionModelID = settings.transcriptionModelID
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let textProcessingModelID = settings.textProcessingModelID
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let structuredTextModelID = settings.structuredTextModelID
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard isSupportedTranscriptionModel(transcriptionModelID) else {
      errorMessage = String(localized: "Choose a supported transcription model.")
      return
    }
    guard GroqTextModelCatalog.candidates.contains(textProcessingModelID) else {
      errorMessage = String(localized: "Choose a supported text-processing model.")
      return
    }
    guard GroqTextModelCatalog.candidates.contains(structuredTextModelID) else {
      errorMessage = String(localized: "Choose a supported structured-note model.")
      return
    }
    guard
      !settings.localOnly || settings.transcriptionProviderID.isLocalTranscriptionProvider
    else {
      errorMessage = String(localized: "Choose a local transcription provider before enabling local-only transcription.")
      return
    }
    let recognitionLanguageCode = normalizedLanguageCode(
      settings.recognitionLanguageCode
    )
    let outputLanguageCode = normalizedLanguageCode(settings.outputLanguageCode)
    guard isSupportedLanguageCode(
      recognitionLanguageCode,
      in: recognitionLanguageOptions
    ),
      isSupportedLanguageCode(outputLanguageCode, in: outputLanguageOptions)
    else {
      errorMessage = String(
        localized:
          "Choose a supported language, or choose Automatic."
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
    let candidates: [(ProviderID, any TranscriptionProviderCapabilityChecking)]
    switch settings.transcriptionProviderID {
    case .appleSpeech:
      candidates = appleSpeechCapability.map { [(.appleSpeech, $0)] } ?? []
    case .breezeASR:
      candidates = breezeCapability.map { [(.breezeASR, $0)] } ?? []
    default:
      candidates = [
        appleSpeechCapability.map { (.appleSpeech, $0) },
        breezeCapability.map { (.breezeASR, $0) },
      ].compactMap { $0 }
    }
    guard !candidates.isEmpty else {
      localTranscriptionCapability = .unavailable(.providerNotConfigured)
      return
    }
    var firstUnavailable: ProviderTranscriptionCapability?
    for (_, capability) in candidates {
      let result = await capability.providerCapability(
        for: TranscriptionCapabilityRequest(
          duration: duration,
          languageCode: settings.recognitionLanguageCode
        )
      )
      if case .available = result {
        localTranscriptionCapability = result
        return
      }
      firstUnavailable = firstUnavailable ?? result
    }
    localTranscriptionCapability = firstUnavailable ?? .unavailable(.providerNotConfigured)
  }

  @discardableResult
  func refreshProviderOptions() async -> Bool {
    if settings.transcriptionProviderID == .appleSpeech,
      let appleSpeechCapability
    {
      let options = await appleSpeechCapability.supportedLanguageOptions()
      recognitionLanguageOptions = options.isEmpty
        ? ProviderLanguageCatalog.groq
        : options
    } else if settings.transcriptionProviderID == .breezeASR {
      recognitionLanguageOptions = ProviderLanguageCatalog.breeze
    } else {
      recognitionLanguageOptions = ProviderLanguageCatalog.groq
    }
    outputLanguageOptions = ProviderLanguageCatalog.groq
    transcriptionModelOptions = settings.transcriptionProviderID == .breezeASR
      ? BreezeTranscriptionModelCatalog.options
      : GroqTranscriptionModelCatalog.options
    return normalizeConfiguredValues()
  }

  func refreshBreezeModelState() async {
    guard let breezeModelManager else {
      breezeModelState = .notDownloaded
      return
    }
    breezeModelState = await breezeModelManager.state(
      for: BreezeTranscriptionModel.defaultID
    )
  }

  func downloadBreezeModel() async {
    guard let breezeModelManager else { return }
    isBusy = true
    breezeModelState = .downloading(progress: 0)
    breezeDownloadProgressTask?.cancel()
    breezeDownloadProgressTask = Task { [weak self, breezeModelManager] in
      while !Task.isCancelled {
        guard let self else { return }
        self.breezeModelState = await breezeModelManager.state(
          for: BreezeTranscriptionModel.defaultID
        )
        do {
          try await Task.sleep(nanoseconds: 250_000_000)
        } catch {
          return
        }
      }
    }
    defer {
      breezeDownloadProgressTask?.cancel()
      breezeDownloadProgressTask = nil
      isBusy = false
    }
    do {
      try await breezeModelManager.download(modelID: BreezeTranscriptionModel.defaultID)
      await refreshBreezeModelState()
      await refreshLocalTranscriptionCapability()
    } catch let error as LocalizedError {
      breezeModelState = .failed(
        error as? BreezeModelStoreError ?? .downloadFailed
      )
      errorMessage = error.errorDescription
    } catch {
      breezeModelState = .failed(.downloadFailed)
      errorMessage = String(localized: "The Breeze model download failed.")
    }
  }

  func cancelBreezeModelDownload() async {
    await breezeModelManager?.cancelDownload()
    await refreshBreezeModelState()
  }

  func deleteBreezeModel() async {
    guard let breezeModelManager else { return }
    do {
      try await breezeModelManager.delete(modelID: BreezeTranscriptionModel.defaultID)
      await refreshBreezeModelState()
      await refreshLocalTranscriptionCapability()
    } catch {
      errorMessage = String(localized: "The Breeze model could not be deleted.")
    }
  }

  func setLocalOnly(_ enabled: Bool) {
    settings.localOnly = enabled
    guard enabled, !settings.transcriptionProviderID.isLocalTranscriptionProvider else {
      return
    }
    settings.transcriptionProviderID = .appleSpeech
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
      .replacingOccurrences(of: "_", with: "-")
    return trimmed.isEmpty ? nil : trimmed
  }

  private func isSupportedLanguageCode(
    _ value: String?,
    in options: [ProviderLanguageOption]
  ) -> Bool {
    guard let value else { return true }
    return options.contains { $0.code == value }
  }

  private func normalizeConfiguredValues() -> Bool {
    var changed = false
    let transcriptionModelID = settings.transcriptionModelID
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if transcriptionModelID != settings.transcriptionModelID {
      settings.transcriptionModelID = transcriptionModelID
      changed = true
    }
    if !isSupportedTranscriptionModel(transcriptionModelID) {
      settings.transcriptionModelID = settings.transcriptionProviderID == .breezeASR
        ? BreezeTranscriptionModel.defaultID
        : ProviderDefaults.transcriptionModelID
      changed = true
    }
    let textProcessingModelID = settings.textProcessingModelID
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if textProcessingModelID != settings.textProcessingModelID {
      settings.textProcessingModelID = textProcessingModelID
      changed = true
    }
    if !GroqTextModelCatalog.candidates.contains(textProcessingModelID) {
      settings.textProcessingModelID = ProviderDefaults.quickTextModelID
      changed = true
    }
    let structuredTextModelID = settings.structuredTextModelID
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if structuredTextModelID != settings.structuredTextModelID {
      settings.structuredTextModelID = structuredTextModelID
      changed = true
    }
    if !GroqTextModelCatalog.candidates.contains(structuredTextModelID) {
      settings.structuredTextModelID = ProviderDefaults.structuredTextModelID
      changed = true
    }
    let recognition = normalizedLanguageCode(settings.recognitionLanguageCode)
    if recognition != settings.recognitionLanguageCode {
      settings.recognitionLanguageCode = recognition
      changed = true
    }
    let output = normalizedLanguageCode(settings.outputLanguageCode)
    if output != settings.outputLanguageCode {
      settings.outputLanguageCode = output
      changed = true
    }
    if !isSupportedLanguageCode(recognition, in: recognitionLanguageOptions) {
      settings.recognitionLanguageCode = nil
      changed = true
    }
    if !isSupportedLanguageCode(output, in: outputLanguageOptions) {
      settings.outputLanguageCode = nil
      changed = true
    }
    return changed
  }

  private func isSupportedTranscriptionModel(_ modelID: String) -> Bool {
    switch settings.transcriptionProviderID {
    case .breezeASR:
      BreezeTranscriptionModel.supported.contains(modelID)
    case .groq, .appleSpeech:
      GroqTranscriptionModel.supported.contains(modelID)
    default:
      false
    }
  }
}
