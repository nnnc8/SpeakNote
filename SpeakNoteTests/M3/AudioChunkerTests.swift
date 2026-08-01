import AVFAudio
import XCTest

@testable import SpeakNote

final class AudioChunkerTests: XCTestCase {
  func testConvertsInChunksWithTimeOverlapAndHardByteLimit() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try makeSource(duration: 1.1, in: root)
    let output = root.appendingPathComponent("chunks")
    let maximumBytes: Int64 = 24 * 1024

    let chunks = try await TimeBasedAudioChunker(
      destinationDirectory: output,
      maximumDuration: 0.4,
      maximumBytes: maximumBytes,
      overlapDuration: 0.1
    ).chunks(from: source)

    XCTAssertEqual(chunks.count, 4)
    XCTAssertEqual(chunks.map(\.index), [0, 1, 2, 3])
    XCTAssertEqual(chunks[0].startTime, 0, accuracy: 0.001)
    XCTAssertEqual(chunks[1].startTime, 0.3, accuracy: 0.001)
    XCTAssertEqual(chunks[2].startTime, 0.6, accuracy: 0.001)
    XCTAssertEqual(chunks[3].startTime, 0.9, accuracy: 0.001)
    XCTAssertEqual(chunks.last?.endTime ?? 0, 1.1, accuracy: 0.002)

    for chunk in chunks {
      XCTAssertLessThanOrEqual(chunk.byteCount, maximumBytes)
      XCTAssertEqual(chunk.sha256.count, 64)
      let file = try AVAudioFile(forReading: chunk.url)
      XCTAssertEqual(file.fileFormat.sampleRate, 16_000, accuracy: 0.1)
      XCTAssertEqual(file.fileFormat.channelCount, 1)
      XCTAssertEqual(
        (file.fileFormat.settings[AVLinearPCMBitDepthKey] as? NSNumber)?.intValue,
        16
      )
    }
  }

  func testByteLimitSplitsBeforeDurationLimit() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try makeSource(duration: 0.3, in: root)
    let output = root.appendingPathComponent("chunks")
    let maximumBytes: Int64 = 4_096 + 1_600 * 2

    let chunks = try await TimeBasedAudioChunker(
      destinationDirectory: output,
      maximumDuration: 10,
      maximumBytes: maximumBytes,
      overlapDuration: 0.02
    ).chunks(from: source)

    XCTAssertGreaterThan(chunks.count, 1)
    XCTAssertTrue(chunks.allSatisfy { $0.byteCount <= maximumBytes })
    XCTAssertTrue(chunks.allSatisfy { $0.endTime - $0.startTime <= 0.101 })
  }

  func testCancellationRemovesInvocationOutputs() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try makeSource(duration: 0.2, in: root)
    let output = root.appendingPathComponent("chunks")
    let chunker = TimeBasedAudioChunker(destinationDirectory: output)

    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await chunker.chunks(from: source)
    }

    do {
      _ = try await task.value
      XCTFail("A cancelled chunk operation must not return descriptors.")
    } catch is CancellationError {
      let files =
        (try? FileManager.default.contentsOfDirectory(
          at: output,
          includingPropertiesForKeys: nil
        )) ?? []
      XCTAssertTrue(files.isEmpty)
    }
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakNoteChunkTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url
  }

  private func makeSource(duration: TimeInterval, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("source.caf")
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
      ))
    let file = try AVAudioFile(
      forWriting: url,
      settings: format.settings,
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    var remaining = Int(duration * format.sampleRate)
    var phase = 0
    while remaining > 0 {
      let count = min(2_048, remaining)
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(
          pcmFormat: format,
          frameCapacity: AVAudioFrameCount(count)
        ))
      buffer.frameLength = AVAudioFrameCount(count)
      for channel in 0..<Int(format.channelCount) {
        let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
        for frame in 0..<count {
          samples[frame] = sin(Float(phase + frame) * 0.03)
        }
      }
      try file.write(from: buffer)
      phase += count
      remaining -= count
    }
    return url
  }
}
