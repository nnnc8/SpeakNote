@preconcurrency import AVFoundation
import Foundation
import whisper

enum BreezeWhisperError: Error, Equatable, LocalizedError, Sendable {
  case modelNotFound
  case modelLoadFailed
  case unreadableAudio
  case invalidAudioFormat
  case inferenceFailed
  case cancelled

  var errorDescription: String? {
    switch self {
    case .modelNotFound:
      String(localized: "Download the Breeze ASR 26 model before using it.")
    case .modelLoadFailed:
      String(localized: "The Breeze ASR 26 model could not be loaded.")
    case .unreadableAudio, .invalidAudioFormat:
      String(localized: "The audio could not be prepared for Breeze ASR 26.")
    case .inferenceFailed:
      String(localized: "Breeze ASR 26 could not transcribe this audio.")
    case .cancelled:
      String(localized: "Breeze ASR 26 transcription was cancelled.")
    }
  }
}

actor BreezeWhisperContext {
  private let context: BreezeWhisperContextHandle

  init(modelURL: URL) throws {
    guard FileManager.default.fileExists(atPath: modelURL.path) else {
      throw BreezeWhisperError.modelNotFound
    }
    var parameters = whisper_context_default_params()
    parameters.use_gpu = true
    parameters.flash_attn = true
    guard let context = modelURL.path.withCString({ path in
      whisper_init_from_file_with_params(path, parameters)
    }) else {
      throw BreezeWhisperError.modelLoadFailed
    }
    self.context = BreezeWhisperContextHandle(pointer: context)
  }

  fileprivate func transcribe(
    samples: [Float],
    languageCode: String?,
    cancellation: BreezeWhisperCancellation
  ) throws -> Transcript {
    try Task.checkCancellation()
    guard !samples.isEmpty else { throw BreezeWhisperError.unreadableAudio }

    var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
    parameters.print_progress = false
    parameters.print_realtime = false
    parameters.print_timestamps = false
    parameters.print_special = false
    parameters.translate = false
    parameters.no_context = true
    parameters.single_segment = false
    parameters.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
    parameters.language = nil
    parameters.detect_language = true
    parameters.abort_callback = { userData in
      guard let userData else { return false }
      return Unmanaged<BreezeWhisperCancellation>.fromOpaque(userData).takeUnretainedValue().isCancelled
    }
    parameters.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
    let result: Int32
    if let languageCode, !languageCode.isEmpty {
      result = languageCode.withCString { language in
        parameters.language = language
        return runWhisper(parameters: parameters, samples: samples)
      }
    } else {
      result = runWhisper(parameters: parameters, samples: samples)
    }
    if result != 0 {
      if Task.isCancelled || cancellation.isCancelled {
        throw BreezeWhisperError.cancelled
      }
      throw BreezeWhisperError.inferenceFailed
    }
    try Task.checkCancellation()
    return readTranscript()
  }

  private func runWhisper(
    parameters: whisper_full_params,
    samples: [Float]
  ) -> Int32 {
    samples.withUnsafeBufferPointer { buffer in
      whisper_full(
        context.pointer,
        parameters,
        buffer.baseAddress,
        Int32(samples.count)
      )
    }
  }

  private func readTranscript() -> Transcript {
    var segments: [TranscriptSegment] = []
    let count = whisper_full_n_segments(context.pointer)
    for index in 0..<count {
      let start = TimeInterval(whisper_full_get_segment_t0(context.pointer, index)) / 100
      let end = TimeInterval(whisper_full_get_segment_t1(context.pointer, index)) / 100
      let text = String(cString: whisper_full_get_segment_text(context.pointer, index))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      segments.append(
        TranscriptSegment(
          startTime: start,
          endTime: max(start, end),
          text: text,
          detectedLanguage: "zh"
        )
      )
    }
    return Transcript(
      text: segments.map(\.text).joined(),
      segments: segments,
      detectedLanguage: "zh"
    )
  }
}

private final class BreezeWhisperContextHandle: @unchecked Sendable {
  let pointer: OpaquePointer

  init(pointer: OpaquePointer) {
    self.pointer = pointer
  }

