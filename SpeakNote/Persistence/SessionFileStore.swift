import CryptoKit
import Foundation

enum SessionFileStoreError: Error, Equatable, Sendable {
  case invalidRelativePath
  case sessionAlreadyExists
  case sessionNotFound
  case unsupportedManifestVersion
  case assetAlreadyExists
  case unreadableSource
  case checksumMismatch
  case invalidRecordingJournal
}

actor SessionFileStore {
  static let manifestRelativePath = "manifest.json"

  private let rootURL: URL
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(rootURL: URL? = nil, fileManager: FileManager = .default) throws {
    self.fileManager = fileManager
    if let rootURL {
      self.rootURL = rootURL.standardizedFileURL
    } else {
      let applicationSupport = try fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      self.rootURL =
        applicationSupport
        .appendingPathComponent("SpeakNote", isDirectory: true)
        .standardizedFileURL
    }
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
  }

  var sessionsRootURL: URL {
    rootURL.appendingPathComponent("Sessions", isDirectory: true)
  }

  func prepareSession(
    id: UUID,
    source: SessionManifest.Source,
    createdAt: Date = Date()
  ) throws -> SessionManifest {
    let directory = sessionDirectory(for: id)
    guard !fileManager.fileExists(atPath: directory.path) else {
      throw SessionFileStoreError.sessionAlreadyExists
    }
    try createSessionDirectories(at: directory)
    let manifest = SessionManifest(
      sessionID: id,
      createdAt: createdAt,
      source: source
    )
    do {
      try writeManifest(manifest)
      return manifest
    } catch {
      try? fileManager.removeItem(at: directory)
      throw error
    }
  }

  func manifest(sessionID: UUID) throws -> SessionManifest {
    let url = sessionDirectory(for: sessionID)
      .appendingPathComponent(Self.manifestRelativePath)
    guard fileManager.fileExists(atPath: url.path) else {
      throw SessionFileStoreError.sessionNotFound
    }
    let manifest = try decoder.decode(SessionManifest.self, from: Data(contentsOf: url))
    guard manifest.version == SessionManifest.currentVersion,
      manifest.sessionID == sessionID
    else {
      throw SessionFileStoreError.unsupportedManifestVersion
    }
    return manifest
  }

  func updateState(
    sessionID: UUID,
    state: SessionManifest.State,
    at date: Date = Date()
  ) throws {
    var current = try manifest(sessionID: sessionID)
    current.state = state
    current.updatedAt = date
    try writeManifest(current)
  }

  func importM4A(
    from sourceURL: URL,
    sessionID: UUID,
    createdAt: Date = Date()
  ) async throws -> SessionManifest.Asset {
    guard sourceURL.isFileURL,
      sourceURL.pathExtension.lowercased() == "m4a"
    else {
      throw SessionFileStoreError.unreadableSource
    }
    let didStartScope = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if didStartScope {
        sourceURL.stopAccessingSecurityScopedResource()
      }
    }
    return try await copyAsset(
      from: sourceURL,
      sessionID: sessionID,
      relativePath: "audio/imported-original.m4a",
      kind: .importedOriginal,
      createdAt: createdAt
    )
  }

  func copyAsset(
    from sourceURL: URL,
    sessionID: UUID,
    relativePath: String,
    kind: SessionManifest.Asset.Kind,
    createdAt: Date = Date()
  ) async throws -> SessionManifest.Asset {
    _ = try manifest(sessionID: sessionID)
    let destination = try assetURL(sessionID: sessionID, relativePath: relativePath)
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw SessionFileStoreError.assetAlreadyExists
    }
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let partialURL = destination.appendingPathExtension("partial")
    let operation = Task.detached(priority: .utility) {
      try Self.streamCopy(from: sourceURL, to: partialURL)
      try Task.checkCancellation()
      let digest = try Self.digestAndSize(of: partialURL)
      try Task.checkCancellation()
      return digest
    }

    do {
      let digest = try await withTaskCancellationHandler {
        try await operation.value
      } onCancel: {
        operation.cancel()
      }
      try Task.checkCancellation()
      try fileManager.moveItem(at: partialURL, to: destination)
      let asset = SessionManifest.Asset(
        kind: kind,
        relativePath: relativePath,
        sha256: digest.sha256,
        byteCount: digest.byteCount,
        createdAt: createdAt
      )
      try append(asset: asset, sessionID: sessionID, at: createdAt)
      return asset
    } catch {
      operation.cancel()
      try? fileManager.removeItem(at: partialURL)
      throw error
    }
  }

  func writeJSON<Value: Encodable & Sendable>(
    _ value: Value,
    sessionID: UUID,
    relativePath: String,
    kind: SessionManifest.Asset.Kind,
    createdAt: Date = Date()
  ) throws -> SessionManifest.Asset {
    _ = try manifest(sessionID: sessionID)
    let data = try encoder.encode(value)
    return try write(
      data,
      sessionID: sessionID,
      relativePath: relativePath,
      kind: kind,
      createdAt: createdAt
    )
  }

  func replaceJSON<Value: Encodable & Sendable>(
    _ value: Value,
    sessionID: UUID,
    relativePath: String,
    kind: SessionManifest.Asset.Kind,
    updatedAt: Date = Date()
  ) throws -> SessionManifest.Asset {
    guard kind == .checkpoint else {
      throw SessionFileStoreError.invalidRelativePath
    }
    var current = try manifest(sessionID: sessionID)
    let data = try encoder.encode(value)
    let destination = try assetURL(
      sessionID: sessionID,
      relativePath: relativePath
    )
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let partialURL = destination.appendingPathExtension("partial")
    do {
      try data.write(to: partialURL, options: [])
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: partialURL.path
      )
      let handle = try FileHandle(forWritingTo: partialURL)
      try handle.synchronize()
      try handle.close()
      if fileManager.fileExists(atPath: destination.path) {
        _ = try fileManager.replaceItemAt(
          destination,
          withItemAt: partialURL,
          backupItemName: nil,
          options: []
        )
      } else {
        try fileManager.moveItem(at: partialURL, to: destination)
      }
      let asset = SessionManifest.Asset(
        kind: kind,
        relativePath: relativePath,
        sha256: SHA256.hash(data: data)
          .map { String(format: "%02x", $0) }
          .joined(),
        byteCount: Int64(data.count),
        createdAt: updatedAt
      )
      if let index = current.assets.firstIndex(where: {
        $0.relativePath == relativePath
      }) {
        current.assets[index] = asset
      } else {
        current.assets.append(asset)
      }
      current.updatedAt = updatedAt
      try writeManifest(current)
      return asset
    } catch {
      try? fileManager.removeItem(at: partialURL)
      throw error
    }
  }

  func readJSON<Value: Decodable & Sendable>(
    _ type: Value.Type,
    sessionID: UUID,
    relativePath: String,
    expectedSHA256: String? = nil
  ) throws -> Value {
    let data = try readData(
      sessionID: sessionID,
      relativePath: relativePath,
      expectedSHA256: expectedSHA256
    )
    return try decoder.decode(type, from: data)
  }

  func write(
    _ data: Data,
    sessionID: UUID,
    relativePath: String,
    kind: SessionManifest.Asset.Kind,
    createdAt: Date = Date()
  ) throws -> SessionManifest.Asset {
    _ = try manifest(sessionID: sessionID)
    let destination = try assetURL(sessionID: sessionID, relativePath: relativePath)
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw SessionFileStoreError.assetAlreadyExists
    }
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let partialURL = destination.appendingPathExtension("partial")
    do {
      try data.write(to: partialURL, options: [])
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: partialURL.path
      )
      let handle = try FileHandle(forWritingTo: partialURL)
      try handle.synchronize()
      try handle.close()
      let digest = SHA256.hash(data: data)
      try fileManager.moveItem(at: partialURL, to: destination)
      let asset = SessionManifest.Asset(
        kind: kind,
        relativePath: relativePath,
        sha256: digest.map { String(format: "%02x", $0) }.joined(),
        byteCount: Int64(data.count),
        createdAt: createdAt
      )
      try append(asset: asset, sessionID: sessionID, at: createdAt)
      return asset
    } catch {
      try? fileManager.removeItem(at: partialURL)
      throw error
    }
  }

  func readData(
    sessionID: UUID,
    relativePath: String,
    expectedSHA256: String? = nil
  ) throws -> Data {
    let url = try assetURL(sessionID: sessionID, relativePath: relativePath)
    let data = try Data(contentsOf: url)
    if let expectedSHA256 {
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      guard digest == expectedSHA256 else {
        throw SessionFileStoreError.checksumMismatch
      }
    }
    return data
  }

  func fileURL(sessionID: UUID, relativePath: String) throws -> URL {
    try assetURL(sessionID: sessionID, relativePath: relativePath)
  }

  func registerExistingAsset(
    sessionID: UUID,
    relativePath: String,
    kind: SessionManifest.Asset.Kind,
    expectedSHA256: String,
    expectedByteCount: Int64,
    createdAt: Date = Date()
  ) async throws -> SessionManifest.Asset {
    let current = try manifest(sessionID: sessionID)
    let url = try assetURL(sessionID: sessionID, relativePath: relativePath)
    let operation = Task.detached(priority: .utility) {
      try Self.digestAndSize(of: url)
    }
    let digest = try await withTaskCancellationHandler {
      try await operation.value
    } onCancel: {
      operation.cancel()
    }
    try Task.checkCancellation()
    guard digest.sha256 == expectedSHA256,
      digest.byteCount == expectedByteCount
    else {
      throw SessionFileStoreError.checksumMismatch
    }
    if let existing = current.assets.first(where: {
      $0.relativePath == relativePath
    }) {
      guard existing.kind == kind,
        existing.sha256 == digest.sha256,
        existing.byteCount == digest.byteCount
      else {
        throw SessionFileStoreError.assetAlreadyExists
      }
      return existing
    }
    let asset = SessionManifest.Asset(
      kind: kind,
      relativePath: relativePath,
      sha256: digest.sha256,
      byteCount: digest.byteCount,
      createdAt: createdAt
    )
    try append(asset: asset, sessionID: sessionID, at: createdAt)
    return asset
  }

  func removeAssets(
    sessionID: UUID,
    kind: SessionManifest.Asset.Kind,
    at date: Date = Date()
  ) throws {
    var current = try manifest(sessionID: sessionID)
    let removed = current.assets.filter { $0.kind == kind }
    guard !removed.isEmpty else { return }

    current.assets.removeAll { $0.kind == kind }
    current.updatedAt = date
    try writeManifest(current)
    for asset in removed {
      let url = try assetURL(
        sessionID: sessionID,
        relativePath: asset.relativePath
      )
      try? fileManager.removeItem(at: url)
    }
  }

  func removeUnregisteredFile(
    sessionID: UUID,
    relativePath: String
  ) throws {
    let current = try manifest(sessionID: sessionID)
    guard
      !current.assets.contains(where: {
        $0.relativePath == relativePath
      })
    else {
      throw SessionFileStoreError.assetAlreadyExists
    }
    let url = try assetURL(
      sessionID: sessionID,
      relativePath: relativePath
    )
    if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
  }

  func sessionIDs() throws -> [UUID] {
    guard fileManager.fileExists(atPath: sessionsRootURL.path) else {
      return []
    }
    return try fileManager.contentsOfDirectory(
      at: sessionsRootURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    .compactMap { url in
      guard
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      else {
        return nil
      }
      return UUID(uuidString: url.lastPathComponent)
    }
    .sorted { $0.uuidString < $1.uuidString }
  }

  func writeRecordingJournal(_ journal: RecordingJournal) throws {
    guard journal.version == RecordingJournal.currentVersion,
      journal.segmentDuration.isFinite,
      journal.segmentDuration > 0,
      journal.lastClosedSegmentIndex.map({ $0 >= 0 }) ?? true
    else {
      throw SessionFileStoreError.invalidRecordingJournal
    }
    _ = try manifest(sessionID: journal.sessionID)
    let destination = recordingJournalURL
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let partialURL = destination.appendingPathExtension("partial")
    let data = try encoder.encode(journal)
    do {
      try data.write(to: partialURL, options: [])
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: partialURL.path
      )
      let handle = try FileHandle(forWritingTo: partialURL)
      try handle.synchronize()
      try handle.close()
      if fileManager.fileExists(atPath: destination.path) {
        _ = try fileManager.replaceItemAt(
          destination,
          withItemAt: partialURL,
          backupItemName: nil,
          options: []
        )
      } else {
        try fileManager.moveItem(at: partialURL, to: destination)
      }
    } catch {
      try? fileManager.removeItem(at: partialURL)
      throw error
    }
  }

  func recordingJournal() throws -> RecordingJournal? {
    guard fileManager.fileExists(atPath: recordingJournalURL.path) else {
      return nil
    }
    let journal = try decoder.decode(
      RecordingJournal.self,
      from: Data(contentsOf: recordingJournalURL)
    )
    guard journal.version == RecordingJournal.currentVersion,
      journal.segmentDuration.isFinite,
      journal.segmentDuration > 0,
      journal.lastClosedSegmentIndex.map({ $0 >= 0 }) ?? true
    else {
      throw SessionFileStoreError.invalidRecordingJournal
    }
    return journal
  }

  func clearRecordingJournal(sessionID: UUID) throws {
    guard let journal = try recordingJournal() else { return }
    guard journal.sessionID == sessionID else {
      throw SessionFileStoreError.invalidRecordingJournal
    }
    try fileManager.removeItem(at: recordingJournalURL)
  }

  func temporaryJobDirectory(jobID: UUID) throws -> URL {
    let directory =
      rootURL
      .appendingPathComponent("Temp", isDirectory: true)
      .appendingPathComponent(jobID.uuidString, isDirectory: true)
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  func removeTemporaryJobDirectory(jobID: UUID) {
    let directory =
      rootURL
      .appendingPathComponent("Temp", isDirectory: true)
      .appendingPathComponent(jobID.uuidString, isDirectory: true)
    try? fileManager.removeItem(at: directory)
  }

  func removeSession(sessionID: UUID) throws {
    var current = try manifest(sessionID: sessionID)
    current.state = .pendingDeletion
    current.updatedAt = Date()
    try writeManifest(current)
    try fileManager.removeItem(at: sessionDirectory(for: sessionID))
  }

  private func append(
    asset: SessionManifest.Asset,
    sessionID: UUID,
    at date: Date
  ) throws {
    var current = try manifest(sessionID: sessionID)
    guard !current.assets.contains(where: { $0.relativePath == asset.relativePath }) else {
      throw SessionFileStoreError.assetAlreadyExists
    }
    current.assets.append(asset)
    current.updatedAt = date
    try writeManifest(current)
  }

  private func writeManifest(_ manifest: SessionManifest) throws {
    let directory = sessionDirectory(for: manifest.sessionID)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(Self.manifestRelativePath)
    let partialURL = destination.appendingPathExtension("partial")
    let data = try encoder.encode(manifest)
    do {
      try data.write(to: partialURL, options: [])
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: partialURL.path
      )
      let handle = try FileHandle(forWritingTo: partialURL)
      try handle.synchronize()
      try handle.close()
      if fileManager.fileExists(atPath: destination.path) {
        _ = try fileManager.replaceItemAt(
          destination,
          withItemAt: partialURL,
          backupItemName: nil,
          options: []
        )
      } else {
        try fileManager.moveItem(at: partialURL, to: destination)
      }
    } catch {
      try? fileManager.removeItem(at: partialURL)
      throw error
    }
  }

  private func assetURL(sessionID: UUID, relativePath: String) throws -> URL {
    guard Self.isSafe(relativePath: relativePath) else {
      throw SessionFileStoreError.invalidRelativePath
    }
    let session = sessionDirectory(for: sessionID)
    let candidate = session.appendingPathComponent(relativePath).standardizedFileURL
    let prefix = session.path.hasSuffix("/") ? session.path : session.path + "/"
    guard candidate.path.hasPrefix(prefix) else {
      throw SessionFileStoreError.invalidRelativePath
    }
    return candidate
  }

  private func sessionDirectory(for id: UUID) -> URL {
    sessionsRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
  }

  private var recordingJournalURL: URL {
    rootURL
      .appendingPathComponent("Recovery", isDirectory: true)
      .appendingPathComponent("recording-journal.json")
  }

  private func createSessionDirectories(at directory: URL) throws {
    for relativePath in [
      "audio",
      "transcripts/chunks",
      "runs",
      "jobs",
    ] {
      try fileManager.createDirectory(
        at: directory.appendingPathComponent(relativePath, isDirectory: true),
        withIntermediateDirectories: true
      )
    }
  }

  private static func isSafe(relativePath: String) -> Bool {
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return false }
    return relativePath.split(separator: "/", omittingEmptySubsequences: false)
      .allSatisfy { $0 != ".." && !$0.isEmpty }
  }

  private static func streamCopy(
    from sourceURL: URL,
    to destinationURL: URL
  ) throws {
    let values = try sourceURL.resourceValues(forKeys: [
      .isRegularFileKey,
      .isReadableKey,
    ])
    guard sourceURL.isFileURL,
      values.isRegularFile == true,
      values.isReadable == true
    else {
      throw SessionFileStoreError.unreadableSource
    }
    let input = try FileHandle(forReadingFrom: sourceURL)
    defer { try? input.close() }
    FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: destinationURL.path
    )
    let output = try FileHandle(forWritingTo: destinationURL)
    defer { try? output.close() }
    while true {
      try Task.checkCancellation()
      guard let block = try input.read(upToCount: 1_048_576), !block.isEmpty else {
        break
      }
      try output.write(contentsOf: block)
    }
    try output.synchronize()
  }

  private static func digestAndSize(of url: URL) throws -> (
    sha256: String,
    byteCount: Int64
  ) {
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    var hasher = SHA256()
    var byteCount: Int64 = 0
    while true {
      try Task.checkCancellation()
      guard let block = try input.read(upToCount: 1_048_576), !block.isEmpty else {
        break
      }
      hasher.update(data: block)
      byteCount += Int64(block.count)
    }
    return (
      hasher.finalize().map { String(format: "%02x", $0) }.joined(),
      byteCount
    )
  }
}
