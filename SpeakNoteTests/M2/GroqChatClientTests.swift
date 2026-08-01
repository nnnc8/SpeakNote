import Foundation
import XCTest

@testable import SpeakNote

@MainActor
final class GroqChatClientTests: XCTestCase {
  func testSendsJSONChatCompletionAndParsesText() async throws {
    let transport = ChatStubTransport(steps: [
      .success(
        HTTPResponse(
          statusCode: 200,
          body: Data(#"{"choices":[{"message":{"content":" cleaned result "}}]}"#.utf8)
        )
      )
    ])
    let client = try makeClient(transport: transport)

    let result = try await client.complete(
      prompt: TextProcessingPrompt(system: "system contract", user: "raw transcript"),
      model: ProviderDefaults.quickTextModelID
    )

    XCTAssertEqual(result, "cleaned result")
    let capturedRequests = await transport.requests
    let request = try XCTUnwrap(capturedRequests.first)
    XCTAssertEqual(request.request.url?.path, "/openai/v1/chat/completions")
    XCTAssertEqual(request.request.httpMethod, "POST")
    XCTAssertEqual(
      request.request.value(forHTTPHeaderField: "Authorization"),
      "Bearer test-key"
    )
    guard case .data(let body) = request.body else {
      return XCTFail("Chat completion must use a JSON data body.")
    }
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    XCTAssertEqual(json["model"] as? String, ProviderDefaults.quickTextModelID)
    XCTAssertEqual(json["temperature"] as? Int, 0)
    let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
    XCTAssertEqual(messages[0]["content"] as? String, "system contract")
    XCTAssertEqual(messages[1]["content"] as? String, "raw transcript")
  }

  func testRetriesRetryableStatusAndPropagatesCancellation() async throws {
    let transport = ChatStubTransport(steps: [
      .success(HTTPResponse(statusCode: 429, headers: ["Retry-After": "2"])),
      .success(
        HTTPResponse(
          statusCode: 200,
          body: Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8)
        )
      ),
    ])
    let sleeps = ChatSleepRecorder()
    let client = try makeClient(
      transport: transport,
      sleep: { await sleeps.append($0) }
    )

    _ = try await client.complete(
      prompt: TextProcessingPrompt(system: "s", user: "u"),
      model: ProviderDefaults.quickTextModelID
    )

    let requestCount = await transport.requestCount
    let recordedSleeps = await sleeps.values
    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(recordedSleeps, [2])

    let cancellingClient = try makeClient(
      transport: CancellationChatTransport(),
      sleep: { _ in XCTFail("Cancellation must not retry.") }
    )
    do {
      _ = try await cancellingClient.complete(
        prompt: TextProcessingPrompt(system: "s", user: "u"),
        model: ProviderDefaults.quickTextModelID
      )
      XCTFail("Expected cancellation.")
    } catch is CancellationError {
      // Expected control flow.
    }
  }

  func testMapsHTTPAndMalformedResponseErrors() async throws {
    let unauthorized = try makeClient(
      transport: ChatStubTransport(steps: [
        .success(HTTPResponse(statusCode: 401))
      ])
    )
    do {
      _ = try await unauthorized.complete(
        prompt: TextProcessingPrompt(system: "s", user: "u"),
        model: ProviderDefaults.quickTextModelID
      )
      XCTFail("Expected HTTP error.")
    } catch {
      XCTAssertEqual(error as? GroqTextProcessingError, .httpStatus(401))
    }

    let malformed = try makeClient(
      transport: ChatStubTransport(steps: [
        .success(HTTPResponse(statusCode: 200, body: Data("{}".utf8)))
      ])
    )
    do {
      _ = try await malformed.complete(
        prompt: TextProcessingPrompt(system: "s", user: "u"),
        model: ProviderDefaults.quickTextModelID
      )
      XCTFail("Expected response error.")
    } catch {
      XCTAssertEqual(error as? GroqTextProcessingError, .invalidResponse)
    }
  }

