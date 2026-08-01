import Foundation
import XCTest

@testable import SpeakNote

@MainActor
final class M5GroqStructuredNoteEngineTests: XCTestCase {
  func testStrictSchemaRequestUsesKeychainTransportAndCanonicalContract() async throws {
    let responseJSON = #"{"groupIndex":3}"#
    let transport = M5StructuredStubTransport(responses: [
      try modelsResponse(),
      try chatResponse(content: responseJSON)
    ])
    let engine = M5KeychainBackedGroqStructuredNoteEngine(
      keychainService: M5StructuredFakeAPIKeyStore(apiKey: "unit-secret"),
      transport: transport,
      baseURL: URL(string: "https://unit.test")!
    )

    let result = try await engine.generatePartial(
      for: request(
        index: 3,
        noteType: .classNotes,
        modelID: ProviderDefaults.structuredTextModelID
      )
    )

    XCTAssertEqual(result, Data(responseJSON.utf8))
    let requests = await transport.requests
    XCTAssertEqual(requests.first?.request.httpMethod, "GET")
    XCTAssertEqual(requests.first?.request.url?.path, "/openai/v1/models")
    let captured = try XCTUnwrap(requests.last)
    XCTAssertEqual(captured.request.url?.path, "/openai/v1/chat/completions")
    XCTAssertEqual(captured.request.httpMethod, "POST")
    XCTAssertEqual(
      captured.request.value(forHTTPHeaderField: "Authorization"),
      "Bearer unit-secret"
    )
    let body = try bodyJSON(captured)
    XCTAssertEqual(body["model"] as? String, ProviderDefaults.structuredTextModelID)
    XCTAssertEqual(body["temperature"] as? Int, 0)

    let responseFormat = try XCTUnwrap(body["response_format"] as? [String: Any])
    XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
    let jsonSchema = try XCTUnwrap(
      responseFormat["json_schema"] as? [String: Any]
    )
    XCTAssertEqual(jsonSchema["strict"] as? Bool, true)
    let schema = try XCTUnwrap(jsonSchema["schema"] as? [String: Any])
    XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
    let groupIndex = try XCTUnwrap(properties["groupIndex"] as? [String: Any])
    XCTAssertEqual(groupIndex["enum"] as? [Int], [3])
    let noteType = try XCTUnwrap(properties["noteType"] as? [String: Any])
    XCTAssertEqual(noteType["enum"] as? [String], ["classNotes"])
    let lecture = try XCTUnwrap(properties["lecture"] as? [String: Any])
    let lectureProperties = try XCTUnwrap(
      lecture["properties"] as? [String: Any]
    )
    XCTAssertNotNil(lectureProperties["reviewQuestions"])
    let meeting = try XCTUnwrap(properties["meeting"] as? [String: Any])
    XCTAssertEqual(meeting["type"] as? String, "null")

    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
    let userMessage = try XCTUnwrap(messages[1]["content"] as? String)
    let userPayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(userMessage.utf8))
        as? [String: Any]
    )
    XCTAssertEqual(userPayload["groupIndex"] as? Int, 3)
    XCTAssertEqual(userPayload["transcript"] as? String, "segment 3")
    guard case .data(let bodyData) = captured.body else {
      return XCTFail("Structured completion must use a JSON data body.")
    }
    XCTAssertFalse(String(decoding: bodyData, as: UTF8.self).contains("unit-secret"))
  }

  func testJSONOutputFallbackAndRepairRequestBodies() async throws {
    let transport = M5StructuredStubTransport(responses: [
      try modelsResponse(),
      try chatResponse(content: "initial"),
      try chatResponse(content: "repaired"),
    ])
    let engine = M5KeychainBackedGroqStructuredNoteEngine(
      keychainService: M5StructuredFakeAPIKeyStore(apiKey: "unit-secret"),
      transport: transport,
      baseURL: URL(string: "https://unit.test")!
    )
    let groupRequest = request(
      index: 0,
      noteType: .generalNotes,
      modelID: ProviderDefaults.jsonObjectTextModelID
    )

    _ = try await engine.generatePartial(for: groupRequest)
    let repaired = try await engine.repairPartial(
      Data("{broken".utf8),
      for: groupRequest
    )

    XCTAssertEqual(repaired, Data("repaired".utf8))
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 3)
    for captured in requests.dropFirst() {
      let body = try bodyJSON(captured)
      let responseFormat = try XCTUnwrap(
        body["response_format"] as? [String: Any]
      )
      XCTAssertEqual(responseFormat["type"] as? String, "json_object")
      XCTAssertNil(responseFormat["json_schema"])
    }

    let repairBody = try bodyJSON(requests[2])
    let messages = try XCTUnwrap(repairBody["messages"] as? [[String: Any]])
    let systemMessage = try XCTUnwrap(messages[0]["content"] as? String)
    XCTAssertTrue(systemMessage.contains("Repair the prior output"))
    let userMessage = try XCTUnwrap(messages[1]["content"] as? String)
    let userPayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(userMessage.utf8))
        as? [String: Any]
    )
    XCTAssertEqual(userPayload["priorInvalidJSON"] as? String, "{broken")
  }

  func testMissingKeyAndUnsupportedModelNeverReachTransport() async throws {
    let transport = M5StructuredStubTransport(responses: [])
    let missingKeyEngine = M5KeychainBackedGroqStructuredNoteEngine(
      keychainService: M5StructuredFakeAPIKeyStore(apiKey: nil),
      transport: transport,
      baseURL: URL(string: "https://unit.test")!
    )

    do {
      _ = try await missingKeyEngine.generatePartial(
        for: request(
          index: 0,
          noteType: .generalNotes,
          modelID: ProviderDefaults.structuredTextModelID
        )
      )
      XCTFail("Expected a missing-key error.")
    } catch {
      XCTAssertEqual(error as? LiveTextProcessingEngineError, .missingAPIKey)
    }

    let unsupportedEngine = M5KeychainBackedGroqStructuredNoteEngine(
      keychainService: M5StructuredFakeAPIKeyStore(apiKey: "unit-secret"),
      transport: transport,
      baseURL: URL(string: "https://unit.test")!
    )
    do {
      _ = try await unsupportedEngine.generatePartial(
        for: request(
          index: 0,
          noteType: .generalNotes,
          modelID: "unsupported/model"
        )
      )
      XCTFail("Expected an unsupported-model error.")
    } catch {
      XCTAssertEqual(error as? GroqTextProcessingError, .unsupportedModel)
    }
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testConfiguredModelMustBeVisibleToCurrentGroqAccount() async throws {
    let transport = M5StructuredStubTransport(responses: [
      try modelsResponse([ProviderDefaults.quickTextModelID])
    ])
    let engine = M5KeychainBackedGroqStructuredNoteEngine(
      keychainService: M5StructuredFakeAPIKeyStore(apiKey: "unit-secret"),
      transport: transport,
      baseURL: URL(string: "https://unit.test")!
    )

    do {
      _ = try await engine.generatePartial(
        for: request(
          index: 0,
          noteType: .generalNotes,
          modelID: ProviderDefaults.structuredTextModelID
        )
      )
      XCTFail("An account-hidden model must require reselection.")
    } catch {
      XCTAssertEqual(
        error as? GroqTextProcessingError,
        .modelUnavailable(ProviderDefaults.structuredTextModelID)
      )
    }
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.request.url?.path, "/openai/v1/models")
  }

  private func request(
    index: Int,
    noteType: NoteType,
    modelID: String
  ) -> M5StructuredGroupRequest {
    M5StructuredGroupRequest(
      noteType: noteType,
      group: StructuredTranscriptGroup(
        index: index,
        segments: [],
        text: "segment \(index)",
        sourceRange: StructuredSourceRange(
          startTime: TimeInterval(index * 10),
          endTime: TimeInterval(index * 10 + 4)
        ),
        characterCount: 9,
        estimatedTokenCount: 3,
        isOversized: false
      ),
      modelID: modelID
    )
  }

  private func chatResponse(content: String) throws -> HTTPResponse {
    HTTPResponse(
      statusCode: 200,
      body: try JSONSerialization.data(withJSONObject: [
        "choices": [["message": ["content": content]]]
      ])
    )
  }

  private func modelsResponse(
    _ modelIDs: [String] = GroqTextModelCatalog.candidates
  ) throws -> HTTPResponse {
    HTTPResponse(
      statusCode: 200,
      body: try JSONSerialization.data(withJSONObject: [
        "data": modelIDs.map { ["id": $0] }
      ])
    )
  }

  private func bodyJSON(_ request: HTTPRequest) throws -> [String: Any] {
    guard case .data(let data) = request.body else {
      XCTFail("Expected JSON data body.")
      return [:]
    }
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
  }
}

private actor M5StructuredStubTransport: HTTPTransport {
  private var responses: [HTTPResponse]
  private(set) var requests: [HTTPRequest] = []

  init(responses: [HTTPResponse]) {
    self.responses = responses
  }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else {
      throw HTTPTransportError.requestFailed(code: nil)
    }
    return responses.removeFirst()
  }
}

private actor M5StructuredFakeAPIKeyStore: APIKeyStoring {
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
