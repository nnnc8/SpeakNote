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
  case modelLoadFailed
  case modelNotInstalled
  case cancellation
  case downloadInProgress

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
    case .modelLoadFailed:
      String(localized: "The Breeze model could not be loaded for inference.")
    case .modelNotInstalled:
      String(localized: "Download the Breeze model before using offline transcription.")
    case .cancellation:
      String(localized: "The Breeze model operation was cancelled.")
    case .downloadInProgress:
      String(localized: "The Breeze model is already downloading.")
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

  static let catalog: [String: BreezeModelMetadata] = [
    q5_0.modelID: q5_0
  ]

  static func metadata(for modelID: String) -> BreezeModelMetadata? {
    catalog[modelID]
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

private struct BreezeModelFileSignature: Equatable, Sendable {
  let byteCount: Int64
  let modificationDate: Date?
}

protocol BreezeModelManaging: Sendable {
  func state(for modelID: String) async -> BreezeModelState
  func modelURL(for modelID: String) async throws -> URL
  func download(modelID: String) async throws
  func cancelDownload() async
  func delete(modelID: String) async throws
  func markLoading(modelID: String) async
  func markReady(modelID: String) async
  func markFailed(modelID: String, error: BreezeModelStoreError) async
}

/// The byte-stream boundary keeps model downloads testable without loading the
/// entire model into memory. Production uses URLSession; tests provide a small
/// deterministic stream.
struct BreezeDownloadResponse: Sendable {
  let statusCode: Int
  let bytes: AsyncThrowingStream<UInt8, Error>
}

protocol BreezeDownloadStreaming: Sendable {
  func stream(for request: URLRequest) async throws -> BreezeDownloadResponse
}

struct URLSessionBreezeDownloadStreaming: BreezeDownloadStreaming {
  let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func stream(for request: URLRequest) async throws -> BreezeDownloadResponse {
    let (bytes, response) = try await session.bytes(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw BreezeModelStoreError.downloadFailed
    }
    let stream = AsyncThrowingStream<UInt8, Error> { continuation in
      let producer = Task {
        do {
          for try await byte in bytes {
            try Task.checkCancellation()
            continuation.yield(byte)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in
        producer.cancel()
      }
    }
    return BreezeDownloadResponse(
      statusCode: httpResponse.statusCode,
      bytes: stream
    )
  }
}

extension BreezeModelManaging {
  func markLoading(modelID _: String) async {}
  func markReady(modelID _: String) async {}
  func markFailed(modelID _: String, error _: BreezeModelStoreError) async {}
}

actor BreezeModelStore: BreezeModelManaging {
  private let rootURL: URL
  private let fileManager: FileManager
  private let diskCapacityChecker: any DiskCapacityChecking
  private let downloadStreaming: any BreezeDownloadStreaming
  private let metadataByID: [String: BreezeModelMetadata]
  private var states: [String: BreezeModelState] = [:]
  private var verifiedSignatures: [String: BreezeModelFileSignature] = [:]
  private var downloadTask: Task<Void, Error>?
  private var activeDownloadModelID: String?

  init(
    rootURL: URL? = nil,
    fileManager: FileManager = .default,
    diskCapacityChecker: any DiskCapacityChecking = VolumeDiskCapacityChecker(),
    session: URLSession = .shared,
    downloadStreaming: (any BreezeDownloadStreaming)? = nil,
    metadata: [String: BreezeModelMetadata] = BreezeModelMetadata.catalog
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
    self.downloadStreaming = downloadStreaming ?? URLSessionBreezeDownloadStreaming(session: session)
    self.metadataByID = metadata
  }

  static func modelDirectoryURL(applicationSupportURL: URL) -> URL {
    applicationSupportURL
      .appendingPathComponent("SpeakNote", isDirectory: true)
      .appendingPathComponent("Models", isDirectory: true)
      .appendingPathComponent("Breeze-ASR-26", isDirectory: true)
  }

  func state(for modelID: String) async -> BreezeModelState {
    guard let metadata = metadataByID[modelID] else {
      return .failed(.invalidModelIdentifier)
    }
    if let state = states[modelID] {
      switch state {
      case .installed, .ready:
        let url = rootURL.appendingPathComponent(metadata.fileName)
        if
          fileManager.fileExists(atPath: url.path),
          verifiedSignatures[modelID] == fileSignature(for: url)
        {
          return state
        }
      case .notDownloaded:
        break
      default:
        return state
      }
    }
    let url = rootURL.appendingPathComponent(metadata.fileName)
    let shouldRemainReady = states[modelID] == .ready
    guard fileManager.fileExists(atPath: url.path) else {
      if case .installed? = states[modelID] {
        states[modelID] = .notDownloaded
      }
      if case .ready? = states[modelID] {
        states[modelID] = .notDownloaded
      }
      return states[modelID] ?? .notDownloaded
    }
    do {
      try await verifyInstalledModel(
        modelID: modelID,
        metadata: metadata,
        url: url
      )
      let validatedState: BreezeModelState = shouldRemainReady ? .ready : .installed
      states[modelID] = validatedState
      return validatedState
    } catch let error as BreezeModelStoreError {
      states[modelID] = .failed(error)
      return .failed(error)
    } catch {
      states[modelID] = .failed(.modelCorrupted)
      return .failed(.modelCorrupted)
    }
  }

  func modelURL(for modelID: String) async throws -> URL {
    guard let metadata = metadataByID[modelID] else {
      throw BreezeModelStoreError.invalidModelIdentifier
    }
    let url = rootURL.appendingPathComponent(metadata.fileName)
    guard fileManager.fileExists(atPath: url.path) else {
      throw BreezeModelStoreError.modelNotInstalled
    }
    do {
      try await verifyInstalledModel(
        modelID: modelID,
        metadata: metadata,
        url: url
      )
    } catch let error as BreezeModelStoreError {
      states[modelID] = .failed(error)
      throw error
    } catch {
      states[modelID] = .failed(.modelCorrupted)
      throw BreezeModelStoreError.modelCorrupted
    }
    return url
  }

  func download(modelID: String) async throws {
    guard let metadata = metadataByID[modelID] else {
      throw BreezeModelStoreError.invalidModelIdentifier
    }
    guard downloadTask == nil else {
      throw BreezeModelStoreError.downloadInProgress
    }
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
    verifiedSignatures[modelID] = nil
    let progress: @Sendable (Double) -> Void = { [weak self] value in
      Task { await self?.setProgress(value, for: modelID) }
    }
    let task = Task.detached(priority: .utility) { [downloadStreaming, rootURL, progress] in
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
        let response = try await downloadStreaming.stream(for: request)
        let append = existingCount > 0 && response.statusCode == 206
        guard append || (200..<300).contains(response.statusCode) else {
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
        for try await byte in response.bytes {
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
    activeDownloadModelID = modelID
    do {
      try await task.value
      states[modelID] = .installed
      verifiedSignatures[modelID] = fileSignature(
        for: rootURL.appendingPathComponent(metadata.fileName)
      )
      downloadTask = nil
      activeDownloadModelID = nil
    } catch {
      downloadTask = nil
      activeDownloadModelID = nil
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
    let modelID = activeDownloadModelID
    task?.cancel()
    _ = try? await task?.value
    downloadTask = nil
    activeDownloadModelID = nil
    if let modelID {
      states[modelID] = .notDownloaded
    }
  }

  func delete(modelID: String) async throws {
    guard let metadata = metadataByID[modelID] else {
      throw BreezeModelStoreError.invalidModelIdentifier
    }
    let task = downloadTask
    task?.cancel()
    _ = try? await task?.value
    downloadTask = nil
    activeDownloadModelID = nil
    let url = rootURL.appendingPathComponent(metadata.fileName)
    let partialURL = rootURL.appendingPathComponent("\(metadata.fileName).partial")
    if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
    if fileManager.fileExists(atPath: partialURL.path) {
      try fileManager.removeItem(at: partialURL)
    }
    verifiedSignatures[modelID] = nil
    states[modelID] = .notDownloaded
  }

  func markLoading(modelID: String) {
    guard metadataByID[modelID] != nil else { return }
    states[modelID] = .loading
  }

  func markReady(modelID: String) {
    guard let metadata = metadataByID[modelID] else { return }
    let url = rootURL.appendingPathComponent(metadata.fileName)
    verifiedSignatures[modelID] = fileSignature(for: url)
    states[modelID] = .ready
  }

  func markFailed(modelID: String, error: BreezeModelStoreError) {
    guard metadataByID[modelID] != nil else { return }
    states[modelID] = .failed(error)
  }

  private func verifyInstalledModel(
    modelID: String,
    metadata: BreezeModelMetadata,
    url: URL
  ) async throws {
    guard let signature = fileSignature(for: url) else {
      throw BreezeModelStoreError.modelNotInstalled
    }
    if verifiedSignatures[modelID] == signature {
      return
    }
    try await Task.detached(priority: .utility) {
      try BreezeModelIntegrityVerifier.verify(
        fileURL: url,
        metadata: metadata
      )
    }.value
    verifiedSignatures[modelID] = signature
  }

  private func fileSignature(for url: URL) -> BreezeModelFileSignature? {
    guard
      let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let byteCount = attributes[.size] as? NSNumber
    else {
      return nil
    }
    return BreezeModelFileSignature(
      byteCount: byteCount.int64Value,
      modificationDate: attributes[.modificationDate] as? Date
    )
  }
}
