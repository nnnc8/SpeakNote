import Combine
import Foundation

protocol VoiceNoteWorkflowRunning: Actor {
  func importAndStart(url: URL, title: String?) async throws -> UUID
  func resume(sessionID: UUID) async throws
  func cancel(sessionID: UUID) async
  func delete(sessionID: UUID) async throws
}

@MainActor
protocol VoiceNoteFilePicking: AnyObject {
  func chooseAudioFile() async -> URL?
}

@MainActor
final class VoiceNoteCoordinator: ObservableObject {
  @Published private(set) var sessions: [RecordingSessionDTO] = []
  @Published private(set) var jobs: [TranscriptionJobDTO] = []
  @Published var selectedSessionID: UUID?
  @Published var renameDraft = ""
  @Published private(set) var isBusy = false
  @Published var errorMessage: String?
  @Published private(set) var recordingState: VoiceNoteRecordingWorkflowState = .idle
  @Published private(set) var recordingMeter: M4RecordingMeter?
  @Published private(set) var structuredRuns: [ProcessingRunDTO] = []
  @Published var selectedStructuredRunID: UUID?
  @Published private(set) var structuredDocument: ProcessedDocument?
  @Published private(set) var structuredMarkdown: String?
  @Published private(set) var structuredRunErrorCategory: String?
  @Published var selectedNoteType: NoteType = .generalNotes
  @Published private(set) var isStructuring = false
  @Published private(set) var alternativeProviderID: ProviderID?

  let audioPlayer: M4AudioPlayerController

  private let sessionRepository: any VoiceNoteSessionStoring
  private let settingsRepository: any SettingsStoring
  private let workflow: any VoiceNoteWorkflowRunning
  private let filePicker: any VoiceNoteFilePicking
  private let recordingWorkflow: (any VoiceNoteRecordingRunning)?
  private let recoveryManager: (any VoiceNoteRecoveryManaging)?
  private let structuredWorkflow: (any VoiceNoteStructuredProcessingRunning)?
  private let providerFallbackWorkflow: (any VoiceNoteProviderFallbackRunning)?
  private var recordingEventTask: Task<Void, Never>?
  private var loadedPlaybackSessionID: UUID?
  private var structuredTask: Task<VoiceNoteStructuredRun, any Error>?

  init(
    sessionRepository: any VoiceNoteSessionStoring,
    settingsRepository: any SettingsStoring,
    workflow: any VoiceNoteWorkflowRunning,
    filePicker: any VoiceNoteFilePicking,
    recordingWorkflow: (any VoiceNoteRecordingRunning)? = nil,
    recoveryManager: (any VoiceNoteRecoveryManaging)? = nil,
    structuredWorkflow: (any VoiceNoteStructuredProcessingRunning)? = nil,
    providerFallbackWorkflow: (any VoiceNoteProviderFallbackRunning)? = nil,
    audioPlayer: M4AudioPlayerController = M4AudioPlayerController()
  ) {
    self.sessionRepository = sessionRepository
    self.settingsRepository = settingsRepository
    self.workflow = workflow
    self.filePicker = filePicker
    self.recordingWorkflow = recordingWorkflow
    self.recoveryManager = recoveryManager
    self.structuredWorkflow = structuredWorkflow
    self.providerFallbackWorkflow = providerFallbackWorkflow
    self.audioPlayer = audioPlayer
  }

  var selectedSession: RecordingSessionDTO? {
    guard let selectedSessionID else { return nil }
    return sessions.first { $0.id == selectedSessionID }
  }

  var selectedJob: TranscriptionJobDTO? {
    if let currentJobID = selectedSession?.currentJobID {
      return jobs.first { $0.id == currentJobID }
    }
    return jobs.last
  }

  var selectedStructuredRun: ProcessingRunDTO? {
    guard let selectedStructuredRunID else { return nil }
    return structuredRuns.first { $0.id == selectedStructuredRunID }
  }

