import AVFoundation
import Foundation

struct AVFoundationAudioDurationLoader: AudioDurationLoading {
  func duration(of audioURL: URL) async throws -> TimeInterval {
    do {
      let asset = AVURLAsset(url: audioURL)
      let duration = try await asset.load(.duration).seconds
      try Task.checkCancellation()
      guard duration.isFinite, duration >= 0 else {
        throw AppleTranscriptionError.unreadableAudio
      }
      return duration
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as AppleTranscriptionError {
      throw error
    } catch {
      throw AppleTranscriptionError.unreadableAudio
    }
  }
}

actor AppleTranscriptionEngine:
  TranscriptionEngine,
  TranscriptionProviderCapabilityChecking
{
  nonisolated let fallbackPolicy: FallbackPolicy

  private let speechAnalyzer: (any AppleSpeechAdapter)?
  private let legacyRecognizer: any AppleSpeechAdapter
  private let durationLoader: any AudioDurationLoading
  private let resolver: TranscriptionCapabilityResolver
  private let macOSMajorVersion: Int

  init(
    speechAnalyzer: (any AppleSpeechAdapter)?,
    legacyRecognizer: any AppleSpeechAdapter,
    durationLoader: any AudioDurationLoading = AVFoundationAudioDurationLoader(),
    resolver: TranscriptionCapabilityResolver = TranscriptionCapabilityResolver(),
    macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
    fallbackPolicy: FallbackPolicy = .defaultValue
  ) {
    self.speechAnalyzer = speechAnalyzer
    self.legacyRecognizer = legacyRecognizer
    self.durationLoader = durationLoader
    self.resolver = resolver
    self.macOSMajorVersion = macOSMajorVersion
    self.fallbackPolicy = fallbackPolicy
  }

  nonisolated static func live(
    fallbackPolicy: FallbackPolicy = .defaultValue
  ) -> AppleTranscriptionEngine {
    if #available(macOS 26, *) {
      return AppleTranscriptionEngine(
        speechAnalyzer: SpeechAnalyzerAdapter(),
        legacyRecognizer: LegacySpeechRecognizerAdapter(),
        fallbackPolicy: fallbackPolicy
      )
    }
    return AppleTranscriptionEngine(
      speechAnalyzer: nil,
      legacyRecognizer: LegacySpeechRecognizerAdapter(),
      fallbackPolicy: fallbackPolicy
    )
  }

  nonisolated func fallbackDecision(
    to destination: TranscriptionPrivacyClass,
    userConsented: Bool = false
  ) -> FallbackDecision {
    fallbackPolicy.decision(
      from: .local,
      to: destination,
      userConsented: userConsented
    )
  }

  func capability(
    duration: TimeInterval,
    languageCode: String?
  ) async -> TranscriptionCapability {
    let locale = Locale(identifier: languageCode ?? Locale.current.identifier)
    guard let adapter = selectedAdapter else {
      return .unavailable(.recognizerUnavailable)
    }
    let availability = await adapter.availability(for: locale)
    return resolver.resolve(
      TranscriptionCapabilityInput(
        macOSMajorVersion: macOSMajorVersion,
        duration: duration,
        adapter: availability
      )
    )
  }

  func providerCapability(
    for request: TranscriptionCapabilityRequest
  ) async -> ProviderTranscriptionCapability {
    switch await capability(
      duration: request.duration,
      languageCode: request.languageCode
    ) {
    case .available:
      .available
    case .unavailable(let reason):
      .unavailable(reason)
    }
  }

  func transcribe(
    audioURL: URL,
    configuration: TranscriptionConfiguration
  ) async throws -> Transcript {
    let duration = try await durationLoader.duration(of: audioURL)
    let locale = Locale(
      identifier: configuration.languageCode ?? Locale.current.identifier
    )
    guard let adapter = selectedAdapter else {
      throw AppleTranscriptionError.unavailable(.recognizerUnavailable)
    }
    let availability = await adapter.availability(for: locale)
    let capability = resolver.resolve(
      TranscriptionCapabilityInput(
        macOSMajorVersion: macOSMajorVersion,
        duration: duration,
        adapter: availability
      )
    )
    guard case .available = capability else {
      guard case .unavailable(let reason) = capability else {
        throw AppleTranscriptionError.recognitionFailed
      }
      throw AppleTranscriptionError.unavailable(reason)
    }

    do {
      return try await adapter.transcribe(
        audioURL: audioURL,
        locale: locale,
        duration: duration
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as AppleTranscriptionError {
      throw error
    } catch {
      throw AppleTranscriptionError.recognitionFailed
    }
  }

  private var selectedAdapter: (any AppleSpeechAdapter)? {
    macOSMajorVersion >= 26 ? speechAnalyzer : legacyRecognizer
  }
}