  deinit {
    whisper_free(pointer)
  }
}

private final class BreezeWhisperCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func cancel() {
    lock.lock()
    value = true
    lock.unlock()
  }
}

actor BreezeWhisperEngine: TranscriptionEngine {
  private let modelManager: any BreezeModelManaging
  private var context: BreezeWhisperContext?
  private var loadedModelID: String?

  init(modelManager: any BreezeModelManaging) {
    self.modelManager = modelManager
  }

  func unload() {
    context = nil
    loadedModelID = nil
  }

  func transcribe(
    audioURL: URL,
    configuration: TranscriptionConfiguration
  ) async throws -> Transcript {
    guard configuration.providerID == .breezeASR else {
      throw BreezeWhisperError.modelLoadFailed
    }
    try Task.checkCancellation()
    let modelID = configuration.modelID.isEmpty
      ? BreezeTranscriptionModel.defaultID
      : configuration.modelID
    let modelURL = try await modelManager.modelURL(for: modelID)
    await modelManager.markLoading(modelID: modelID)
    if context == nil || loadedModelID != modelID {
      do {
        context = try BreezeWhisperContext(modelURL: modelURL)
        loadedModelID = modelID
      } catch {
        await modelManager.markFailed(
          modelID: modelID,
          error: .modelLoadFailed
        )
        throw error
      }
    }
    await modelManager.markReady(modelID: modelID)
    let samples = try await Self.readSamples(from: audioURL)
    try Task.checkCancellation()
    guard let context else { throw BreezeWhisperError.modelLoadFailed }
    let cancellation = BreezeWhisperCancellation()
    return try await withTaskCancellationHandler {
      try await context.transcribe(
        samples: samples,
        languageCode: Self.whisperLanguageCode(configuration.languageCode),
        cancellation: cancellation
      )
    } onCancel: {
      cancellation.cancel()
    }
  }

  private static func whisperLanguageCode(_ languageCode: String?) -> String? {
    guard let languageCode else { return nil }
    let value = languageCode
      .replacingOccurrences(of: "_", with: "-")
      .split(separator: "-")
      .first
      .map(String.init) ?? languageCode
    return value.isEmpty ? nil : value
  }

  private static func readSamples(from audioURL: URL) async throws -> [Float] {
    try await Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let file: AVAudioFile
      do {
        file = try AVAudioFile(forReading: audioURL)
      } catch {
        throw BreezeWhisperError.unreadableAudio
      }
      let format = file.processingFormat
      guard format.sampleRate == 16_000, format.channelCount == 1 else {
        throw BreezeWhisperError.invalidAudioFormat
      }
      guard let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(file.length)
      ) else {
        throw BreezeWhisperError.unreadableAudio
      }
      do {
        try file.read(into: buffer)
      } catch {
        throw BreezeWhisperError.unreadableAudio
      }
      let frameCount = Int(buffer.frameLength)
      if let channel = buffer.floatChannelData?[0] {
        return Array(UnsafeBufferPointer(start: channel, count: frameCount))
      }
      if let channel = buffer.int16ChannelData?[0] {
        return (0..<frameCount).map { Float(channel[$0]) / Float(Int16.max) }
      }
      throw BreezeWhisperError.invalidAudioFormat
    }.value
  }
}

struct BreezeTranscriptionCapability: TranscriptionProviderCapabilityChecking {
  let modelManager: any BreezeModelManaging

  func providerCapability(
    for request: TranscriptionCapabilityRequest
  ) async -> ProviderTranscriptionCapability {
#if !arch(arm64)
    return .unavailable(.unsupportedArchitecture)
#else
    guard request.duration.isFinite, request.duration >= 0 else {
      return .unavailable(.invalidDuration)
    }
    switch await modelManager.state(for: BreezeTranscriptionModel.defaultID) {
    case .installed, .ready:
      return .available
    case .notDownloaded, .downloading, .verifying, .loading:
      return .unavailable(.modelMissing)
    case .failed:
      return .unavailable(.modelUnavailable)
    }
#endif
  }

  func supportedLanguageOptions() async -> [ProviderLanguageOption] {
    ProviderLanguageCatalog.breeze
  }
}
