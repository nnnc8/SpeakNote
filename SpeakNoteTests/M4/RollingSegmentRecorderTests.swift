import AVFAudio
import Foundation
import XCTest

@testable import SpeakNote

@MainActor
final class RollingSegmentRecorderTests: XCTestCase {
  func testLifecycleForwardsMeterAndReturnsClosedSegments() async throws {
    let capture = M4FakeCaptureEngine()
    let recorder = M4RollingSegmentRecorder(capture: capture, segmentDuration: 30)
    let sessionID = UUID()
    let directory = URL(fileURLWithPath: "/tmp/m4-recorder-test")
    let meterTask = Task<M4RecordingMeter?, Never> {
      for await event in recorder.events {
        if case .meter(let meter) = event {
          return meter
        }
      }
      return nil
    }

    try await recorder.start(sessionID: sessionID, directory: directory)
    guard case .recording(let activeID, _) = await recorder.currentState() else {
      return XCTFail("Recorder must enter recording state.")
    }
    XCTAssertEqual(activeID, sessionID)

    let meter = M4RecordingMeter(
      elapsedTime: 1,
      averagePower: -18,
      peakPower: -4
    )
    let segment = makeSegment(sessionID: sessionID, index: 0)
    await capture.emit(.meter(meter))
    await capture.emit(.segmentClosed(segment))

    try await recorder.pause()
    guard case .paused(let pausedID, _) = await recorder.currentState() else {
      return XCTFail("Recorder must enter paused state.")
    }
    XCTAssertEqual(pausedID, sessionID)
    try await recorder.resume()

    let result = try await recorder.stop()
    let observedMeter = await meterTask.value
    XCTAssertEqual(result, M4RollingRecordingResult(sessionID: sessionID, segments: [segment]))
    XCTAssertEqual(observedMeter, meter)
    let finalState = await recorder.currentState()
    XCTAssertEqual(finalState, .idle)
    let snapshot = await capture.snapshot()
    XCTAssertEqual(snapshot.segmentDuration, 30)
    XCTAssertEqual(snapshot.pauseCount, 1)
    XCTAssertEqual(snapshot.resumeCount, 1)
    XCTAssertEqual(snapshot.stopCount, 1)
  }

  func testInterruptionFinalizesWithoutDiscardingClosedSegments() async throws {
    let capture = M4FakeCaptureEngine()
    let recorder = M4RollingSegmentRecorder(capture: capture)
    let sessionID = UUID()
    try await recorder.start(
      sessionID: sessionID,
      directory: URL(fileURLWithPath: "/tmp/m4-interruption-test")
    )
    let segment = makeSegment(sessionID: sessionID, index: 0)
    await capture.emit(.segmentClosed(segment))

    await recorder.interrupt(reason: .appSuspended)

    let interruptedState = await recorder.currentState()
    XCTAssertEqual(
      interruptedState,
      .interrupted(sessionID: sessionID, reason: .appSuspended)
    )
    let result = try await recorder.stop()
    XCTAssertEqual(result.segments, [segment])
  }

  func testDeviceLossHasExplicitInterruptedState() async throws {
    let capture = M4FakeCaptureEngine()
    let recorder = M4RollingSegmentRecorder(capture: capture)
    let sessionID = UUID()
    try await recorder.start(
      sessionID: sessionID,
      directory: URL(fileURLWithPath: "/tmp/m4-device-test")
    )

    await capture.fail(.deviceLost)
    let state = await waitForTerminalState(recorder)

    XCTAssertEqual(
      state,
      .interrupted(sessionID: sessionID, reason: .deviceLost)
    )
  }

  func testCancelReturnsToIdleAndDelegatesCleanup() async throws {
    let capture = M4FakeCaptureEngine()
    let recorder = M4RollingSegmentRecorder(capture: capture)
    try await recorder.start(
      sessionID: UUID(),
      directory: URL(fileURLWithPath: "/tmp/m4-cancel-test")
    )

    await recorder.cancel()

    let finalState = await recorder.currentState()
    let snapshot = await capture.snapshot()
    XCTAssertEqual(finalState, .idle)
    XCTAssertEqual(snapshot.cancelCount, 1)
  }

  func testTwoHourSyntheticCaptureKeepsEveryFiveMinuteSegment() async throws {
    let capture = M4FakeCaptureEngine()
    let recorder = M4RollingSegmentRecorder(
      capture: capture,
      segmentDuration: 5 * 60
    )
    let sessionID = UUID()
    try await recorder.start(
      sessionID: sessionID,
      directory: URL(fileURLWithPath: "/tmp/m4-two-hour-test")
    )

    for index in 0..<24 {
      let start = TimeInterval(index * 5 * 60)
      await capture.emit(
        .segmentClosed(
          M4RecordingSegment(
            sessionID: sessionID,
            index: index,
            url: URL(fileURLWithPath: "/tmp/capture-\(index).caf"),
            relativePath: "capture-\(index).caf",
            startTime: start,
            endTime: start + 5 * 60,
            byteCount: 10,
            sha256: "fixture-\(index)",
            createdAt: Date(timeIntervalSince1970: start)
          )
        )
      )
    }

    let result = try await recorder.stop()

    XCTAssertEqual(result.segments.map(\.index), Array(0..<24))
    XCTAssertEqual(result.duration, 2 * 60 * 60)
  }

