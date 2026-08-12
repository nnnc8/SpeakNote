import XCTest

@testable import SpeakNote

@MainActor
final class SettingsCoordinatorTests: XCTestCase {
  func testLoadsSettingsAndKeyStatusFromFakes() async {
    let expected = AppSettings(
      transcriptionProviderID: .groq,
      transcriptionModelID: ProviderDefaults.transcriptionModelID
    )
    let settingsStore = FakeSettingsRepository(settings: expected)
    let keyStore = FakeAPIKeyStore(apiKey: "fixture-key")
    let capability = FakeProviderCapability(.available)
    let coordinator = SettingsCoordinator(
      settingsRepository: settingsStore,
      keychainService: keyStore,
      appleSpeechCapability: capability
    )

    await coordinator.load()

    XCTAssertEqual(coordinator.settings, expected)
    XCTAssertTrue(coordinator.hasStoredAPIKey)
    XCTAssertTrue(coordinator.apiKeyDraft.isEmpty)
    XCTAssertTrue(coordinator.isLocalTranscriptionAvailable)
    let requests = await capability.requests
    XCTAssertEqual(
      requests,
      [TranscriptionCapabilityRequest(duration: 0)]
    )
  }

  func testSavesTrimmedAPIKeyAndClearsDraft() async {
    let keyStore = FakeAPIKeyStore()
    let coordinator = SettingsCoordinator(
      settingsRepository: FakeSettingsRepository(),
      keychainService: keyStore
    )
    coordinator.settings.hasAcknowledgedGroqCloudProcessing = true
    coordinator.apiKeyDraft = "  test-key  "

    await coordinator.saveAPIKey()
    let storedKey = await keyStore.inspect()

    XCTAssertEqual(storedKey, "test-key")
    XCTAssertTrue(coordinator.apiKeyDraft.isEmpty)
    XCTAssertTrue(coordinator.hasStoredAPIKey)
  }

  func testEmptyAPIKeyIsRejectedWithoutWriting() async {
    let keyStore = FakeAPIKeyStore()
    let coordinator = SettingsCoordinator(
      settingsRepository: FakeSettingsRepository(),
      keychainService: keyStore
    )
    coordinator.apiKeyDraft = "   "

    await coordinator.saveAPIKey()
    let storedKey = await keyStore.inspect()

    XCTAssertNil(storedKey)
    XCTAssertEqual(
      coordinator.errorMessage,
      String(localized: "Enter an API key before saving.")
    )
  }

  func testCloudDisclosureIsRequiredBeforeSavingAPIKey() async {
    let keyStore = FakeAPIKeyStore()
    let settingsStore = FakeSettingsRepository()
    let coordinator = SettingsCoordinator(
      settingsRepository: settingsStore,
      keychainService: keyStore
    )
    coordinator.apiKeyDraft = "test-key"

    await coordinator.saveAPIKey()
    let storedKey = await keyStore.inspect()

    XCTAssertNil(storedKey)
    XCTAssertFalse(coordinator.hasStoredAPIKey)
    XCTAssertEqual(
      coordinator.errorMessage,
      String(
        localized:
          "Acknowledge the Groq cloud-processing disclosure before saving the API key."
      )
    )
  }

  func testStructuredModelIsTrimmedBeforeSaving() async {
    let settingsStore = FakeSettingsRepository()
    let coordinator = SettingsCoordinator(
      settingsRepository: settingsStore,
      keychainService: FakeAPIKeyStore()
    )
    coordinator.settings.structuredTextModelID =
      "  \(ProviderDefaults.structuredTextModelID)  "

    await coordinator.saveSettings()

    let saved = await settingsStore.inspect()
    XCTAssertEqual(saved.structuredTextModelID, ProviderDefaults.structuredTextModelID)
    XCTAssertNil(coordinator.errorMessage)
  }

  func testEmptyStructuredModelFallsBackToSupportedDefault() async {
    let settingsStore = FakeSettingsRepository()
    let coordinator = SettingsCoordinator(
      settingsRepository: settingsStore,
      keychainService: FakeAPIKeyStore()
    )
    coordinator.settings.structuredTextModelID = "  "

    await coordinator.saveSettings()

    let saved = await settingsStore.inspect()
    XCTAssertEqual(saved.structuredTextModelID, ProviderDefaults.structuredTextModelID)
    XCTAssertNil(coordinator.errorMessage)
  }

  func testLocalOnlyRejectsCloudTranscriptionProvider() async {
    let settingsStore = FakeSettingsRepository()
    let coordinator = SettingsCoordinator(
      settingsRepository: settingsStore,
      keychainService: FakeAPIKeyStore()
    )
    coordinator.settings.localOnly = true
    coordinator.settings.transcriptionProviderID = .groq

    await coordinator.saveSettings()

    let saved = await settingsStore.inspect()
    XCTAssertFalse(saved.localOnly)
    XCTAssertEqual(
      coordinator.errorMessage,
      String(
        localized:
          "Choose Apple Speech before enabling local-only transcription."
      )
    )
  }

