import SwiftUI

struct SettingsView: View {
  @ObservedObject var coordinator: SettingsCoordinator
  @ObservedObject var permissionCenter: PermissionCenter
  let appCoordinator: AppCoordinator

  var body: some View {
    TabView {
      generalSettings
        .tabItem {
          Label("General", systemImage: "slider.horizontal.3")
        }

      providerSettings
        .tabItem {
          Label("Provider", systemImage: "network")
        }

      permissionSettings
        .tabItem {
          Label("Permissions", systemImage: "hand.raised")
        }
    }
    .frame(width: 620, height: 500)
    .task {
      await coordinator.load()
      permissionCenter.refresh()
    }
    .alert(
      "SpeakNote",
      isPresented: Binding(
        get: { coordinator.errorMessage != nil },
        set: { if !$0 { coordinator.errorMessage = nil } }
      ),
      actions: {
        Button("OK") {
          coordinator.errorMessage = nil
        }
      },
      message: {
        Text(coordinator.errorMessage ?? "")
      }
    )
  }

  private var generalSettings: some View {
    Form {
      Picker("Dictation output", selection: $coordinator.settings.compressionLevel) {
        ForEach(CompressionLevel.allCases, id: \.self) { level in
          Text(level.title).tag(level)
        }
      }

      TextField(
        "Recognition language (automatic when empty)",
        text: optionalString($coordinator.settings.recognitionLanguageCode)
      )
      TextField(
        "Output language (same as input when empty)",
        text: optionalString($coordinator.settings.outputLanguageCode)
      )

      Toggle(
        "Keep quick-dictation history",
        isOn: $coordinator.settings.dictationHistoryEnabled
      )
      Text(
        coordinator.settings.dictationHistoryEnabled
          ? String(
            localized:
              "Raw transcripts are stored locally. Successful quick-dictation audio is still deleted."
          )
          : String(
            localized:
              "Quick-dictation audio and text are removed after the current operation."
          )
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Button("Save General Settings") {
        Task { await coordinator.saveSettings() }
      }
      .disabled(coordinator.isBusy)
    }
    .formStyle(.grouped)
    .padding()
  }

  private var providerSettings: some View {
    Form {
      Picker(
        "Transcription provider",
        selection: $coordinator.settings.transcriptionProviderID
      ) {
        Text("Groq Cloud").tag(ProviderID.groq)
        Text("Apple Speech (On Device)").tag(ProviderID.appleSpeech)
      }
      .disabled(coordinator.settings.localOnly)
      .onChange(of: coordinator.settings.transcriptionProviderID) {
        _, providerID in
        guard providerID == .appleSpeech else { return }
        Task {
          if permissionCenter.snapshot.speechRecognition == .notDetermined {
            await permissionCenter.request(.speechRecognition)
          }
          await coordinator.refreshLocalTranscriptionCapability()
        }
      }

      Picker(
        "Fallback",
        selection: $coordinator.settings.transcriptionFallbackPolicy
      ) {
        ForEach(FallbackPolicy.allCases, id: \.self) { policy in
          Text(policy.title).tag(policy)
        }
      }
      .disabled(coordinator.settings.localOnly)

      Toggle(
        "Local-only transcription",
        isOn: $coordinator.settings.localOnly
      )
      .disabled(
        !coordinator.isLocalTranscriptionAvailable
          && !coordinator.settings.localOnly
      )
      .onChange(of: coordinator.settings.localOnly) { _, localOnly in
        if localOnly {
          coordinator.settings.transcriptionProviderID = .appleSpeech
        }
      }

      LabeledContent(
        "Apple Speech",
        value: localTranscriptionAvailabilityTitle
      )
      Text(localTranscriptionAvailabilityDetail)
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(
        coordinator.settings.transcriptionProviderID == .appleSpeech
          ? String(
            localized:
              "Apple Speech keeps primary transcription on this Mac. A cloud fallback is offered only when your fallback policy allows asking, and runs only after you accept."
          )
          : String(
            localized:
              "Audio is sent to Groq for transcription. When cleanup, translation, or compression is selected, transcript text is also sent for processing."
          )
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      TextField(
        "Transcription model",
        text: $coordinator.settings.transcriptionModelID
      )
      TextField(
        "Text-processing model",
        text: $coordinator.settings.textProcessingModelID
      )
      TextField(
        "Structured-note model",
        text: $coordinator.settings.structuredTextModelID
      )

      Toggle(
        "I understand that audio and text may be processed by Groq Cloud",
        isOn: $coordinator.settings.hasAcknowledgedGroqCloudProcessing
      )

      Text(
        "Groq says inference inputs and outputs are not retained by default, but they may be temporarily logged for reliability or abuse review. Zero Data Retention is controlled in the Groq console."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Link(
        "Read Groq data policy",
        destination: URL(string: "https://console.groq.com/docs/your-data")!
      )

      HStack {
        SecureField("Groq API key", text: $coordinator.apiKeyDraft)
        Button("Save Key") {
          Task { await coordinator.saveAPIKey() }
        }
        .disabled(
          coordinator.apiKeyDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty || coordinator.isBusy
        )
      }

      LabeledContent(
        "Keychain",
        value: coordinator.hasStoredAPIKey
          ? String(localized: "Configured") : String(localized: "Not configured")
      )

      HStack {
        Button("Save Settings") {
          Task { await coordinator.saveSettings() }
        }
        .disabled(coordinator.isBusy)

        Spacer()

        Button("Delete Key", role: .destructive) {
          Task { await coordinator.deleteAPIKey() }
        }
        .disabled(!coordinator.hasStoredAPIKey || coordinator.isBusy)
      }
    }
    .formStyle(.grouped)
    .padding()
  }

  private var permissionSettings: some View {
    Form {
      Text(
        "SpeakNote requests access only when you choose the related feature or press a request button."
      )
      .foregroundStyle(.secondary)

      ForEach(PermissionKind.allCases) { permission in
        HStack {
          VStack(alignment: .leading) {
            Text(permission.title)
            Text(permissionCenter.snapshot[permission].title)
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Spacer()

          Button("Request") {
            Task {
              await permissionCenter.request(permission)
              if permission == .listenEvents {
                appCoordinator.refreshHotkey()
              }
            }
          }
          .disabled(
            permissionCenter.snapshot[permission] == .granted
          )

          Button("System Settings") {
            permissionCenter.openSystemSettings(for: permission)
          }
        }
      }
    }
    .formStyle(.grouped)
    .padding()
  }

  private func optionalString(_ value: Binding<String?>) -> Binding<String> {
    Binding(
      get: { value.wrappedValue ?? "" },
      set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
    )
  }

  private var localTranscriptionAvailabilityTitle: String {
    switch coordinator.localTranscriptionCapability {
    case .available:
      String(localized: "Available")
    case .unavailable:
      String(localized: "Unavailable")
    }
  }

  private var localTranscriptionAvailabilityDetail: String {
    switch coordinator.localTranscriptionCapability {
    case .available:
      String(
        localized:
          "Available for the selected recognition language. On macOS 14–25, Apple Speech is limited to audio shorter than 55 seconds."
      )
    case .unavailable(let reason):
      String(localized: "Local-only transcription is unavailable: \(reason.title).")
    }
  }
}

extension CompressionLevel {
  fileprivate var title: String {
    switch self {
    case .verbatim: String(localized: "Verbatim")
    case .clean: String(localized: "Clean")
    case .polished: String(localized: "Polished")
    case .concise: String(localized: "Concise")
    }
  }
}

extension FallbackPolicy {
  fileprivate var title: String {
    switch self {
    case .never: String(localized: "Never")
    case .samePrivacyClass: String(localized: "Same privacy class only")
    case .askBeforeCrossingBoundary:
      String(localized: "Ask before switching local/cloud")
    }
  }
}

extension TranscriptionUnavailableReason {
  fileprivate var title: String {
    switch self {
    case .unsupportedOperatingSystem: String(localized: "unsupported macOS version")
    case .invalidDuration: String(localized: "invalid audio duration")
    case .permissionNotDetermined:
      String(localized: "Speech Recognition permission not requested")
    case .permissionDenied:
      String(localized: "Speech Recognition permission not granted")
    case .unsupportedLocale: String(localized: "language not supported")
    case .recognizerUnavailable: String(localized: "recognizer currently unavailable")
    case .onDeviceRecognitionUnavailable:
      String(localized: "on-device recognition not supported")
    case .modelMissing: String(localized: "Apple Speech model is not downloaded")
    case .modelUnavailable: String(localized: "Apple Speech model is unavailable")
    case .legacyDurationLimitExceeded:
      String(localized: "audio must be shorter than 55 seconds")
    case .providerNotConfigured:
      String(localized: "Apple Speech provider not configured")
    }
  }
}
