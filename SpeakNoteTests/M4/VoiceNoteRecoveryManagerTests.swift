@preconcurrency import AVFAudio
import Foundation
import XCTest

@testable import SpeakNote

final class VoiceNoteRecoveryManagerTests: XCTestCase {
  func testReconcileRegistersClosedSegmentsAndOffersRecovery() async throws {
    let fixture = try await makeFixture(status: .recording)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let segmentURL = try await fixture.fileStore.fileURL(
      sessionID: fixture.sessionID,
      relativePath: "audio/capture-000000.caf"
    )
    try writeCAF(to: segmentURL, duration: 0.25)
    try await fixture.fileStore.writeRecordingJournal(
      RecordingJournal(
        sessionID: fixture.sessionID,
        startedAt: Date(timeIntervalSince1970: 100),
        segmentDuration: 300,
        state: .recording
      )
    )
    let manager = VoiceNoteRecoveryManager(
      repository: fixture.repository,
      fileStore: fixture.fileStore,
      now: { Date(timeIntervalSince1970: 200) }
    )

    let candidates = try await manager.reconcile()
    let playback = try await manager.playbackSegments(
      sessionID: fixture.sessionID
    )

    let candidate = try XCTUnwrap(candidates.first)
    let session = try await fixture.repository.session(id: fixture.sessionID)
    let manifest = try await fixture.fileStore.manifest(
      sessionID: fixture.sessionID
    )
    XCTAssertEqual(candidate.id, fixture.sessionID)
    XCTAssertEqual(candidate.completeSegments.map(\.index), [0])
    XCTAssertEqual(playback.map(\.index), [0])
    XCTAssertEqual(
      playback.first?.url.resolvingSymlinksInPath(),
      segmentURL.resolvingSymlinksInPath()
    )
    XCTAssertNil(candidate.incompleteCurrentSegment)
    XCTAssertEqual(session?.status, .recoveryAvailable)
    XCTAssertGreaterThan(session?.duration ?? 0, 0)
    XCTAssertEqual(
      manifest.assets.filter { $0.kind == .captureSegment }.count,
      1
    )
    XCTAssertEqual(manifest.state, .interrupted)
  }

  func testReconcileMarksDatabaseSessionNeedsRepairWhenManifestIsMissing() async throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let repository = SwiftDataSessionRepository(
      modelContainer: try SpeakNoteModelContainer.inMemory()
    )
    let sessionID = UUID()
    _ = try await repository.createSession(
      NewRecordingSession(
        id: sessionID,
        title: "Missing files",
        source: .recorded,
        status: .interrupted,
        duration: 10
      )
    )
    let manager = VoiceNoteRecoveryManager(
      repository: repository,
      fileStore: try SessionFileStore(rootURL: rootURL)
    )

    let candidates = try await manager.reconcile()
    let repaired = try await repository.session(id: sessionID)

