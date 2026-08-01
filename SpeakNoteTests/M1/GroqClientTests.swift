import Foundation
import XCTest

@testable import SpeakNote

@MainActor
final class GroqClientTests: XCTestCase {
  func testTranscriptionUsesFileBackedVerboseMultipart() async throws {
    let payload = """
      {"text":"hello","language":"en","segments":[{"start":0.0,"end":1.25,"text":"hello"}]}
      """
    let transport = GroqStubTransport(steps: [
      .success(HTTPResponse(statusCode: 200, body: Data(payload.utf8)))
    ])
    let client = try GroqAPIClient(
      apiKey: "test-key",
      baseURL: URL(string: "https://unit.test")!,
      transport: transport,
      sleep: { _ in XCTFail("unexpected retry") }
    )
    let audioURL = try makeAudio(bytes: Data("audio".utf8))
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let response = try await client.transcribe(audioURL: audioURL, language: "en")

    XCTAssertEqual(response.text, "hello")
    XCTAssertEqual(response.segments, [.init(start: 0, end: 1.25, text: "hello")])
    let capture = await transport.capture
    XCTAssertEqual(capture?.request.url?.path, "/openai/v1/audio/transcriptions")
    guard case .file = capture?.body else {
      return XCTFail("multipart must be file-backed")
    }
    let uploadedBody = await transport.uploadedBody
    let uploadedPermissions = await transport.uploadedPermissions
    let multipart = try XCTUnwrap(uploadedBody)
    let string = try XCTUnwrap(String(data: multipart, encoding: .utf8))
    XCTAssertTrue(string.contains("name=\"response_format\"\r\n\r\nverbose_json"))
    XCTAssertTrue(string.contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo"))
    XCTAssertTrue(string.contains("name=\"language\"\r\n\r\nen"))
    XCTAssertTrue(string.contains("name=\"file\""))
    XCTAssertEqual(uploadedPermissions, 0o600)
  }

  func testRetryBudgetAndRetryAfterAreApplied() async throws {
    let payload = Data(#"{"text":"ok","segments":[]}"#.utf8)
    let transport = GroqStubTransport(steps: [
      .success(HTTPResponse(statusCode: 429, headers: ["Retry-After": "3"])),
      .success(HTTPResponse(statusCode: 503)),
      .success(HTTPResponse(statusCode: 200, body: payload)),
    ])
    let sleeps = DurationRecorder()
    let client = try GroqAPIClient(
      apiKey: "test-key",
      baseURL: URL(string: "https://unit.test")!,
      transport: transport,
      retryPolicy: RetryPolicy(baseDelay: 2, randomUnit: { 0.5 }),
      sleep: { value in await sleeps.append(value) }
    )
    let audioURL = try makeAudio(bytes: Data("audio".utf8))
    defer { try? FileManager.default.removeItem(at: audioURL) }

    _ = try await client.transcribe(audioURL: audioURL)

    let requestCount = await transport.requestCount
    let recordedSleeps = await sleeps.values
    XCTAssertEqual(requestCount, 3)
    XCTAssertEqual(recordedSleeps, [3, 2])
  }

  func testDoesNotRetryUnauthorizedOrAmbiguousCompletion() async throws {
    let unauthorized = GroqStubTransport(steps: [
      .success(HTTPResponse(statusCode: 401))
    ])
    let firstClient = try GroqAPIClient(
      apiKey: "test-key",
      baseURL: URL(string: "https://unit.test")!,
      transport: unauthorized,
      sleep: { _ in XCTFail("unexpected retry") }
    )
    let audioURL = try makeAudio(bytes: Data("audio".utf8))
    defer { try? FileManager.default.removeItem(at: audioURL) }

    do {
      _ = try await firstClient.transcribe(audioURL: audioURL)
      XCTFail("expected unauthorized")
    } catch {
      XCTAssertEqual(error as? GroqAPIError, .httpStatus(401))
    }
    let unauthorizedCount = await unauthorized.requestCount
    XCTAssertEqual(unauthorizedCount, 1)

    let ambiguous = GroqStubTransport(steps: [
      .failure(.ambiguousCompletion(code: URLError.networkConnectionLost.rawValue))
    ])
    let secondClient = try GroqAPIClient(
      apiKey: "test-key",
      baseURL: URL(string: "https://unit.test")!,
      transport: ambiguous,
      sleep: { _ in XCTFail("unexpected retry") }
    )
    do {
      _ = try await secondClient.transcribe(audioURL: audioURL)
      XCTFail("expected ambiguity")
    } catch {
      XCTAssertEqual(error as? GroqAPIError, .ambiguousCompletion)
    }
    let ambiguousCount = await ambiguous.requestCount
    XCTAssertEqual(ambiguousCount, 1)
  }

  func testCancellationPropagatesWithoutRetry() async throws {
    let client = try GroqAPIClient(
      apiKey: "test-key",
      baseURL: URL(string: "https://unit.test")!,
      transport: CancellationTransport(),
      sleep: { _ in XCTFail("unexpected retry") }
    )
    let audioURL = try makeAudio(bytes: Data("audio".utf8))
    defer { try? FileManager.default.removeItem(at: audioURL) }

    do {
      _ = try await client.transcribe(audioURL: audioURL)
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Cancellation is a control-flow result, not a provider failure.
    }
  }

  func testCatalogIntersectsOnlySupportedSpeechModels() async throws {
    let body = Data(
      #"{"data":[{"id":"llama"},{"id":"whisper-large-v3"},{"id":"whisper-large-v3-turbo"},{"id":"future-whisper"}]}"#
        .utf8)
    let transport = GroqStubTransport(steps: [
      .success(HTTPResponse(statusCode: 200, body: body))
    ])
    let client = try GroqAPIClient(
      apiKey: "test-key",
      baseURL: URL(string: "https://unit.test")!,
      transport: transport
    )

    let models = try await client.availableTranscriptionModels()
    XCTAssertEqual(
      models,
      [GroqTranscriptionModel.largeV3Turbo, GroqTranscriptionModel.largeV3]
    )
    let capturedPath = await transport.capture?.request.url?.path
    XCTAssertEqual(capturedPath, "/openai/v1/models")
  }

  func testRejectsAudioOverTwentyMiBBeforeTransport() async throws {
    let transport = GroqStubTransport(steps: [])
    let client = try GroqAPIClient(
      apiKey: "test-key",
      baseURL: URL(string: "https://unit.test")!,
      transport: transport
    )
    let audioURL = try makeAudio(bytes: Data(count: Int(GroqAPIClient.maximumAudioBytes + 1)))
    defer { try? FileManager.default.removeItem(at: audioURL) }

    do {
      _ = try await client.transcribe(audioURL: audioURL)
      XCTFail("expected size rejection")
    } catch {
      XCTAssertEqual(
        error as? GroqAPIError,
        .audioFileTooLarge(maximumBytes: GroqAPIClient.maximumAudioBytes)
      )
    }
    let requestCount = await transport.requestCount
    XCTAssertEqual(requestCount, 0)
  }

  private func makeAudio(bytes: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("m4a")
    try bytes.write(to: url, options: .atomic)
    return url
  }
}

private actor GroqStubTransport: HTTPTransport {
  private var steps: [Result<HTTPResponse, HTTPTransportError>]
  private(set) var requestCount = 0
  private(set) var capture: HTTPRequest?
  private(set) var uploadedBody: Data?
  private(set) var uploadedPermissions: Int?

  init(steps: [Result<HTTPResponse, HTTPTransportError>]) {
    self.steps = steps
  }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    requestCount += 1
    capture = request
    if case .file(let url) = request.body {
      uploadedBody = try Data(contentsOf: url)
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      uploadedPermissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
    }
    guard !steps.isEmpty else { throw HTTPTransportError.requestFailed(code: nil) }
    return try steps.removeFirst().get()
  }
}

private actor DurationRecorder {
  private(set) var values: [TimeInterval] = []
  func append(_ value: TimeInterval) { values.append(value) }
}

private actor CancellationTransport: HTTPTransport {
  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    throw CancellationError()
  }
}