  func load() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    startRecordingEventMonitoring()

    do {
      selectedNoteType = try await settingsRepository.load().defaultVoiceNoteType
      if let recoveryManager {
        _ = try await recoveryManager.reconcile()
      }
      try await refreshState()
    } catch {
      errorMessage = String(localized: "Voice notes could not be loaded.")
    }
  }

  func monitorSelectedSession() async {
    while !Task.isCancelled {
      guard let selectedSessionID else { return }
      do {
        let latestSessions = try await sessionRepository.sessions()
        let latestJobs = try await sessionRepository.jobs(
          sessionID: selectedSessionID
        )
        guard self.selectedSessionID == selectedSessionID else { return }
        sessions = latestSessions
        jobs = latestJobs
      } catch {
        guard self.selectedSessionID == selectedSessionID else { return }
        errorMessage = String(localized: "Transcription progress could not be refreshed.")
        return
      }

      guard
        let status = sessions.first(where: {
          $0.id == selectedSessionID
        })?.status,
        Self.requiresProgressMonitoring(status)
      else {
        return
      }
      do {
        try await Task.sleep(for: .milliseconds(500))
      } catch {
        return
      }
    }
  }

  func select(_ id: UUID?) async {
    if selectedSessionID != id {
      audioPlayer.stop()
      loadedPlaybackSessionID = nil
      clearStructuredSelection()
    }
    selectedSessionID = id
    jobs = []
    renameDraft = sessions.first(where: { $0.id == id })?.title ?? ""
    guard let id else { return }

    do {
      let loadedJobs = try await sessionRepository.jobs(sessionID: id)
      guard selectedSessionID == id else { return }
      jobs = loadedJobs
      try await refreshStructuredRuns(sessionID: id, preserveSelection: false)
    } catch {
      guard selectedSessionID == id else { return }
      errorMessage = String(localized: "Transcription progress could not be loaded.")
    }
  }

  func importVoiceNote(title: String? = nil) async {
    guard !isBusy, let url = await filePicker.chooseAudioFile() else { return }
    isBusy = true
    defer { isBusy = false }

    do {
      let sessionID = try await workflow.importAndStart(url: url, title: title)
      selectedSessionID = sessionID
      try await refreshState()
    } catch {
      errorMessage = String(localized: "The voice note could not be imported.")
      await refreshAfterFailure()
    }
  }

  func startRecording(title: String? = nil) async {
    guard !isBusy, let recordingWorkflow else { return }
    isBusy = true
    defer { isBusy = false }
    startRecordingEventMonitoring()

    do {
      let sessionID = try await recordingWorkflow.start(title: title)
      selectedSessionID = sessionID
      try await refreshState()
    } catch {
      if (error as? VoiceNoteRecordingWorkflowError) == .insufficientDiskSpace {
        errorMessage =
          String(
            localized:
              "Recording needs at least 512 MiB of available disk space. Free space and try again."
          )
      } else {
        errorMessage = String(localized: "Recording could not be started.")
      }
      await refreshAfterFailure()
    }
  }

  func pauseRecording() async {
    await performRecordingAction(
      failureMessage: String(localized: "Recording could not be paused.")
    ) { workflow in
      try await workflow.pause()
    }
  }

  func resumeRecording() async {
    await performRecordingAction(
      failureMessage: String(localized: "Recording could not be resumed.")
    ) { workflow in
      try await workflow.resume()
    }
  }

  func finishRecording() async {
    await performRecordingAction(
      failureMessage: String(localized: "Recording could not be finalized.")
    ) { workflow in
      try await workflow.stopAndProcess()
    }
  }

  func cancelActiveRecording() async {
    guard !isBusy, let recordingWorkflow else { return }
    isBusy = true
    defer { isBusy = false }
    await recordingWorkflow.cancelPreservingAudio()
    do {
      try await refreshState()
    } catch {
      errorMessage = String(localized: "Recovered recording state could not be loaded.")
    }
  }

  func recoverSelectedRecording() async {
    guard !isBusy, let selectedSessionID, let recordingWorkflow else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await recordingWorkflow.recoverAndProcess(
        sessionID: selectedSessionID
      )
      try await refreshState()
    } catch {
      errorMessage = String(localized: "The recovered audio could not be processed.")
      await refreshAfterFailure()
    }
  }

  func keepSelectedRecording() async {
    guard !isBusy, let selectedSessionID, let recordingWorkflow else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await recordingWorkflow.keepRecoveredAudio(
        sessionID: selectedSessionID
      )
      try await refreshState()
    } catch {
      errorMessage = String(localized: "The recovered audio could not be kept.")
      await refreshAfterFailure()
    }
  }

  func togglePlaybackSelected() async {
    guard let selectedSessionID, let recoveryManager else { return }
    do {
      try await ensurePlaybackLoaded(
        sessionID: selectedSessionID,
        recoveryManager: recoveryManager
      )
      if audioPlayer.state == .playing {
        audioPlayer.pause()
      } else {
        try audioPlayer.play()
      }
    } catch {
      errorMessage = String(localized: "Audio playback could not be started.")
    }
  }

  func stopPlayback() {
    audioPlayer.stop()
  }

  func seekPlayback(to time: TimeInterval) {
    guard loadedPlaybackSessionID == selectedSessionID else { return }
    do {
      try audioPlayer.seek(to: time)
    } catch {
      errorMessage = String(localized: "Audio playback could not seek to that position.")
    }
  }

  func generateStructuredNote() async {
    guard !isStructuring,
      let selectedSessionID,
      let structuredWorkflow,
      selectedSession?.status == .completed
    else { return }
    isStructuring = true
    let noteType = selectedNoteType
    let task = Task {
      try await structuredWorkflow.process(
        sessionID: selectedSessionID,
        noteType: noteType
      )
    }
    structuredTask = task
    defer {
      structuredTask = nil
      isStructuring = false
    }

    do {
      let output = try await task.value
      guard self.selectedSessionID == selectedSessionID else { return }
      try await refreshStructuredRuns(
        sessionID: selectedSessionID,
        preserveSelection: false,
        preferredRunID: output.run.id
      )
    } catch is CancellationError {
      if self.selectedSessionID == selectedSessionID {
        try? await refreshStructuredRuns(
          sessionID: selectedSessionID,
          preserveSelection: true
        )
      }
    } catch {
      if self.selectedSessionID == selectedSessionID {
        errorMessage =
          String(
            localized:
              "The structured note could not be generated. The raw transcript is unchanged."
          )
        try? await refreshStructuredRuns(
          sessionID: selectedSessionID,
          preserveSelection: false
        )
      }
    }
  }

  func cancelStructuredNote() {
    structuredTask?.cancel()
  }

  func selectStructuredRun(_ id: UUID?) async {
    guard let selectedSessionID else {
      clearStructuredSelection()
      return
    }
    selectedStructuredRunID = id
    do {
      try await loadStructuredRun(sessionID: selectedSessionID, runID: id)
    } catch {
      errorMessage = String(localized: "The selected processing run could not be loaded.")
      structuredDocument = nil
      structuredMarkdown = nil
      structuredRunErrorCategory = nil
    }
  }

  func openStructuredSource(_ url: URL) async -> Bool {
    guard let time = Self.structuredSourceStartTime(from: url),
      let selectedSessionID,
      let recoveryManager
    else { return false }
    do {
      try await ensurePlaybackLoaded(
        sessionID: selectedSessionID,
        recoveryManager: recoveryManager
      )
      try audioPlayer.seek(to: time)
      return true
    } catch {
      errorMessage = String(localized: "Audio could not seek to that source timestamp.")
      return true
    }
  }

  static func structuredSourceStartTime(from url: URL) -> TimeInterval? {
    guard let fragment = url.fragment,
      fragment.hasPrefix("t=")
    else { return nil }
    let parts = fragment.dropFirst(2).split(
      separator: "-",
      maxSplits: 1,
      omittingEmptySubsequences: false
    )
    guard parts.count == 2,
      let startMilliseconds = Int64(parts[0]),
      let endMilliseconds = Int64(parts[1]),
      startMilliseconds >= 0,
      endMilliseconds >= startMilliseconds
    else { return nil }
    return TimeInterval(startMilliseconds) / 1_000
  }

  func retrySelected() async {
    await resumeSelected(
      failureMessage: String(localized: "The transcription could not be retried.")
    )
  }

  func retrySelectedWithAlternative() async {
    guard
      !isBusy,
      let selectedSessionID,
      let alternativeProviderID,
      let providerFallbackWorkflow
    else {
      return
    }
    isBusy = true
    defer { isBusy = false }
    do {
      try await providerFallbackWorkflow.retry(
        sessionID: selectedSessionID,
        using: alternativeProviderID
      )
      try await refreshState()
    } catch {
      errorMessage = String(
        localized: "The alternative transcription provider could not be started."
      )
      await refreshAfterFailure()
    }
  }

  func repairSelected() async {
    await resumeSelected(
      failureMessage: String(localized: "The voice note could not be repaired.")
    )
  }

  func cancelSelected() async {
    guard !isBusy, let selectedSessionID else { return }
    isBusy = true
    defer { isBusy = false }

    await workflow.cancel(sessionID: selectedSessionID)
    do {
      try await refreshState()
    } catch {
      errorMessage = String(localized: "The updated voice note state could not be loaded.")
    }
  }

  func renameSelected() async {
    guard !isBusy, let selectedSessionID else { return }
    let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      errorMessage = String(localized: "Enter a name for the voice note.")
      return
    }
    isBusy = true
    defer { isBusy = false }

    do {
      _ = try await sessionRepository.renameSession(
        id: selectedSessionID,
        title: title,
        updatedAt: Date()
      )
      try await refreshState()
    } catch {
      errorMessage = String(localized: "The voice note could not be renamed.")
      await refreshAfterFailure()
    }
  }

  func deleteSelected() async {
    guard !isBusy, let selectedSessionID else { return }
    isBusy = true
    defer { isBusy = false }

    do {
      if let recordingWorkflow,
        selectedSession?.status == .recording
          || selectedSession?.status == .paused
      {
        await recordingWorkflow.cancelPreservingAudio()
      }
      try await workflow.delete(sessionID: selectedSessionID)
      audioPlayer.stop()
      loadedPlaybackSessionID = nil
      self.selectedSessionID = nil
      jobs = []
      renameDraft = ""
      alternativeProviderID = nil
      clearStructuredSelection()
      try await refreshState()
    } catch {
      errorMessage = String(localized: "The voice note could not be deleted.")
      await refreshAfterFailure()
    }
  }

  private func performRecordingAction(
    failureMessage: String,
    operation: (any VoiceNoteRecordingRunning) async throws -> Void
  ) async {
    guard !isBusy, let recordingWorkflow else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await operation(recordingWorkflow)
      try await refreshState()
    } catch {
      errorMessage = failureMessage
      await refreshAfterFailure()
    }
  }

  private func startRecordingEventMonitoring() {
    guard recordingEventTask == nil, let recordingWorkflow else { return }
    recordingEventTask = Task { [weak self] in
      let events = await recordingWorkflow.events
      for await event in events {
        guard let self, !Task.isCancelled else { return }
        switch event {
        case .stateChanged(let state):
          recordingState = state
          if state == .idle {
            recordingMeter = nil
          }
          try? await refreshState()
        case .meter(let meter):
          recordingMeter = meter
        case .segmentCommitted:
          try? await refreshState()
        case .lowDiskWarning:
          errorMessage =
            String(
              localized:
                "Recording stopped because disk space is low. Completed audio was kept for recovery."
            )
        }
      }
    }
  }

  private func resumeSelected(failureMessage: String) async {
    guard !isBusy, let selectedSessionID else { return }
    isBusy = true
    defer { isBusy = false }

    do {
      try await workflow.resume(sessionID: selectedSessionID)
      try await refreshState()
    } catch {
      errorMessage = failureMessage
      await refreshAfterFailure()
    }
  }

  private func refreshState() async throws {
    sessions = try await sessionRepository.sessions()

    guard let selectedSessionID,
      sessions.contains(where: { $0.id == selectedSessionID })
    else {
      self.selectedSessionID = nil
      jobs = []
      renameDraft = ""
      alternativeProviderID = nil
      clearStructuredSelection()
      return
    }

    jobs = try await sessionRepository.jobs(sessionID: selectedSessionID)
    if sessions.first(where: { $0.id == selectedSessionID })?.status
      == .retryRequired,
      let providerFallbackWorkflow
    {
      alternativeProviderID =
        try? await providerFallbackWorkflow
        .availableAlternativeProvider(sessionID: selectedSessionID)
    } else {
      alternativeProviderID = nil
    }
    renameDraft =
      sessions.first(where: { $0.id == selectedSessionID })?.title ?? ""
    try await refreshStructuredRuns(
      sessionID: selectedSessionID,
      preserveSelection: true
    )
  }

  private func ensurePlaybackLoaded(
    sessionID: UUID,
    recoveryManager: any VoiceNoteRecoveryManaging
  ) async throws {
    guard loadedPlaybackSessionID != sessionID else { return }
    let segments = try await recoveryManager.playbackSegments(
      sessionID: sessionID
    )
    try audioPlayer.load(segments: segments)
    loadedPlaybackSessionID = sessionID
  }

  private func refreshStructuredRuns(
    sessionID: UUID,
    preserveSelection: Bool,
    preferredRunID: UUID? = nil
  ) async throws {
    guard let structuredWorkflow else {
      clearStructuredSelection()
      return
    }
    let loaded = try await structuredWorkflow.runs(sessionID: sessionID)
    guard selectedSessionID == sessionID else { return }
    structuredRuns = loaded

    let preservedID = preserveSelection ? selectedStructuredRunID : nil
    let selectedID =
      [preferredRunID, preservedID]
      .compactMap { $0 }
      .first(where: { id in loaded.contains { $0.id == id } })
      ?? loaded.last(where: { $0.status == .succeeded })?.id
      ?? loaded.last?.id
    selectedStructuredRunID = selectedID
    try await loadStructuredRun(sessionID: sessionID, runID: selectedID)
  }

  private func loadStructuredRun(
    sessionID: UUID,
    runID: UUID?
  ) async throws {
    guard let runID, let structuredWorkflow else {
      structuredDocument = nil
      structuredMarkdown = nil
      structuredRunErrorCategory = nil
      return
    }
    let output = try await structuredWorkflow.read(
      sessionID: sessionID,
      runID: runID
    )
    guard selectedSessionID == sessionID,
      selectedStructuredRunID == runID
    else { return }
    structuredDocument = output?.document
    structuredMarkdown = output?.markdown
    structuredRunErrorCategory = output?.run.errorCategory
  }

  private func clearStructuredSelection() {
    structuredRuns = []
    selectedStructuredRunID = nil
    structuredDocument = nil
    structuredMarkdown = nil
    structuredRunErrorCategory = nil
  }

  private func refreshAfterFailure() async {
    do {
      try await refreshState()
    } catch {
      // Keep the operation error visible and the last durable state on screen.
    }
  }

  private static func requiresProgressMonitoring(
    _ status: VoiceNoteSessionStatus
  ) -> Bool {
    switch status {
    case .importing, .recording, .paused, .preprocessing, .transcribing, .merging:
      true
    case .ready, .completed, .cancelled, .retryRequired, .interrupted,
      .recoveryAvailable, .needsRepair, .pendingDeletion:
      false
    }
  }
}
