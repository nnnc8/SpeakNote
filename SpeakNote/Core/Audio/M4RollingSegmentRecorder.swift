import Foundation

struct M4RecordingSegment: Codable, Equatable, Identifiable, Sendable {
  var id: Int { index }

  let sessionID: UUID
  let index: Int
  let url: URL
  let relativePath: String
  let startTime: TimeInterval
  let endTime: TimeInterval
  let byteCount: Int64
  let sha256: String
  let createdAt: Date
}

struct M4RecordingMeter: Equatable, Sendable {
  let elapsedTime: TimeInterval
  let averagePower: Float
  let peakPower: Float
}

struct M4RollingRecordingResult: Equatable, Sendable {
  let sessionID: UUID
  let segments: [M4RecordingSegment]

  var duration: TimeInterval {
    segments.last?.endTime ?? 0
  }
}

enum M4RecordingInterruptionReason: Equatable, Sendable {
  case appSuspended
  case systemInterruption
  case deviceLost
  case userRequested
}

enum M4RollingRecorderFailure: Error, Equatable, Sendable {
  case alreadyActive
  case invalidState
  case invalidConfiguration
  case permissionDenied
  case invalidInputFormat
  case bufferOverrun
  case deviceLost
  case recoveryRequired
  case cancelled
  case captureFailed(String)
  case diskWriteFailed(String)
}

enum M4RollingRecorderState: Equatable, Sendable {
  case idle
  case preparing(sessionID: UUID)
  case recording(sessionID: UUID, startedAt: Date)
  case paused(sessionID: UUID, startedAt: Date)
  case stopping(sessionID: UUID)
  case interrupted(sessionID: UUID, reason: M4RecordingInterruptionReason)
  case failed(sessionID: UUID?, failure: M4RollingRecorderFailure)
}

enum M4RollingRecorderEvent: Equatable, Sendable {
  case stateChanged(M4RollingRecorderState)
  case meter(M4RecordingMeter)
  case segmentClosed(M4RecordingSegment)
}

struct M4RollingCaptureConfiguration: Equatable, Sendable {
  let sessionID: UUID
  let directory: URL
  let segmentDuration: TimeInterval
}

enum M4RollingCaptureEvent: Equatable, Sendable {
  case meter(M4RecordingMeter)
  case segmentClosed(M4RecordingSegment)
}

protocol M4RollingCaptureEngine: Sendable {
  func start(
    configuration: M4RollingCaptureConfiguration
  ) async throws -> AsyncThrowingStream<M4RollingCaptureEvent, Error>
  func pause() async throws
  func resume() async throws
  func stop() async
  func cancel() async
}

protocol M4RollingSegmentRecording: Sendable {
  var events: AsyncStream<M4RollingRecorderEvent> { get }

  func currentState() async -> M4RollingRecorderState
  func start(sessionID: UUID, directory: URL) async throws
  func pause() async throws
  func resume() async throws
  func stop() async throws -> M4RollingRecordingResult
  func cancel() async
  func interrupt(reason: M4RecordingInterruptionReason) async
}

