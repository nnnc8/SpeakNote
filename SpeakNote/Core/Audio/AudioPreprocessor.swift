@preconcurrency import AVFAudio
import AudioToolbox
import Foundation

protocol AudioPreprocessing: Sendable {
  func preprocess(cafURL: URL) async throws -> URL
}

struct PCM16WAVPreprocessor: AudioPreprocessing, Sendable {
  static let sampleRate = 16_000.0

  private let destinationDirectory: URL

  init(destinationDirectory: URL = FileManager.default.temporaryDirectory) {
    self.destinationDirectory = destinationDirectory
  }

  func preprocess(cafURL: URL) async throws -> URL {
    let outputURL =
      destinationDirectory
      .appendingPathComponent("\(cafURL.deletingPathExtension().lastPathComponent)-16k")
      .appendingPathExtension("wav")

    let conversion = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      try Self.convert(cafURL: cafURL, outputURL: outputURL)
      try Task.checkCancellation()
      return outputURL
    }

    do {
      return try await withTaskCancellationHandler {
        let result = try await conversion.value
        try Task.checkCancellation()
        return result
      } onCancel: {
        conversion.cancel()
      }
    } catch {
      conversion.cancel()
      try? FileManager.default.removeItem(at: outputURL)
      throw error
    }
  }

  private static func convert(cafURL: URL, outputURL: URL) throws {
    let fileManager = FileManager.default
    try Task.checkCancellation()
    if fileManager.fileExists(atPath: outputURL.path) {
      try fileManager.removeItem(at: outputURL)
    }

    do {
      let inputFile = try AVAudioFile(forReading: cafURL)
      let inputFormat = inputFile.processingFormat
      guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
        let outputFormat = AVAudioFormat(
          commonFormat: .pcmFormatInt16,
          sampleRate: sampleRate,
          channels: 1,
          interleaved: true
        ),
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
      else {
        throw AudioRecorderError.invalidInputFormat
      }

      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ]
      let outputFile = try AVAudioFile(
        forWriting: outputURL,
        settings: settings,
        commonFormat: .pcmFormatInt16,
        interleaved: true
      )
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: outputURL.path
      )
      let input = ConverterInput(file: inputFile)

      while true {
        try Task.checkCancellation()
        guard
          let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: 4_096
          )
        else {
          throw AudioRecorderError.conversionFailed("Could not allocate an output buffer.")
        }

        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) {
          packetCount, inputStatus in
          input.read(packetCount: packetCount, status: inputStatus)
        }

        if let readError = input.readError {
          throw readError
        }
        if let conversionError {
          throw conversionError
        }
        if outputBuffer.frameLength > 0 {
          try outputFile.write(from: outputBuffer)
        }

        switch status {
        case .haveData, .inputRanDry:
          continue
        case .endOfStream:
          return
        case .error:
          throw AudioRecorderError.conversionFailed("The audio converter returned an error.")
        @unknown default:
          throw AudioRecorderError.conversionFailed(
            "The audio converter returned an unknown status.")
        }
      }
    } catch is CancellationError {
      try? fileManager.removeItem(at: outputURL)
      throw CancellationError()
    } catch let error as AudioRecorderError {
      try? fileManager.removeItem(at: outputURL)
      throw error
    } catch {
      try? fileManager.removeItem(at: outputURL)
      throw AudioRecorderError.conversionFailed(error.localizedDescription)
    }
  }
}

private final class ConverterInput: @unchecked Sendable {
  let file: AVAudioFile
  let format: AVAudioFormat
  var finished = false
  var readError: Error?

  init(file: AVAudioFile) {
    self.file = file
    format = file.processingFormat
  }

  func read(
    packetCount: AVAudioPacketCount,
    status: UnsafeMutablePointer<AVAudioConverterInputStatus>
  ) -> AVAudioBuffer? {
    guard !finished else {
      status.pointee = .endOfStream
      return nil
    }

    let remaining = file.length - file.framePosition
    guard remaining > 0 else {
      finished = true
      status.pointee = .endOfStream
      return nil
    }

    let frameCount = min(AVAudioFrameCount(packetCount), AVAudioFrameCount(remaining))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
      finished = true
      readError = AudioRecorderError.conversionFailed("Could not allocate an input buffer.")
      status.pointee = .noDataNow
      return nil
    }

    do {
      try file.read(into: buffer, frameCount: frameCount)
      guard buffer.frameLength > 0 else {
        finished = true
        status.pointee = .endOfStream
        return nil
      }
      status.pointee = .haveData
      return buffer
    } catch {
      finished = true
      readError = error
      status.pointee = .noDataNow
      return nil
    }
  }
}
