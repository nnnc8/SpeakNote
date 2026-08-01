import Foundation

enum AppleSpeechBackend: Equatable, Sendable {
  case speechAnalyzer
  case legacyOnDevice
}

enum SpeechAuthorizationState: Equatable, Sendable {
  case notDetermined
  case denied
  case restricted
  case authorized
}

enum SpeechModelAssetState: Equatable, Sendable {
  case notRequired
  case installed
  case missing
  case unavailable
}

struct SpeechAdapterAvailability: Equatable, Sendable {
  let authorization: SpeechAuthorizationState
  let isAvailable: Bool
  let supportsLocale: Bool
  let supportsOnDeviceRecognition: Bool
  let modelAssetState: SpeechModelAssetState
}

struct TranscriptionCapabilityInput: Equatable, Sendable {
  let macOSMajorVersion: Int
  let duration: TimeInterval
  let adapter: SpeechAdapterAvailability
}

enum TranscriptionUnavailableReason: Error, Equatable, Sendable {
  case unsupportedOperatingSystem
  case invalidDuration
  case permissionNotDetermined
  case permissionDenied
  case unsupportedLocale
  case recognizerUnavailable
  case onDeviceRecognitionUnavailable
  case modelMissing
  case modelUnavailable
  case legacyDurationLimitExceeded
  case providerNotConfigured
}

enum TranscriptionCapability: Equatable, Sendable {
  case available(AppleSpeechBackend)
  case unavailable(TranscriptionUnavailableReason)
}

struct TranscriptionCapabilityResolver: Sendable {
  static let legacyMaximumDuration: TimeInterval = 55

  func resolve(_ input: TranscriptionCapabilityInput) -> TranscriptionCapability {
    guard input.macOSMajorVersion >= 14 else {
      return .unavailable(.unsupportedOperatingSystem)
    }
    guard input.duration.isFinite, input.duration >= 0 else {
      return .unavailable(.invalidDuration)
    }
    switch input.adapter.authorization {
    case .notDetermined:
      return .unavailable(.permissionNotDetermined)
    case .denied, .restricted:
      return .unavailable(.permissionDenied)
    case .authorized:
      break
    }
    guard input.adapter.isAvailable else {
      return .unavailable(.recognizerUnavailable)
    }

    if input.macOSMajorVersion >= 26 {
      guard input.adapter.supportsLocale else {
        return .unavailable(.unsupportedLocale)
      }
      switch input.adapter.modelAssetState {
      case .installed:
        return .available(.speechAnalyzer)
      case .missing:
        return .unavailable(.modelMissing)
      case .unavailable, .notRequired:
        return .unavailable(.modelUnavailable)
      }
    }

    guard input.duration < Self.legacyMaximumDuration else {
      return .unavailable(.legacyDurationLimitExceeded)
    }
    guard input.adapter.supportsLocale else {
      return .unavailable(.unsupportedLocale)
    }
    guard input.adapter.supportsOnDeviceRecognition else {
      return .unavailable(.onDeviceRecognitionUnavailable)
    }
    return .available(.legacyOnDevice)
  }
}

enum TranscriptionPrivacyClass: Equatable, Sendable {
  case local
  case cloud
}

enum FallbackDecision: Equatable, Sendable {
  case allowed
  case requiresConsent
  case denied
}

enum FallbackPolicy: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
  case never
  case samePrivacyClass
  case askBeforeCrossingBoundary

  static let defaultValue = FallbackPolicy.askBeforeCrossingBoundary

  func decision(
    from source: TranscriptionPrivacyClass,
    to destination: TranscriptionPrivacyClass,
    userConsented: Bool = false
  ) -> FallbackDecision {
    switch self {
    case .never:
      .denied
    case .samePrivacyClass:
      source == destination ? .allowed : .denied
    case .askBeforeCrossingBoundary:
      if source == destination || userConsented {
        .allowed
      } else {
        .requiresConsent
      }
    }
  }
}

struct TranscriptionCapabilityRequest: Equatable, Sendable {
  let duration: TimeInterval
  let languageCode: String?

  init(duration: TimeInterval, languageCode: String? = nil) {
    self.duration = duration
    self.languageCode = languageCode
  }
}

enum ProviderTranscriptionCapability: Equatable, Sendable {
  case available
  case unavailable(TranscriptionUnavailableReason)
}

protocol TranscriptionProviderCapabilityChecking: Sendable {
  func providerCapability(
    for request: TranscriptionCapabilityRequest
  ) async -> ProviderTranscriptionCapability
}

struct ConstantTranscriptionCapabilityChecker:
  TranscriptionProviderCapabilityChecking
{
  let capability: ProviderTranscriptionCapability

  init(_ capability: ProviderTranscriptionCapability) {
    self.capability = capability
  }

  func providerCapability(
    for _: TranscriptionCapabilityRequest
  ) -> ProviderTranscriptionCapability {
    capability
  }
}

enum AppleTranscriptionError: Error, Equatable, Sendable {
  case unavailable(TranscriptionUnavailableReason)
  case unreadableAudio
  case recognitionFailed
  case invalidResult
}

protocol AppleSpeechAdapter: Actor {
  func availability(for locale: Locale) async -> SpeechAdapterAvailability
  func transcribe(
    audioURL: URL,
    locale: Locale,
    duration: TimeInterval
  ) async throws -> Transcript
}

protocol AudioDurationLoading: Sendable {
  func duration(of audioURL: URL) async throws -> TimeInterval
}
