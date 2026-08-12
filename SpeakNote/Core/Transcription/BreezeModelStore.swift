import CryptoKit
import Foundation

enum BreezeModelState: Equatable, Sendable {
  case notDownloaded
  case downloading(progress: Double)
  case verifying
  case installed
  case loading
  case ready
  case failed(BreezeModelStoreError)
}

enum BreezeModelStoreError: Error, Equatable, LocalizedError, Sendable {
  case invalidModelIdentifier
  case insufficientDiskSpace
  case downloadFailed
  case checksumMismatch
  case partialModel
  case modelCorrupted
  case modelNotInstalled
  case cancellation

  var errorDescription: String? {
    switch self {
    case .invalidModelIdentifier:
      String(localized: "The Breeze model selection is invalid.")
    case .insufficientDiskSpace:
      String(localized: "There is not enough disk space for the Breeze model.")
    case .downloadFailed:
      String(localized: "The Breeze model download failed.")
    case .checksumMismatch, .partialModel, .modelCorrupted:
      String(localized: "The downloaded Breeze model failed integrity verification.")
    case .modelNotInstalled:
      String(localized: "Download the Breeze model before using offline transcription.")
    case .cancellation:
      String(localized: "The Breeze model operation was cancelled.")
    }
  }
}

struct BreezeModelMetadata: Equatable, Sendable {
  let modelID: String
  let fileName: String
  let downloadURL: URL
  let expectedByteCount: Int64
  let expectedSHA256: String

  static let q5_0 = BreezeModelMetadata(
    modelID: BreezeTranscriptionModel.q5_0,
    fileName: "breeze-q5_0.bin",
    downloadURL: URL(
      string: "https://huggingface.co/weemed/Breeze-ASR-26-GGML/resolve/16b8f9a257a99e0d21baa2667f3ffdc881b8e445/breeze-q5_0.bin?download=true"
    )!,
    expectedByteCount: 1_080_732_108,
    expectedSHA256: "60f25e3a21feca12ec082e6d36f08f94455d9900d6343f7fcb2906f71cc7c449"
  )

  static func metadata(for modelID: String) -> BreezeModelMetadata? {
    modelID == q5_0.modelID ? q5_0 : nil
  }
}

struct BreezeModelIntegrityVerifier: Sendable {
  static func verify(
    fileURL: URL,
    metadata: BreezeModelMetadata,
    fileManager: FileManager = .default
  ) throws {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      throw BreezeModelStoreError.modelNotInstalled
    }
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    var hasher = SHA256()
    var byteCount: Int64 = 0
    while true {
      let data = try handle.read(upToCount: 1_048_576) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
      byteCount += Int64(data.count)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard byteCount == metadata.expectedByteCount else {
      throw BreezeModelStoreError.partialModel
    }
    guard digest == metadata.expectedSHA256 else {
      throw BreezeModelStoreError.checksumMismatch
    }
  }
}

protocol BreezeModelManaging: Sendable {
  func state(for modelID: String) async -> BreezeModelState
  func modelURL(for modelID: String) async throws -> URL
  func download(modelID: String) async throws
  func cancelDownload() async
  func delete(modelID: String) async throws
}

