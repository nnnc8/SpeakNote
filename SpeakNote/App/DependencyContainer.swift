import Foundation
import SwiftData

@MainActor
final class DependencyContainer {
  let settingsRepository: any SettingsStoring
  let keychainService: any APIKeyStoring
  let permissionCenter: PermissionCenter
  let appCoordinator: AppCoordinator
  let onboardingCoordinator: OnboardingCoordinator
  let dictationCoordinator: DictationCoordinator
  let dictationHistoryCoordinator: DictationHistoryCoordinator
  let voiceNoteCoordinator: VoiceNoteCoordinator
  let vocabularyCoordinator: VocabularyCoordinator
  let voiceNoteRecordingWorkflow: any VoiceNoteRecordingRunning
  let settingsCoordinator: SettingsCoordinator

  init(
    settingsRepository: any SettingsStoring,
    keychainService: any APIKeyStoring,
    permissionCenter: PermissionCenter,
    appCoordinator: AppCoordinator,
    onboardingCoordinator: OnboardingCoordinator,
    dictationCoordinator: DictationCoordinator,
    dictationHistoryCoordinator: DictationHistoryCoordinator,
    voiceNoteCoordinator: VoiceNoteCoordinator,
    vocabularyCoordinator: VocabularyCoordinator,
    voiceNoteRecordingWorkflow: any VoiceNoteRecordingRunning,
    appleSpeechCapability: any TranscriptionProviderCapabilityChecking
  ) {
    self.settingsRepository = settingsRepository
    self.keychainService = keychainService
    self.permissionCenter = permissionCenter
    self.appCoordinator = appCoordinator
    self.onboardingCoordinator = onboardingCoordinator
    self.dictationCoordinator = dictationCoordinator
    self.dictationHistoryCoordinator = dictationHistoryCoordinator
    self.voiceNoteCoordinator = voiceNoteCoordinator
    self.vocabularyCoordinator = vocabularyCoordinator
    self.voiceNoteRecordingWorkflow = voiceNoteRecordingWorkflow
    settingsCoordinator = SettingsCoordinator(
      settingsRepository: settingsRepository,
      keychainService: keychainService,
      appleSpeechCapability: appleSpeechCapability
    )
  }

