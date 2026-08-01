@preconcurrency import AVFAudio
import CryptoKit
import Foundation

struct M4IncompleteRecordingSegment: Equatable, Sendable {
  let index: Int
  let url: URL
  let byteCount: Int64
  let recoverableDuration: TimeInterval?
}

enum M4RecordingRecoveryIssue: Equatable, Sendable {
  case missingSegment(index: Int)
  case unreadableSegment(url: URL)
  case orphanedPartial(url: URL)
}

struct M4RecordingRecoveryReport: Equatable, Sendable {
  let completeSegments: [M4RecordingSegment]
  let incompleteCurrentSegment: M4IncompleteRecordingSegment?
  let issues: [M4RecordingRecoveryIssue]
}

struct M4RecordingRecoveryClassification: Equatable, Sendable {
  let complete: [(index: Int, url: URL)]
  let currentPartial: (index: Int, url: URL)?
  let orphanedPartials: [URL]

  static func == (
    lhs: M4RecordingRecoveryClassification,
    rhs: M4RecordingRecoveryClassification
  ) -> Bool {
    lhs.complete.map(\.index) == rhs.complete.map(\.index)
      && lhs.complete.map(\.url) == rhs.complete.map(\.url)
      && lhs.currentPartial?.index == rhs.currentPartial?.index
      && lhs.currentPartial?.url == rhs.currentPartial?.url
      && lhs.orphanedPartials == rhs.orphanedPartials
  }
}

enum M4RecordingRecoveryError: Error, Equatable, Sendable {
  case directoryUnavailable
}

struct M4RecordingRecovery: Sendable {
  func scan(
    sessionID: UUID,
    directory: URL
  ) async throws -> M4RecordingRecoveryReport {
    try await Task.detached(priority: .utility) {
      try Self.scanSynchronously(sessionID: sessionID, directory: directory)
    }.value
  }

  static func classify(_ urls: [URL]) -> M4RecordingRecoveryClassification {
    let indexed = urls.compactMap { url -> (Int, URL, Bool)? in
      guard let index = segmentIndex(url) else { return nil }
      return (index, url, url.deletingPathExtension().lastPathComponent.hasSuffix(".partial"))
    }
    let complete =
      indexed
      .filter { !$0.2 }
      .map { (index: $0.0, url: $0.1) }
      .sorted { ($0.index, $0.url.path) < ($1.index, $1.url.path) }
    let highestComplete = complete.last?.index ?? -1
    let partials =
      indexed
      .filter { $0.2 }
      .map { (index: $0.0, url: $0.1) }
      .sorted { ($0.index, $0.url.path) < ($1.index, $1.url.path) }
    let candidates = partials.filter { $0.index > highestComplete }
    let current = candidates.last
    let orphaned =
      partials
      .filter { candidate in
        candidate.index <= highestComplete
          || candidate.index != current?.index
          || candidate.url != current?.url
      }
      .map(\.url)
    return M4RecordingRecoveryClassification(
      complete: complete,
      currentPartial: current,
      orphanedPartials: orphaned
    )
  }

  static func segmentIndex(_ url: URL) -> Int? {
    guard url.pathExtension.lowercased() == "caf" else { return nil }
    var stem = url.deletingPathExtension().lastPathComponent
    if stem.hasSuffix(".partial") {
      stem.removeLast(".partial".count)
    }
    let prefix: String
    if stem.hasPrefix("capture-") {
      prefix = "capture-"
    } else if stem.hasPrefix("segment-") {
      prefix = "segment-"
    } else {
      return nil
    }
    let suffix = stem.dropFirst(prefix.count)
    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber),
      let index = Int(suffix),
      index >= 0
    else {
      return nil
    }
    return index
  }

  static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
      try Task.checkCancellation()
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func scanSynchronously(
    sessionID: UUID,
    directory: URL
  ) throws -> M4RecordingRecoveryReport {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard directory.isFileURL,
      fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      let urls = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [
          .isRegularFileKey,
          .fileSizeKey,
          .creationDateKey,
        ],
        options: [.skipsHiddenFiles]
      )
    else {
      throw M4RecordingRecoveryError.directoryUnavailable
    }

    let classification = classify(urls)
    var completeSegments: [M4RecordingSegment] = []
    var issues = classification.orphanedPartials.map {
      M4RecordingRecoveryIssue.orphanedPartial(url: $0)
    }
    var elapsed: TimeInterval = 0
    var expectedIndex = 0

    for candidate in classification.complete {
      try Task.checkCancellation()
      while expectedIndex < candidate.index {
        issues.append(.missingSegment(index: expectedIndex))
        expectedIndex += 1
      }
      expectedIndex = candidate.index + 1
      guard
        let inspected = inspectComplete(
          sessionID: sessionID,
          index: candidate.index,
          url: candidate.url,
          startTime: elapsed
        )
      else {
        issues.append(.unreadableSegment(url: candidate.url))
        continue
      }
      completeSegments.append(inspected)
      elapsed = inspected.endTime
    }

    let incomplete = classification.currentPartial.map { candidate in
      let values = try? candidate.url.resourceValues(forKeys: [.fileSizeKey])
      let duration = try? audioDuration(of: candidate.url)
      return M4IncompleteRecordingSegment(
        index: candidate.index,
        url: candidate.url,
        byteCount: Int64(values?.fileSize ?? 0),
        recoverableDuration: duration
      )
    }
    return M4RecordingRecoveryReport(
      completeSegments: completeSegments,
      incompleteCurrentSegment: incomplete,
      issues: issues
    )
  }

  private static func inspectComplete(
    sessionID: UUID,
    index: Int,
    url: URL,
    startTime: TimeInterval
  ) -> M4RecordingSegment? {
    guard let duration = try? audioDuration(of: url),
      let values = try? url.resourceValues(forKeys: [
        .fileSizeKey,
        .creationDateKey,
      ]),
      let sha256 = try? sha256(of: url)
    else {
      return nil
    }
    return M4RecordingSegment(
      sessionID: sessionID,
      index: index,
      url: url,
      relativePath: url.lastPathComponent,
      startTime: startTime,
      endTime: startTime + duration,
      byteCount: Int64(values.fileSize ?? 0),
      sha256: sha256,
      createdAt: values.creationDate ?? Date.distantPast
    )
  }

  private static func audioDuration(of url: URL) throws -> TimeInterval {
    let file = try AVAudioFile(forReading: url)
    guard file.processingFormat.sampleRate > 0 else {
      throw M4RollingRecorderFailure.invalidInputFormat
    }
    return Double(file.length) / file.processingFormat.sampleRate
  }
}
