@preconcurrency import AVFAudio
import AudioToolbox
import Foundation
import XCTest

@testable import SpeakNote

final class AudioImporterTests: XCTestCase {
  func testImportsRealM4AIntoSessionStore() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("source.m4a")
    try writeM4A(at: sourceURL)
    let store = try SessionFileStore(rootURL: root)
    let sessionID = UUID()
    _ = try await store.prepareSession(id: sessionID, source: .imported)
    let importer = AVFoundationAudioImporter(fileStore: store)

    let imported = try await importer.importAudio(
      from: sourceURL,
      sessionID: sessionID
    )

    XCTAssertEqual(imported.asset.kind, .importedOriginal)
    XCTAssertEqual(imported.asset.relativePath, "audio/imported-original.m4a")
    XCTAssertTrue(imported.duration.isFinite)
    XCTAssertGreaterThan(imported.duration, 0)
    let copiedURL = try await store.fileURL(
      sessionID: sessionID,
      relativePath: imported.asset.relativePath
    )
    let manifest = try await store.manifest(sessionID: sessionID)
    XCTAssertTrue(FileManager.default.fileExists(atPath: copiedURL.path))
    let storedAsset = try XCTUnwrap(manifest.assets.first)
    XCTAssertEqual(manifest.assets.count, 1)
    XCTAssertEqual(storedAsset.id, imported.asset.id)
    XCTAssertEqual(storedAsset.kind, imported.asset.kind)
    XCTAssertEqual(storedAsset.relativePath, imported.asset.relativePath)
    XCTAssertEqual(storedAsset.sha256, imported.asset.sha256)
    XCTAssertEqual(storedAsset.byteCount, imported.asset.byteCount)
  }

  func testRejectsWrongExtensionBeforeSecurityScope() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionFileStore(rootURL: root)
    let scope = SecurityScopeSpy()
    let importer = AVFoundationAudioImporter(
      fileStore: store,
      validator: FixedAudioAssetValidator(
        metadata: AudioAssetMetadata(isPlayable: true, duration: 1)
      ),
      securityScope: scope.access()
    )

    do {
      _ = try await importer.importAudio(
        from: root.appendingPathComponent("source.flac"),
        sessionID: UUID()
      )
      XCTFail("Expected an unsupported source to be rejected")
    } catch {
      XCTAssertEqual(error as? AudioImporterError, .unsupportedFormat)
    }
    XCTAssertEqual(scope.counts, .init(starts: 0, stops: 0))
  }

  func testRejectsNonPlayableAndInvalidDurations() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionFileStore(rootURL: root)
    let sourceURL = root.appendingPathComponent("source.m4a")
    let invalidMetadata = [
      AudioAssetMetadata(isPlayable: false, duration: 1),
      AudioAssetMetadata(isPlayable: true, duration: 0),
      AudioAssetMetadata(isPlayable: true, duration: .nan),
      AudioAssetMetadata(isPlayable: true, duration: .infinity),
    ]
    let expectedErrors: [AudioImporterError] = [
      .notPlayable,
      .invalidDuration,
      .invalidDuration,
      .invalidDuration,
    ]

    for (metadata, expectedError) in zip(invalidMetadata, expectedErrors) {
      let importer = AVFoundationAudioImporter(
        fileStore: store,
        validator: FixedAudioAssetValidator(metadata: metadata)
      )
      do {
        _ = try await importer.importAudio(from: sourceURL, sessionID: UUID())
        XCTFail("Expected invalid metadata to be rejected")
      } catch {
        XCTAssertEqual(error as? AudioImporterError, expectedError)
      }
    }
  }

  func testBalancesSecurityScopeWhenValidationFails() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionFileStore(rootURL: root)
    let scope = SecurityScopeSpy()
    let importer = AVFoundationAudioImporter(
      fileStore: store,
      validator: FixedAudioAssetValidator(
        metadata: AudioAssetMetadata(isPlayable: true, duration: .nan)
      ),
      securityScope: scope.access()
    )

    do {
      _ = try await importer.importAudio(
        from: root.appendingPathComponent("source.m4a"),
        sessionID: UUID()
      )
      XCTFail("Expected invalid duration")
    } catch {
      XCTAssertEqual(error as? AudioImporterError, .invalidDuration)
    }
    XCTAssertEqual(scope.counts, .init(starts: 1, stops: 1))
  }

  func testPreservesCancellationAndReleasesSecurityScope() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionFileStore(rootURL: root)
    let scope = SecurityScopeSpy()
    let importer = AVFoundationAudioImporter(
      fileStore: store,
      validator: CancellingAudioAssetValidator(),
      securityScope: scope.access()
    )

    do {
      _ = try await importer.importAudio(
        from: root.appendingPathComponent("source.m4a"),
        sessionID: UUID()
      )
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(scope.counts, .init(starts: 1, stops: 1))
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakNoteAudioImporter-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url
  }

  private func writeM4A(at url: URL) throws {
    let sampleRate = 44_100.0
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 64_000,
    ]
    var file: AVAudioFile? = try AVAudioFile(
      forWriting: url,
      settings: settings
    )
    let format = try XCTUnwrap(file?.processingFormat)
    let frameCount = AVAudioFrameCount(sampleRate / 4)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
    )
    buffer.frameLength = frameCount
    let channel = try XCTUnwrap(buffer.floatChannelData?[0])
    channel.initialize(repeating: 0, count: Int(frameCount))
    try file?.write(from: buffer)
    file = nil
  }
}

private struct FixedAudioAssetValidator: AudioAssetValidating {
  let metadata: AudioAssetMetadata

  func metadata(for url: URL) async throws -> AudioAssetMetadata {
    metadata
  }
}

private struct CancellingAudioAssetValidator: AudioAssetValidating {
  func metadata(for url: URL) async throws -> AudioAssetMetadata {
    throw CancellationError()
  }
}

private final class SecurityScopeSpy: @unchecked Sendable {
  struct Counts: Equatable {
    let starts: Int
    let stops: Int
  }

  private let lock = NSLock()
  private var starts = 0
  private var stops = 0

  var counts: Counts {
    lock.withLock {
      Counts(starts: starts, stops: stops)
    }
  }

  func access() -> SecurityScopedResourceAccess {
    SecurityScopedResourceAccess(
      start: { [self] _ in
        lock.withLock { starts += 1 }
        return true
      },
      stop: { [self] _ in
        lock.withLock { stops += 1 }
      }
    )
  }
}
