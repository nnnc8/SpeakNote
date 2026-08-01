import AppKit
import Carbon.HIToolbox
import CoreGraphics

enum HotkeyAction: Sendable {
  case toggleDictation
  case cancel
}

@MainActor
final class GlobalHotkeyMonitor: NSObject {
  typealias ActionHandler = @MainActor @Sendable (HotkeyAction) -> Void

  private var stateMachine = ModifierTapStateMachine()
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandlerRef: EventHandlerRef?
  private var actionHandler: ActionHandler?
  private var lastFallbackTriggerAt: TimeInterval?
  private(set) var usesFallbackHotkey = false

  func start(actionHandler: @escaping ActionHandler) throws {
    stop()
    self.actionHandler = actionHandler
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(cancelForSystemSleep),
      name: NSWorkspace.willSleepNotification,
      object: nil
    )
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(resetForSystemTransition),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )

    if CGPreflightListenEventAccess(), installListenOnlyEventTap() {
      usesFallbackHotkey = false
      return
    }

    try installCarbonFallback()
    usesFallbackHotkey = true
  }

  func stop() {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    stateMachine.reset()
    lastFallbackTriggerAt = nil
    actionHandler = nil

    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
    }
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
    self.eventTap = nil
    runLoopSource = nil

    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
    }
    if let eventHandlerRef {
      RemoveEventHandler(eventHandlerRef)
    }
    hotKeyRef = nil
    eventHandlerRef = nil
    usesFallbackHotkey = false
  }

  private func installListenOnlyEventTap() -> Bool {
    let eventMask =
      (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
      | (CGEventMask(1) << CGEventType.keyDown.rawValue)
    let userInfo = Unmanaged.passUnretained(self).toOpaque()

    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: eventMask,
        callback: { _, type, event, userInfo in
          guard let userInfo else {
            return Unmanaged.passUnretained(event)
          }
          let monitor = Unmanaged<GlobalHotkeyMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
          MainActor.assumeIsolated {
            monitor.handleEvent(type: type, event: event)
          }
          return Unmanaged.passUnretained(event)
        },
        userInfo: userInfo
      ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    else {
      return false
    }

    eventTap = tap
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
  }

  private func handleEvent(type: CGEventType, event: CGEvent) {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      stateMachine.reset()
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
      }
      return
    }

    let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

    if type == .keyDown {
      _ = stateMachine.handle(.otherKeyActivity(timestamp: timestamp))
      let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
      if keyCode == UInt16(kVK_Escape), !isRepeat {
        actionHandler?(.cancel)
      }
      return
    }

    guard type == .flagsChanged else { return }
    let flags = event.flags
    let hasOtherModifiers = !flags.intersection([
      .maskCommand,
      .maskControl,
      .maskShift,
      .maskSecondaryFn,
    ]).isEmpty
    let isPressed = flags.contains(.maskAlternate)
    if stateMachine.handle(
      .flagsChanged(
        keyCode: keyCode,
        isPressed: isPressed,
        hasOtherModifiers: hasOtherModifiers,
        timestamp: timestamp
      )
    ) {
      actionHandler?(.toggleDictation)
    }
  }

  private func installCarbonFallback() throws {
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let userInfo = Unmanaged.passUnretained(self).toOpaque()
    let handlerStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, userInfo in
        guard let userInfo else { return noErr }
        let monitor = Unmanaged<GlobalHotkeyMonitor>
          .fromOpaque(userInfo)
          .takeUnretainedValue()
        MainActor.assumeIsolated {
          monitor.handleFallbackHotkey()
        }
        return noErr
      },
      1,
      &eventType,
      userInfo,
      &eventHandlerRef
    )
    guard handlerStatus == noErr else {
      throw HotkeyMonitorError.carbonRegistrationFailed(handlerStatus)
    }

    let identifier = EventHotKeyID(signature: OSType(0x534E_4F54), id: 1)
    let hotKeyStatus = RegisterEventHotKey(
      UInt32(kVK_Space),
      UInt32(cmdKey | shiftKey),
      identifier,
      GetApplicationEventTarget(),
      0,
      &hotKeyRef
    )
    guard hotKeyStatus == noErr else {
      if let eventHandlerRef {
        RemoveEventHandler(eventHandlerRef)
        self.eventHandlerRef = nil
      }
      throw HotkeyMonitorError.carbonRegistrationFailed(hotKeyStatus)
    }
  }

  @objc private func cancelForSystemSleep() {
    stateMachine.reset()
    lastFallbackTriggerAt = nil
    actionHandler?(.cancel)
  }

  @objc private func resetForSystemTransition() {
    stateMachine.reset()
    lastFallbackTriggerAt = nil
  }

  private func handleFallbackHotkey() {
    let now = ProcessInfo.processInfo.systemUptime
    if let lastFallbackTriggerAt, now - lastFallbackTriggerAt < 0.250 {
      return
    }
    lastFallbackTriggerAt = now
    actionHandler?(.toggleDictation)
  }
}

enum HotkeyMonitorError: Error, Equatable {
  case carbonRegistrationFailed(OSStatus)
}
