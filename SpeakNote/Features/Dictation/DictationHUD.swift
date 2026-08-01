import AppKit

@MainActor
protocol DictationHUDPresenting: AnyObject {
  func showPreparing()
  func showRecording(startedAt: Date)
  func showTranscribing()
  func showProcessing()
  func showInserting()
  func showSuccess()
  func showFailure(_ message: String)
  func showCancelled()
  func hide()
}

@MainActor
final class DictationHUD: NSObject, DictationHUDPresenting {
  private let panel: NonActivatingHUDPanel
  private let label = NSTextField(labelWithString: "")
  private var recordingStartedAt: Date?
  private var elapsedTimer: Timer?

  override init() {
    panel = NonActivatingHUDPanel(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 72),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    super.init()

    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isMovable = false

    let effect = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
    effect.autoresizingMask = [.width, .height]
    effect.material = .hudWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = 14

    label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
    label.textColor = .labelColor
    label.alignment = .center
    label.maximumNumberOfLines = 3
    label.lineBreakMode = .byWordWrapping
    label.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
      label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
      label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
    ])
    panel.contentView = effect
  }

  func showPreparing() {
    stopElapsedTimer()
    show(message: String(localized: "Preparing microphone…"))
  }

  func showRecording(startedAt: Date) {
    recordingStartedAt = startedAt
    updateElapsed()
    elapsedTimer?.invalidate()
    elapsedTimer = Timer.scheduledTimer(
      timeInterval: 0.25,
      target: self,
      selector: #selector(updateElapsed),
      userInfo: nil,
      repeats: true
    )
    positionAndShow()
  }

  func showTranscribing() {
    stopElapsedTimer()
    show(message: String(localized: "Transcribing…"))
  }

  func showProcessing() {
    stopElapsedTimer()
    show(message: String(localized: "Processing text…"))
  }

  func showInserting() {
    stopElapsedTimer()
    show(message: String(localized: "Inserting text…"))
  }

  func showSuccess() {
    stopElapsedTimer()
    show(message: String(localized: "Done"))
  }

  func showFailure(_ message: String) {
    stopElapsedTimer()
    show(message: message)
  }

  func showCancelled() {
    stopElapsedTimer()
    show(message: String(localized: "Cancelled"))
  }

  func hide() {
    stopElapsedTimer()
    panel.orderOut(nil)
  }

  private func show(message: String) {
    label.stringValue = message
    positionAndShow()
  }

  private func positionAndShow() {
    let screen = NSApp.keyWindow?.screen ?? NSScreen.main
    if let visibleFrame = screen?.visibleFrame {
      let origin = NSPoint(
        x: visibleFrame.midX - panel.frame.width / 2,
        y: visibleFrame.minY + 42
      )
      panel.setFrameOrigin(origin)
    }
    panel.orderFrontRegardless()
  }

  @objc private func updateElapsed() {
    let elapsed = max(0, Date().timeIntervalSince(recordingStartedAt ?? Date()))
    let totalSeconds = Int(elapsed)
    label.stringValue = String(
      format: String(localized: "● Listening  %02d:%02d"),
      totalSeconds / 60,
      totalSeconds % 60
    )
  }

  private func stopElapsedTimer() {
    elapsedTimer?.invalidate()
    elapsedTimer = nil
    recordingStartedAt = nil
  }
}

@MainActor
private final class NonActivatingHUDPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
