@preconcurrency import AVFAudio
import AudioToolbox
import CryptoKit
import Darwin
import Foundation

struct AudioChunk: Codable, Equatable, Sendable {
  let index: Int
  let url: URL
  let startTime: TimeInterval
  let endTime: TimeInterval
  let byteCount: Int64
  let sha256: String
}

protocol AudioChunking: Sendable {
  func chunks(from sourceURL: URL) async throws -> [AudioChunk]
}

enum AudioChunkerError: Error, Equatable, Sendable {
  case invalidConfiguration
  case invalidSource
  case conversionFailed
  case outputTooLarge
}

struct TimeBasedAudioChunker: AudioChunking, Sendable {
  static let sampleRate = 16_000.0
  static let defaultMaximumBytes: Int64 = 20 * 1024 * 1024

  private static let bytesPerFrame: Int64 = 2
  // Keep a conservative 4 KiB allowance even though the canonical WAV header
  // is 44 bytes. The completed file is measured as a final hard-limit check.
  private static let wavHeaderAllowance: Int64 = 4_096

  private let destinationDirectory: URL
  private let maximumDuration: TimeInterval
  private let maximumBytes: Int64
  private let overlapDuration: TimeInterval

  init(
    destinationDirectory: URL = FileManager.default.temporaryDirectory,
    maximumDuration: TimeInterval = 600,
    maximumBytes: Int64 = defaultMaximumBytes,
    overlapDuration: TimeInterval = 2
  ) {
    self.destinationDirectory = destinationDirectory
    self.maximumDuration = maximumDuration
    self.maximumBytes = maximumBytes
    self.overlapDuration = overlapDuration
  }

  func chunks(from sourceURL: URL) async throws -> [AudioChunk] {
    try Task.checkCancellation()
    let destinationDirectory = destinationDirectory
    let maximumDuration = maximumDuration
    let maximumBytes = maximumBytes
    let overlapDuration = overlapDuration
    let work = Task.detached(priority: .utility) {
      try Self.chunkSynchronously(
        sourceURL: sourceURL,
        destinationDirectory: destinationDirectory,
        maximumDuration: maximumDuration,
        maximumBytes: maximumBytes,
        overlapDuration: overlapDuration
      )
    }

    return try await withTaskCancellationHandler {
      let result = try await work.value
      try Task.checkCancellation()
      return result
    } onCancel: {
      work.cancel()
    }
  }

  private static func chunkSynchronously(
    sourceURL: URL,
    destinationDirectory: URL,
    maximumDuration: TimeInterval,
    maximumBytes: Int64,
    overlapDuration: TimeInterval
  ) throws -> [AudioChunk] {
    guard sourceURL.isFileURL,
      maximumDuration.isFinite,
      maximumDuration > 0,
      maximumDuration <= Double(Int64.max) / sampleRate,
      maximumBytes > wavHeaderAllowance + bytesPerFrame,
      overlapDuration.isFinite,
      overlapDuration >= 0,
      overlapDuration <= Double(Int64.max) / sampleRate
    else {
      throw AudioChunkerError.invalidConfiguration
    }

    let durationFrames = Int64((maximumDuration * sampleRate).rounded(.down))
    let byteFrames = (maximumBytes - wavHeaderAllowance) / bytesPerFrame
    let chunkFrameCapacity = min(durationFrames, byteFrames)
    let overlapFrames = Int64((overlapDuration * sampleRate).rounded(.down))
    guard chunkFrameCapacity > 0, overlapFrames < chunkFrameCapacity else {
      throw AudioChunkerError.invalidConfiguration
    }

    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(
        at: destinationDirectory,
        withIntermediateDirectories: true
      )
    } catch {
      throw AudioChunkerError.invalidSource
    }

