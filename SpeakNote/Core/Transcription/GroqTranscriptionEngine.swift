import Foundation

enum LiveTranscriptionEngineError: Error, LocalizedError, Sendable {
  case missingAPIKey
  case unsupportedProvider

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      String(localized: "Add a Groq API key in SpeakNote Settings before dictating.")
    case .unsupportedProvider:
      String(localized: "The selected transcription provider is not available.")
    }
  }
}

struct KeychainBackedGroqTranscriptionEngine: TranscriptionEngine, Sendable {
  private let keychainService: any APIKeyStoring
  private let transport: any HTTPTransport
  private let baseURL: URL

  init(
    keychainService: any APIKeyStoring,
    transport: any HTTPTransport = URLSessionHTTPTransport(),
    baseURL: URL = URL(string: "https://api.groq.com")!
  ) {
    self.keychainService = keychainService
    self.transport = transport
    self.baseURL = baseURL
  }

  func transcribe(
    audioURL: URL,
    configuration: TranscriptionConfiguration
  ) async throws -> Transcript {
    guard configuration.providerID == .groq else {
      throw LiveTranscriptionEngineError.unsupportedProvider
    }
    guard let storedKey = try await keychainService.loadAPIKey() else {
      throw LiveTranscriptionEngineError.missingAPIKey
    }
    let apiKey = storedKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !apiKey.isEmpty else {
      throw LiveTranscriptionEngineError.missingAPIKey
    }

    let client = try GroqAPIClient(
      apiKey: apiKey,
      baseURL: baseURL,
      transport: transport
    )
    return try await GroqTranscriptionEngine(client: client).transcribe(
      audioURL: audioURL,
      configuration: configuration
    )
  }
}

struct GroqTranscriptionEngine: TranscriptionEngine, Sendable {
  private let client: GroqAPIClient

  init(client: GroqAPIClient) {
    self.client = client
  }

  func transcribe(
    audioURL: URL,
    configuration: TranscriptionConfiguration
  ) async throws -> Transcript {
    let response = try await client.transcribe(
      audioURL: audioURL,
      model: configuration.modelID.isEmpty
        ? GroqTranscriptionModel.largeV3Turbo
        : configuration.modelID,
      language: configuration.languageCode,
      prompt: configuration.prompt
    )
    return Transcript(
      id: UUID(),
      text: response.text,
      segments: response.segments.map {
        TranscriptSegment(
          id: UUID(),
          startTime: $0.start,
          endTime: $0.end,
          text: $0.text,
          detectedLanguage: response.language
        )
      },
      detectedLanguage: response.language
    )
  }
}