  func testDynamicModelsAndUnavailableSelectionAreDeterministic() async throws {
    let modelsBody = Data(
      #"{"data":[{"id":"other"},{"id":"openai/gpt-oss-120b"},{"id":"openai/gpt-oss-20b"}]}"#
        .utf8
    )
    let client = try makeClient(
      transport: ChatStubTransport(steps: [
        .success(HTTPResponse(statusCode: 200, body: modelsBody))
      ])
    )

    let availableModels = try await client.availableModels()
    XCTAssertEqual(
      availableModels,
      [
        ProviderDefaults.quickTextModelID,
        ProviderDefaults.structuredTextModelID,
      ]
    )

    let unavailableTransport = ChatStubTransport(steps: [
      .success(
        HTTPResponse(
          statusCode: 200,
          body: Data(#"{"data":[{"id":"unrelated"}]}"#.utf8)
        )
      )
    ])
    let engine = KeychainBackedGroqTextProcessingEngine(
      keychainService: ChatFakeAPIKeyStore(apiKey: "test-key"),
      transport: unavailableTransport,
      baseURL: URL(string: "https://unit.test")!
    )
    do {
      _ = try await engine.process(
        transcript: Transcript(text: "raw"),
        configuration: TextProcessingConfiguration(
          modelID: ProviderDefaults.quickTextModelID,
          compressionLevel: .clean
        )
      )
      XCTFail("Expected unavailable model.")
    } catch {
      XCTAssertEqual(
        error as? GroqTextProcessingError,
        .modelUnavailable(ProviderDefaults.quickTextModelID)
      )
    }
    let unavailableRequestCount = await unavailableTransport.requestCount
    XCTAssertEqual(unavailableRequestCount, 1)
  }

  func testKeychainBackedProductionEngineUsesCatalogThenChat() async throws {
    let transport = ChatStubTransport(steps: [
      .success(
        HTTPResponse(
          statusCode: 200,
          body: Data(
            #"{"data":[{"id":"openai/gpt-oss-20b"}]}"#.utf8
          )
        )
      ),
      .success(
        HTTPResponse(
          statusCode: 200,
          body: Data(#"{"choices":[{"message":{"content":"完成"}}]}"#.utf8)
        )
      ),
    ])
    let engine = KeychainBackedGroqTextProcessingEngine(
      keychainService: ChatFakeAPIKeyStore(apiKey: "test-key"),
      transport: transport,
      baseURL: URL(string: "https://unit.test")!
    )

    let result = try await engine.process(
      transcript: Transcript(text: "原始內容"),
      configuration: TextProcessingConfiguration(
        compressionLevel: .polished,
        recognitionLanguageCode: "zh-TW",
        outputLanguageCode: "zh-TW"
      )
    )

    XCTAssertEqual(result, ProcessedText(text: "完成"))
    let requests = await transport.requests
    XCTAssertEqual(
      requests.map(\.request.url?.path),
      [
        "/openai/v1/models",
        "/openai/v1/chat/completions",
      ])
  }

  private func makeClient(
    transport: any HTTPTransport,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }
  ) throws -> GroqTextProcessingClient {
    try GroqTextProcessingClient(
      apiKey: "test-key",
      baseURL: URL(string: "https://unit.test")!,
      transport: transport,
      sleep: sleep
    )
  }
}

private actor ChatStubTransport: HTTPTransport {
  private var steps: [Result<HTTPResponse, HTTPTransportError>]
  private(set) var requests: [HTTPRequest] = []

  var requestCount: Int {
    requests.count
  }

  init(steps: [Result<HTTPResponse, HTTPTransportError>]) {
    self.steps = steps
  }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    requests.append(request)
    guard !steps.isEmpty else {
      throw HTTPTransportError.requestFailed(code: nil)
    }
    return try steps.removeFirst().get()
  }
}

private actor ChatSleepRecorder {
  private(set) var values: [TimeInterval] = []

  func append(_ value: TimeInterval) {
    values.append(value)
  }
}

private actor CancellationChatTransport: HTTPTransport {
  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    throw CancellationError()
  }
}

private actor ChatFakeAPIKeyStore: APIKeyStoring {
  private var apiKey: String?

  init(apiKey: String?) {
    self.apiKey = apiKey
  }

  func loadAPIKey() throws -> String? {
    apiKey
  }

  func saveAPIKey(_ apiKey: String) throws {
    self.apiKey = apiKey
  }

  func deleteAPIKey() throws {
    apiKey = nil
  }
}