    guard
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: true
      )
    else {
      throw AudioChunkerError.invalidSource
    }
    var input: ExtAudioFileRef?
    guard ExtAudioFileOpenURL(sourceURL as CFURL, &input) == noErr,
      let input
    else {
      throw AudioChunkerError.invalidSource
    }
    defer { ExtAudioFileDispose(input) }

    var clientFormat = outputFormat.streamDescription.pointee
    guard
      ExtAudioFileSetProperty(
        input,
        kExtAudioFileProperty_ClientDataFormat,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
        &clientFormat
      ) == noErr
    else {
      throw AudioChunkerError.invalidSource
    }
    var inputBufferBytes: UInt32 = 64 * 1_024
    guard
      ExtAudioFileSetProperty(
        input,
        kExtAudioFileProperty_IOBufferSizeBytes,
        UInt32(MemoryLayout<UInt32>.size),
        &inputBufferBytes
      ) == noErr,
      let conversionBuffer = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: 4_096
      )
    else {
      throw AudioChunkerError.invalidSource
    }

    let runName =
      "\(sourceURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString)"
    var completedURLs: [URL] = []
    var chunks: [AudioChunk] = []
    var output: ChunkOutput?
    var tail: [Int16] = []
    var totalFrames: Int64 = 0

    do {
      while true {
        try Task.checkCancellation()
        conversionBuffer.frameLength = conversionBuffer.frameCapacity
        var frameCount = conversionBuffer.frameCapacity
        guard
          ExtAudioFileRead(
            input,
            &frameCount,
            conversionBuffer.mutableAudioBufferList
          ) == noErr
        else {
          throw AudioChunkerError.conversionFailed
        }
        try Task.checkCancellation()
        guard frameCount > 0 else {
          if let current = output {
            let chunk = try current.finish(
              endFrame: totalFrames,
              maximumBytes: maximumBytes
            )
            completedURLs.append(chunk.url)
            chunks.append(chunk)
            output = nil
          }
          return chunks
        }
        conversionBuffer.frameLength = frameCount
        guard let data = conversionBuffer.int16ChannelData?[0] else {
          throw AudioChunkerError.conversionFailed
        }
        let samples = Array(
          UnsafeBufferPointer(start: data, count: Int(frameCount))
        )
        try append(
          samples,
          runName: runName,
          destinationDirectory: destinationDirectory,
          chunkFrameCapacity: chunkFrameCapacity,
          overlapFrameCount: Int(overlapFrames),
          maximumBytes: maximumBytes,
          output: &output,
          tail: &tail,
          totalFrames: &totalFrames,
          completedURLs: &completedURLs,
          chunks: &chunks
        )
      }
    } catch {
      output?.remove()
      for url in completedURLs {
        try? fileManager.removeItem(at: url)
      }
      throw error
    }
  }

  private static func append(
    _ samples: [Int16],
    runName: String,
    destinationDirectory: URL,
    chunkFrameCapacity: Int64,
    overlapFrameCount: Int,
    maximumBytes: Int64,
    output: inout ChunkOutput?,
    tail: inout [Int16],
    totalFrames: inout Int64,
    completedURLs: inout [URL],
    chunks: inout [AudioChunk]
  ) throws {
    var offset = 0
    while offset < samples.count {
      try Task.checkCancellation()
      if output == nil {
        let overlap = Array(tail.suffix(overlapFrameCount))
        let startFrame = totalFrames - Int64(overlap.count)
        let next = try ChunkOutput(
          index: chunks.count,
          runName: runName,
          destinationDirectory: destinationDirectory,
          startFrame: startFrame
        )
        try next.write(overlap)
        output = next
      }

      guard let current = output else {
        throw AudioChunkerError.conversionFailed
      }
      let available = Int(chunkFrameCapacity - current.framesWritten)
      let count = min(available, samples.count - offset)
      let newSamples = Array(samples[offset..<(offset + count)])
      try current.write(newSamples)
      totalFrames += Int64(count)
      offset += count

      if overlapFrameCount > 0 {
        tail.append(contentsOf: newSamples)
        if tail.count > overlapFrameCount {
          tail.removeFirst(tail.count - overlapFrameCount)
        }
      }

      if current.framesWritten == chunkFrameCapacity {
        let chunk = try current.finish(
          endFrame: totalFrames,
          maximumBytes: maximumBytes
        )
        completedURLs.append(chunk.url)
        chunks.append(chunk)
        output = nil
      }
    }
  }

}

private final class ChunkOutput {
  let index: Int
  let partialURL: URL
  let finalURL: URL
  let startFrame: Int64
  private var file: FileHandle?
  private(set) var framesWritten: Int64 = 0

