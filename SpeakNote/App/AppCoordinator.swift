import AppKit
import Observation

@MainActor
@Observable
final class AppCoordinator {
  let dictationCoordinator: DictationCoordinator
  private(set) var hotkeyDescription = String(localized: "Hotkey is not running.")
  private(set) var hotkeyErrorMessage: String?

  @ObservationIgnored private let hotkeyMonitor: GlobalHotkeyMonitor
  @ObservationIgnored private var isStarted = false

  init(
    hotkeyMonitor: GlobalHotkeyMonitor,
    dictationCoordinator: DictationCoordinator
  ) {
    self.hotkeyMonitor = hotkeyMonitor
    self.dictationCoordinator = dictationCoordinator
  }

  func start() {
    guard !isStarted else { return }
    installHotkeyMonitor()
  }

  func refreshHotkey() {
    installHotkeyMonitor()
  }

  func activate() {
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  func terminate() {
    NSApplication.shared.terminate(nil)
  }

  func prepareForTermination() async {
    hotkeyMonitor.stop()
    isStarted = false
    await dictationCoordinator.shutdown()
  }

  private func installHotkeyMonitor() {
    do {
      try hotkeyMonitor.start { [weak dictationCoordinator] action in
        dictationCoordinator?.handle(action)
      }
      isStarted = true
      hotkeyErrorMessage = nil
      hotkeyDescription =
        hotkeyMonitor.usesFallbackHotkey
        ? String(
          localized:
            "Shift-Command-Space fallback. Grant Input Monitoring for Right Option and Esc."
        )
        : String(localized: "Right Option tap. Esc cancels an active dictation.")
    } catch {
      isStarted = false
      hotkeyDescription = String(localized: "Hotkey is unavailable.")
      hotkeyErrorMessage =
        String(
          localized:
            "SpeakNote could not register a global hotkey. Quit conflicting apps and retry."
        )
      SecureLogger.error(.hotkeySetupFailed)
    }
  }
}