  func testSurfacesUnavailableLocalTranscriptionCapability() async {
    let capability = FakeProviderCapability(
      .unavailable(.permissionDenied)
    )
    let coordinator = SettingsCoordinator(
      settingsRepository: FakeSettingsRepository(),
      keychainService: FakeAPIKeyStore(),
      appleSpeechCapability: capability
    )

    await coordinator.load()

    XCTAssertFalse(coordinator.isLocalTranscriptionAvailable)
    XCTAssertEqual(
      coordinator.localTranscriptionCapability,
      .unavailable(.permissionDenied)
    )
  }

  func testLoadsProviderPickersAndRepairsLegacyValues() async {
    let expected = AppSettings(
      transcriptionModelID: "removed-model",
      textProcessingModelID: "removed-text-model",
      structuredTextModelID: "removed-structured-model",
      recognitionLanguageCode: "zh-TW"
    )
    let settingsStore = FakeSettingsRepository(settings: expected)
    let coordinator = SettingsCoordinator(
      settingsRepository: settingsStore,
      keychainService: FakeAPIKeyStore()
    )

    await coordinator.load()

    XCTAssertEqual(
      coordinator.settings.transcriptionModelID,
      ProviderDefaults.transcriptionModelID
    )
    XCTAssertEqual(
      coordinator.settings.textProcessingModelID,
      ProviderDefaults.quickTextModelID
    )
    XCTAssertEqual(
      coordinator.settings.structuredTextModelID,
      ProviderDefaults.structuredTextModelID
    )
    XCTAssertEqual(coordinator.settings.recognitionLanguageCode, "zh-TW")
    XCTAssertTrue(coordinator.transcriptionModelOptions.contains {
      $0.id == ProviderDefaults.transcriptionModelID
    })
    XCTAssertTrue(coordinator.recognitionLanguageOptions.contains {
      $0.code == "zh-TW"
    })
    let saved = await settingsStore.inspect()
    XCTAssertEqual(saved.transcriptionModelID, ProviderDefaults.transcriptionModelID)
  }

  func testAppleProviderUsesInjectedLanguageOptions() async {
    let appleLanguage = ProviderLanguageOption(code: "fr-FR", title: "French (France)")
    let capability = FakeProviderCapability(
      .available,
      languageOptions: [appleLanguage]
    )
    let coordinator = SettingsCoordinator(
      settingsRepository: FakeSettingsRepository(
        settings: AppSettings(
          transcriptionProviderID: .appleSpeech,
          recognitionLanguageCode: "fr-FR"
        )
      ),
      keychainService: FakeAPIKeyStore(),
      appleSpeechCapability: capability
    )

    await coordinator.load()

    XCTAssertEqual(coordinator.recognitionLanguageOptions, [appleLanguage])
    XCTAssertEqual(coordinator.settings.recognitionLanguageCode, "fr-FR")
  }

  func testLoadTrimsSupportedModelValuesWithoutReplacingThem() async {
    let settingsStore = FakeSettingsRepository(
      settings: AppSettings(
        transcriptionModelID: "  whisper-large-v3  ",
        textProcessingModelID: "  openai/gpt-oss-120b  ",
        structuredTextModelID: "  llama-3.3-70b-versatile  "
      )
    )
    let coordinator = SettingsCoordinator(
      settingsRepository: settingsStore,
      keychainService: FakeAPIKeyStore()
    )

    await coordinator.load()

    XCTAssertEqual(
      coordinator.settings.transcriptionModelID,
      GroqTranscriptionModel.largeV3
    )
    XCTAssertEqual(
      coordinator.settings.textProcessingModelID,
      ProviderDefaults.structuredTextModelID
    )
    XCTAssertEqual(
      coordinator.settings.structuredTextModelID,
      ProviderDefaults.jsonObjectTextModelID
    )
  }

  func testSaveRepairsUnsupportedModelAndLanguage() async {
    let settingsStore = FakeSettingsRepository()
    let coordinator = SettingsCoordinator(
      settingsRepository: settingsStore,
      keychainService: FakeAPIKeyStore()
    )
    coordinator.settings.transcriptionModelID = "free-form-model"
    coordinator.settings.recognitionLanguageCode = "xx-XX"

    await coordinator.saveSettings()

    XCTAssertNil(coordinator.errorMessage)
    let saved = await settingsStore.inspect()
    XCTAssertEqual(saved.transcriptionModelID, ProviderDefaults.transcriptionModelID)
    XCTAssertNil(saved.recognitionLanguageCode)
  }
}

private actor FakeProviderCapability:
  TranscriptionProviderCapabilityChecking
{
  let result: ProviderTranscriptionCapability
  let languageOptions: [ProviderLanguageOption]
  private(set) var requests: [TranscriptionCapabilityRequest] = []

  init(
    _ result: ProviderTranscriptionCapability,
    languageOptions: [ProviderLanguageOption] = ProviderLanguageCatalog.groq
  ) {
    self.result = result
    self.languageOptions = languageOptions
  }

  func providerCapability(
    for request: TranscriptionCapabilityRequest
  ) -> ProviderTranscriptionCapability {
    requests.append(request)
    return result
  }

  func supportedLanguageOptions() -> [ProviderLanguageOption] {
    languageOptions
  }
}