  func testStalledEventConsumerFailsClosedBeforeHidingSegment() async throws {
    let capture = M4FakeCaptureEngine()
    let recorder = M4RollingSegmentRecorder(capture: capture)
    let sessionID = UUID()
    try await recorder.start(
      sessionID: sessionID,
      directory: URL(fileURLWithPath: "/tmp/m4-stalled-consumer-test")
    )

    let meter = M4RecordingMeter(
      elapsedTime: 1,
      averagePower: -18,
      peakPower: -4
    )
    for _ in 0..<300 {
      await capture.emit(.meter(meter))
    }
    await capture.emit(.segmentClosed(makeSegment(sessionID: sessionID, index: 0)))

    let state = await waitForTerminalState(recorder)
    XCTAssertEqual(
      state,
      .failed(sessionID: sessionID, failure: .bufferOverrun)
    )
    let snapshot = await capture.snapshot()
    XCTAssertEqual(snapshot.stopCount, 1)
  }

  func testProductionWriterRollsImmutableSegments() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sessionID = UUID()
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
      )
    )
    let writer = try M4RollingFileWriter(
      configuration: M4RollingCaptureConfiguration(
        sessionID: sessionID,
        directory: directory,
        segmentDuration: 0.1
      ),
      format: format
    )
    let queue = M4AudioBufferQueue(capacity: 8)
    let stream = AsyncThrowingStream<M4RollingCaptureEvent, Error>.makeStream()
    let writerTask = Task.detached {
      do {
        try writer.writeAll(from: queue, continuation: stream.continuation)
        stream.continuation.finish()
      } catch {
        stream.continuation.finish(throwing: error)
        throw error
      }
    }

    for _ in 0..<4 {
      queue.enqueueCopy(of: try makeBuffer(format: format, frameCount: 800))
    }
    queue.finish()
    try await writerTask.value

    var segments: [M4RecordingSegment] = []
    var meters: [M4RecordingMeter] = []
    for try await event in stream.stream {
      switch event {
      case .segmentClosed(let segment):
        segments.append(segment)
      case .meter(let meter):
        meters.append(meter)
      }
    }
    XCTAssertEqual(segments.map(\.index), [0, 1])
    XCTAssertEqual(segments[0].startTime, 0, accuracy: 0.001)
    XCTAssertEqual(segments[0].endTime, 0.1, accuracy: 0.001)
    XCTAssertEqual(segments[1].startTime, 0.1, accuracy: 0.001)
    XCTAssertEqual(segments[1].endTime, 0.2, accuracy: 0.001)
    XCTAssertTrue(segments.allSatisfy { $0.sha256.count == 64 })
    for segment in segments {
      XCTAssertEqual(
        segment.sha256,
        try M4RecordingRecovery.sha256(of: segment.url)
      )
    }
    XCTAssertEqual(meters.count, 4)
    XCTAssertTrue(meters.allSatisfy { $0.averagePower.isFinite && $0.peakPower.isFinite })
    for segment in segments {
      let attributes = try FileManager.default.attributesOfItem(
        atPath: segment.url.path
      )
      let permissions = try XCTUnwrap(
        attributes[.posixPermissions] as? NSNumber
      )
      XCTAssertEqual(permissions.intValue & 0o777, 0o400)
    }
  }

  func testProductionWriterFailsClosedBeforeDroppingClosedSegmentEvent()
    async throws
  {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
      )
    )
    let writer = try M4RollingFileWriter(
      configuration: M4RollingCaptureConfiguration(
        sessionID: UUID(),
        directory: directory,
        segmentDuration: 0.05
      ),
      format: format
    )
    let queue = M4AudioBufferQueue(capacity: 4)
    let stream = AsyncThrowingStream<M4RollingCaptureEvent, Error>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    queue.enqueueCopy(of: try makeBuffer(format: format, frameCount: 800))
    queue.enqueueCopy(of: try makeBuffer(format: format, frameCount: 800))
    queue.finish()

    do {
      try await Task.detached {
        try writer.writeAll(from: queue, continuation: stream.continuation)
      }.value
      XCTFail("A stalled event consumer must stop the writer before data is hidden.")
    } catch let failure as M4RollingRecorderFailure {
      XCTAssertEqual(failure, .bufferOverrun)
    }
    stream.continuation.finish()

    let remaining = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(
      remaining.filter { $0.pathExtension == "caf" }.map(\.lastPathComponent),
      ["capture-000000.caf"]
    )
    XCTAssertFalse(remaining.contains { $0.pathExtension == "partial" })
  }

  func testProductionWriterCancellationDeletesInvocationSegments() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
      )
    )
    let writer = try M4RollingFileWriter(
      configuration: M4RollingCaptureConfiguration(
        sessionID: UUID(),
        directory: directory,
        segmentDuration: 0.05
      ),
      format: format
    )
    let queue = M4AudioBufferQueue(capacity: 8)
    let stream = AsyncThrowingStream<M4RollingCaptureEvent, Error>.makeStream()
    for _ in 0..<3 {
      queue.enqueueCopy(of: try makeBuffer(format: format, frameCount: 800))
    }
    queue.finish(error: .cancelled)

    do {
      try await Task.detached {
        try writer.writeAll(from: queue, continuation: stream.continuation)
      }.value
      XCTFail("Cancellation must terminate the writer.")
    } catch let error as M4RollingRecorderFailure {
      XCTAssertEqual(error, .cancelled)
    }
    stream.continuation.finish()

    let remaining = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    XCTAssertTrue(remaining.isEmpty)
  }

  func testProductionWriterRequiresRecoveryBeforeReusingDirectory() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data().write(
      to: directory.appendingPathComponent("segment-000000.partial.caf")
    )
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
      )
    )

    XCTAssertThrowsError(
      try M4RollingFileWriter(
        configuration: M4RollingCaptureConfiguration(
          sessionID: UUID(),
          directory: directory,
          segmentDuration: 1
        ),
        format: format
      )
    ) { error in
      XCTAssertEqual(error as? M4RollingRecorderFailure, .recoveryRequired)
    }
  }

  private func makeSegment(sessionID: UUID, index: Int) -> M4RecordingSegment {
    M4RecordingSegment(
      sessionID: sessionID,
      index: index,
      url: URL(fileURLWithPath: "/tmp/segment-\(index).caf"),
      relativePath: "segment-\(index).caf",
      startTime: TimeInterval(index),
      endTime: TimeInterval(index + 1),
      byteCount: 10,
      sha256: "fixture-\(index)",
      createdAt: Date(timeIntervalSince1970: 100)
    )
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakNote-M4-Writer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  private func makeBuffer(
    format: AVAudioFormat,
    frameCount: Int
  ) throws -> AVAudioPCMBuffer {
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(frameCount)
      )
    )
    buffer.frameLength = AVAudioFrameCount(frameCount)
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    for frame in 0..<frameCount {
      samples[frame] = sin(Float(frame) * 0.03)
    }
    return buffer
  }

  private func waitForTerminalState(
    _ recorder: M4RollingSegmentRecorder
  ) async -> M4RollingRecorderState {
    for _ in 0..<100 {
      let state = await recorder.currentState()
      if case .interrupted = state {
        return state
      }
      if case .failed = state {
        return state
      }
      await Task.yield()
    }
    return await recorder.currentState()
  }
}

