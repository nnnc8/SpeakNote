import AVFAudio
import Darwin
import Foundation
import XCTest

@testable import SpeakNote

final class HardeningStressTests: XCTestCase {
  func testTwoHourSparsePCMStreamsWithinMemoryBudgetAndKeepsChunkTimeline()
    async throws
  {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakNote-M8-LongAudio-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appendingPathComponent("two-hours.wav")
    try makeSparsePCMSource(duration: 2 * 60 * 60, at: source)
    let allocatedBytes = try XCTUnwrap(
      source.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize
    )
    XCTAssertLessThan(allocatedBytes, 1 * 1_024 * 1_024)

    let residentBefore = maximumResidentBytes()
    let chunks = try await TimeBasedAudioChunker(
      destinationDirectory: root.appendingPathComponent("chunks")
    ).chunks(from: source)
    let extraResidentBytes = maximumResidentBytes() - residentBefore

    XCTAssertEqual(chunks.count, 13)
    XCTAssertEqual(chunks.map(\.index), Array(0..<13))
    XCTAssertEqual(chunks.first?.startTime ?? -1, 0, accuracy: 0.001)
    XCTAssertEqual(chunks.last?.endTime ?? -1, 2 * 60 * 60, accuracy: 0.01)
    XCTAssertTrue(
      chunks.allSatisfy {
        $0.byteCount <= TimeBasedAudioChunker.defaultMaximumBytes
      }
    )
    for index in 1..<chunks.count {
      XCTAssertEqual(
        chunks[index - 1].endTime - chunks[index].startTime,
        2,
        accuracy: 0.001
      )
    }
    XCTAssertLessThanOrEqual(extraResidentBytes, 200 * 1_024 * 1_024)
  }

  func testRetryableStatusMatrixStopsAfterTwoRetriesAndHonorsRetryAfter() async throws {
    let transport = HardeningHTTPTransport(steps: [
      .success(HTTPResponse(statusCode: 408)),
      .success(HTTPResponse(statusCode: 429, headers: ["Retry-After": "7"])),
      .success(HTTPResponse(statusCode: 502)),
    ])
    let sleeps = HardeningSleepRecorder()
    let client = try makeClient(transport: transport) {
      await sleeps.append($0)
    }
    let audioURL = try makeAudioFile()
    defer { try? FileManager.default.removeItem(at: audioURL) }

    do {
      _ = try await client.transcribe(audioURL: audioURL)
      XCTFail("Retry budget exhaustion must surface the final provider status.")
    } catch {
      XCTAssertEqual(error as? GroqAPIError, .httpStatus(502))
    }

    let requestCount = await transport.requestCount
    let recordedSleeps = await sleeps.values
    XCTAssertEqual(requestCount, 3)
    XCTAssertEqual(recordedSleeps, [0.25, 7])
  }

  func testPermanentClientErrorsAndPreUploadNetworkFailureNeverRetry() async throws {
    let audioURL = try makeAudioFile()
    defer { try? FileManager.default.removeItem(at: audioURL) }

    for statusCode in [400, 401, 403, 413] {
      let transport = HardeningHTTPTransport(steps: [
        .success(HTTPResponse(statusCode: statusCode))
      ])
      let client = try makeClient(transport: transport) { _ in
        XCTFail("HTTP \(statusCode) must not sleep or retry.")
      }

      do {
        _ = try await client.transcribe(audioURL: audioURL)
        XCTFail("HTTP \(statusCode) must fail.")
      } catch {
        XCTAssertEqual(error as? GroqAPIError, .httpStatus(statusCode))
      }
      let requestCount = await transport.requestCount
      XCTAssertEqual(requestCount, 1)
    }

    let disconnected = HardeningHTTPTransport(steps: [
      .failure(.requestFailed(code: URLError.notConnectedToInternet.rawValue))
    ])
    let disconnectedClient = try makeClient(transport: disconnected) { _ in
      XCTFail("A pre-upload network failure must not be retried implicitly.")
    }
    do {
      _ = try await disconnectedClient.transcribe(audioURL: audioURL)
      XCTFail("A disconnected network must fail.")
    } catch {
      XCTAssertEqual(error as? GroqAPIError, .transportFailed)
    }
    let disconnectedRequestCount = await disconnected.requestCount
    XCTAssertEqual(disconnectedRequestCount, 1)
  }

