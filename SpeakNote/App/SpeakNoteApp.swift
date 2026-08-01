import SwiftUI

@main
@MainActor
struct SpeakNoteApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var bootstrap: ApplicationBootstrap

  init() {
    let process = ProcessInfo.processInfo
    let isUITesting = process.arguments.contains("--ui-testing")
    let settingsRepository: any SettingsStoring
    if isUITesting,
      let suiteName = process.environment["SPEAKNOTE_UI_TEST_SETTINGS_SUITE"],
      !suiteName.isEmpty,
      let defaults = UserDefaults(suiteName: suiteName)
    {
      defaults.removePersistentDomain(forName: suiteName)
      settingsRepository =
        (try? SettingsRepository(suiteName: suiteName))
        ?? SettingsRepository()
    } else {
      settingsRepository = SettingsRepository()
    }
    let storageRootURL = process.environment["SPEAKNOTE_UI_TEST_STORAGE_ROOT"]
      .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    let isTestHost =
      process.environment["XCTestConfigurationFilePath"] != nil
      || isUITesting
    let bootstrap = ApplicationBootstrap(startsServices: !isTestHost) {
      try DependencyContainer.live(
        settingsRepository: settingsRepository,
        usesEphemeralStorage: isUITesting,
        storageRootURL: isUITesting ? storageRootURL : nil
      )
    }
    _bootstrap = StateObject(
      wrappedValue: bootstrap
    )
    appDelegate.launchHandler = {
      bootstrap.startIfNeeded()
    }
    appDelegate.shutdownHandler = {
      await bootstrap.prepareForTermination()
    }
    appDelegate.sleepHandler = {
      await bootstrap.handleSystemSleep()
    }
  }

  var body: some Scene {
    WindowGroup("SpeakNote", id: "main") {
      ApplicationRootView(bootstrap: bootstrap)
    }
    .defaultSize(width: 760, height: 520)

    MenuBarExtra {
      ApplicationMenuBarContentView(bootstrap: bootstrap)
    } label: {
      LaunchWindowMenuBarLabel()
    }

    Settings {
      ApplicationSettingsRootView(bootstrap: bootstrap)
    }
  }
}

@MainActor
private final class ApplicationBootstrap: ObservableObject {
  @Published private(set) var dependencies: DependencyContainer?

  private let startsServices: Bool
  private let build: () throws -> DependencyContainer

  init(
    startsServices: Bool,
    build: @escaping () throws -> DependencyContainer
  ) {
    self.startsServices = startsServices
    self.build = build
    load()
  }

  func retry() {
    load()
    startIfNeeded()
  }

  func startIfNeeded() {
    guard startsServices else { return }
    dependencies?.start()
  }

  func prepareForTermination() async {
    await dependencies?.prepareForTermination()
  }

  func handleSystemSleep() async {
    await dependencies?.handleSystemSleep()
  }

  private func load() {
    do {
      dependencies = try build()
    } catch {
      dependencies = nil
      SecureLogger.error(.storageInitializationFailed)
    }
  }
}

private struct ApplicationRootView: View {
  @ObservedObject var bootstrap: ApplicationBootstrap

  var body: some View {
    if let dependencies = bootstrap.dependencies {
      MainView(
        appCoordinator: dependencies.appCoordinator,
        dictationCoordinator: dependencies.dictationCoordinator,
        historyCoordinator: dependencies.dictationHistoryCoordinator,
        voiceNoteCoordinator: dependencies.voiceNoteCoordinator,
        vocabularyCoordinator: dependencies.vocabularyCoordinator,
        onboardingCoordinator: dependencies.onboardingCoordinator
      )
    } else {
      startupFailure
    }
  }

  private var startupFailure: some View {
    StartupFailureView(
      retry: { bootstrap.retry() },
      quit: { NSApplication.shared.terminate(nil) }
    )
  }
}

private struct ApplicationMenuBarContentView: View {
  @ObservedObject var bootstrap: ApplicationBootstrap

  var body: some View {
    if let dependencies = bootstrap.dependencies {
      MenuBarContentView(
        coordinator: dependencies.appCoordinator,
        dictationCoordinator: dependencies.dictationCoordinator,
        voiceNoteCoordinator: dependencies.voiceNoteCoordinator
      )
    } else {
      Button("Try Again") {
        bootstrap.retry()
      }
      Button("Quit SpeakNote") {
        NSApplication.shared.terminate(nil)
      }
    }
  }
}

