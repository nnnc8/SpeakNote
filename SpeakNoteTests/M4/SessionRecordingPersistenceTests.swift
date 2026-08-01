import CryptoKit
import Foundation
import XCTest

@testable import SpeakNote

final class SessionRecordingPersistenceTests: XCTestCase {
  func testRegistersClosedCaptureSegmentAndIsIdempotent() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionFileStore(rootURL: root)
    let sessionID = UUID()
    _ = try await store.prepareSession(id: sessionID, source: .recorded)
    let segmentURL = try await store.fileURL(
      sessionID: sessionID,
      relativePath: "audio/capture-0000.caf"
    )
    let data = Data(repeating: 42, count: 4_096)
    try data.write(to: segmentURL)
    let sha256 = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()

    let first = try await store.registerExistingAsset(
      sessionID: sessionID,
      relativePath: "audio/capture-0000.caf",
      kind: .captureSegment,
      expectedSHA256: sha256,
      expectedByteCount: Int64(data.count),
      createdAt: Date(timeIntervalSince1970: 100)
    )
    let second = try await store.registerExistingAsset(
      sessionID: sessionID,
      relativePath: "audio/capture-0000.caf",
      kind: .captureSegment,
      expectedSHA256: sha256,
      expectedByteCount: Int64(data.count),
      createdAt: Date(timeIntervalSince1970: 200)
    )
    let manifest = try await store.manifest(sessionID: sessionID)

    XCTAssertEqual(first, second)
    XCTAssertEqual(first.kind, .captureSegment)
    XCTAssertEqual(manifest.assets.filter { $0.kind == .captureSegment }, [first])
  }

  func testRejectsCaptureSegmentWhenClosedFileDoesNotMatchMetadata() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionFileStore(rootURL: root)
    let sessionID = UUID()
    _ = try await store.prepareSession(id: sessionID, source: .recorded)
    let segmentURL = try await store.fileURL(
      sessionID: sessionID,
      relativePath: "audio/capture-0000.caf"
    )
    try Data(repeating: 1, count: 64).write(to: segmentURL)

    do {
      _ = try await store.registerExistingAsset(
        sessionID: sessionID,
        relativePath: "audio/capture-0000.caf",
        kind: .captureSegment,
        expectedSHA256: String(repeating: "0", count: 64),
        expectedByteCount: 64
      )
      XCTFail("A mismatched segment must not enter the manifest.")
    } catch let error as SessionFileStoreError {
      XCTAssertEqual(error, .checksumMismatch)
    }
    let manifest = try await store.manifest(sessionID: sessionID)
    XCTAssertTrue(manifest.assets.isEmpty)
  }

  func testRecordingJournalRoundTripsAcrossStoreReopenAndClearsByOwner() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let firstStore = try SessionFileStore(rootURL: root)
    _ = try await firstStore.prepareSession(id: sessionID, source: .recorded)
    let journal = RecordingJournal(
      sessionID: sessionID,
      startedAt: Date(timeIntervalSince1970: 100),
      updatedAt: Date(timeIntervalSince1970: 110),
      segmentDuration: 300,
      lastClosedSegmentIndex: 2,
      state: .recording
    )

    try await firstStore.writeRecordingJournal(journal)
    let reopenedStore = try SessionFileStore(rootURL: root)
    let reopened = try await reopenedStore.recordingJournal()
    let ids = try await reopenedStore.sessionIDs()

    XCTAssertEqual(reopened, journal)
    XCTAssertEqual(ids, [sessionID])

    do {
      try await reopenedStore.clearRecordingJournal(sessionID: UUID())
      XCTFail("A different session must not clear the active journal.")
    } catch let error as SessionFileStoreError {
      XCTAssertEqual(error, .invalidRecordingJournal)
    }
    try await reopenedStore.clearRecordingJournal(sessionID: sessionID)
    let cleared = try await reopenedStore.recordingJournal()
    XCTAssertNil(cleared)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakNote-M4PersistenceTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url
  }
}
