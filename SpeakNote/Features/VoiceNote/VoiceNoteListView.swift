import Foundation
import SwiftUI

struct VoiceNoteListView: View {
  @ObservedObject var coordinator: VoiceNoteCoordinator

  var body: some View {
    NavigationSplitView {
      List(
        coordinator.sessions,
        selection: Binding(
          get: { coordinator.selectedSessionID },
          set: { newValue in
            Task { await coordinator.select(newValue) }
          }
        )
      ) { session in
        VoiceNoteRow(session: session)
          .tag(session.id)
      }
      .navigationTitle("Voice Notes")
      .toolbar {
        switch coordinator.recordingState {
        case .recording:
          Button {
            Task { await coordinator.pauseRecording() }
          } label: {
            Label("Pause Recording", systemImage: "pause.fill")
          }
          Button {
            Task { await coordinator.finishRecording() }
          } label: {
            Label("Finish Recording", systemImage: "stop.fill")
          }
        case .paused:
          Button {
            Task { await coordinator.resumeRecording() }
          } label: {
            Label("Resume Recording", systemImage: "play.fill")
          }
          Button {
            Task { await coordinator.finishRecording() }
          } label: {
            Label("Finish Recording", systemImage: "stop.fill")
          }
        case .preparing, .finalizing:
          ProgressView()
            .controlSize(.small)
        case .idle, .processing, .recoveryAvailable, .failed:
          Button {
            Task { await coordinator.startRecording() }
          } label: {
            Label("Record", systemImage: "record.circle")
          }
        }
        Button {
          Task { await coordinator.importVoiceNote() }
        } label: {
          Label("Import Audio", systemImage: "square.and.arrow.down")
        }
        .disabled(coordinator.isBusy)
      }
      .overlay {
        if coordinator.sessions.isEmpty && !coordinator.isBusy {
          ContentUnavailableView(
            "No Voice Notes",
            systemImage: "waveform",
            description: Text("Record audio or import an audio file to begin.")
          )
        }
      }
    } detail: {
      if let session = coordinator.selectedSession {
        VoiceNoteDetailView(coordinator: coordinator, session: session)
      } else {
        ContentUnavailableView(
          "Select a Voice Note",
          systemImage: "sidebar.left",
          description: Text("Review durable progress or manage a voice note.")
        )
      }
    }
    .task {
      await coordinator.load()
    }
    .task(id: coordinator.selectedSessionID) {
      await coordinator.monitorSelectedSession()
    }
    .alert(
      "SpeakNote",
      isPresented: Binding(
        get: { coordinator.errorMessage != nil },
        set: { if !$0 { coordinator.errorMessage = nil } }
      )
    ) {
      Button("OK") {
        coordinator.errorMessage = nil
      }
    } message: {
      Text(coordinator.errorMessage ?? "")
    }
  }
}

