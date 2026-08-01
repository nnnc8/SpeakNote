@preconcurrency import AVFoundation
import Foundation

actor AVAudioEngineRecorder: AudioRecorder {
  static let hardMaximumDuration: TimeInterval = 5 * 60

  private struct Session {
    let engine: AVAudioEngine
    let queue: BoundedAudioBufferQueue
    let rawURL: URL
    let writer: Task<URL, Error>
  }

  private let preprocessor: any AudioPreprocessing
  private let maximumDuration: TimeInterval
  private let queueCapacity: Int
  private var session: Session?
  private var timeoutTask: Task<Void, Never>?
  private var terminalError: AudioRecorderError?
  private var isFinishing = false
  private var cancelRequested = false

  init(
    preprocessor: any AudioPreprocessing = PCM16WAVPreprocessor(),
    maximumDuration: TimeInterval = hardMaximumDuration,
    queueCapacity: Int = 64
  ) {
    self.preprocessor = preprocessor
    self.maximumDuration = min(max(maximumDuration, 0.010), Self.hardMaximumDuration)
    self.queueCapacity = max(1, queueCapacity)
  }

  func start() async throws {
    guard session == nil, !isFinishing else {
      throw AudioRecorderError.alreadyRecording
    }
    terminalError = nil
    cancelRequested = false

    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      throw AudioRecorderError.permissionDenied
    }

    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw AudioRecorderError.invalidInputFormat
    }

    let rawURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakNote-\(UUID().uuidString)")
      .appendingPathExtension("caf")
    let queue = BoundedAudioBufferQueue(capacity: queueCapacity)
    let sink: CAFFileSink
    do {
      sink = try CAFFileSink(url: rawURL, format: format)
    } catch {
      throw AudioRecorderError.recordingFailed(error.localizedDescription)
    }

    let writer = Task.detached(priority: .userInitiated) {
      try sink.writeAll(from: queue)
      return rawURL
    }
    inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) {
      buffer, _ in
      queue.enqueueCopy(of: buffer)
    }

    do {
      engine.prepare()
      try engine.start()
      session = Session(engine: engine, queue: queue, rawURL: rawURL, writer: writer)
      scheduleMaximumDuration()
    } catch {
      inputNode.removeTap(onBus: 0)
      queue.finish(error: .recordingFailed(error.localizedDescription))
      _ = try? await writer.value
      try? FileManager.default.removeItem(at: rawURL)
      throw AudioRecorderError.recordingFailed(error.localizedDescription)
    }
  }

  func stop() async throws -> URL {
    guard let current = session else {
      if let terminalError {
        self.terminalError = nil
        throw terminalError
      }
      throw AudioRecorderError.notRecording
    }

    session = nil
    isFinishing = true
    timeoutTask?.cancel()
    timeoutTask = nil
    current.engine.stop()
    current.engine.inputNode.removeTap(onBus: 0)
    current.queue.finish()

    do {
      let rawURL = try await current.writer.value
      try Task.checkCancellation()
      guard !cancelRequested else {
        throw AudioRecorderError.cancelled
      }

      let wavURL = try await preprocessor.preprocess(cafURL: rawURL)
      try? FileManager.default.removeItem(at: rawURL)
      guard !cancelRequested, !Task.isCancelled else {
        try? FileManager.default.removeItem(at: wavURL)
        throw AudioRecorderError.cancelled
      }
      isFinishing = false
      return wavURL
    } catch let error as AudioRecorderError {
      try? FileManager.default.removeItem(at: current.rawURL)
      isFinishing = false
      throw error
    } catch is CancellationError {
      try? FileManager.default.removeItem(at: current.rawURL)
      isFinishing = false
      throw AudioRecorderError.cancelled
    } catch {
      try? FileManager.default.removeItem(at: current.rawURL)
      isFinishing = false
      throw AudioRecorderError.recordingFailed(error.localizedDescription)
    }
  }

  func cancel() async {
    timeoutTask?.cancel()
    timeoutTask = nil

    guard let current = session else {
      if isFinishing {
        cancelRequested = true
      }
      return
    }

    session = nil
    current.engine.stop()
    current.engine.inputNode.removeTap(onBus: 0)
    current.queue.finish(error: .cancelled)
    _ = try? await current.writer.value
    try? FileManager.default.removeItem(at: current.rawURL)
    terminalError = nil
  }

  private func scheduleMaximumDuration() {
    let nanoseconds = UInt64(maximumDuration * 1_000_000_000)
    timeoutTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: nanoseconds)
      guard !Task.isCancelled else { return }
      await self?.expireRecording()
    }
  }

  private func expireRecording() async {
    guard let current = session else { return }
    session = nil
    current.engine.stop()
    current.engine.inputNode.removeTap(onBus: 0)
    current.queue.finish(error: .maximumDurationExceeded)
    _ = try? await current.writer.value
    try? FileManager.default.removeItem(at: current.rawURL)
    terminalError = .maximumDurationExceeded
  }
}

private final class CAFFileSink: @unchecked Sendable {
  private let file: AVAudioFile

  init(url: URL, format: AVAudioFormat) throws {
    file = try AVAudioFile(
      forWriting: url,
      settings: format.settings,
      commonFormat: format.commonFormat,
      interleaved: format.isInterleaved
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path
    )
  }

  func writeAll(from queue: BoundedAudioBufferQueue) throws {
    while let buffer = queue.dequeue() {
      try file.write(from: buffer)
    }
    if let error = queue.error {
      throw error
    }
  }
}

private final class BoundedAudioBufferQueue: @unchecked Sendable {
  private let capacity: Int
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var slots: [AVAudioPCMBuffer?]
  private var head = 0
  private var tail = 0
  private var count = 0
  private var isFinished = false
  private var storedError: AudioRecorderError?

  init(capacity: Int) {
    self.capacity = capacity
    slots = Array(repeating: nil, count: capacity)
  }

  var error: AudioRecorderError? {
    lock.lock()
    defer { lock.unlock() }
    return storedError
  }

  // The realtime callback performs one owned-buffer copy and one bounded enqueue.
  // It never touches disk, converts formats, waits on a semaphore, or schedules unbounded work.
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

    let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
    let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
      let byteCount = Int(sourceBuffers[index].mDataByteSize)
      guard let sourceData = sourceBuffers[index].mData,
        let destinationData = destinationBuffers[index].mData
      else {
        finish(error: .bufferOverrun)
        return
      }
      memcpy(destinationData, sourceData, byteCount)
      destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
    }

    lock.lock()
    guard !isFinished, count < capacity else {
      if !isFinished {
        storedError = .bufferOverrun
        isFinished = true
      }
      lock.unlock()
      semaphore.signal()
      return
    }
    slots[tail] = copy
    tail = (tail + 1) % capacity
    count += 1
    lock.unlock()
    semaphore.signal()
  }

  func dequeue() -> AVAudioPCMBuffer? {
    while true {
      semaphore.wait()
      lock.lock()
      if count > 0 {
        let buffer = slots[head]
        slots[head] = nil
        head = (head + 1) % capacity
        count -= 1
        lock.unlock()
        return buffer
      }
      let finished = isFinished
      lock.unlock()
      if finished {
        return nil
      }
    }
  }

  func finish(error: AudioRecorderError? = nil) {
    lock.lock()
    if let error, storedError == nil {
      storedError = error
    }
    isFinished = true
    lock.unlock()
    semaphore.signal()
  }
}
