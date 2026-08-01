import Foundation
import Observation

enum DictationState: Equatable, Sendable {
  case idle
  case preparing
  case recording(startedAt: Date)
  case stopping
  case transcribing
  case processing
  case inserting
  case cancelling
  case success(text: String)
  case failure(message: String)
  case cancelled
}

enum DictationEvent: Equatable, Sendable {
  case startRequested
  case recorderStarted(Date)
  case stopRequested
  case recorderStopped
  case transcriptReady(String)
  case processedTextReady(String)
  case insertionCompleted(String)
  case manualCopyCompleted(String)
  case cancellationRequested
  case failed(String)
  case cancelled
}

enum DictationStateReducer {
  static func reduce(_ state: DictationState, _ event: DictationEvent) -> DictationState {
    switch (state, event) {
    case (.idle, .startRequested),
      (.success, .startRequested),
      (.failure, .startRequested),
      (.cancelled, .startRequested):
      .preparing
    case (.preparing, .recorderStarted(let date)):
      .recording(startedAt: date)
    case (.recording, .stopRequested):
      .stopping
    case (.stopping, .recorderStopped):
      .transcribing
    case (.transcribing, .transcriptReady(let text)):
      text.isEmpty
        ? .failure(message: String(localized: "Transcription returned no text."))
        : .processing
    case (.processing, .processedTextReady(let text)):
      text.isEmpty
        ? .failure(message: String(localized: "Text processing returned no text."))
        : .inserting
    case (.inserting, .insertionCompleted(let text)):
      .success(text: text)
    case (.failure, .manualCopyCompleted(let text)):
      .success(text: text)
    case (
      .preparing, .cancellationRequested
    ),
      (
        .recording, .cancellationRequested
      ),
      (
        .stopping, .cancellationRequested
      ),
      (
        .transcribing, .cancellationRequested
      ),
      (
        .processing, .cancellationRequested
      ),
      (
        .inserting, .cancellationRequested
      ):
      .cancelling
    case (.idle, .failed):
      state
    case (_, .failed(let message)):
      .failure(message: message)
    case (.idle, .cancelled):
      .idle
    case (_, .cancelled):
      .cancelled
    default:
      state
    }
  }
}

@MainActor
@Observable
final class DictationCoordinator {
  private(set) var state: DictationState = .idle
  private(set) var manualCopyText: String?
  private(set) var fallbackOffer: TranscriptionFallbackOffer?

  @ObservationIgnored private let recorder: any AudioRecorder
  @ObservationIgnored private let transcriptionRouter: any TranscriptionProviderRouting
  @ObservationIgnored private let vocabularyProcessor: (any VocabularyProcessing)?
  @ObservationIgnored private let textProcessor: any TextProcessingEngine
  @ObservationIgnored private let historyRepository: any DictationHistoryStoring
  @ObservationIgnored private let settingsRepository: any SettingsStoring
  @ObservationIgnored private let inserter: any TextInserting
  @ObservationIgnored private let manualTextCopier: any ManualTextCopying
  @ObservationIgnored private let hud: any DictationHUDPresenting
  @ObservationIgnored private let maximumDuration: TimeInterval
  @ObservationIgnored private var insertionTarget: InsertionTarget?
  @ObservationIgnored private var operation: Task<Void, Never>?
  @ObservationIgnored private var durationTask: Task<Void, Never>?
  @ObservationIgnored private var hideTask: Task<Void, Never>?
  @ObservationIgnored private var activeHistoryRecordID: UUID?
  @ObservationIgnored private var pendingFallbackSettings: AppSettings?
  @ObservationIgnored private var pendingAudioURL: URL?
  @ObservationIgnored private var isManualCopyOnly = false

