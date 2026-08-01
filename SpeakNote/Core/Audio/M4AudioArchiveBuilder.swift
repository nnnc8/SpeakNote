@preconcurrency import AVFoundation
import Foundation

struct M4AudioArchive: Equatable, Sendable {
  let url: URL
  let duration: TimeInterval
  let byteCount: Int64
  let sha256: String
}

protocol M4AudioArchiving: Sendable {
  func buildArchive(
    segments: [M4RecordingSegment],
    destinationURL: URL
  ) async throws -> M4AudioArchive
}

enum M4AudioArchiveError: Error, Equatable, Sendable {
  case emptySegments
  case mismatchedSession
  case noncontiguousSegments
  case missingSegment(index: Int)
  case invalidSegmentDuration(index: Int)
  case invalidDestination
  case destinationAlreadyExists
  case unreadableSegment(index: Int)
  case exportUnavailable
  case exportFailed(String)
  case archiveNotPlayable
  case invalidArchiveDuration
  case emptyArchive
}

struct M4AVFoundationAudioArchiveBuilder: M4AudioArchiving, Sendable {
  typealias ExportOperation =
    @Sendable ([M4RecordingSegment], URL) async throws -> Void

  private let exportOperation: ExportOperation

  init(
    exportOperation: @escaping ExportOperation = Self.exportWithAVFoundation
  ) {
    self.exportOperation = exportOperation
  }

  func buildArchive(
    segments: [M4RecordingSegment],
    destinationURL: URL
  ) async throws -> M4AudioArchive {
    let ordered = try Self.validatedSegments(segments)
    guard destinationURL.isFileURL,
      destinationURL.pathExtension.lowercased() == "m4a"
    else {
      throw M4AudioArchiveError.invalidDestination
    }

    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      throw M4AudioArchiveError.destinationAlreadyExists
    }
    try fileManager.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // AVFoundation determines the container from the final extension. Keep the
    // temporary marker before `.m4a` so the exported file remains probeable.
    let partialURL = destinationURL.deletingPathExtension()
      .appendingPathExtension("partial")
      .appendingPathExtension("m4a")
    try? fileManager.removeItem(at: partialURL)
    var committed = false
    defer {
      if !committed {
        try? fileManager.removeItem(at: partialURL)
      }
    }

    try Task.checkCancellation()
    try await exportOperation(ordered, partialURL)
    try Task.checkCancellation()
    try Self.flush(partialURL)

    let metadata = try await Self.probeAndDigest(partialURL)
    try Task.checkCancellation()
    try fileManager.moveItem(at: partialURL, to: destinationURL)
    committed = true
    return M4AudioArchive(
      url: destinationURL,
      duration: metadata.duration,
      byteCount: metadata.byteCount,
      sha256: metadata.sha256
    )
  }

  private static func validatedSegments(
    _ segments: [M4RecordingSegment]
  ) throws -> [M4RecordingSegment] {
    guard !segments.isEmpty else {
      throw M4AudioArchiveError.emptySegments
    }
    let ordered = segments.sorted { $0.index < $1.index }
    guard ordered.allSatisfy({ $0.sessionID == ordered[0].sessionID }) else {
      throw M4AudioArchiveError.mismatchedSession
    }
    guard ordered.map(\.index) == Array(0..<ordered.count) else {
      throw M4AudioArchiveError.noncontiguousSegments
    }
    for segment in ordered {
      let duration = segment.endTime - segment.startTime
      guard duration.isFinite, duration > 0 else {
        throw M4AudioArchiveError.invalidSegmentDuration(index: segment.index)
      }
      guard segment.url.isFileURL,
        FileManager.default.fileExists(atPath: segment.url.path)
      else {
        throw M4AudioArchiveError.missingSegment(index: segment.index)
      }
    }
    return ordered
  }

  private static func exportWithAVFoundation(
    _ segments: [M4RecordingSegment],
    _ partialURL: URL
  ) async throws {
    let composition = AVMutableComposition()
    guard
      let outputTrack = composition.addMutableTrack(
        withMediaType: .audio,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    else {
      throw M4AudioArchiveError.exportUnavailable
    }

    var insertionTime = CMTime.zero
    for segment in segments {
      try Task.checkCancellation()
      let asset = AVURLAsset(url: segment.url)
      let duration: CMTime
      let tracks: [AVAssetTrack]
      do {
        duration = try await asset.load(.duration)
        tracks = try await asset.loadTracks(withMediaType: .audio)
      } catch {
        throw M4AudioArchiveError.unreadableSegment(index: segment.index)
      }
      guard duration.seconds.isFinite, duration.seconds > 0,
        let sourceTrack = tracks.first
      else {
        throw M4AudioArchiveError.invalidSegmentDuration(index: segment.index)
      }
      do {
        try outputTrack.insertTimeRange(
          CMTimeRange(start: .zero, duration: duration),
          of: sourceTrack,
          at: insertionTime
        )
      } catch {
        throw M4AudioArchiveError.unreadableSegment(index: segment.index)
      }
      insertionTime = CMTimeAdd(insertionTime, duration)
    }

    guard
      let session = AVAssetExportSession(
        asset: composition,
        presetName: AVAssetExportPresetAppleM4A
      )
    else {
      throw M4AudioArchiveError.exportUnavailable
    }
    session.outputURL = partialURL
    session.outputFileType = .m4a
    session.shouldOptimizeForNetworkUse = true
    try await export(session)
  }

  private static func export(_ session: AVAssetExportSession) async throws {
    let box = M4ExportSessionBox(session)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        box.session.exportAsynchronously {
          switch box.session.status {
          case .completed:
            continuation.resume()
          case .cancelled:
            continuation.resume(throwing: CancellationError())
          case .failed:
            continuation.resume(
              throwing: M4AudioArchiveError.exportFailed(
                box.session.error?.localizedDescription ?? "Unknown export failure."
              )
            )
          default:
            continuation.resume(
              throwing: M4AudioArchiveError.exportFailed(
                "Export ended without a terminal status."
              )
            )
          }
        }
      }
    } onCancel: {
      box.session.cancelExport()
    }
  }

  private static func flush(_ url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
  }

  private static func probeAndDigest(
    _ url: URL
  ) async throws -> (duration: TimeInterval, byteCount: Int64, sha256: String) {
    let asset = AVURLAsset(url: url)
    let isPlayable: Bool
    let duration: CMTime
    do {
      isPlayable = try await asset.load(.isPlayable)
      duration = try await asset.load(.duration)
    } catch {
      throw M4AudioArchiveError.archiveNotPlayable
    }
    guard isPlayable else {
      throw M4AudioArchiveError.archiveNotPlayable
    }
    guard duration.seconds.isFinite, duration.seconds > 0 else {
      throw M4AudioArchiveError.invalidArchiveDuration
    }

    let digest = try await Task.detached(priority: .utility) {
      let values = try url.resourceValues(forKeys: [.fileSizeKey])
      let byteCount = Int64(values.fileSize ?? 0)
      let sha256 = try M4RecordingRecovery.sha256(of: url)
      return (byteCount, sha256)
    }.value
    guard digest.0 > 0 else {
      throw M4AudioArchiveError.emptyArchive
    }
    return (duration.seconds, digest.0, digest.1)
  }
}

private final class M4ExportSessionBox: @unchecked Sendable {
  let session: AVAssetExportSession

  init(_ session: AVAssetExportSession) {
    self.session = session
  }
}