actor M4RollingSegmentRecorder: M4RollingSegmentRecording {
  static let defaultSegmentDuration: TimeInterval = 5 * 60

  nonisolated let events: AsyncStream<M4RollingRecorderEvent>

  private let capture: any M4RollingCaptureEngine
  private let segmentDuration: TimeInterval
  private let eventContinuation: AsyncStream<M4RollingRecorderEvent>.Continuation
  private var state: M4RollingRecorderState = .idle
  private var sessionID: UUID?
  private var startedAt: Date?
  private var closedSegments: [M4RecordingSegment] = []
  private var monitorTask: Task<Void, Never>?

  init(
    capture: any M4RollingCaptureEngine = M4AVFoundationRollingCaptureEngine(),
    segmentDuration: TimeInterval = defaultSegmentDuration
  ) {
    let stream = AsyncStream<M4RollingRecorderEvent>.makeStream(
      bufferingPolicy: .bufferingOldest(256)
    )
    events = stream.stream
    eventContinuation = stream.continuation
    self.capture = capture
    self.segmentDuration = segmentDuration
  }

  deinit {
    eventContinuation.finish()
  }

  func currentState() -> M4RollingRecorderState {
    state
  }

  func start(sessionID: UUID, directory: URL) async throws {
    guard state == .idle else {
      throw M4RollingRecorderFailure.alreadyActive
    }
    guard directory.isFileURL,
      segmentDuration.isFinite,
      segmentDuration > 0
    else {
      throw M4RollingRecorderFailure.invalidConfiguration
    }

    self.sessionID = sessionID
    startedAt = Date()
    closedSegments = []
    setState(.preparing(sessionID: sessionID))

    do {
      let stream = try await capture.start(
        configuration: M4RollingCaptureConfiguration(
          sessionID: sessionID,
          directory: directory,
          segmentDuration: segmentDuration
        )
      )
      let startedAt = self.startedAt ?? Date()
      setState(.recording(sessionID: sessionID, startedAt: startedAt))
      monitorTask = Task { [weak self] in
        await self?.monitor(stream, sessionID: sessionID)
      }
    } catch {
      let failure = Self.failure(from: error)
      setState(.failed(sessionID: sessionID, failure: failure))
      throw failure
    }
  }

  func pause() async throws {
    guard case .recording(let sessionID, let startedAt) = state else {
      throw M4RollingRecorderFailure.invalidState
    }
    do {
      try await capture.pause()
      setState(.paused(sessionID: sessionID, startedAt: startedAt))
    } catch {
      try await fail(error, sessionID: sessionID)
    }
  }

  func resume() async throws {
    guard case .paused(let sessionID, let startedAt) = state else {
      throw M4RollingRecorderFailure.invalidState
    }
    do {
      try await capture.resume()
      setState(.recording(sessionID: sessionID, startedAt: startedAt))
    } catch {
      try await fail(error, sessionID: sessionID)
    }
  }

  func stop() async throws -> M4RollingRecordingResult {
    guard let sessionID, Self.canStop(state) else {
      throw M4RollingRecorderFailure.invalidState
    }
    setState(.stopping(sessionID: sessionID))
    await capture.stop()
    await monitorTask?.value
    monitorTask = nil

    if case .failed(_, let failure) = state {
      throw failure
    }
    let result = M4RollingRecordingResult(
      sessionID: sessionID,
      segments: closedSegments.sorted { $0.index < $1.index }
    )
    reset()
    return result
  }

  func cancel() async {
    guard state != .idle else { return }
    monitorTask?.cancel()
    await capture.cancel()
    await monitorTask?.value
    monitorTask = nil
    reset()
  }

  func interrupt(reason: M4RecordingInterruptionReason) async {
    guard let sessionID, Self.isActive(state) else { return }
    setState(.interrupted(sessionID: sessionID, reason: reason))
    await capture.stop()
    await monitorTask?.value
    monitorTask = nil
    if case .failed = state {
      return
    }
    setState(.interrupted(sessionID: sessionID, reason: reason))
  }

  private func monitor(
    _ stream: AsyncThrowingStream<M4RollingCaptureEvent, Error>,
    sessionID: UUID
  ) async {
    do {
      for try await event in stream {
        guard !Task.isCancelled else { return }
        switch event {
        case .meter(let meter):
          eventContinuation.yield(.meter(meter))
        case .segmentClosed(let segment):
          try forwardClosedSegment(segment)
          closedSegments.removeAll { $0.index == segment.index }
          closedSegments.append(segment)
        }
      }
    } catch {
      guard !Task.isCancelled else { return }
      let failure = Self.failure(from: error)
      await capture.stop()
      if failure == .deviceLost {
        setState(.interrupted(sessionID: sessionID, reason: .deviceLost))
      } else if failure != .cancelled {
        setState(.failed(sessionID: sessionID, failure: failure))
      }
    }
  }

  private func fail(_ error: Error, sessionID: UUID) async throws -> Never {
    let failure = Self.failure(from: error)
    await capture.stop()
    setState(.failed(sessionID: sessionID, failure: failure))
    throw failure
  }

  private func forwardClosedSegment(_ segment: M4RecordingSegment) throws {
    switch eventContinuation.yield(.segmentClosed(segment)) {
    case .enqueued:
      return
    case .dropped:
      throw M4RollingRecorderFailure.bufferOverrun
    case .terminated:
      throw M4RollingRecorderFailure.cancelled
    @unknown default:
      throw M4RollingRecorderFailure.bufferOverrun
    }
  }

  private func setState(_ newState: M4RollingRecorderState) {
    state = newState
    eventContinuation.yield(.stateChanged(newState))
  }

  private func reset() {
    sessionID = nil
    startedAt = nil
    closedSegments = []
    setState(.idle)
  }

  private static func isActive(_ state: M4RollingRecorderState) -> Bool {
    switch state {
    case .preparing, .recording, .paused:
      true
    case .idle, .stopping, .interrupted, .failed:
      false
    }
  }

  private static func canStop(_ state: M4RollingRecorderState) -> Bool {
    switch state {
    case .recording, .paused, .interrupted:
      true
    case .idle, .preparing, .stopping, .failed:
      false
    }
  }

  private static func failure(from error: Error) -> M4RollingRecorderFailure {
    if let failure = error as? M4RollingRecorderFailure {
      return failure
    }
    if error is CancellationError {
      return .cancelled
    }
    return .captureFailed(error.localizedDescription)
  }
}