  convenience init(
    recorder: any AudioRecorder,
    transcriber: any TranscriptionEngine,
    textProcessor: any TextProcessingEngine,
    historyRepository: any DictationHistoryStoring,
    settingsRepository: any SettingsStoring,
    inserter: any TextInserting,
    vocabularyProcessor: (any VocabularyProcessing)? = nil,
    manualTextCopier: any ManualTextCopying = SystemManualTextCopier(),
    hud: any DictationHUDPresenting = DictationHUD(),
    // Stop through the normal pipeline before the recorder's five-minute fail-safe.
    maximumDuration: TimeInterval =
      AVAudioEngineRecorder.hardMaximumDuration - 1
  ) {
    self.init(
      recorder: recorder,
      transcriptionRouter: DirectTranscriptionRouter(engine: transcriber),
      textProcessor: textProcessor,
      historyRepository: historyRepository,
      settingsRepository: settingsRepository,
      inserter: inserter,
      vocabularyProcessor: vocabularyProcessor,
      manualTextCopier: manualTextCopier,
      hud: hud,
      maximumDuration: maximumDuration
    )
  }

  init(
    recorder: any AudioRecorder,
    transcriptionRouter: any TranscriptionProviderRouting,
    textProcessor: any TextProcessingEngine,
    historyRepository: any DictationHistoryStoring,
    settingsRepository: any SettingsStoring,
    inserter: any TextInserting,
    vocabularyProcessor: (any VocabularyProcessing)? = nil,
    manualTextCopier: any ManualTextCopying = SystemManualTextCopier(),
    hud: any DictationHUDPresenting = DictationHUD(),
    maximumDuration: TimeInterval =
      AVAudioEngineRecorder.hardMaximumDuration - 1
  ) {
    self.recorder = recorder
    self.transcriptionRouter = transcriptionRouter
    self.vocabularyProcessor = vocabularyProcessor
    self.textProcessor = textProcessor
    self.historyRepository = historyRepository
    self.settingsRepository = settingsRepository
    self.inserter = inserter
    self.manualTextCopier = manualTextCopier
    self.hud = hud
    self.maximumDuration = min(
      max(maximumDuration, 0.010),
      AVAudioEngineRecorder.hardMaximumDuration
    )
  }

  func handle(_ action: HotkeyAction) {
    switch action {
    case .toggleDictation:
      toggle()
    case .cancel:
      cancel()
    }
  }

  func toggle() {
    toggle(manualCopyOnly: false)
  }

  func toggleForManualCopy() {
    toggle(manualCopyOnly: true)
  }

  private func toggle(manualCopyOnly: Bool) {
    switch state {
    case .idle, .success, .failure, .cancelled:
      beginRecording(manualCopyOnly: manualCopyOnly)
    case .recording:
      finishRecording()
    case .preparing, .stopping, .transcribing, .processing, .inserting, .cancelling:
      break
    }
  }

  func cancel() {
    switch state {
    case .preparing, .recording, .stopping, .transcribing, .processing, .inserting:
      break
    case .idle, .cancelling, .success, .failure, .cancelled:
      return
    }
    let previousOperation = operation
    transition(.cancellationRequested)
    previousOperation?.cancel()
    durationTask?.cancel()
    durationTask = nil
    hideTask?.cancel()
    insertionTarget = nil
    manualCopyText = nil
    fallbackOffer = nil
    pendingFallbackSettings = nil
    isManualCopyOnly = false
    let fallbackAudioURL = pendingAudioURL
    pendingAudioURL = nil
    let recorder = self.recorder
    operation = Task { [weak self, recorder] in
      await recorder.cancel()
      await previousOperation?.value
      if let fallbackAudioURL {
        try? FileManager.default.removeItem(at: fallbackAudioURL)
      }
      guard let self else { return }
      await markActiveRecordCancelled()
      operation = nil
      transition(.cancelled)
      hud.showCancelled()
      scheduleHUDHide()
    }
  }

  func shutdown() async {
    let activeOperation = operation
    if isActive {
      transition(.cancellationRequested)
    }
    activeOperation?.cancel()
    durationTask?.cancel()
    durationTask = nil
    hideTask?.cancel()
    hideTask = nil
    insertionTarget = nil
    manualCopyText = nil
    fallbackOffer = nil
    pendingFallbackSettings = nil
    isManualCopyOnly = false
    let fallbackAudioURL = pendingAudioURL
    pendingAudioURL = nil
    await recorder.cancel()
    await activeOperation?.value
    if let fallbackAudioURL {
      try? FileManager.default.removeItem(at: fallbackAudioURL)
    }
    await markActiveRecordCancelled()
    operation = nil
    hud.hide()
    transition(.cancelled)
  }

