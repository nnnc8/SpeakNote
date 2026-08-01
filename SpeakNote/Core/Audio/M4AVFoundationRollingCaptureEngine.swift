@preconcurrency import AVFAudio
import AVFoundation
import CryptoKit
import Foundation

actor M4AVFoundationRollingCaptureEngine: M4RollingCaptureEngine {
  private struct Session {
    let engine: AVAudioEngine
    let queue: M4AudioBufferQueue
    let writer: Task<Void, Never>
    let notification: M4NotificationToken
  }

  private let queueCapacity: Int
  private var session: Session?

  init(queueCapacity: Int = 128) {
    self.queueCapacity = max(1, queueCapacity)
  }

  func start(
    configuration: M4RollingCaptureConfiguration
  ) async throws -> AsyncThrowingStream<M4RollingCaptureEvent, Error> {
    guard session == nil else {
      throw M4RollingRecorderFailure.alreadyActive
    }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      throw M4RollingRecorderFailure.permissionDenied
    }

    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw M4RollingRecorderFailure.invalidInputFormat
    }
    guard
      configuration.segmentDuration.isFinite,
      configuration.segmentDuration > 0,
      configuration.segmentDuration <= Double(Int64.max) / format.sampleRate
    else {
      throw M4RollingRecorderFailure.invalidConfiguration
    }

    let stream = AsyncThrowingStream<M4RollingCaptureEvent, Error>.makeStream(
      bufferingPolicy: .bufferingNewest(256)
    )
    let queue = M4AudioBufferQueue(capacity: queueCapacity)
    let writer: M4RollingFileWriter
    do {
      writer = try M4RollingFileWriter(
        configuration: configuration,
        format: format
      )
    } catch let failure as M4RollingRecorderFailure {
      throw failure
    } catch {
      throw M4RollingRecorderFailure.diskWriteFailed(error.localizedDescription)
    }

    let writerTask = Task.detached(priority: .utility) {
      do {
        try writer.writeAll(from: queue, continuation: stream.continuation)
        stream.continuation.finish()
      } catch {
        stream.continuation.finish(throwing: error)
      }
    }

    inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) {
      buffer, _ in
      queue.enqueueCopy(of: buffer)
    }
    let token = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { _ in
      engine.stop()
      queue.finish(error: .deviceLost)
    }

    do {
      engine.prepare()
      try engine.start()
      session = Session(
        engine: engine,
        queue: queue,
        writer: writerTask,
        notification: M4NotificationToken(token)
      )
      return stream.stream
    } catch {
      NotificationCenter.default.removeObserver(token)
      inputNode.removeTap(onBus: 0)
      queue.finish(error: .captureFailed(error.localizedDescription))
      await writerTask.value
      throw M4RollingRecorderFailure.captureFailed(error.localizedDescription)
    }
  }

  func pause() async throws {
    guard let session else {
      throw M4RollingRecorderFailure.invalidState
    }
    session.engine.pause()
  }

  func resume() async throws {
    guard let session else {
      throw M4RollingRecorderFailure.invalidState
    }
    do {
      try session.engine.start()
    } catch {
      session.queue.finish(error: .captureFailed(error.localizedDescription))
      throw M4RollingRecorderFailure.captureFailed(error.localizedDescription)
    }
  }

  func stop() async {
    guard let current = session else { return }
    session = nil
    NotificationCenter.default.removeObserver(current.notification.value)
    current.engine.stop()
    current.engine.inputNode.removeTap(onBus: 0)
    current.queue.finish()
    await current.writer.value
  }

  func cancel() async {
    guard let current = session else { return }
    session = nil
    NotificationCenter.default.removeObserver(current.notification.value)
    current.engine.stop()
    current.engine.inputNode.removeTap(onBus: 0)
    current.queue.finish(error: .cancelled)
    await current.writer.value
  }
}

private final class M4NotificationToken: @unchecked Sendable {
  let value: NSObjectProtocol

  init(_ value: NSObjectProtocol) {
    self.value = value
  }
}

final class M4AudioBufferQueue: @unchecked Sendable {
  private let capacity: Int
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var slots: [AVAudioPCMBuffer?]
  private var head = 0
  private var tail = 0
  private var count = 0
  private var isFinished = false
  private var storedError: M4RollingRecorderFailure?

  init(capacity: Int) {
    self.capacity = capacity
    slots = Array(repeating: nil, count: capacity)
  }

  var error: M4RollingRecorderFailure? {
    lock.withLock { storedError }
  }