  static func live(
    settingsRepository: any SettingsStoring = SettingsRepository(),
    usesEphemeralStorage: Bool = false,
    storageRootURL: URL? = nil
  ) throws -> DependencyContainer {
    let keychainService = SystemKeychainService()
    let permissionCenter = PermissionCenter()
    let historyContainer: ModelContainer
    let sessionFileStore: SessionFileStore
    if usesEphemeralStorage {
      historyContainer = try SpeakNoteModelContainer.inMemory()
    } else {
      historyContainer = try SpeakNoteModelContainer.persistent()
    }
    let sessionRootURL: URL
    if let storageRootURL {
      sessionRootURL = storageRootURL
    } else if usesEphemeralStorage {
      sessionRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "SpeakNote-UITests-\(UUID().uuidString)",
          isDirectory: true
        )
    } else {
      let applicationSupport = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      sessionRootURL =
        applicationSupport
        .appendingPathComponent("SpeakNote", isDirectory: true)
    }
    try FileManager.default.createDirectory(
      at: sessionRootURL,
      withIntermediateDirectories: true
    )
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: sessionRootURL.path,
        isDirectory: &isDirectory
      ),
      isDirectory.boolValue,
      FileManager.default.isWritableFile(atPath: sessionRootURL.path)
    else {
      throw CocoaError(.fileWriteNoPermission)
    }
    sessionFileStore = try SessionFileStore(rootURL: sessionRootURL)
    let historyRepository = SwiftDataSessionRepository(
      modelContainer: historyContainer
    )
    let vocabularyRepository = SwiftDataVocabularyRepository(
      modelContainer: historyContainer
    )
    let vocabularyService = VocabularyService(
      repository: vocabularyRepository
    )
    let textProcessor = TextProcessingService(
      engine: KeychainBackedGroqTextProcessingEngine(
        keychainService: keychainService
      )
    )
    let groqTranscriptionEngine = KeychainBackedGroqTranscriptionEngine(
      keychainService: keychainService
    )
    let appleTranscriptionEngine = AppleTranscriptionEngine.live()
    let transcriptionRouter = TranscriptionProviderRouter(
      appleSpeechEngine: appleTranscriptionEngine,
      appleSpeechCapability: appleTranscriptionEngine,
      groqEngine: groqTranscriptionEngine,
      groqCapability: GroqTranscriptionCapability()
    )
    let dictationCoordinator = DictationCoordinator(
      recorder: AVAudioEngineRecorder(),
      transcriptionRouter: transcriptionRouter,
      textProcessor: textProcessor,
      historyRepository: historyRepository,
      settingsRepository: settingsRepository,
      inserter: TextInsertionService(),
      vocabularyProcessor: vocabularyService
    )
    let dictationHistoryCoordinator = DictationHistoryCoordinator(
      historyRepository: historyRepository,
      textProcessor: textProcessor,
      settingsRepository: settingsRepository
    )
    let voiceNotePipeline = VoiceNoteTranscriptionPipeline(
      repository: historyRepository,
      fileStore: sessionFileStore,
      transcriptionEngine: ProviderDispatchingTranscriptionEngine(
        appleSpeech: appleTranscriptionEngine,
        groq: groqTranscriptionEngine
      ),
      markdownRenderer: RawTranscriptMarkdownRenderer()
    )
    let voiceNoteWorkflow = VoiceNoteWorkflow(
      repository: historyRepository,
      settingsRepository: settingsRepository,
      fileStore: sessionFileStore,
      audioImporter: AVFoundationAudioImporter(fileStore: sessionFileStore),
      pipeline: voiceNotePipeline,
      appleSpeechCapability: appleTranscriptionEngine,
      vocabularyProcessor: vocabularyService
    )
    let structuredRunStore = VoiceNoteStructuredRunStore(
      fileStore: sessionFileStore,
      history: historyRepository
    )
    let voiceNoteRecoveryManager = VoiceNoteRecoveryManager(
      repository: historyRepository,
      fileStore: sessionFileStore,
      structuredRunReconciler: structuredRunStore
    )
    let voiceNoteRecordingWorkflow = VoiceNoteRecordingWorkflow(
      repository: historyRepository,
      fileStore: sessionFileStore,
      recorder: M4RollingSegmentRecorder(),
      archiveBuilder: M4AVFoundationAudioArchiveBuilder(),
      processingStarter: voiceNoteWorkflow,
      recoveryManager: voiceNoteRecoveryManager
    )
    let structuredNoteEngine = M5KeychainBackedGroqStructuredNoteEngine(
      keychainService: keychainService
    )
    let structuredProcessingWorkflow = VoiceNoteStructuredProcessingWorkflow(
      settingsRepository: settingsRepository,
      fileStore: sessionFileStore,
      processor: M5StructuredNoteProcessor(engine: structuredNoteEngine),
      runStore: structuredRunStore,
      vocabularyProcessor: vocabularyService
    )
    let voiceNoteCoordinator = VoiceNoteCoordinator(
      sessionRepository: historyRepository,
      settingsRepository: settingsRepository,
      workflow: voiceNoteWorkflow,
      filePicker: AppKitVoiceNoteFilePicker(),
      recordingWorkflow: voiceNoteRecordingWorkflow,
      recoveryManager: voiceNoteRecoveryManager,
      structuredWorkflow: structuredProcessingWorkflow,
      providerFallbackWorkflow: voiceNoteWorkflow
    )
    let appCoordinator = AppCoordinator(
      hotkeyMonitor: GlobalHotkeyMonitor(),
      dictationCoordinator: dictationCoordinator
    )
    let onboardingCoordinator = OnboardingCoordinator(
      settingsRepository: settingsRepository,
      permissionCenter: permissionCenter,
      refreshHotkey: { appCoordinator.refreshHotkey() }
    )
    let vocabularyCoordinator = VocabularyCoordinator(
      repository: vocabularyRepository,
      settingsRepository: settingsRepository
    )
    return DependencyContainer(
      settingsRepository: settingsRepository,
      keychainService: keychainService,
      permissionCenter: permissionCenter,
      appCoordinator: appCoordinator,
      onboardingCoordinator: onboardingCoordinator,
      dictationCoordinator: dictationCoordinator,
      dictationHistoryCoordinator: dictationHistoryCoordinator,
      voiceNoteCoordinator: voiceNoteCoordinator,
      vocabularyCoordinator: vocabularyCoordinator,
      voiceNoteRecordingWorkflow: voiceNoteRecordingWorkflow,
      appleSpeechCapability: appleTranscriptionEngine
    )
  }

  func start() {
    appCoordinator.start()
  }

  func prepareForTermination() async {
    await voiceNoteRecordingWorkflow.interrupt(reason: .systemInterruption)
    await appCoordinator.prepareForTermination()
  }

  func handleSystemSleep() async {
    await voiceNoteRecordingWorkflow.interrupt(reason: .appSuspended)
  }
}

private struct GroqTranscriptionCapability:
  TranscriptionProviderCapabilityChecking
{
  func providerCapability(
    for request: TranscriptionCapabilityRequest
  ) async -> ProviderTranscriptionCapability {
    guard request.duration.isFinite, request.duration >= 0 else {
      return .unavailable(.invalidDuration)
    }
    return .available
  }
}

private struct ProviderDispatchingTranscriptionEngine: TranscriptionEngine {
  let appleSpeech: any TranscriptionEngine
  let groq: any TranscriptionEngine

  func transcribe(
    audioURL: URL,
    configuration: TranscriptionConfiguration
  ) async throws -> Transcript {
    switch configuration.providerID {
    case .appleSpeech:
      try await appleSpeech.transcribe(
        audioURL: audioURL,
        configuration: configuration
      )
    case .groq:
      try await groq.transcribe(
        audioURL: audioURL,
        configuration: configuration
      )
    default:
      throw TranscriptionProviderRouterError.unsupportedProvider(
        configuration.providerID
      )
    }
  }
}