  private func beginRecording(manualCopyOnly: Bool) {
    hideTask?.cancel()
    manualCopyText = nil
    fallbackOffer = nil
    pendingFallbackSettings = nil
    isManualCopyOnly = manualCopyOnly
    if let pendingAudioURL {
      try? FileManager.default.removeItem(at: pendingAudioURL)
      self.pendingAudioURL = nil
    }
    activeHistoryRecordID = nil
    transition(.startRequested)
    hud.showPreparing()

    if manualCopyOnly {
      insertionTarget = nil
    } else {
      do {
        insertionTarget = try inserter.captureTarget()
      } catch {
        fail(error)
        return
      }
    }

    operation = Task { [weak self] in
      guard let self else { return }
      do {
        let settings = try await settingsRepository.load()
        if Self.requiresGroqDisclosure(settings),
          !settings.hasAcknowledgedGroqCloudProcessing
        {
          throw DictationCoordinatorError.cloudDisclosureRequired
        }
        try await recorder.start()
        try Task.checkCancellation()
        let startedAt = Date()
        transition(.recorderStarted(startedAt))
        hud.showRecording(startedAt: startedAt)
        scheduleMaximumDuration()
      } catch is CancellationError {
        await recorder.cancel()
        completeCancellationIfNeeded()
      } catch {
        await recorder.cancel()
        guard !isCancellingOrCancelled else { return }
        fail(error)
      }
    }
  }

  private func finishRecording() {
    guard case .recording(let startedAt) = state else { return }
    let recordedDuration = max(0, Date().timeIntervalSince(startedAt))
    transition(.stopRequested)
    durationTask?.cancel()
    durationTask = nil
    hud.showTranscribing()

    operation = Task { [weak self] in
      guard let self else { return }
      var temporaryAudioURL: URL?
      var recognizedText: String?
      defer {
        if let temporaryAudioURL {
          try? FileManager.default.removeItem(at: temporaryAudioURL)
        }
      }

      do {
        temporaryAudioURL = try await recorder.stop()
        try Task.checkCancellation()
        transition(.recorderStopped)
        hud.showTranscribing()

        let settings = try await settingsRepository.load()
        let configuration = TranscriptionConfiguration(
          providerID: settings.transcriptionProviderID,
          modelID: settings.transcriptionModelID,
          languageCode: settings.recognitionLanguageCode,
          prompt: try await vocabularyProcessor?.promptFragment(
            profileID: settings.activeProfileID
          )
        )
        let outcome = try await transcriptionRouter.transcribe(
          TranscriptionRoutingRequest(
            audioURL: temporaryAudioURL!,
            duration: recordedDuration,
            configuration: configuration,
            fallbackProviderID: Self.fallbackProvider(
              for: settings.transcriptionProviderID
            ),
            fallbackPolicy: settings.transcriptionFallbackPolicy,
            localOnly: settings.localOnly
          )
        )
        switch outcome {
        case .completed(_, let transcript):
          recognizedText = transcript.text
          try await completeDictation(transcript, settings: settings)
        case .fallbackOffered(let offer):
          fallbackOffer = offer
          pendingFallbackSettings = settings
          pendingAudioURL = offer.audioURL
          temporaryAudioURL = nil
          hud.showFailure(Self.fallbackOfferMessage(offer))
        case .fallbackDeclined:
          throw DictationCoordinatorError.fallbackDeclined
        }
      } catch is CancellationError {
        await recorder.cancel()
        completeCancellationIfNeeded()
      } catch {
        guard !isCancellingOrCancelled else { return }
        if let recognizedText, !recognizedText.isEmpty {
          requireManualCopy(
            recognizedText,
            message: String(
              localized: "Automatic insertion could not be confirmed safely."
            )
          )
        } else {
          fail(error)
        }
      }
    }
  }

