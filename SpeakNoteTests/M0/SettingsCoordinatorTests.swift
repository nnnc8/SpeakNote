import XCTest

@testable import SpeakNote

@MainActor
final class SettingsCoordinatorTests: XCTestCase {
  func testLoadsSettingsAndKeyStatusFromFakes() async {
    let expected = AppSettings(
      transcriptionProviderID: .groq,
      transcriptionModelID: "fixture-model"
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
    coordinator.settings.structuredTextModelID = "  structured-model  "

    await coordinator.saveSettings()

    let saved = await settingsStore.inspect()
    XCTAssertEqual(saved.structuredTextModelID, "structured-model")
    XCTAssertNil(coordinator.errorMessage)
  }

  func testEmptyStructuredModelIsRejected() async {
    let settingsStore = FakeSettingsRepository()
    let coordinator = SettingsCoordinator(
      settingsRepository: settingsStore,
      keychainService: FakeAPIKeyStore()
    )
    coordinator.settings.structuredTextModelID = "  "

    await coordinator.saveSettings()

    let saved = await settingsStore.inspect()
    XCTAssertEqual(saved.structuredTextModelID, ProviderDefaults.structuredTextModelID)
    XCTAssertEqual(
      coordinator.errorMessage,
      String(localized: "The structured-note model cannot be empty.")
    )
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
}

private actor FakeProviderCapability:
  TranscriptionProviderCapabilityChecking
{
  let result: ProviderTranscriptionCapability
  private(set) var requests: [TranscriptionCapabilityRequest] = []

  init(_ result: ProviderTranscriptionCapability) {
    self.result = result
  }

  func providerCapability(
    for request: TranscriptionCapabilityRequest
  ) -> ProviderTranscriptionCapability {
    requests.append(request)
    return result
  }
}
