import Foundation

enum TextProcessingRoute: Equatable, Sendable {
  case localPassthrough
  case engine
}

enum TextProcessingPolicy {
  static func route(for configuration: TextProcessingConfiguration) -> TextProcessingRoute {
    guard configuration.compressionLevel == .verbatim else {
      return .engine
    }
    return requiresTranslation(configuration) ? .engine : .localPassthrough
  }

  private static func requiresTranslation(
    _ configuration: TextProcessingConfiguration
  ) -> Bool {
    guard let output = normalized(configuration.outputLanguageCode) else {
      return false
    }
    guard let recognition = normalized(configuration.recognitionLanguageCode),
      recognition != "auto"
    else {
      return true
    }
    return recognition != output
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized =
      value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "_", with: "-")
      .lowercased()
    return normalized.isEmpty ? nil : normalized
  }
}

struct TextProcessingService: TextProcessingEngine, Sendable {
  private let engine: any TextProcessingEngine

  init(engine: any TextProcessingEngine) {
    self.engine = engine
  }

  func process(
    transcript: Transcript,
    configuration: TextProcessingConfiguration
  ) async throws -> ProcessedText {
    switch TextProcessingPolicy.route(for: configuration) {
    case .localPassthrough:
      ProcessedText(text: transcript.text)
    case .engine:
      try await engine.process(
        transcript: transcript,
        configuration: configuration
      )
    }
  }
}
