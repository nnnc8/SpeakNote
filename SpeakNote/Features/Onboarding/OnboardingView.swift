import SwiftUI

struct OnboardingView: View {
  @ObservedObject var coordinator: OnboardingCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Image(systemName: stepIcon)
          .font(.system(size: 34))
          .foregroundStyle(.tint)
        VStack(alignment: .leading) {
          Text(stepTitle)
            .font(.title2)
          Text("Step \(coordinator.step.rawValue + 1) of \(OnboardingStep.allCases.count)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      stepContent
        .frame(maxWidth: .infinity, alignment: .leading)

      Spacer()

      HStack {
        if coordinator.step != .privacy {
          Button("Back") { coordinator.goBack() }
        }
        Spacer()
        if coordinator.step == .localSpeech {
          Button("Finish") {
            Task { await coordinator.finish() }
          }
          .keyboardShortcut(.defaultAction)
        } else {
          Button("Continue") { coordinator.advance() }
            .keyboardShortcut(.defaultAction)
        }
      }
      .disabled(coordinator.isBusy)
    }
    .padding(28)
    .frame(width: 560, height: 430)
    .interactiveDismissDisabled()
    .alert(
      "SpeakNote",
      isPresented: Binding(
        get: { coordinator.errorMessage != nil },
        set: { if !$0 { coordinator.errorMessage = nil } }
      )
    ) {
      Button("OK") { coordinator.errorMessage = nil }
    } message: {
      Text(coordinator.errorMessage ?? "")
    }
  }

  @ViewBuilder
  private var stepContent: some View {
    switch coordinator.step {
    case .privacy:
      VStack(alignment: .leading, spacing: 12) {
        Text(
          "SpeakNote records only when you start dictation or a voice note. Quick-dictation audio is deleted after the operation; Voice Note audio and transcripts stay in the app container until you delete the session."
        )
        Text(
          "Groq features send audio or transcript text to Groq Cloud only after you acknowledge the disclosure in Settings. Apple Speech keeps transcription on this Mac when available. API keys are stored in Keychain."
        )
        Text("SpeakNote has no analytics or advertising tracking.")
          .foregroundStyle(.secondary)
      }
    case .microphone:
      permissionStep(
        kind: .microphone,
        explanation:
          String(
            localized:
              "Microphone access is needed only for live dictation and Voice Note recording. Imported audio files do not require it."
          )
      )
    case .hotkey:
      VStack(alignment: .leading, spacing: 16) {
        permissionStep(
          kind: .listenEvents,
          explanation:
            String(
              localized:
                "Input Monitoring lets SpeakNote detect the global Option-tap shortcut. You can still use the app button without it."
            )
        )
        Divider()
        permissionStep(
          kind: .postEvents,
          explanation:
            String(
              localized:
                "Accessibility lets SpeakNote post Command-V after restoring focus to the original app. If unavailable, SpeakNote keeps the transcript for explicit Copy."
            )
        )
      }
    case .localSpeech:
      permissionStep(
        kind: .speechRecognition,
        explanation:
          String(
            localized:
              "Speech Recognition enables the optional on-device Apple Speech provider. Groq transcription does not require this permission."
          )
      )
    }
  }

  private func permissionStep(
    kind: PermissionKind,
    explanation: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(explanation)
      LabeledContent("Status", value: coordinator.permissions[kind].title)
      HStack {
        Button("Request \(kind.title)") {
          Task { await coordinator.request(kind) }
        }
        .disabled(
          coordinator.permissions[kind] == .granted || coordinator.isBusy
        )
        if coordinator.permissions[kind] != .granted {
          Button("Open System Settings") {
            coordinator.openSystemSettings(for: kind)
          }
        }
      }
    }
  }

  private var stepTitle: String {
    switch coordinator.step {
    case .privacy: String(localized: "Privacy and Storage")
    case .microphone: String(localized: "Microphone")
    case .hotkey: String(localized: "Global Shortcut and Paste")
    case .localSpeech: String(localized: "Optional Local Transcription")
    }
  }

  private var stepIcon: String {
    switch coordinator.step {
    case .privacy: "lock.shield"
    case .microphone: "mic"
    case .hotkey: "keyboard"
    case .localSpeech: "waveform.badge.mic"
    }
  }
}