  func acceptTranscriptionFallback() {
    guard
      let offer = fallbackOffer,
      let settings = pendingFallbackSettings,
      let audioURL = pendingAudioURL
    else {
      return
    }
    fallbackOffer = nil
    pendingFallbackSettings = nil
    hud.showTranscribing()

    operation = Task { [weak self] in
      guard let self else { return }
      var recognizedText: String?
      defer {
        if pendingAudioURL == audioURL {
          pendingAudioURL = nil
        }
        try? FileManager.default.removeItem(at: audioURL)
      }
      do {
        let outcome = try await transcriptionRouter.accept(offer)
        guard case .completed(_, let transcript) = outcome else {
          throw TranscriptionProviderRouterError.invalidFallbackOffer
        }
        recognizedText = transcript.text
        try await completeDictation(transcript, settings: settings)
      } catch is CancellationError {
        await recorder.cancel()
        completeCancellationIfNeeded()
      } catch {
        guard !isCancellingOrCancelled else { return }
        if let recognizedText, !recognizedText.isEmpty {
          requireManualCopy(
            recognizedText,
            message: String(
              localized: "Automatic insertion could not be confirmed safely."
            )
          )
        } else {
          fail(error)
        }
      }
    }
  }

  func declineTranscriptionFallback() {
    guard let offer = fallbackOffer else { return }
    let audioURL = pendingAudioURL
    fallbackOffer = nil
    pendingFallbackSettings = nil
    pendingAudioURL = nil
    Task { [transcriptionRouter] in
      _ = await transcriptionRouter.decline(offer)
    }
    if let audioURL {
      try? FileManager.default.removeItem(at: audioURL)
    }
    fail(DictationCoordinatorError.fallbackDeclined)
  }

  var fallbackOfferDescription: String? {
    fallbackOffer.map(Self.fallbackOfferMessage)
  }

  private func completeDictation(
    _ transcript: Transcript,
    settings: AppSettings
  ) async throws {
    let rawText = transcript.text
    try Task.checkCancellation()
    guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DictationCoordinatorError.emptyTranscript
    }
    if settings.dictationHistoryEnabled {
      let record = try await historyRepository.createRecord(
        NewDictationRecord(
          id: transcript.id,
          rawTranscript: rawText,
          detectedLanguage: transcript.detectedLanguage
        )
      )
      activeHistoryRecordID = record.id
    }

    let processingTranscript: Transcript
    if let vocabularyProcessor {
      processingTranscript = try await vocabularyProcessor.apply(
        to: transcript,
        profileID: settings.activeProfileID,
        recordHistory: settings.dictationHistoryEnabled
      ).transcript
    } else {
      processingTranscript = transcript
    }
    let preparedText = processingTranscript.text

    transition(.transcriptReady(preparedText))
    guard case .processing = state else {
      throw DictationCoordinatorError.emptyTranscript
    }
    hud.showProcessing()

    let processingConfiguration = TextProcessingConfiguration(
      providerID: settings.textProcessingProviderID,
      modelID: settings.textProcessingModelID,
      compressionLevel: settings.compressionLevel,
      recognitionLanguageCode: settings.recognitionLanguageCode,
      outputLanguageCode: settings.outputLanguageCode
    )
    let shouldPersistRun =
      settings.dictationHistoryEnabled
      && TextProcessingPolicy.route(for: processingConfiguration) == .engine
    var finalText = preparedText
    do {
      let processed = try await textProcessor.process(
        transcript: processingTranscript,
        configuration: processingConfiguration
      )
      guard !processed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw DictationCoordinatorError.emptyProcessedText
      }
      finalText = processed.text
      if shouldPersistRun, let activeHistoryRecordID {
        _ = try await historyRepository.appendRun(
          NewProcessingRun(
            ownerID: activeHistoryRecordID,
            providerID: processingConfiguration.providerID.rawValue,
            modelID: processingConfiguration.modelID,
            configurationHash: try ProcessingConfigurationHash.make(
              processingConfiguration
            ),
            outputText: processed.text,
            status: .succeeded
          )
        )
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      finalText = preparedText
      if shouldPersistRun, let activeHistoryRecordID {
        _ = try await historyRepository.appendRun(
          NewProcessingRun(
            ownerID: activeHistoryRecordID,
            providerID: processingConfiguration.providerID.rawValue,
            modelID: processingConfiguration.modelID,
            configurationHash: try ProcessingConfigurationHash.make(
              processingConfiguration
            ),
            outputText: nil,
            status: .failed,
            errorCategory: Self.processingErrorCategory(error)
          )
        )
      }
    }

