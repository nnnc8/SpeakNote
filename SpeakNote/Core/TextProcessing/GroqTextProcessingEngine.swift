import Foundation

enum LiveTextProcessingEngineError: Error, Equatable, LocalizedError, Sendable {
  case missingAPIKey
  case unsupportedProvider

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      String(
        localized: "Add a Groq API key in SpeakNote Settings before processing text."
      )
    case .unsupportedProvider:
      String(localized: "The selected text-processing provider is not available.")
    }
  }
}

struct KeychainBackedGroqTextProcessingEngine: TextProcessingEngine, Sendable {
  private let keychainService: any APIKeyStoring
  private let transport: any HTTPTransport
  private let baseURL: URL
  private let retryPolicy: RetryPolicy
  private let sleep: @Sendable (TimeInterval) async throws -> Void

  init(
    keychainService: any APIKeyStoring,
    transport: any HTTPTransport = URLSessionHTTPTransport(),
    baseURL: URL = URL(string: "https://api.groq.com")!,
    retryPolicy: RetryPolicy = RetryPolicy(),
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
      try await Task.sleep(for: .seconds(seconds))
    }
  ) {
    self.keychainService = keychainService
    self.transport = transport
    self.baseURL = baseURL
    self.retryPolicy = retryPolicy
    self.sleep = sleep
  }

  func process(
    transcript: Transcript,
    configuration: TextProcessingConfiguration
  ) async throws -> ProcessedText {
    guard configuration.providerID == .groq else {
      throw LiveTextProcessingEngineError.unsupportedProvider
    }
    guard let storedKey = try await keychainService.loadAPIKey() else {
      throw LiveTextProcessingEngineError.missingAPIKey
    }
    let apiKey = storedKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !apiKey.isEmpty else {
      throw LiveTextProcessingEngineError.missingAPIKey
    }

    let client = try GroqTextProcessingClient(
      apiKey: apiKey,
      baseURL: baseURL,
      transport: transport,
      retryPolicy: retryPolicy,
      sleep: sleep
    )
    let configuredModel = configuration.modelID
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let model =
      configuredModel.isEmpty
      ? ProviderDefaults.quickTextModelID
      : configuredModel
    let availableModels = try await client.availableModels()
    guard availableModels.contains(model) else {
      throw GroqTextProcessingError.modelUnavailable(model)
    }

    let text = try await client.complete(
      prompt: PromptBuilder.build(
        transcript: transcript,
        configuration: configuration
      ),
      model: model
    )
    return ProcessedText(text: text)
  }
}