    XCTAssertTrue(candidates.isEmpty)
    XCTAssertEqual(repaired?.status, .needsRepair)
    XCTAssertEqual(repaired?.needsRepair, true)
  }

  func testReconcileRebuildsMetadataForManifestWithoutDatabaseRow() async throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileStore = try SessionFileStore(rootURL: rootURL)
    let repository = SwiftDataSessionRepository(
      modelContainer: try SpeakNoteModelContainer.inMemory()
    )
    let sessionID = UUID()
    _ = try await fileStore.prepareSession(
      id: sessionID,
      source: .imported,
      createdAt: Date(timeIntervalSince1970: 50)
    )
    let manager = VoiceNoteRecoveryManager(
      repository: repository,
      fileStore: fileStore
    )

    let candidates = try await manager.reconcile()
    let rebuilt = try await repository.session(id: sessionID)

    XCTAssertTrue(candidates.isEmpty)
    XCTAssertEqual(rebuilt?.title, String(localized: "Recovered Voice Note"))
    XCTAssertEqual(rebuilt?.source, .imported)
    XCTAssertEqual(rebuilt?.status, .needsRepair)
  }

  func testKeepAudioClearsJournalWithoutDeletingRecoveredSegments() async throws {
    let fixture = try await makeFixture(status: .interrupted)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let segmentURL = try await fixture.fileStore.fileURL(
      sessionID: fixture.sessionID,
      relativePath: "audio/capture-000000.caf"
    )
    try writeCAF(to: segmentURL, duration: 0.25)
    try await fixture.fileStore.writeRecordingJournal(
      RecordingJournal(
        sessionID: fixture.sessionID,
        startedAt: Date(timeIntervalSince1970: 100),
        segmentDuration: 300,
        state: .interrupted
      )
    )
    let manager = VoiceNoteRecoveryManager(
      repository: fixture.repository,
      fileStore: fixture.fileStore
    )
    _ = try await manager.reconcile()

    try await manager.keepAudio(sessionID: fixture.sessionID)

    let journal = try await fixture.fileStore.recordingJournal()
    let session = try await fixture.repository.session(id: fixture.sessionID)
    let manifest = try await fixture.fileStore.manifest(
      sessionID: fixture.sessionID
    )
    XCTAssertNil(journal)
    XCTAssertEqual(session?.status, .interrupted)
    XCTAssertEqual(manifest.state, .interrupted)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: segmentURL.path)
    )
  }

  func testPlaybackPrefersDurableArchiveAfterCaptureSegmentsArePruned() async throws {
    let fixture = try await makeFixture(status: .ready)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let archive = try await fixture.fileStore.write(
      Data("archive".utf8),
      sessionID: fixture.sessionID,
      relativePath: "audio/archive.m4a",
      kind: .archive
    )
    _ = try await fixture.repository.updateSession(
      id: fixture.sessionID,
      status: .ready,
      duration: 12,
      currentJobID: nil,
      updatedAt: Date(timeIntervalSince1970: 200)
    )
    let manager = VoiceNoteRecoveryManager(
      repository: fixture.repository,
      fileStore: fixture.fileStore
    )

    let segments = try await manager.playbackSegments(
      sessionID: fixture.sessionID
    )

    XCTAssertEqual(segments.count, 1)
    XCTAssertEqual(segments[0].relativePath, "audio/archive.m4a")
    XCTAssertEqual(segments[0].endTime, 12)
    XCTAssertEqual(segments[0].sha256, archive.sha256)
  }

  private func makeFixture(
    status: VoiceNoteSessionStatus
  ) async throws -> RecoveryFixture {
    let rootURL = try temporaryDirectory()
    let fileStore = try SessionFileStore(rootURL: rootURL)
    let repository = SwiftDataSessionRepository(
      modelContainer: try SpeakNoteModelContainer.inMemory()
    )
    let sessionID = UUID()
    _ = try await fileStore.prepareSession(
      id: sessionID,
      source: .recorded,
      createdAt: Date(timeIntervalSince1970: 100)
    )
    _ = try await repository.createSession(
      NewRecordingSession(
        id: sessionID,
        title: "Recovered recording",
        createdAt: Date(timeIntervalSince1970: 100),
        source: .recorded,
        status: status,
        duration: 0
      )
    )
    return RecoveryFixture(
      rootURL: rootURL,
      fileStore: fileStore,
      repository: repository,
      sessionID: sessionID
    )
  }

  private func writeCAF(to url: URL, duration: TimeInterval) throws {
    let sampleRate = 8_000.0
    let frames = AVAudioFrameCount(sampleRate * duration)
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
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
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
    )
    buffer.frameLength = frames
    if let samples = buffer.floatChannelData?[0] {
      for index in 0..<Int(frames) {
        samples[index] = sin(Float(index) * 0.01) * 0.1
      }
    }
    try file.write(from: buffer)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakNote-RecoveryManagerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url
  }
}

private struct RecoveryFixture {
  let rootURL: URL
  let fileStore: SessionFileStore
  let repository: SwiftDataSessionRepository
  let sessionID: UUID
}