private struct VoiceNoteRow: View {
  let session: RecordingSessionDTO

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(session.title)
        .lineLimit(1)
      HStack {
        Label(session.status.title, systemImage: session.status.systemImage)
        Spacer()
        Text(session.updatedAt, format: .dateTime)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

private struct VoiceNoteDetailView: View {
  @ObservedObject var coordinator: VoiceNoteCoordinator
  @ObservedObject private var audioPlayer: M4AudioPlayerController
  let session: RecordingSessionDTO

  init(coordinator: VoiceNoteCoordinator, session: RecordingSessionDTO) {
    self.coordinator = coordinator
    self.session = session
    _audioPlayer = ObservedObject(wrappedValue: coordinator.audioPlayer)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
              .font(.title2)
            Text(session.createdAt, format: .dateTime)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Label(session.status.title, systemImage: session.status.systemImage)
        }

        GroupBox("Session") {
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
              Text("Source")
              Text(session.source.title)
            }
            GridRow {
              Text("Duration")
              Text(durationLabel(session.duration))
            }
            GridRow {
              Text("Updated")
              Text(session.updatedAt, format: .dateTime)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        if session.duration > 0 {
          GroupBox("Audio") {
            HStack {
              Button {
                Task { await coordinator.togglePlaybackSelected() }
              } label: {
                Label(
                  audioPlayer.state == .playing
                    ? String(localized: "Pause") : String(localized: "Play"),
                  systemImage: audioPlayer.state == .playing
                    ? "pause.fill" : "play.fill"
                )
              }
              Button("Stop") {
                coordinator.stopPlayback()
              }
              Slider(
                value: Binding(
                  get: { audioPlayer.progress },
                  set: { coordinator.seekPlayback(to: $0) }
                ),
                in: 0...max(max(audioPlayer.duration, session.duration), 1)
              )
              Text(durationLabel(audioPlayer.progress))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        if let job = coordinator.selectedJob {
          VoiceNoteJobView(job: job)
        } else {
          GroupBox("Transcription") {
            Text("No transcription job has been saved for this session.")
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        VoiceNoteStructuredRunsView(
          coordinator: coordinator,
          session: session
        )

        HStack {
          TextField("Voice note name", text: $coordinator.renameDraft)
          Button("Rename") {
            Task { await coordinator.renameSelected() }
          }
          .disabled(coordinator.isBusy)
        }

        HStack {
          if session.canRecoverRecording {
            Button("Recover and Process") {
              Task { await coordinator.recoverSelectedRecording() }
            }
            Button("Keep Audio") {
              Task { await coordinator.keepSelectedRecording() }
            }
          }
          if session.canCancel {
            Button("Cancel") {
              if session.status == .recording || session.status == .paused {
                Task { await coordinator.cancelActiveRecording() }
              } else {
                Task { await coordinator.cancelSelected() }
              }
            }
          }
          if session.canRetry {
            Button("Retry") {
              Task { await coordinator.retrySelected() }
            }
            if let alternativeProviderID = coordinator.alternativeProviderID {
              Button(
                alternativeProviderID == .appleSpeech
                  ? String(localized: "Retry as New Job with Apple Speech")
                  : String(localized: "Retry as New Job with Groq Cloud")
              ) {
                Task { await coordinator.retrySelectedWithAlternative() }
              }
              .help(
                alternativeProviderID == .groq
                  ? String(
                    localized:
                      "Creates a new job and sends the source audio to Groq only after this click."
                  )
                  : String(
                    localized: "Creates a new job and keeps transcription on this Mac."
                  )
              )
            }
          }
          if session.needsRepair || session.status == .needsRepair {
            Button("Repair") {
              Task { await coordinator.repairSelected() }
            }
          }
          Spacer()
          Button("Delete", role: .destructive) {
            Task { await coordinator.deleteSelected() }
          }
        }
        .disabled(coordinator.isBusy)
      }
      .padding()
    }
    .navigationTitle("Voice Note")
  }

  private func durationLabel(_ duration: TimeInterval) -> String {
    let totalSeconds = max(0, Int(duration.rounded()))
    return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
  }
}

private struct VoiceNoteStructuredRunsView: View {
  @ObservedObject var coordinator: VoiceNoteCoordinator
  let session: RecordingSessionDTO

  var body: some View {
    GroupBox("Structured Notes") {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Picker("Format", selection: $coordinator.selectedNoteType) {
            ForEach(NoteType.allCases, id: \.rawValue) { noteType in
              Text(noteType.title).tag(noteType)
            }
          }
          .frame(maxWidth: 260)

          if coordinator.isStructuring {
            ProgressView()
              .controlSize(.small)
            Button("Cancel") {
              coordinator.cancelStructuredNote()
            }
          } else {
            Button(
              coordinator.structuredRuns.isEmpty
                ? String(localized: "Generate Note")
                : String(localized: "Generate New Run")
            ) {
              Task { await coordinator.generateStructuredNote() }
            }
            .disabled(session.status != .completed || coordinator.isBusy)
          }
        }

        if !coordinator.structuredRuns.isEmpty {
          Picker(
            "Version",
            selection: Binding(
              get: { coordinator.selectedStructuredRunID },
              set: { id in
                Task { await coordinator.selectStructuredRun(id) }
              }
            )
          ) {
            ForEach(coordinator.structuredRuns) { run in
              Text(run.versionTitle).tag(Optional(run.id))
            }
          }

          if coordinator.selectedStructuredRun?.status == .failed {
            Label(
              "This run failed. The raw transcript and earlier runs are unchanged.",
              systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
          }

          if let warning = VoiceNoteStructuredRunWarning.message(
            for: coordinator.structuredRunErrorCategory
          ) {
            Label(warning, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }

          if let markdown = coordinator.structuredMarkdown {
            Divider()
            structuredPreview(markdown)
              .textSelection(.enabled)
              .environment(
                \.openURL,
                OpenURLAction { url in
                  guard VoiceNoteCoordinator.structuredSourceStartTime(from: url) != nil else {
                    return .systemAction
                  }
                  Task { _ = await coordinator.openStructuredSource(url) }
                  return .handled
                }
              )
          } else if coordinator.selectedStructuredRun?.status == .succeeded {
            Text("The saved preview could not be loaded.")
              .foregroundStyle(.secondary)
          }
        } else {
          Text(
            session.status == .completed
              ? String(
                localized: "Choose a format to create an append-only Markdown version."
              )
              : String(
                localized:
                  "A structured note can be generated after the raw transcript is complete."
              )
          )
          .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private func structuredPreview(_ markdown: String) -> some View {
    if let attributed = try? AttributedString(markdown: markdown) {
      Text(attributed)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      Text(markdown)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct VoiceNoteJobView: View {
  let job: TranscriptionJobDTO

  var body: some View {
    GroupBox("Transcription") {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Label(job.stage.title, systemImage: "waveform.badge.magnifyingglass")
          Spacer()
          if job.totalChunks > 0 {
            Text("\(job.completedChunks) of \(job.totalChunks) chunks")
              .foregroundStyle(.secondary)
          }
        }

        if job.totalChunks > 0 {
          ProgressView(
            value: Double(job.completedChunks),
            total: Double(job.totalChunks)
          )
        } else if job.isActive {
          ProgressView()
            .controlSize(.small)
        }

        if let failureMessage = job.userFacingFailureMessage {
          Label(
            failureMessage,
            systemImage: "exclamationmark.triangle"
          )
          .foregroundStyle(.red)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

extension TranscriptionJobDTO {
  fileprivate var userFacingFailureMessage: LocalizedStringKey? {
    guard let errorCategory else { return nil }
    return switch errorCategory {
    case "ambiguousCompletionConfirmationRequired":
      "The provider may have received the last chunk. Retry only after checking to avoid duplicate processing."
    case "sessionIntegrity":
      "Stored session files did not pass integrity checks. Use Repair before retrying."
    case "audioPreprocessing":
      "The audio could not be prepared. Keep the source, then retry or delete the session."
    case "transcriptionProvider":
      "The transcription provider stopped. Retry this job or choose the available alternative provider."
    default:
      "Voice Note processing stopped. Your source audio and completed progress were kept."
    }
  }
}

extension RecordingSessionDTO {
  fileprivate var canCancel: Bool {
    switch status {
    case .importing, .recording, .paused, .preprocessing, .transcribing, .merging:
      true
    default:
      false
    }
  }

  fileprivate var canRetry: Bool {
    switch status {
    case .cancelled, .retryRequired:
      true
    case .interrupted:
      source == .imported || currentJobID != nil
    default:
      false
    }
  }

  fileprivate var canRecoverRecording: Bool {
    source == .recorded
      && (status == .recoveryAvailable || status == .interrupted)
  }
}

extension VoiceNoteSource {
  fileprivate var title: String {
    switch self {
    case .imported: String(localized: "Imported")
    case .recorded: String(localized: "Recorded")
    }
  }
}

extension VoiceNoteSessionStatus {
  fileprivate var title: String {
    switch self {
    case .importing: String(localized: "Importing")
    case .recording: String(localized: "Recording")
    case .paused: String(localized: "Paused")
    case .ready: String(localized: "Ready")
    case .preprocessing: String(localized: "Preprocessing")
    case .transcribing: String(localized: "Transcribing")
    case .merging: String(localized: "Merging")
    case .completed: String(localized: "Completed")
    case .cancelled: String(localized: "Cancelled")
    case .retryRequired: String(localized: "Retry Required")
    case .interrupted: String(localized: "Interrupted")
    case .recoveryAvailable: String(localized: "Recovery Available")
    case .needsRepair: String(localized: "Needs Repair")
    case .pendingDeletion: String(localized: "Pending Deletion")
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .importing, .recording, .preprocessing, .transcribing, .merging:
      "clock.arrow.circlepath"
    case .paused:
      "pause.circle"
    case .ready:
      "checkmark.circle"
    case .completed:
      "checkmark.circle.fill"
    case .cancelled:
      "xmark.circle"
    case .retryRequired, .interrupted, .recoveryAvailable:
      "arrow.clockwise.circle"
    case .needsRepair:
      "wrench.and.screwdriver"
    case .pendingDeletion:
      "trash"
    }
  }
}

extension TranscriptionJobStage {
  fileprivate var title: String {
    switch self {
    case .queued: String(localized: "Queued")
    case .preprocessing: String(localized: "Preprocessing")
    case .chunking: String(localized: "Chunking")
    case .transcribing: String(localized: "Transcribing")
    case .merging: String(localized: "Merging")
    case .exporting: String(localized: "Exporting")
    case .completed: String(localized: "Completed")
    case .cancelled: String(localized: "Cancelled")
    case .retryRequired: String(localized: "Retry Required")
    }
  }

  fileprivate var isActive: Bool {
    switch self {
    case .queued, .preprocessing, .chunking, .transcribing, .merging, .exporting:
      true
    case .completed, .cancelled, .retryRequired:
      false
    }
  }
}

extension TranscriptionJobDTO {
  fileprivate var isActive: Bool { stage.isActive }
}

extension NoteType {
  fileprivate var title: String {
    switch self {
    case .classNotes: String(localized: "Class Notes")
    case .meetingMinutes: String(localized: "Meeting Minutes")
    case .generalNotes: String(localized: "General Notes")
    }
  }
}

extension ProcessingRunDTO {
  fileprivate var versionTitle: String {
    let state =
      status == .succeeded ? String(localized: "Saved") : String(localized: "Failed")
    return String(
      localized:
        "\(createdAt.formatted(date: .abbreviated, time: .shortened)) · \(modelID) · \(state)"
    )
  }
}
