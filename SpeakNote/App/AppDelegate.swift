import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var launchHandler: (@MainActor @Sendable () -> Void)?
  var shutdownHandler: (@MainActor @Sendable () async -> Void)?
  var sleepHandler: (@MainActor @Sendable () async -> Void)?
  private var terminationTask: Task<Void, Never>?
  private var sleepObserver: NSObjectProtocol?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
    sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        await self?.sleepHandler?()
      }
    }
    launchHandler?()
  }

  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    false
  }

  func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    guard let shutdownHandler else {
      return .terminateNow
    }
    guard terminationTask == nil else {
      return .terminateLater
    }

    terminationTask = Task { [weak self] in
      await shutdownHandler()
      sender.reply(toApplicationShouldTerminate: true)
      self?.terminationTask = nil
    }
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let sleepObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
      self.sleepObserver = nil
    }
  }
}
