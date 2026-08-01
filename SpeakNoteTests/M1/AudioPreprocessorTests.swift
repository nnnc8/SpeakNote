import AVFAudio
import AudioToolbox
import XCTest

@testable import SpeakNote

@MainActor
final class AudioPreprocessorTests: XCTestCase {
  func testConvertsCAFToSixteenKilohertzMonoPCM16WAV() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = try makeSourceCAF(in: directory)

    let outputURL = try await PCM16WAVPreprocessor(
      destinationDirectory: directory
    ).preprocess(cafURL: sourceURL)
    let outputFile = try AVAudioFile(forReading: outputURL)

    XCTAssertEqual(outputURL.pathExtension, "wav")
    XCTAssertEqual(outputFile.fileFormat.sampleRate, 16_000, accuracy: 0.1)
    XCTAssertEqual(outputFile.fileFormat.channelCount, 1)
    XCTAssertEqual(
      (outputFile.fileFormat.settings[AVLinearPCMBitDepthKey] as? NSNumber)?.intValue,
      16
    )
    XCTAssertGreaterThan(outputFile.length, 0)
    let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testCancellationRemovesConvertedOutput() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = try makeSourceCAF(in: directory)
    let outputURL = directory.appendingPathComponent("source-16k.wav")
    let preprocessor = PCM16WAVPreprocessor(destinationDirectory: directory)

    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await preprocessor.preprocess(cafURL: sourceURL)
    }

    do {
      _ = try await task.value
      XCTFail("A cancelled conversion must not return an audio file.")
    } catch is CancellationError {
      XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakNoteAudioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  private func makeSourceCAF(in directory: URL) throws -> URL {
    let sourceURL = directory.appendingPathComponent("source.caf")
    let sourceFormat = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 44_100,
        channels: 2,
        interleaved: false
      ))
    let sourceFile = try AVAudioFile(
      forWriting: sourceURL,
      settings: sourceFormat.settings,
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(
        pcmFormat: sourceFormat,
        frameCapacity: 4_410
      ))
    buffer.frameLength = 4_410
    for channel in 0..<Int(sourceFormat.channelCount) {
      let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
      for frame in 0..<Int(buffer.frameLength) {
        samples[frame] = sin(Float(frame) * 0.03)
      }
    }
    try sourceFile.write(from: buffer)
    return sourceURL
  }
}
