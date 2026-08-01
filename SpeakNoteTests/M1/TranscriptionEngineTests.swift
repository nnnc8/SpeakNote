import Foundation
import XCTest

@testable import SpeakNote

@MainActor
final class TranscriptionEngineTests: XCTestCase {
  func testMapsVerboseSegmentsIntoSharedTranscript() async throws {
    let body = Data(
      #"{"text":"hello","language":"en","segments":[{"start":0.25,"end":1.5,"text":"hello"}]}"#.utf8
    )
    let transport = EngineStubTransport(response: HTTPResponse(statusCode: 200, body: body))
    let client = try GroqAPIClient(
      apiKey: "test-key",
      baseURL: URL(string: "https://unit.test")!,
      transport: transport
    )
    let engine = GroqTranscriptionEngine(client: client)
    let audioURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("m4a")
    try Data("audio".utf8).write(to: audioURL)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let transcript = try await engine.transcribe(
      audioURL: audioURL,
      configuration: TranscriptionConfiguration(
        providerID: ProviderID(rawValue: "groq"),
        modelID: GroqTranscriptionModel.largeV3Turbo,
        languageCode: "en",
        prompt: nil
      )
    )

    XCTAssertEqual(transcript.text, "hello")
    XCTAssertEqual(transcript.detectedLanguage, "en")
    XCTAssertEqual(transcript.segments.count, 1)
    XCTAssertEqual(transcript.segments[0].startTime, 0.25)
    XCTAssertEqual(transcript.segments[0].endTime, 1.5)
    XCTAssertEqual(transcript.segments[0].detectedLanguage, "en")
  }

  func testLiveEngineLoadsKeychainCredentialThroughInjectedBoundary() async throws {
    let body = Data(#"{"text":"live boundary","segments":[]}"#.utf8)
    let transport = EngineStubTransport(
      response: HTTPResponse(statusCode: 200, body: body)
    )
    let engine = KeychainBackedGroqTranscriptionEngine(
      keychainService: FakeAPIKeyStore(apiKey: "fixture-key"),
      transport: transport,
      baseURL: URL(string: "https://unit.test")!
    )
    let audioURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("wav")
    try Data("audio".utf8).write(to: audioURL)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let transcript = try await engine.transcribe(
      audioURL: audioURL,
      configuration: TranscriptionConfiguration()
    )
    let requestCount = await transport.requestCount

    XCTAssertEqual(transcript.text, "live boundary")
    XCTAssertEqual(requestCount, 1)
  }

  func testLiveEngineRejectsMissingKeyBeforeNetwork() async throws {
    let transport = EngineStubTransport(
      response: HTTPResponse(statusCode: 500)
    )
    let engine = KeychainBackedGroqTranscriptionEngine(
      keychainService: FakeAPIKeyStore(),
      transport: transport,
      baseURL: URL(string: "https://unit.test")!
    )

    do {
      _ = try await engine.transcribe(
        audioURL: URL(fileURLWithPath: "/tmp/not-read.wav"),
        configuration: TranscriptionConfiguration()
      )
      XCTFail("Expected missing credential")
    } catch {
      XCTAssertEqual(
        error as? LiveTranscriptionEngineError,
        .missingAPIKey
      )
    }
    let requestCount = await transport.requestCount
    XCTAssertEqual(requestCount, 0)
  }
}

private actor EngineStubTransport: HTTPTransport {
  let response: HTTPResponse
  private(set) var requestCount = 0
  init(response: HTTPResponse) { self.response = response }
  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    requestCount += 1
    return response
  }
}
