import Foundation

enum GroqTextProcessingError: Error, Equatable, LocalizedError, Sendable {
  case invalidConfiguration
  case invalidInput
  case unsupportedModel
  case modelUnavailable(String)
  case invalidResponse
  case httpStatus(Int)
  case transportFailed
  case ambiguousCompletion

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      String(localized: "The Groq text-processing configuration is invalid.")
    case .invalidInput:
      String(localized: "There is no transcript text to process.")
    case .unsupportedModel:
      String(localized: "The selected Groq text model is not supported.")
    case .modelUnavailable(let model):
      String(localized: "The selected Groq text model is unavailable: \(model).")
    case .invalidResponse:
      String(localized: "Groq returned an unreadable text-processing response.")
    case .httpStatus(let status):
      String(localized: "Groq could not process the text request (HTTP \(status)).")
    case .transportFailed:
      String(localized: "SpeakNote could not reach Groq. Check the network connection.")
    case .ambiguousCompletion:
      String(
        localized:
          "The network disconnected before Groq's result was confirmed. Please retry."
      )
    }
  }
}

struct GroqTextProcessingClient: Sendable {
  private let apiKey: String
  private let baseURL: URL
  private let transport: any HTTPTransport
  private let retryPolicy: RetryPolicy
  private let sleep: @Sendable (TimeInterval) async throws -> Void

  init(
    apiKey: String,
    baseURL: URL = URL(string: "https://api.groq.com")!,
    transport: any HTTPTransport = URLSessionHTTPTransport(),
    retryPolicy: RetryPolicy = RetryPolicy(),
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
      try await Task.sleep(for: .seconds(seconds))
    }
  ) throws {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty,
      !key.contains("\r"),
      !key.contains("\n"),
      baseURL.scheme?.lowercased() == "https",
      baseURL.host != nil
    else {
      throw GroqTextProcessingError.invalidConfiguration
    }
    self.apiKey = key
    self.baseURL = baseURL
    self.transport = transport
    self.retryPolicy = retryPolicy
    self.sleep = sleep
  }

  func complete(
    prompt: TextProcessingPrompt,
    model: String
  ) async throws -> String {
    guard GroqTextModelCatalog.candidates.contains(model) else {
      throw GroqTextProcessingError.unsupportedModel
    }
    guard !prompt.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GroqTextProcessingError.invalidInput
    }

    let body = try JSONEncoder().encode(
      ChatCompletionRequest(
        model: model,
        messages: [
          .init(role: "system", content: prompt.system),
          .init(role: "user", content: prompt.user),
        ],
        temperature: 0
      )
    )
    var request = URLRequest(url: try endpoint(path: "/openai/v1/chat/completions"))
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")

    let response = try await execute(HTTPRequest(request: request, body: .data(body)))
    let decoded: ChatCompletionResponse
    do {
      decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: response.body)
    } catch {
      throw GroqTextProcessingError.invalidResponse
    }
    guard
      let content = decoded.choices.first?.message.content
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !content.isEmpty
    else {
      throw GroqTextProcessingError.invalidResponse
    }
    return content
  }

  func availableModels() async throws -> [String] {
    var request = URLRequest(url: try endpoint(path: "/openai/v1/models"))
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let response = try await execute(HTTPRequest(request: request))
    let decoded: ModelsResponse
    do {
      decoded = try JSONDecoder().decode(ModelsResponse.self, from: response.body)
    } catch {
      throw GroqTextProcessingError.invalidResponse
    }
    return GroqTextModelCatalog.availableModels(from: decoded.data.map(\.id))
  }

  private func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    var retryCount = 0
    while true {
      let response: HTTPResponse
      do {
        response = try await transport.send(request)
      } catch is CancellationError {
        throw CancellationError()
      } catch HTTPTransportError.ambiguousCompletion {
        throw GroqTextProcessingError.ambiguousCompletion
      } catch {
        throw GroqTextProcessingError.transportFailed
      }

      if (200...299).contains(response.statusCode) {
        return response
      }
      guard retryPolicy.shouldRetry(statusCode: response.statusCode, retryCount: retryCount) else {
        throw GroqTextProcessingError.httpStatus(response.statusCode)
      }
      let delay = retryPolicy.delay(headers: response.headers, retryCount: retryCount)
      retryCount += 1
      try await sleep(delay)
    }
  }

  private func endpoint(path: String) throws -> URL {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw GroqTextProcessingError.invalidConfiguration
    }
    components.path = path
    components.query = nil
    components.fragment = nil
    guard let url = components.url else {
      throw GroqTextProcessingError.invalidConfiguration
    }
    return url
  }
}

private struct ChatCompletionRequest: Encodable {
  struct Message: Encodable {
    let role: String
    let content: String
  }

  let model: String
  let messages: [Message]
  let temperature: Int
}

private struct ChatCompletionResponse: Decodable {
  struct Choice: Decodable {
    struct Message: Decodable {
      let content: String
    }

    let message: Message
  }

  let choices: [Choice]
}

private struct ModelsResponse: Decodable {
  struct Model: Decodable {
    let id: String
  }

  let data: [Model]
}