  func testDiskWriteFailureBecomesVisibleTerminalRecorderState() async throws {
    let capture = HardeningCaptureEngine()
    let recorder = M4RollingSegmentRecorder(capture: capture)
    let sessionID = UUID()

    try await recorder.start(
      sessionID: sessionID,
      directory: URL(
        fileURLWithPath: "/tmp/SpeakNote-M8-LowDisk-\(sessionID.uuidString)"
      )
    )
    await capture.fail(.diskWriteFailed("No space left on device"))

    let state = await eventuallyTerminalState(recorder)
    XCTAssertEqual(
      state,
      .failed(
        sessionID: sessionID,
        failure: .diskWriteFailed("No space left on device")
      )
    )
    let stopCount = await capture.stopCount
    XCTAssertEqual(stopCount, 1)
  }

  private func makeClient(
    transport: any HTTPTransport,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void
  ) throws -> GroqAPIClient {
    try GroqAPIClient(
      apiKey: "test-key",
      baseURL: URL(string: "https://unit.test")!,
      transport: transport,
      retryPolicy: RetryPolicy(
        maximumRetryCount: 2,
        baseDelay: 1,
        maximumDelay: 30,
        randomUnit: { 0.25 }
      ),
      sleep: sleep
    )
  }

  private func makeAudioFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakNote-M8-\(UUID().uuidString).m4a")
    try Data("fixture-audio".utf8).write(to: url, options: .atomic)
    return url
  }

  private func eventuallyTerminalState(
    _ recorder: M4RollingSegmentRecorder
  ) async -> M4RollingRecorderState {
    for _ in 0..<100 {
      let state = await recorder.currentState()
      if case .failed = state { return state }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await recorder.currentState()
  }

  private func makeSparsePCMSource(duration: TimeInterval, at url: URL) throws {
    let sampleRate: UInt32 = 16_000
    let frameCount = UInt32(duration * Double(sampleRate))
    let dataByteCount = frameCount * 2
    var header = Data()
    header.append(contentsOf: "RIFF".utf8)
    appendLittleEndian(UInt32(36) + dataByteCount, to: &header)
    header.append(contentsOf: "WAVEfmt ".utf8)
    appendLittleEndian(UInt32(16), to: &header)
    appendLittleEndian(UInt16(1), to: &header)
    appendLittleEndian(UInt16(1), to: &header)
    appendLittleEndian(sampleRate, to: &header)
    appendLittleEndian(sampleRate * 2, to: &header)
    appendLittleEndian(UInt16(2), to: &header)
    appendLittleEndian(UInt16(16), to: &header)
    header.append(contentsOf: "data".utf8)
    appendLittleEndian(dataByteCount, to: &header)
    XCTAssertEqual(header.count, 44)

    try header.write(to: url, options: .atomic)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(header.count) + UInt64(dataByteCount))
    try handle.close()

    let file = try AVAudioFile(forReading: url)
    XCTAssertEqual(file.length, AVAudioFramePosition(frameCount))
  }

  private func appendLittleEndian<T: FixedWidthInteger>(
    _ value: T,
    to data: inout Data
  ) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) {
      data.append(contentsOf: $0)
    }
  }

  private func maximumResidentBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return UInt64(max(0, usage.ru_maxrss))
  }
}

private actor HardeningHTTPTransport: HTTPTransport {
  private var steps: [Result<HTTPResponse, HTTPTransportError>]
  private(set) var requestCount = 0

  init(steps: [Result<HTTPResponse, HTTPTransportError>]) {
    self.steps = steps
  }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    requestCount += 1
    guard !steps.isEmpty else {
      throw HTTPTransportError.requestFailed(code: nil)
    }
    return try steps.removeFirst().get()
  }
}

private actor HardeningSleepRecorder {
  private(set) var values: [TimeInterval] = []

  func append(_ value: TimeInterval) {
    values.append(value)
  }
}

private actor HardeningCaptureEngine: M4RollingCaptureEngine {
  private var continuation:
    AsyncThrowingStream<M4RollingCaptureEvent, Error>.Continuation?
  private(set) var stopCount = 0

  func start(
    configuration: M4RollingCaptureConfiguration
  ) -> AsyncThrowingStream<M4RollingCaptureEvent, Error> {
    let stream = AsyncThrowingStream<M4RollingCaptureEvent, Error>.makeStream()
    continuation = stream.continuation
    return stream.stream
  }

  func pause() {}
  func resume() {}

  func stop() {
    stopCount += 1
    continuation?.finish()
  }

  func cancel() {
    continuation?.finish(throwing: M4RollingRecorderFailure.cancelled)
  }

  func fail(_ error: M4RollingRecorderFailure) {
    continuation?.finish(throwing: error)
  }
}