    try Task.checkCancellation()
    transition(.processedTextReady(finalText))
    guard case .inserting = state else {
      throw DictationCoordinatorError.emptyProcessedText
    }
    hud.showInserting()

    if isManualCopyOnly {
      requireManualCopy(
        finalText,
        message: String(
          localized:
            "Dictation started from SpeakNote, so automatic paste is unavailable."
        )
      )
      return
    }
    guard let insertionTarget else {
      throw DictationCoordinatorError.missingInsertionTarget
    }
    let insertionResult = try await inserter.insert(finalText, into: insertionTarget)
    try Task.checkCancellation()
    switch insertionResult {
    case .inserted:
      transition(.insertionCompleted(finalText))
      self.insertionTarget = nil
      activeHistoryRecordID = nil
      hud.showSuccess()
      scheduleHUDHide()
    case .manualCopyRequired(let reason):
      activeHistoryRecordID = nil
      requireManualCopy(finalText, reason: reason)
    }
  }

  private func scheduleMaximumDuration() {
    let nanoseconds = UInt64(maximumDuration * 1_000_000_000)
    durationTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: nanoseconds)
      guard !Task.isCancelled, let self, case .recording = state else { return }
      finishRecording()
    }
  }

  @discardableResult
  func copyManualTranscript() -> Bool {
    guard let text = manualCopyText else { return false }
    guard manualTextCopier.copy(text) else {
      let message = String(localized: "The transcript could not be copied.")
      transition(.failed(message))
      hud.showFailure(message)
      scheduleHUDHide(after: 4)
      return false
    }
    manualCopyText = nil
    transition(.manualCopyCompleted(text))
    hud.showSuccess()
    scheduleHUDHide()
    return true
  }

  private func scheduleHUDHide(after delay: TimeInterval = 1.2) {
    hideTask?.cancel()
    hideTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.hud.hide()
    }
  }

  private func requireManualCopy(
    _ text: String,
    reason: TextInsertionFallbackReason
  ) {
    let baseMessage =
      DictationCoordinatorError.manualCopyRequired(reason)
      .errorDescription ?? String(localized: "Automatic paste is unavailable.")
    requireManualCopy(text, message: baseMessage)
  }

  private func requireManualCopy(
    _ text: String,
    message: String
  ) {
    insertionTarget = nil
    activeHistoryRecordID = nil
    isManualCopyOnly = false
    manualCopyText = text
    let instruction = String(
      localized: "\(message) Use “Copy Last Transcript” in SpeakNote."
    )
    transition(.failed(instruction))
    hud.showFailure(instruction)
    scheduleHUDHide(after: 4)
  }

  private func fail(_ error: Error) {
    durationTask?.cancel()
    durationTask = nil
    insertionTarget = nil
    isManualCopyOnly = false
    manualCopyText = nil
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    transition(.failed(message))
    hud.showFailure(message)
    scheduleHUDHide()
  }

  private func completeCancellationIfNeeded() {
    guard !isCancellingOrCancelled else { return }
    transition(.cancelled)
    hud.showCancelled()
    scheduleHUDHide()
  }

  private func markActiveRecordCancelled() async {
    guard let activeHistoryRecordID else { return }
    _ = try? await historyRepository.updateRecordStatus(
      id: activeHistoryRecordID,
      status: .cancelled
    )
    self.activeHistoryRecordID = nil
  }

  private static func processingErrorCategory(_ error: Error) -> String {
    if error is URLError { return "network" }
    return "provider"
  }

  private static func requiresGroqDisclosure(_ settings: AppSettings) -> Bool {
    if settings.transcriptionProviderID == .groq {
      return true
    }
    let processingConfiguration = TextProcessingConfiguration(
      providerID: settings.textProcessingProviderID,
      modelID: settings.textProcessingModelID,
      compressionLevel: settings.compressionLevel,
      recognitionLanguageCode: settings.recognitionLanguageCode,
      outputLanguageCode: settings.outputLanguageCode
    )
    return processingConfiguration.providerID == .groq
      && TextProcessingPolicy.route(for: processingConfiguration) == .engine
  }

  private static func fallbackProvider(for providerID: ProviderID) -> ProviderID? {
    switch providerID {
    case .groq:
      .appleSpeech
    case .appleSpeech:
      .groq
    default:
      nil
    }
  }

  private static func fallbackOfferMessage(
    _ offer: TranscriptionFallbackOffer
  ) -> String {
    let destination =
      offer.destinationProviderID == .appleSpeech
      ? String(localized: "Apple Speech") : String(localized: "Groq Cloud")
    let privacy =
      offer.destinationPrivacyClass == .cloud
      ? String(localized: "Audio will leave this Mac.")
      : String(localized: "Audio stays on this Mac.")
    return String(
      localized:
        "The selected transcription provider is unavailable. Use \(destination) instead? \(privacy)"
    )
  }

  private func transition(_ event: DictationEvent) {
    state = DictationStateReducer.reduce(state, event)
  }

  private var isActive: Bool {
    switch state {
    case .preparing, .recording, .stopping, .transcribing, .processing, .inserting,
      .cancelling:
      true
    case .idle, .success, .failure, .cancelled:
      false
    }
  }

  private var isCancellingOrCancelled: Bool {
    switch state {
    case .cancelling, .cancelled:
      true
    default:
      false
    }
  }
}

