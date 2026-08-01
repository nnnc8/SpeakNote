import Foundation
import XCTest

@testable import SpeakNote

final class SessionFileStoreTests: XCTestCase {
  func testImportsM4AWithChecksumAndUpdatesManifest() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("fixture.m4a")
    let bytes = Data((0..<8_192).map { UInt8($0 % 251) })
    try bytes.write(to: source)
    let store = try SessionFileStore(rootURL: root.appendingPathComponent("AppSupport"))
    let sessionID = UUID()
    _ = try await store.prepareSession(id: sessionID, source: .imported)
    let createdAt = Date(timeIntervalSince1970: 100)

    let asset = try await store.importM4A(
      from: source,
      sessionID: sessionID,
      createdAt: createdAt
    )
    let manifest = try await store.manifest(sessionID: sessionID)
    let copied = try await store.readData(
      sessionID: sessionID,
      relativePath: asset.relativePath,
      expectedSHA256: asset.sha256
    )

    XCTAssertEqual(copied, bytes)
    XCTAssertEqual(asset.kind, .importedOriginal)
    XCTAssertEqual(asset.byteCount, Int64(bytes.count))
    XCTAssertEqual(manifest.assets, [asset])
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: source.appendingPathExtension("partial").path
      )
    )
  }

  func testJSONCommitIsAtomicAndManifestReopens() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let storeRoot = root.appendingPathComponent("AppSupport")
    let firstStore = try SessionFileStore(rootURL: storeRoot)
    let sessionID = UUID()
    _ = try await firstStore.prepareSession(id: sessionID, source: .imported)
    let checkpoint = TranscriptionCheckpoint(
      jobID: UUID(),
      sessionID: sessionID,
      totalChunks: 3,
      updatedAt: Date(timeIntervalSince1970: 100)
    )

    let asset = try await firstStore.writeJSON(
      checkpoint,
      sessionID: sessionID,
      relativePath: "jobs/\(checkpoint.jobID.uuidString)/checkpoint.json",
      kind: .checkpoint
    )
    let secondStore = try SessionFileStore(rootURL: storeRoot)
    let reopened = try await secondStore.manifest(sessionID: sessionID)
    let encoded = try await secondStore.readData(
      sessionID: sessionID,
      relativePath: asset.relativePath,
      expectedSHA256: asset.sha256
    )

    XCTAssertEqual(reopened.assets.map(\.relativePath), [asset.relativePath])
    XCTAssertEqual(
      try JSONDecoder.sessionStore.decode(TranscriptionCheckpoint.self, from: encoded),
      checkpoint
    )
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath:
          storeRoot
          .appendingPathComponent("Sessions/\(sessionID.uuidString)/\(asset.relativePath).partial")
          .path
      )
    )
  }

  func testRejectsTraversalAndDuplicateAssetWithoutChangingManifest() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionFileStore(rootURL: root)
    let sessionID = UUID()
    _ = try await store.prepareSession(id: sessionID, source: .imported)

    do {
      _ = try await store.write(
        Data("secret".utf8),
        sessionID: sessionID,
        relativePath: "../escape",
        kind: .rawTranscriptMarkdown
      )
      XCTFail("Traversal must be rejected")
    } catch let error as SessionFileStoreError {
      XCTAssertEqual(error, .invalidRelativePath)
    }

    _ = try await store.write(
      Data("one".utf8),
      sessionID: sessionID,
      relativePath: "transcripts/raw-v1.md",
      kind: .rawTranscriptMarkdown
    )
    do {
      _ = try await store.write(
        Data("two".utf8),
        sessionID: sessionID,
        relativePath: "transcripts/raw-v1.md",
        kind: .rawTranscriptMarkdown
      )
      XCTFail("Immutable raw output must not be replaced")
    } catch let error as SessionFileStoreError {
      XCTAssertEqual(error, .assetAlreadyExists)
    }
    let manifest = try await store.manifest(sessionID: sessionID)
    XCTAssertEqual(manifest.assets.count, 1)
  }

  func testPendingDeletionRemovesSessionDirectory() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionFileStore(rootURL: root)
    let sessionID = UUID()
    _ = try await store.prepareSession(id: sessionID, source: .recorded)

    try await store.removeSession(sessionID: sessionID)

    do {
      _ = try await store.manifest(sessionID: sessionID)
      XCTFail("Deleted session must not remain indexed by its manifest")
    } catch let error as SessionFileStoreError {
      XCTAssertEqual(error, .sessionNotFound)
    }
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakNote-SessionStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url
  }
}

extension JSONDecoder {
  fileprivate static var sessionStore: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
  }
}