actor BreezeModelStore: BreezeModelManaging {
  private let rootURL: URL
  private let fileManager: FileManager
  private let diskCapacityChecker: any DiskCapacityChecking
  private let session: URLSession
  private var states: [String: BreezeModelState] = [:]
  private var downloadTask: Task<Void, Error>?

  init(
    rootURL: URL? = nil,
    fileManager: FileManager = .default,
    diskCapacityChecker: any DiskCapacityChecking = VolumeDiskCapacityChecker(),
    session: URLSession = .shared
  ) throws {
    if let rootURL {
      self.rootURL = rootURL
    } else {
      let applicationSupport = try fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      self.rootURL = applicationSupport
        .appendingPathComponent("SpeakNote", isDirectory: true)
        .appendingPathComponent("Models", isDirectory: true)
        .appendingPathComponent("Breeze-ASR-26", isDirectory: true)
    }
    self.fileManager = fileManager
    self.diskCapacityChecker = diskCapacityChecker
    self.session = session
  }

  static func modelDirectoryURL(applicationSupportURL: URL) -> URL {
    applicationSupportURL
      .appendingPathComponent("SpeakNote", isDirectory: true)
      .appendingPathComponent("Models", isDirectory: true)
      .appendingPathComponent("Breeze-ASR-26", isDirectory: true)
  }

  func state(for modelID: String) async -> BreezeModelState {
    guard let metadata = BreezeModelMetadata.metadata(for: modelID) else {
      return .failed(.invalidModelIdentifier)
    }
    if let state = states[modelID] {
      switch state {
      case .installed, .ready:
        return state
      case .notDownloaded:
        break
      default:
        return state
      }
    }
    let url = rootURL.appendingPathComponent(metadata.fileName)
    guard fileManager.fileExists(atPath: url.path) else {
      return states[modelID] ?? .notDownloaded
    }
    do {
      try await Task.detached(priority: .utility) {
        try BreezeModelIntegrityVerifier.verify(
          fileURL: url,
          metadata: metadata
        )
      }.value
      states[modelID] = .installed
      return .installed
    } catch let error as BreezeModelStoreError {
      states[modelID] = .failed(error)
      return .failed(error)
    } catch {
      states[modelID] = .failed(.modelCorrupted)
      return .failed(.modelCorrupted)
    }
  }

  func modelURL(for modelID: String) throws -> URL {
    guard let metadata = BreezeModelMetadata.metadata(for: modelID) else {
      throw BreezeModelStoreError.invalidModelIdentifier
    }
    let url = rootURL.appendingPathComponent(metadata.fileName)
    guard fileManager.fileExists(atPath: url.path) else {
      throw BreezeModelStoreError.modelNotInstalled
    }
    return url
  }

  func download(modelID: String) async throws {
    guard let metadata = BreezeModelMetadata.metadata(for: modelID) else {
      throw BreezeModelStoreError.invalidModelIdentifier
    }
    guard downloadTask == nil else { return }
    try fileManager.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let available = try await diskCapacityChecker.availableCapacity(at: rootURL)
    guard available >= metadata.expectedByteCount + 128 * 1_024 * 1_024 else {
      states[modelID] = .failed(.insufficientDiskSpace)
      throw BreezeModelStoreError.insufficientDiskSpace
    }

    states[modelID] = .downloading(progress: 0)
    let progress: @Sendable (Double) -> Void = { [weak self] value in
      Task { await self?.setProgress(value, for: modelID) }
    }
    let task = Task.detached(priority: .utility) { [session, rootURL, progress] in
      let fileManager = FileManager.default
      let destination = rootURL.appendingPathComponent(metadata.fileName)
      let partialURL = rootURL.appendingPathComponent("\(metadata.fileName).partial")
      do {
        try Task.checkCancellation()
        var existingCount: Int64 = 0
        if let attributes = try? fileManager.attributesOfItem(atPath: partialURL.path),
           let fileSize = attributes[.size] as? NSNumber {
          existingCount = fileSize.int64Value
          if existingCount >= metadata.expectedByteCount {
            try? fileManager.removeItem(at: partialURL)
            existingCount = 0
          }
        }
        var request = URLRequest(url: metadata.downloadURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if existingCount > 0 {
          request.setValue("bytes=\(existingCount)-", forHTTPHeaderField: "Range")
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
          throw BreezeModelStoreError.downloadFailed
        }
        let append = existingCount > 0 && http.statusCode == 206
        guard append || (200..<300).contains(http.statusCode) else {
          throw BreezeModelStoreError.downloadFailed
        }
        if !append, fileManager.fileExists(atPath: partialURL.path) {
          try fileManager.removeItem(at: partialURL)
        }
        if !fileManager.fileExists(atPath: partialURL.path) {
          fileManager.createFile(atPath: partialURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partialURL)
        if append {
          try handle.seekToEnd()
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var count: Int64 = 0
        if append {
          let existingHandle = try FileHandle(forReadingFrom: partialURL)
          defer { try? existingHandle.close() }
          while true {
            let data = try existingHandle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
            count += Int64(data.count)
          }
        }
        var buffer = Data()
        buffer.reserveCapacity(64 * 1_024)
        for try await byte in bytes {
          try Task.checkCancellation()
          buffer.append(byte)
          if buffer.count >= 64 * 1_024 {
            try handle.write(contentsOf: buffer)
            hasher.update(data: buffer)
            count += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            progress(min(0.99, Double(count) / Double(metadata.expectedByteCount)))
          }
        }
        if !buffer.isEmpty {
          try handle.write(contentsOf: buffer)
          hasher.update(data: buffer)
          count += Int64(buffer.count)
        }
        progress(1)
        guard count == metadata.expectedByteCount else {
          throw BreezeModelStoreError.partialModel
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == metadata.expectedSHA256 else {
          throw BreezeModelStoreError.checksumMismatch
        }
        if fileManager.fileExists(atPath: destination.path) {
          try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: partialURL, to: destination)
      } catch is CancellationError {
        throw BreezeModelStoreError.cancellation
      } catch let error as BreezeModelStoreError {
        if error == .checksumMismatch || error == .partialModel || error == .modelCorrupted {
          try? fileManager.removeItem(at: partialURL)
        }
        throw error
      } catch {
        throw BreezeModelStoreError.downloadFailed
      }
    }
    downloadTask = task
    do {
      try await task.value
      states[modelID] = .installed
      downloadTask = nil
    } catch {
      downloadTask = nil
      let storeError = error as? BreezeModelStoreError ?? .downloadFailed
      states[modelID] = .failed(storeError)
      throw storeError
    }
  }

  private func setProgress(_ value: Double, for modelID: String) {
    guard downloadTask != nil else { return }
    states[modelID] = value >= 1
      ? .verifying
      : .downloading(progress: min(max(value, 0), 0.99))
  }

  func cancelDownload() async {
    let task = downloadTask
    task?.cancel()
    _ = try? await task?.value
    downloadTask = nil
    states[BreezeTranscriptionModel.defaultID] = .notDownloaded
  }

  func delete(modelID: String) async throws {
    guard let metadata = BreezeModelMetadata.metadata(for: modelID) else {
      throw BreezeModelStoreError.invalidModelIdentifier
    }
    let task = downloadTask
    task?.cancel()
    _ = try? await task?.value
    downloadTask = nil
    let url = rootURL.appendingPathComponent(metadata.fileName)
    let partialURL = rootURL.appendingPathComponent("\(metadata.fileName).partial")
    if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
    if fileManager.fileExists(atPath: partialURL.path) {
      try fileManager.removeItem(at: partialURL)
    }
    states[modelID] = .notDownloaded
  }
}