enum DictationCoordinatorError: Error, LocalizedError {
  case missingInsertionTarget
  case emptyTranscript
  case emptyProcessedText
  case cloudDisclosureRequired
  case fallbackDeclined
  case manualCopyRequired(TextInsertionFallbackReason)

  var errorDescription: String? {
    switch self {
    case .missingInsertionTarget:
      String(localized: "The original text field is no longer available.")
    case .emptyTranscript:
      String(localized: "Transcription returned no text.")
    case .emptyProcessedText:
      String(localized: "Text processing returned no text.")
    case .cloudDisclosureRequired:
      String(
        localized:
          "Open SpeakNote Settings and acknowledge Groq cloud processing before dictating."
      )
    case .fallbackDeclined:
      String(
        localized:
          "The alternative transcription provider was declined. No audio was sent to it."
      )
    case .manualCopyRequired(let reason):
      switch reason {
      case .targetChanged:
        String(localized: "The active text field changed before insertion.")
      case .postEventPermissionMissing:
        String(
          localized:
            "Accessibility permission for posting keyboard events is required to paste dictated text."
        )
      case .secureInputEnabled:
        String(localized: "Secure Input prevented automatic insertion.")
      case .pasteboardNotPreservable:
        String(localized: "The current clipboard could not be preserved safely.")
      case .pasteCommandUnavailable:
        String(localized: "The paste command could not be sent.")
      }
    }
  }
}

private actor DirectTranscriptionRouter: TranscriptionProviderRouting {
  private let engine: any TranscriptionEngine

  init(engine: any TranscriptionEngine) {
    self.engine = engine
  }

  func transcribe(
    _ request: TranscriptionRoutingRequest
  ) async throws -> TranscriptionRoutingOutcome {
    let transcript = try await engine.transcribe(
      audioURL: request.audioURL,
      configuration: request.configuration
    )
    return .completed(
      providerID: request.configuration.providerID,
      transcript: transcript
    )
  }

  func accept(
    _ offer: TranscriptionFallbackOffer
  ) async throws -> TranscriptionRoutingOutcome {
    throw TranscriptionProviderRouterError.invalidFallbackOffer
  }

  func decline(
    _ offer: TranscriptionFallbackOffer
  ) -> TranscriptionRoutingOutcome {
    .fallbackDeclined(offer)
  }
}
