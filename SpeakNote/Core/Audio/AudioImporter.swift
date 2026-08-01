@preconcurrency import AVFoundation
import Foundation

struct ImportedAudio: Equatable, Sendable {
  let asset: SessionManifest.Asset
  let duration: TimeInterval
}

protocol AudioImporting: Sendable {
  func importAudio(from url: URL, sessionID: UUID) async throws -> ImportedAudio
}

enum AudioImportFormat: String, CaseIterable, Sendable {
  case m4a
  case mp3
  case wav
  case aiff
  case caf

  init?(url: URL) {
    self.init(rawValue: url.pathExtension.lowercased())
  }
}

struct AudioAssetMetadata: Equatable, Sendable {
  let isPlayable: Bool
  let duration: TimeInterval
}

protocol AudioAssetValidating: Sendable {
  func metadata(for url: URL) async throws -> AudioAssetMetadata
}

enum AudioImporterError: Error, Equatable, Sendable {
  case unsupportedFormat
  case unreadableAsset
  case notPlayable
  case invalidDuration
}

struct AVFoundationAudioAssetValidator: AudioAssetValidating, Sendable {
  func metadata(for url: URL) async throws -> AudioAssetMetadata {
    let operation = Task.detached(priority: .utility) {
      try await Self.loadAndDecodeMetadata(for: url)
    }
    return try await withTaskCancellationHandler {
      try await operation.value
    } onCancel: {
      operation.cancel()
    }
  }

  private static func loadAndDecodeMetadata(
    for url: URL
  ) async throws -> AudioAssetMetadata {
    do {
      let asset = AVURLAsset(url: url)
      let (isPlayable, duration) = try await asset.load(.isPlayable, .duration)
      try Task.checkCancellation()
      guard isPlayable else {
        throw AudioImporterError.unreadableAsset
      }
      try decodeToEnd(url: url)
      return AudioAssetMetadata(
        isPlayable: true,
        duration: duration.seconds
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw AudioImporterError.unreadableAsset
    }
  }

  private static func decodeToEnd(url: URL) throws {
    let file = try AVAudioFile(forReading: url)
    guard file.length > 0 else {
      throw AudioImporterError.invalidDuration
    }
    let frameCapacity: AVAudioFrameCount = 4_096
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: frameCapacity
      )
    else {
      throw AudioImporterError.unreadableAsset
    }

    var decodedFrames: AVAudioFramePosition = 0
    while decodedFrames < file.length {
      try Task.checkCancellation()
      buffer.frameLength = 0
      try file.read(into: buffer, frameCount: frameCapacity)
      guard buffer.frameLength > 0 else {
        throw AudioImporterError.unreadableAsset
      }
      decodedFrames += AVAudioFramePosition(buffer.frameLength)
    }
  }
}

struct SecurityScopedResourceAccess: Sendable {
  let start: @Sendable (URL) -> Bool
  let stop: @Sendable (URL) -> Void

  static let live = SecurityScopedResourceAccess(
    start: { $0.startAccessingSecurityScopedResource() },
    stop: { $0.stopAccessingSecurityScopedResource() }
  )
}

struct AVFoundationAudioImporter: AudioImporting, Sendable {
  private let fileStore: SessionFileStore
  private let validator: any AudioAssetValidating
  private let securityScope: SecurityScopedResourceAccess

  init(
    fileStore: SessionFileStore,
    validator: any AudioAssetValidating = AVFoundationAudioAssetValidator(),
    securityScope: SecurityScopedResourceAccess = .live
  ) {
    self.fileStore = fileStore
    self.validator = validator
    self.securityScope = securityScope
  }

  func importAudio(from url: URL, sessionID: UUID) async throws -> ImportedAudio {
    guard url.isFileURL, AudioImportFormat(url: url) != nil else {
      throw AudioImporterError.unsupportedFormat
    }
    try Task.checkCancellation()

    let didStartScope = securityScope.start(url)
    defer {
      if didStartScope {
        securityScope.stop(url)
      }
    }

    let metadata = try await validator.metadata(for: url)
    try Task.checkCancellation()
    guard metadata.isPlayable else {
      throw AudioImporterError.notPlayable
    }
    guard metadata.duration.isFinite, metadata.duration > 0 else {
      throw AudioImporterError.invalidDuration
    }

    let asset = try await fileStore.copyAsset(
      from: url,
      sessionID: sessionID,
      relativePath: "audio/imported-original.\(url.pathExtension)",
      kind: .importedOriginal
    )
    return ImportedAudio(asset: asset, duration: metadata.duration)
  }
}