  init(
    index: Int,
    runName: String,
    destinationDirectory: URL,
    startFrame: Int64
  ) throws {
    self.index = index
    self.startFrame = startFrame
    let stem = "\(runName)-chunk-\(String(format: "%04d", index))"
    partialURL =
      destinationDirectory
      .appendingPathComponent("\(stem).partial")
      .appendingPathExtension("wav")
    finalURL =
      destinationDirectory
      .appendingPathComponent(stem)
      .appendingPathExtension("wav")

    let fileManager = FileManager.default
    guard
      fileManager.createFile(
        atPath: partialURL.path,
        contents: Self.wavHeader(dataByteCount: 0),
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw AudioChunkerError.conversionFailed
    }
    do {
      let handle = try FileHandle(forWritingTo: partialURL)
      _ = try handle.seekToEnd()
      file = handle
    } catch {
      try? fileManager.removeItem(at: partialURL)
      throw AudioChunkerError.conversionFailed
    }
  }

  func write(_ samples: [Int16]) throws {
    guard !samples.isEmpty else { return }
    guard let handle = file else { throw AudioChunkerError.conversionFailed }
    try autoreleasepool {
      let data = samples.withUnsafeBufferPointer {
        Data(
          bytes: $0.baseAddress!,
          count: $0.count * MemoryLayout<Int16>.size
        )
      }
      try handle.write(contentsOf: data)
    }
    framesWritten += Int64(samples.count)
  }

  func finish(endFrame: Int64, maximumBytes: Int64) throws -> AudioChunk {
    guard
      framesWritten >= 0,
      framesWritten <= (Int64(UInt32.max) - 36) / 2
    else {
      throw AudioChunkerError.outputTooLarge
    }
    let dataByteCount = framesWritten * 2
    guard let handle = file else { throw AudioChunkerError.conversionFailed }
    try handle.seek(toOffset: 0)
    try handle.write(
      contentsOf: Self.wavHeader(dataByteCount: UInt32(dataByteCount))
    )
    try handle.synchronize()
    try handle.close()
    self.file = nil
    let fileManager = FileManager.default
    try fileManager.moveItem(at: partialURL, to: finalURL)
    let byteCount =
      (try fileManager.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber)?
      .int64Value ?? 0
    guard byteCount <= maximumBytes else {
      try? fileManager.removeItem(at: finalURL)
      throw AudioChunkerError.outputTooLarge
    }
    return AudioChunk(
      index: index,
      url: finalURL,
      startTime: Double(startFrame) / TimeBasedAudioChunker.sampleRate,
      endTime: Double(endFrame) / TimeBasedAudioChunker.sampleRate,
      byteCount: byteCount,
      sha256: try Self.sha256(of: finalURL)
    )
  }

  func remove() {
    try? file?.close()
    file = nil
    try? FileManager.default.removeItem(at: partialURL)
    try? FileManager.default.removeItem(at: finalURL)
  }

  deinit {
    try? file?.close()
  }

  private static func wavHeader(dataByteCount: UInt32) -> Data {
    var header = Data()
    header.append(contentsOf: "RIFF".utf8)
    appendLittleEndian(UInt32(36) + dataByteCount, to: &header)
    header.append(contentsOf: "WAVEfmt ".utf8)
    appendLittleEndian(UInt32(16), to: &header)
    appendLittleEndian(UInt16(1), to: &header)
    appendLittleEndian(UInt16(1), to: &header)
    appendLittleEndian(UInt32(TimeBasedAudioChunker.sampleRate), to: &header)
    appendLittleEndian(UInt32(TimeBasedAudioChunker.sampleRate * 2), to: &header)
    appendLittleEndian(UInt16(2), to: &header)
    appendLittleEndian(UInt16(16), to: &header)
    header.append(contentsOf: "data".utf8)
    appendLittleEndian(dataByteCount, to: &header)
    return header
  }

  private static func appendLittleEndian<T: FixedWidthInteger>(
    _ value: T,
    to data: inout Data
  ) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) {
      data.append(contentsOf: $0)
    }
  }

  private static func sha256(of url: URL) throws -> String {
    let descriptor = url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return Darwin.open(path, O_RDONLY)
    }
    guard descriptor >= 0 else { throw AudioChunkerError.conversionFailed }
    defer { _ = Darwin.close(descriptor) }

    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      try Task.checkCancellation()
      let readCount = buffer.withUnsafeMutableBytes { bytes -> Int in
        while true {
          let result = Darwin.read(descriptor, bytes.baseAddress, bytes.count)
          if result < 0, errno == EINTR { continue }
          return result
        }
      }
      guard readCount >= 0 else { throw AudioChunkerError.conversionFailed }
      guard readCount > 0 else { break }
      buffer.withUnsafeBytes { bytes in
        hasher.update(
          bufferPointer: UnsafeRawBufferPointer(
            start: bytes.baseAddress,
            count: readCount
          )
        )
      }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
