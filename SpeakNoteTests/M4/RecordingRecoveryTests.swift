import AVFAudio
import XCTest

@testable import SpeakNote

final class RecordingRecoveryTests: XCTestCase {
  func testScanRecoversCompleteSegmentsAndMarksCurrentPartial() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try makeCAF(
      at: directory.appendingPathComponent("segment-000000.caf"),
      duration: 0.1
    )
    try makeCAF(
      at: directory.appendingPathComponent("segment-000002.caf"),
      duration: 0.2
    )
    try makeCAF(
      at: directory.appendingPathComponent("segment-000003.partial.caf"),
      duration: 0.05
    )
    let sessionID = UUID()

    let report = try await M4RecordingRecovery().scan(
      sessionID: sessionID,
      directory: directory
    )

    XCTAssertEqual(report.completeSegments.map(\.index), [0, 2])
    XCTAssertEqual(report.completeSegments.map(\.sessionID), [sessionID, sessionID])
    XCTAssertEqual(report.completeSegments[0].startTime, 0, accuracy: 0.001)
    XCTAssertEqual(report.completeSegments[0].endTime, 0.1, accuracy: 0.002)
    XCTAssertEqual(report.completeSegments[1].startTime, 0.1, accuracy: 0.002)
    XCTAssertEqual(report.completeSegments[1].endTime, 0.3, accuracy: 0.003)
    XCTAssertTrue(report.completeSegments.allSatisfy { $0.sha256.count == 64 })
    XCTAssertEqual(report.incompleteCurrentSegment?.index, 3)
    XCTAssertEqual(
      report.incompleteCurrentSegment?.recoverableDuration ?? 0,
      0.05,
      accuracy: 0.002
    )
    XCTAssertTrue(report.issues.contains(.missingSegment(index: 1)))
  }

  func testClassificationIsPureAndKeepsOnlyNewestUncommittedPartial() {
    let urls = [
      URL(fileURLWithPath: "/tmp/segment-000000.caf"),
      URL(fileURLWithPath: "/tmp/segment-000000.partial.caf"),
      URL(fileURLWithPath: "/tmp/segment-000001.partial.caf"),
      URL(fileURLWithPath: "/tmp/segment-000002.partial.caf"),
      URL(fileURLWithPath: "/tmp/notes.txt"),
    ]

    let result = M4RecordingRecovery.classify(urls)

    XCTAssertEqual(result.complete.map(\.index), [0])
    XCTAssertEqual(result.currentPartial?.index, 2)
    XCTAssertEqual(
      result.orphanedPartials.map(\.lastPathComponent),
      ["segment-000000.partial.caf", "segment-000001.partial.caf"]
    )
  }

  func testUnreadableCompleteSegmentIsReportedWithoutHidingOtherSegments() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let corrupt = directory.appendingPathComponent("segment-000000.caf")
    try Data("not audio".utf8).write(to: corrupt)
    try makeCAF(
      at: directory.appendingPathComponent("segment-000001.caf"),
      duration: 0.05
    )

    let report = try await M4RecordingRecovery().scan(
      sessionID: UUID(),
      directory: directory
    )

    XCTAssertEqual(report.completeSegments.map(\.index), [1])
    XCTAssertTrue(
      report.issues.contains {
        if case .unreadableSegment(let url) = $0 {
          return url.standardizedFileURL.path == corrupt.standardizedFileURL.path
        }
        return false
      }
    )
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakNote-M4-Recovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  private func makeCAF(at url: URL, duration: TimeInterval) throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
      )
    )
    let file = try AVAudioFile(
      forWriting: url,
      settings: format.settings,
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    let frameCount = Int(duration * format.sampleRate)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(frameCount)
      )
    )
    buffer.frameLength = AVAudioFrameCount(frameCount)
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    for frame in 0..<frameCount {
      samples[frame] = sin(Float(frame) * 0.03)
    }
    try file.write(from: buffer)
  }
}