  func enqueueCopy(of source: AVAudioPCMBuffer) {
    guard
      let copy = AVAudioPCMBuffer(
        pcmFormat: source.format,
        frameCapacity: source.frameLength
      )
    else {
      finish(error: .bufferOverrun)
      return
    }
    copy.frameLength = source.frameLength

    let sources = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
    let destinations = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for index in 0..<min(sources.count, destinations.count) {
      let byteCount = Int(sources[index].mDataByteSize)
      guard let sourceData = sources[index].mData,
        let destinationData = destinations[index].mData
      else {
        finish(error: .bufferOverrun)
        return
      }
      memcpy(destinationData, sourceData, byteCount)
      destinations[index].mDataByteSize = sources[index].mDataByteSize
    }

    let didEnqueue = lock.withLock {
      guard !isFinished, count < capacity else {
        if !isFinished {
          storedError = .bufferOverrun
          isFinished = true
        }
        return false
      }
      slots[tail] = copy
      tail = (tail + 1) % capacity
      count += 1
      return true
    }
    if didEnqueue || error != nil {
      semaphore.signal()
    }
  }

  func dequeue() -> AVAudioPCMBuffer? {
    while true {
      semaphore.wait()
      let result: (AVAudioPCMBuffer?, Bool) = lock.withLock {
        if count > 0 {
          let buffer = slots[head]
          slots[head] = nil
          head = (head + 1) % capacity
          count -= 1
          return (buffer, false)
        }
        return (nil, isFinished)
      }
      if let buffer = result.0 {
        return buffer
      }
      if result.1 {
        return nil
      }
    }
  }

  func finish(error: M4RollingRecorderFailure? = nil) {
    lock.withLock {
      if let error, storedError == nil {
        storedError = error
      }
      isFinished = true
    }
    semaphore.signal()
  }
}

final class M4RollingFileWriter: @unchecked Sendable {
  private let configuration: M4RollingCaptureConfiguration
  private let format: AVAudioFormat
  private let segmentFrameLimit: Int64
  private var output: M4SegmentOutput?
  private var completedURLs: [URL] = []
  private var totalFrames: Int64 = 0
  private var nextIndex: Int

  init(
    configuration: M4RollingCaptureConfiguration,
    format: AVAudioFormat
  ) throws {
    guard format.sampleRate > 0,
      configuration.segmentDuration.isFinite,
      configuration.segmentDuration > 0,
      configuration.segmentDuration <= Double(Int64.max) / format.sampleRate
    else {
      throw M4RollingRecorderFailure.invalidConfiguration
    }
    self.configuration = configuration
    self.format = format
    segmentFrameLimit = max(
      1,
      Int64((configuration.segmentDuration * format.sampleRate).rounded(.down))
    )
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: configuration.directory,
      withIntermediateDirectories: true
    )
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: configuration.directory.path
    )
    let files = try fileManager.contentsOfDirectory(
      at: configuration.directory,
      includingPropertiesForKeys: nil
    )
    guard !files.contains(where: { M4RecordingRecovery.segmentIndex($0) != nil }) else {
      throw M4RollingRecorderFailure.recoveryRequired
    }
    nextIndex = 0
  }

  func writeAll(
    from queue: M4AudioBufferQueue,
    continuation: AsyncThrowingStream<M4RollingCaptureEvent, Error>.Continuation
  ) throws {
    do {
      while let buffer = queue.dequeue() {
        try Task.checkCancellation()
        if output == nil {
          output = try M4SegmentOutput(
            sessionID: configuration.sessionID,
            index: nextIndex,
            directory: configuration.directory,
            format: format,
            startFrame: totalFrames
          )
          nextIndex += 1
        }
        guard let output else {
          throw M4RollingRecorderFailure.diskWriteFailed("Missing segment output.")
        }
        try output.write(buffer)
        totalFrames += Int64(buffer.frameLength)
        try yieldEvent(
          .meter(M4RecordingMeter.make(from: buffer, totalFrames: totalFrames)),
          continuation: continuation
        )
        if output.framesWritten >= segmentFrameLimit {
          try closeCurrent(continuation: continuation)
        }
      }

      if let error = queue.error {
        throw error
      }
      try closeCurrent(continuation: continuation)
    } catch {
      output?.remove()
      output = nil
      if Self.isCancellation(error) {
        for url in completedURLs {
          try? FileManager.default.removeItem(at: url)
        }
      }
      if error is CancellationError {
        throw M4RollingRecorderFailure.cancelled
      }
      throw error
    }
  }

  private func closeCurrent(
    continuation: AsyncThrowingStream<M4RollingCaptureEvent, Error>.Continuation
  ) throws {
    guard let current = output else { return }
    let segment = try current.finish(endFrame: totalFrames)
    completedURLs.append(segment.url)
    output = nil
    try yieldEvent(.segmentClosed(segment), continuation: continuation)
  }

  private func yieldEvent(
    _ event: M4RollingCaptureEvent,
    continuation: AsyncThrowingStream<M4RollingCaptureEvent, Error>.Continuation
  ) throws {
    switch continuation.yield(event) {
    case .enqueued:
      return
    case .dropped(let droppedEvent):
      if case .meter = droppedEvent {
        return
      }
      throw M4RollingRecorderFailure.bufferOverrun
    case .terminated:
      throw M4RollingRecorderFailure.cancelled
    @unknown default:
      throw M4RollingRecorderFailure.bufferOverrun
    }
  }

  private static func isCancellation(_ error: Error) -> Bool {
    error is CancellationError
      || (error as? M4RollingRecorderFailure) == .cancelled
  }
}

