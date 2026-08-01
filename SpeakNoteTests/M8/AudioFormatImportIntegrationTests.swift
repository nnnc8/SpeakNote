@preconcurrency import AVFAudio
import AudioToolbox
import Foundation
import XCTest

@testable import SpeakNote

final class AudioFormatImportIntegrationTests: XCTestCase {
  func testImportsEveryReleasedAudioFormatUsingRealAVFoundationAssets() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionFileStore(rootURL: root)
    let formats: [AudioImportFormat] = [.m4a, .mp3, .wav, .aiff, .caf]

    for format in formats {
      let sourceURL = root.appendingPathComponent(
        "synthetic-silence.\(format.rawValue)"
      )
      try writeStereoSilence(at: sourceURL, format: format)
      let sessionID = UUID()
      _ = try await store.prepareSession(id: sessionID, source: .imported)
      let importer = AVFoundationAudioImporter(fileStore: store)

      let imported = try await importer.importAudio(
        from: sourceURL,
        sessionID: sessionID
      )

      XCTAssertEqual(
        imported.asset.relativePath,
        "audio/imported-original.\(format.rawValue)"
      )
      XCTAssertGreaterThan(imported.duration, 0)
      XCTAssertGreaterThan(imported.asset.byteCount, 0)
      XCTAssertEqual(imported.asset.sha256.count, 64)
      let copiedURL = try await store.fileURL(
        sessionID: sessionID,
        relativePath: imported.asset.relativePath
      )
      XCTAssertTrue(FileManager.default.fileExists(atPath: copiedURL.path))
      XCTAssertEqual(
        try Data(contentsOf: copiedURL),
        try Data(contentsOf: sourceURL)
      )
    }
  }

  func testPreservesOriginalExtensionCase() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("uppercase.AIFF")
    try writeStereoSilence(at: sourceURL, format: .aiff)
    let store = try SessionFileStore(rootURL: root)
    let sessionID = UUID()
    _ = try await store.prepareSession(id: sessionID, source: .imported)

    let imported = try await AVFoundationAudioImporter(fileStore: store)
      .importAudio(from: sourceURL, sessionID: sessionID)

    XCTAssertEqual(imported.asset.relativePath, "audio/imported-original.AIFF")
  }

  func testRejectsCorruptAndTruncatedSupportedFiles() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let corruptURL = root.appendingPathComponent("corrupt.wav")
    try Data("not an audio stream".utf8).write(to: corruptURL)
    let validURL = root.appendingPathComponent("valid.m4a")
    try writeStereoSilence(at: validURL, format: .m4a)
    let truncatedURL = root.appendingPathComponent("truncated.m4a")
    let validData = try Data(contentsOf: validURL)
    try validData.prefix(validData.count / 2).write(to: truncatedURL)
    let store = try SessionFileStore(rootURL: root)

    for sourceURL in [corruptURL, truncatedURL] {
      let sessionID = UUID()
      _ = try await store.prepareSession(id: sessionID, source: .imported)
      let scope = AudioFormatSecurityScopeSpy()
      do {
        _ = try await AVFoundationAudioImporter(
          fileStore: store,
          securityScope: scope.access()
        )
        .importAudio(from: sourceURL, sessionID: sessionID)
        XCTFail("Invalid audio must not be imported: \(sourceURL.lastPathComponent)")
      } catch let error as AudioImporterError {
        XCTAssertEqual(error, .unreadableAsset)
      }
      XCTAssertEqual(scope.counts, .init(starts: 1, stops: 1))
      let manifest = try await store.manifest(sessionID: sessionID)
      XCTAssertTrue(manifest.assets.isEmpty)
    }
  }

  private func writeStereoSilence(
    at url: URL,
    format: AudioImportFormat
  ) throws {
    let sampleRate = 48_000.0
    let settings: [String: Any]
    switch format {
    case .m4a:
      settings = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 96_000,
      ]
    case .mp3:
      let data = try XCTUnwrap(
        Data(
          base64Encoded: Self.syntheticMonoMP3Base64,
          options: .ignoreUnknownCharacters
        )
      )
      try data.write(to: url)
      return
    case .wav, .aiff, .caf:
      settings = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: format == .aiff,
        AVLinearPCMIsNonInterleaved: false,
      ]
    }

    var file: AVAudioFile? = try AVAudioFile(
      forWriting: url,
      settings: settings,
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    let processingFormat = try XCTUnwrap(file?.processingFormat)
    let frameCount = AVAudioFrameCount(sampleRate / 4)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(
        pcmFormat: processingFormat,
        frameCapacity: frameCount
      )
    )
    buffer.frameLength = frameCount
    for channelIndex in 0..<Int(processingFormat.channelCount) {
      let channel = try XCTUnwrap(buffer.floatChannelData?[channelIndex])
      channel.initialize(repeating: 0, count: Int(frameCount))
    }
    try file?.write(from: buffer)
    file = nil
  }

  // Self-generated 0.1 second, 48 kHz mono silence encoded as MP3. Keeping the
  // tiny fixture inline avoids relying on a host-side encoder during tests.
  private static let syntheticMonoMP3Base64 = """
    //sUxAADwAABpAAAACAAADSAAAAETEFNRTMuMTAwVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
    VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUxCWDwAABpAAAACAAADSA
    AAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
    VVVVVVVVVVVVVVVVVVVVVV//sUxEsDwAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVV
    VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUxHCD
    wAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
    VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUxJYDwAABpAAAACAAADSAAAAEVVVVVVVVVV
    VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
    VVVVVVVVVVVV//sUxLuDwAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
    VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
    """

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "SpeakNote-AudioFormatImportTests-\(UUID().uuidString)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url
  }
}

private final class AudioFormatSecurityScopeSpy: @unchecked Sendable {
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
