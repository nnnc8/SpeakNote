import Foundation
import XCTest

@testable import SpeakNote

@MainActor
final class M4AudioPlayerControllerTests: XCTestCase {
  func testLoadPlayPauseStopAndProgressState() throws {
    let fixture = try makeFixture(durations: [2, 3, 4])
    defer { fixture.removeFiles() }
    let backend = FakeM4AudioPlaybackBackend()
    let controller = M4AudioPlayerController(backend: backend)

    try controller.load(segments: fixture.segments.reversed())

    XCTAssertEqual(controller.duration, 9)
    XCTAssertEqual(controller.progress, 0)
    XCTAssertEqual(controller.state, .ready)
    XCTAssertEqual(backend.loadedURLs, fixture.segments.map(\.url))

    try controller.play()
    XCTAssertEqual(controller.state, .playing)
    controller.pause()
    XCTAssertEqual(controller.state, .paused)
    controller.stop()
    XCTAssertEqual(controller.state, .stopped)
    XCTAssertEqual(controller.progress, 0)
    XCTAssertEqual(backend.actions, [.play, .pause, .stop])

    try controller.play()
    backend.emit(.position(segmentIndex: 1, time: 1.25))
    XCTAssertEqual(controller.progress, 3.25, accuracy: 0.001)
    backend.emit(.completed)
    XCTAssertEqual(controller.progress, 9)
    XCTAssertEqual(controller.state, .completed)
  }

  func testSeekMapsBoundariesAcrossSegmentsAndFinalEndpoint() throws {
    let fixture = try makeFixture(durations: [2, 3, 4])
    defer { fixture.removeFiles() }
    let backend = FakeM4AudioPlaybackBackend()
    let controller = M4AudioPlayerController(backend: backend)
    try controller.load(segments: fixture.segments)

    try controller.seek(to: 1.5)
    try controller.seek(to: 2)
    try controller.seek(to: 4.5)
    try controller.seek(to: 9)
    try controller.seek(to: 99)

    XCTAssertEqual(
      backend.seeks,
      [
        .init(segmentIndex: 0, time: 1.5),
        .init(segmentIndex: 1, time: 0),
        .init(segmentIndex: 1, time: 2.5),
        .init(segmentIndex: 2, time: 4),
        .init(segmentIndex: 2, time: 4),
      ]
    )
    XCTAssertEqual(controller.progress, 9)
  }

  func testPlayingSeekResumesAndCompletedPlayRestarts() throws {
    let fixture = try makeFixture(durations: [2, 3])
    defer { fixture.removeFiles() }
    let backend = FakeM4AudioPlaybackBackend()
    let controller = M4AudioPlayerController(backend: backend)
    try controller.load(segments: fixture.segments)
    try controller.play()

    try controller.seek(to: 2.5)
    XCTAssertEqual(
      backend.actions,
      [.play, .seek(segmentIndex: 1, time: 0.5), .play]
    )
    backend.emit(.completed)
    try controller.play()
    XCTAssertEqual(
      backend.actions.suffix(2),
      [.seek(segmentIndex: 0, time: 0), .play]
    )
    XCTAssertEqual(controller.progress, 0)
    XCTAssertEqual(controller.state, .playing)
  }

  func testMissingFileAndInvalidDurationAreTypedFailures() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let missing = makeSegment(
      sessionID: UUID(),
      index: 0,
      url: directory.appendingPathComponent("missing.caf"),
      startTime: 0,
      duration: 1
    )
    let missingController = M4AudioPlayerController(
      backend: FakeM4AudioPlaybackBackend()
    )

    XCTAssertThrowsError(try missingController.load(segments: [missing])) {
      XCTAssertEqual(
        $0 as? M4AudioPlayerError,
        .missingFile(index: 0)
      )
    }
    XCTAssertEqual(
      missingController.state,
      .failed(.missingFile(index: 0))
    )

    let existingURL = directory.appendingPathComponent("segment.caf")
    try Data().write(to: existingURL)
    let invalid = makeSegment(
      sessionID: UUID(),
      index: 0,
      url: existingURL,
      startTime: 1,
      duration: 0
    )
    let invalidController = M4AudioPlayerController(
      backend: FakeM4AudioPlaybackBackend()
    )
    XCTAssertThrowsError(try invalidController.load(segments: [invalid])) {
      XCTAssertEqual(
        $0 as? M4AudioPlayerError,
        .invalidDuration(index: 0)
      )
    }
    XCTAssertEqual(
      invalidController.state,
      .failed(.invalidDuration(index: 0))
    )
  }

  private func makeFixture(
    durations: [TimeInterval]
  ) throws -> M4PlayerFixture {
    let directory = try temporaryDirectory()
    let sessionID = UUID()
    var offset: TimeInterval = 0
    var segments: [M4RecordingSegment] = []
    for (index, duration) in durations.enumerated() {
      let url = directory.appendingPathComponent("segment-\(index).caf")
      try Data("segment-\(index)".utf8).write(to: url)
      segments.append(
        makeSegment(
          sessionID: sessionID,
          index: index,
          url: url,
          startTime: offset,
          duration: duration
        )
      )
      offset += duration
    }
    return M4PlayerFixture(directory: directory, segments: segments)
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
      .appendingPathComponent("M4AudioPlayerControllerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }
}

private struct M4PlayerFixture {
  let directory: URL
  let segments: [M4RecordingSegment]

  func removeFiles() {
    try? FileManager.default.removeItem(at: directory)
  }
}

@MainActor
private final class FakeM4AudioPlaybackBackend: M4AudioPlaybackBackend {
  struct Seek: Equatable {
    let segmentIndex: Int
    let time: TimeInterval
  }

  enum Action: Equatable {
    case play
    case pause
    case stop
    case seek(segmentIndex: Int, time: TimeInterval)
  }

  var eventHandler: ((M4AudioPlaybackEvent) -> Void)?
  private(set) var loadedURLs: [URL] = []
  private(set) var actions: [Action] = []
  private(set) var seeks: [Seek] = []

  func load(urls: [URL]) {
    loadedURLs = urls
  }

  func play() {
    actions.append(.play)
  }

  func pause() {
    actions.append(.pause)
  }

  func stop() {
    actions.append(.stop)
  }

  func seek(toSegment index: Int, time: TimeInterval) {
    seeks.append(Seek(segmentIndex: index, time: time))
    actions.append(.seek(segmentIndex: index, time: time))
  }

  func emit(_ event: M4AudioPlaybackEvent) {
    eventHandler?(event)
  }
}