private final class M4SegmentOutput {
  let framesWrittenStart: Int64
  private(set) var framesWritten: Int64 = 0

  private let sessionID: UUID
  private let index: Int
  private let partialURL: URL
  private let finalURL: URL
  private let format: AVAudioFormat
  private var file: AVAudioFile?

  init(
    sessionID: UUID,
    index: Int,
    directory: URL,
    format: AVAudioFormat,
    startFrame: Int64
  ) throws {
    self.sessionID = sessionID
    self.index = index
    self.format = format
    framesWrittenStart = startFrame
    let stem = String(format: "capture-%06d", index)
    partialURL =
      directory
      .appendingPathComponent("\(stem).partial")
      .appendingPathExtension("caf")
    finalURL = directory.appendingPathComponent(stem).appendingPathExtension("caf")
    file = try AVAudioFile(
      forWriting: partialURL,
      settings: format.settings,
      commonFormat: format.commonFormat,
      interleaved: format.isInterleaved
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: partialURL.path
    )
  }

  func write(_ buffer: AVAudioPCMBuffer) throws {
    guard let file else {
      throw M4RollingRecorderFailure.diskWriteFailed("Segment is already closed.")
    }
    do {
      try file.write(from: buffer)
      framesWritten += Int64(buffer.frameLength)
    } catch {
      throw M4RollingRecorderFailure.diskWriteFailed(error.localizedDescription)
    }
  }

  func finish(endFrame: Int64) throws -> M4RecordingSegment {
    file = nil
    let fileManager = FileManager.default
    do {
      let handle = try FileHandle(forWritingTo: partialURL)
      try handle.synchronize()
      try handle.close()
      let values = try partialURL.resourceValues(forKeys: [
        .fileSizeKey,
        .creationDateKey,
      ])
      let sha256 = try M4RecordingRecovery.sha256(of: partialURL)
      try fileManager.moveItem(at: partialURL, to: finalURL)
      try fileManager.setAttributes(
        [.posixPermissions: 0o400],
        ofItemAtPath: finalURL.path
      )
      return M4RecordingSegment(
        sessionID: sessionID,
        index: index,
        url: finalURL,
        relativePath: finalURL.lastPathComponent,
        startTime: Double(framesWrittenStart) / format.sampleRate,
        endTime: Double(endFrame) / format.sampleRate,
        byteCount: Int64(values.fileSize ?? 0),
        sha256: sha256,
        createdAt: values.creationDate ?? Date()
      )
    } catch {
      try? fileManager.removeItem(at: partialURL)
      try? fileManager.removeItem(at: finalURL)
      throw M4RollingRecorderFailure.diskWriteFailed(error.localizedDescription)
    }
  }

  func remove() {
    file = nil
    try? FileManager.default.removeItem(at: partialURL)
    try? FileManager.default.removeItem(at: finalURL)
  }
}

extension M4RecordingMeter {
  fileprivate static func make(
    from buffer: AVAudioPCMBuffer,
    totalFrames: Int64
  ) -> M4RecordingMeter {
    guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
      return M4RecordingMeter(
        elapsedTime: Double(totalFrames) / buffer.format.sampleRate,
        averagePower: -160,
        peakPower: -160
      )
    }
    var squareSum: Float = 0
    var peak: Float = 0
    let frameCount = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    for channel in 0..<channelCount {
      for frame in 0..<frameCount {
        let value = abs(channels[channel][frame])
        peak = max(peak, value)
        squareSum += value * value
      }
    }
    let sampleCount = max(1, frameCount * channelCount)
    let rms = sqrt(squareSum / Float(sampleCount))
    return M4RecordingMeter(
      elapsedTime: Double(totalFrames) / buffer.format.sampleRate,
      averagePower: Self.decibels(rms),
      peakPower: Self.decibels(peak)
    )
  }

  fileprivate static func decibels(_ amplitude: Float) -> Float {
    20 * log10(max(amplitude, 0.000_000_01))
  }
}
