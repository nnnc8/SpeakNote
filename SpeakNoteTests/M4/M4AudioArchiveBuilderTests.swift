@preconcurrency import AVFoundation
import Foundation
import XCTest

@testable import SpeakNote

final class M4AudioArchiveBuilderTests: XCTestCase {
  func testBuildsPlayableVerifiedArchiveFromOrderedSegments() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sessionID = UUID()
    let firstURL = directory.appendingPathComponent("segment-000000.caf")
    let secondURL = directory.appendingPathComponent("segment-000001.caf")
    let firstDuration = try writeCAF(at: firstURL, duration: 0.12)
    let secondDuration = try writeCAF(at: secondURL, duration: 0.08)
    let first = makeSegment(
      sessionID: sessionID,
      index: 0,
      url: firstURL,
      startTime: 0,
      duration: firstDuration
    )
    let second = makeSegment(
      sessionID: sessionID,
      index: 1,
      url: secondURL,
      startTime: firstDuration,
      duration: secondDuration
    )
    let destination = directory.appendingPathComponent("archive.m4a")

    let archive = try await M4AVFoundationAudioArchiveBuilder().buildArchive(
      segments: [second, first],
      destinationURL: destination
    )

    XCTAssertEqual(archive.url, destination)
    XCTAssertEqual(archive.sha256.count, 64)
    XCTAssertEqual(archive.sha256, try M4RecordingRecovery.sha256(of: destination))
    XCTAssertGreaterThan(archive.byteCount, 0)
    XCTAssertEqual(
      archive.byteCount,
      Int64(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    )
    XCTAssertEqual(
      archive.duration,
      firstDuration + secondDuration,
      accuracy: 0.05
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: destination.appendingPathExtension("partial").path
      )
    )

    let asset = AVURLAsset(url: destination)
    let isPlayable = try await asset.load(.isPlayable)
    let duration = try await asset.load(.duration).seconds
    XCTAssertTrue(isPlayable)
    XCTAssertTrue(duration.isFinite)
    XCTAssertGreaterThan(duration, 0)
  }

  func testRejectsMissingInvalidAndNoncontiguousSegments() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sessionID = UUID()
    let destination = directory.appendingPathComponent("archive.m4a")
    let missing = makeSegment(
      sessionID: sessionID,
      index: 0,
      url: directory.appendingPathComponent("missing.caf"),
      startTime: 0,
      duration: 1
    )

    await assertArchiveError(
      .missingSegment(index: 0),
      segments: [missing],
      destination: destination
    )

    let existingURL = directory.appendingPathComponent("segment.caf")
    try Data("source".utf8).write(to: existingURL)
    let invalidDuration = makeSegment(
      sessionID: sessionID,
      index: 0,
      url: existingURL,
      startTime: 1,
      duration: 0
    )
    await assertArchiveError(
      .invalidSegmentDuration(index: 0),
      segments: [invalidDuration],
      destination: destination
    )

    let noncontiguous = makeSegment(
      sessionID: sessionID,
      index: 1,
      url: existingURL,
      startTime: 0,
      duration: 1
    )
    await assertArchiveError(
      .noncontiguousSegments,
      segments: [noncontiguous],
      destination: destination
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: destination.appendingPathExtension("partial").path
      )
    )
  }

  func testCancellationRemovesPartialAndPreservesSourceSegment() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("segment-000000.caf")
    try Data("immutable-pcm".utf8).write(to: sourceURL)
    let segment = makeSegment(
      sessionID: UUID(),
      index: 0,
      url: sourceURL,
      startTime: 0,
      duration: 1
    )
    let destination = directory.appendingPathComponent("archive.m4a")
    let started = AsyncStream<Void>.makeStream()
    let builder = M4AVFoundationAudioArchiveBuilder {
      _, partialURL in
      try Data("partial".utf8).write(to: partialURL)
      started.continuation.yield()
      try await Task.sleep(for: .seconds(60))
    }
    let task = Task {
      try await builder.buildArchive(
        segments: [segment],
        destinationURL: destination
      )
    }
    for await _ in started.stream.prefix(1) {
      break
    }

    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation.")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    started.continuation.finish()

    XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: destination.appendingPathExtension("partial").path
      )
    )
  }

  private func assertArchiveError(
    _ expected: M4AudioArchiveError,
    segments: [M4RecordingSegment],
    destination: URL
  ) async {
    do {
      _ = try await M4AVFoundationAudioArchiveBuilder().buildArchive(
        segments: segments,
        destinationURL: destination
      )
      XCTFail("Expected archive validation failure.")
    } catch {
      XCTAssertEqual(error as? M4AudioArchiveError, expected)
    }
  }

  private func makeSegment(
    sessionID: UUID,
    index: Int,
    url: URL,
    startTime: TimeInterval,
    duration: TimeInterval
  ) -> M4RecordingSegment {
    M4RecordingSegment(
      sessionID: sessionID,
      index: index,
      url: url,
      relativePath: url.lastPathComponent,
      startTime: startTime,
      endTime: startTime + duration,
      byteCount: 1,
      sha256: "fixture",
      createdAt: Date(timeIntervalSince1970: 100)
    )
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("M4AudioArchiveBuilderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  private func writeCAF(
    at url: URL,
    duration: TimeInterval
  ) throws -> TimeInterval {
    let sampleRate = 16_000.0
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
      )
    )
    var file: AVAudioFile? = try AVAudioFile(
      forWriting: url,
      settings: format.settings
    )
    let frameCount = AVAudioFrameCount(sampleRate * duration)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
    )
    buffer.frameLength = frameCount
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    for frame in 0..<Int(frameCount) {
      samples[frame] = sin(Float(frame) * 0.03)
    }
    try file?.write(from: buffer)
    file = nil
    return Double(frameCount) / sampleRate
  }
}