private actor M4FakeCaptureEngine: M4RollingCaptureEngine {
  struct Snapshot: Sendable {
    let segmentDuration: TimeInterval?
    let pauseCount: Int
    let resumeCount: Int
    let stopCount: Int
    let cancelCount: Int
  }

  private var continuation: AsyncThrowingStream<M4RollingCaptureEvent, Error>.Continuation?
  private var configuration: M4RollingCaptureConfiguration?
  private var pauseCount = 0
  private var resumeCount = 0
  private var stopCount = 0
  private var cancelCount = 0

  func start(
    configuration: M4RollingCaptureConfiguration
  ) async throws -> AsyncThrowingStream<M4RollingCaptureEvent, Error> {
    self.configuration = configuration
    let pair = AsyncThrowingStream<M4RollingCaptureEvent, Error>.makeStream()
    continuation = pair.continuation
    return pair.stream
  }

  func pause() async throws {
    pauseCount += 1
  }

  func resume() async throws {
    resumeCount += 1
  }

  func stop() async {
    stopCount += 1
    continuation?.finish()
    continuation = nil
  }

  func cancel() async {
    cancelCount += 1
    continuation?.finish(throwing: M4RollingRecorderFailure.cancelled)
    continuation = nil
  }

  func emit(_ event: M4RollingCaptureEvent) {
    continuation?.yield(event)
  }

  func fail(_ error: M4RollingRecorderFailure) {
    continuation?.finish(throwing: error)
    continuation = nil
  }

  func snapshot() -> Snapshot {
    Snapshot(
      segmentDuration: configuration?.segmentDuration,
      pauseCount: pauseCount,
      resumeCount: resumeCount,
      stopCount: stopCount,
      cancelCount: cancelCount
    )
  }
}