private struct ApplicationSettingsRootView: View {
  @ObservedObject var bootstrap: ApplicationBootstrap

  var body: some View {
    if let dependencies = bootstrap.dependencies {
      SettingsView(
        coordinator: dependencies.settingsCoordinator,
        permissionCenter: dependencies.permissionCenter,
        appCoordinator: dependencies.appCoordinator
      )
    } else {
      StartupFailureView(
        retry: { bootstrap.retry() },
        quit: { NSApplication.shared.terminate(nil) }
      )
    }
  }
}

private struct StartupFailureView: View {
  let retry: () -> Void
  let quit: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "externaldrive.badge.exclamationmark")
        .font(.system(size: 42))
        .foregroundStyle(.secondary)
      Text("SpeakNote Couldn't Start")
        .font(.title)
      Text(
        "SpeakNote couldn't open its local data. Check available disk space and folder permissions, then try again."
      )
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      HStack {
        Button("Quit SpeakNote", action: quit)
        Button("Try Again", action: retry)
          .keyboardShortcut(.defaultAction)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }
}

private struct LaunchWindowMenuBarLabel: View {
  @Environment(\.openWindow) private var openWindow
  @State private var hasOpenedInitialWindow = false

  var body: some View {
    Label("SpeakNote", systemImage: "mic.fill")
      .task {
        guard #available(macOS 15.0, *) else { return }
        guard !hasOpenedInitialWindow else { return }
        hasOpenedInitialWindow = true
        await Task.yield()
        openWindow(id: "main")
      }
  }
}

private struct MainView: View {
  let appCoordinator: AppCoordinator
  let dictationCoordinator: DictationCoordinator
  let historyCoordinator: DictationHistoryCoordinator
  let voiceNoteCoordinator: VoiceNoteCoordinator
  let vocabularyCoordinator: VocabularyCoordinator
  @ObservedObject var onboardingCoordinator: OnboardingCoordinator

  var body: some View {
    TabView {
      quickDictation
        .tabItem {
          Label("Quick Dictation", systemImage: "waveform")
        }

      DictationHistoryView(coordinator: historyCoordinator)
        .tabItem {
          Label("History", systemImage: "clock.arrow.circlepath")
        }

      VoiceNoteListView(coordinator: voiceNoteCoordinator)
        .tabItem {
          Label("Voice Notes", systemImage: "doc.text.magnifyingglass")
        }

      VocabularyView(coordinator: vocabularyCoordinator)
        .tabItem {
          Label("Vocabulary", systemImage: "text.book.closed")
        }
    }
    .task {
      await onboardingCoordinator.load()
    }
    .sheet(isPresented: onboardingPresentation) {
      OnboardingView(coordinator: onboardingCoordinator)
    }
  }

  private var onboardingPresentation: Binding<Bool> {
    Binding(
      get: { onboardingCoordinator.isPresented },
      set: { _ in }
    )
  }

