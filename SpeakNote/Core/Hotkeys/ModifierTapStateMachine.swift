import Foundation

struct ModifierTapStateMachine: Sendable {
  struct Configuration: Equatable, Sendable {
    var targetKeyCode: UInt16 = 61
    var minimumPressDuration: TimeInterval = 0.030
    var maximumPressDuration: TimeInterval = 0.700
    var debounceInterval: TimeInterval = 0.250
  }

  enum Input: Equatable, Sendable {
    case flagsChanged(
      keyCode: UInt16,
      isPressed: Bool,
      hasOtherModifiers: Bool,
      timestamp: TimeInterval
    )
    case otherKeyActivity(timestamp: TimeInterval)
  }

  private let configuration: Configuration
  private var pressedAt: TimeInterval?
  private var isDisarmed = false
  private var lastTriggerAt: TimeInterval?

  init(configuration: Configuration = Configuration()) {
    self.configuration = configuration
  }

  mutating func handle(_ input: Input) -> Bool {
    handleTimed(input)
  }

  mutating func reset() {
    pressedAt = nil
    isDisarmed = false
  }

  private mutating func handleTimed(_ input: Input) -> Bool {
    let timestamp: TimeInterval
    switch input {
    case .flagsChanged(_, _, _, let eventTimestamp),
      .otherKeyActivity(let eventTimestamp):
      timestamp = eventTimestamp
    }

    if let pressedAt,
      timestamp < pressedAt || timestamp - pressedAt > configuration.maximumPressDuration
    {
      reset()
    }

    switch input {
    case .flagsChanged(let keyCode, let isPressed, let hasOtherModifiers, let timestamp):
      guard keyCode == configuration.targetKeyCode else {
        if pressedAt != nil {
          isDisarmed = true
        }
        return false
      }

      if isPressed {
        guard pressedAt == nil else { return false }
        self.pressedAt = timestamp
        isDisarmed = hasOtherModifiers
        return false
      }

      guard let pressedAt else { return false }
      defer { reset() }
      let duration = timestamp - pressedAt
      guard !isDisarmed,
        !hasOtherModifiers,
        duration >= configuration.minimumPressDuration,
        duration <= configuration.maximumPressDuration
      else {
        return false
      }
      if let lastTriggerAt,
        timestamp - lastTriggerAt < configuration.debounceInterval
      {
        return false
      }
      lastTriggerAt = timestamp
      return true

    case .otherKeyActivity:
      if pressedAt != nil {
        isDisarmed = true
      }
      return false
    }
  }
}