  private var quickDictation: some View {
    VStack(spacing: 16) {
      Image(systemName: "waveform")
        .font(.system(size: 42))
      Text("SpeakNote")
        .font(.largeTitle)
      Text(stateDescription)
        .foregroundStyle(.secondary)

      Text(appCoordinator.hotkeyDescription)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      if let hotkeyError = appCoordinator.hotkeyErrorMessage {
        Text(hotkeyError)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
      }

      Text("Place the cursor in another app, then use the global hotkey to start and stop.")
        .font(.callout)
        .multilineTextAlignment(.center)

      if canToggleDictation {
        Button(dictationToggleTitle) {
          dictationCoordinator.toggleForManualCopy()
        }
      }

      if isDictationActive {
        Button("Cancel Active Dictation") {
          dictationCoordinator.cancel()
        }
      }

      if let fallbackDescription = dictationCoordinator.fallbackOfferDescription {
        Text(fallbackDescription)
          .font(.callout)
          .multilineTextAlignment(.center)
        HStack {
          Button("Use Alternative") {
            dictationCoordinator.acceptTranscriptionFallback()
          }
          Button("Decline", role: .cancel) {
            dictationCoordinator.declineTranscriptionFallback()
          }
        }
      }

      if dictationCoordinator.manualCopyText != nil {
        Button("Copy Last Transcript") {
          dictationCoordinator.copyManualTranscript()
        }
      }

      SettingsLink {
        Label("Open Settings", systemImage: "gear")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  private var isDictationActive: Bool {
    return switch dictationCoordinator.state {
    case .preparing, .stopping, .transcribing, .processing, .inserting, .cancelling:
      true
    case .recording:
      true
    case .idle, .success, .failure, .cancelled:
      false
    }
  }

  private var canToggleDictation: Bool {
    switch dictationCoordinator.state {
    case .idle, .recording, .success, .failure, .cancelled:
      true
    case .preparing, .stopping, .transcribing, .processing, .inserting, .cancelling:
      false
    }
  }

  private var dictationToggleTitle: String {
    if case .recording = dictationCoordinator.state {
      return String(localized: "Stop Dictation")
    }
    return String(localized: "Start Dictation")
  }

  private var stateDescription: String {
    if let fallbackDescription = dictationCoordinator.fallbackOfferDescription {
      return fallbackDescription
    }
    return switch dictationCoordinator.state {
    case .idle:
      String(localized: "Ready for quick dictation.")
    case .preparing:
      String(localized: "Preparing microphone…")
    case .recording:
      String(localized: "Recording. Trigger the hotkey again to stop.")
    case .stopping:
      String(localized: "Finishing audio…")
    case .transcribing:
      String(localized: "Transcribing audio…")
    case .processing:
      String(localized: "Processing the transcript…")
    case .inserting:
      String(localized: "Pasting into the original text field…")
    case .cancelling:
      String(localized: "Cancelling and cleaning up…")
    case .success:
      String(localized: "The last dictation was sent to the target app.")
    case .failure(let message):
      message
    case .cancelled:
      String(localized: "The last dictation was cancelled.")
    }
  }
}

private struct MenuBarContentView: View {
  @Environment(\.openWindow) private var openWindow
  let coordinator: AppCoordinator
  let dictationCoordinator: DictationCoordinator
  @ObservedObject var voiceNoteCoordinator: VoiceNoteCoordinator

  var body: some View {
    if let fallbackDescription = dictationCoordinator.fallbackOfferDescription {
      Text(fallbackDescription)
      Button("Use Alternative") {
        dictationCoordinator.acceptTranscriptionFallback()
      }
      Button("Decline Alternative") {
        dictationCoordinator.declineTranscriptionFallback()
      }
    } else {
      switch dictationCoordinator.state {
      case .preparing, .stopping, .transcribing, .processing, .inserting:
        Button("Cancel Dictation") {
          dictationCoordinator.cancel()
        }
      case .cancelling:
        Text("Cancelling…")
      case .recording:
        Button("Stop Dictation") {
          dictationCoordinator.toggle()
        }
        Button("Cancel Recording") {
          dictationCoordinator.cancel()
        }
      case .idle, .success, .failure, .cancelled:
        Text(coordinator.hotkeyDescription)
        Button("Start Dictation") {
          dictationCoordinator.toggle()
        }
      }
    }

    if dictationCoordinator.manualCopyText != nil {
      Button("Copy Last Transcript") {
        dictationCoordinator.copyManualTranscript()
      }
    }

    Divider()

    switch voiceNoteCoordinator.recordingState {
    case .recording:
      Button("Finish Voice Note") {
        Task { await voiceNoteCoordinator.finishRecording() }
      }
      Button("Pause Voice Note") {
        Task { await voiceNoteCoordinator.pauseRecording() }
      }
    case .paused:
      Button("Finish Voice Note") {
        Task { await voiceNoteCoordinator.finishRecording() }
      }
      Button("Resume Voice Note") {
        Task { await voiceNoteCoordinator.resumeRecording() }
      }
    case .preparing, .finalizing:
      Text("Saving Voice Note…")
    case .idle, .processing, .recoveryAvailable, .failed:
      Button {
        openWindow(id: "main")
        coordinator.activate()
        Task { await voiceNoteCoordinator.startRecording() }
      } label: {
        Label("New Voice Note", systemImage: "waveform.circle")
      }
    }

    Divider()

    Button {
      openWindow(id: "main")
      coordinator.activate()
    } label: {
      Label("Open SpeakNote", systemImage: "macwindow")
    }

    SettingsLink {
      Label("Settings", systemImage: "gear")
    }

    Divider()

    Button {
      coordinator.terminate()
    } label: {
      Label("Quit SpeakNote", systemImage: "power")
    }
    .keyboardShortcut("q")
  }
}
