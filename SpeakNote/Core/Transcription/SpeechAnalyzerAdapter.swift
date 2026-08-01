import AVFoundation
import CoreMedia
import Foundation
import Speech

@available(macOS 26, *)
actor SpeechAnalyzerAdapter: AppleSpeechAdapter {
  func availability(for locale: Locale) async -> SpeechAdapterAvailability {
    let authorization = Self.authorizationState
    guard SpeechTranscriber.isAvailable else {
      return SpeechAdapterAvailability(
        authorization: authorization,
        isAvailable: false,
        supportsLocale: false,
        supportsOnDeviceRecognition: true,
        modelAssetState: .unavailable
      )
    }
    guard let supportedLocale = await SpeechTranscriber.supportedLocale(
      equivalentTo: locale
    ) else {
      return SpeechAdapterAvailability(
        authorization: authorization,
        isAvailable: true,
        supportsLocale: false,
        supportsOnDeviceRecognition: true,
        modelAssetState: .unavailable
      )
    }

    let transcriber = SpeechTranscriber(
      locale: supportedLocale,
      preset: .timeIndexedTranscriptionWithAlternatives
    )
    let assetStatus = await AssetInventory.status(forModules: [transcriber])
    return SpeechAdapterAvailability(
      authorization: authorization,
      isAvailable: true,
      supportsLocale: true,
      supportsOnDeviceRecognition: true,
      modelAssetState: Self.modelAssetState(for: assetStatus)
    )
  }

  func transcribe(
    audioURL: URL,
    locale: Locale,
    duration _: TimeInterval
  ) async throws -> Transcript {
    let currentAvailability = await availability(for: locale)
    let capability = TranscriptionCapabilityResolver().resolve(
      TranscriptionCapabilityInput(
        macOSMajorVersion: 26,
        duration: 0,
        adapter: currentAvailability
      )
    )
    guard case .available = capability else {
      guard case .unavailable(let reason) = capability else {
        throw AppleTranscriptionError.recognitionFailed
      }
      throw AppleTranscriptionError.unavailable(reason)
    }
    guard let supportedLocale = await SpeechTranscriber.supportedLocale(
      equivalentTo: locale
    ) else {
      throw AppleTranscriptionError.unavailable(.unsupportedLocale)
    }

    let audioFile: AVAudioFile
    do {
      audioFile = try AVAudioFile(forReading: audioURL)
    } catch {
      throw AppleTranscriptionError.unreadableAudio
    }

    let transcriber = SpeechTranscriber(
      locale: supportedLocale,
      preset: .timeIndexedTranscriptionWithAlternatives
    )
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let resultTask = Task {
      var segments: [TranscriptSegment] = []
      for try await result in transcriber.results {
        try Task.checkCancellation()
        guard result.isFinal else { continue }
        let text = String(result.text.characters)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }

        let startTime = result.range.start.seconds
        let segmentDuration = result.range.duration.seconds
        guard
          startTime.isFinite,
          segmentDuration.isFinite,
          startTime >= 0,
          segmentDuration >= 0
        else {
          throw AppleTranscriptionError.invalidResult
        }
        segments.append(
          TranscriptSegment(
            startTime: startTime,
            endTime: startTime + segmentDuration,
            text: text,
            detectedLanguage: supportedLocale.identifier
          )
        )
      }
      return segments
    }

    let segments: [TranscriptSegment]
    do {
      segments = try await withTaskCancellationHandler {
        do {
          try await analyzer.start(
            inputAudioFile: audioFile,
            finishAfterFile: true
          )
          return try await resultTask.value
        } catch {
          resultTask.cancel()
          await analyzer.cancelAndFinishNow()
          throw error
        }
      } onCancel: {
        resultTask.cancel()
        Task {
          await analyzer.cancelAndFinishNow()
        }
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as AppleTranscriptionError {
      throw error
    } catch {
      throw AppleTranscriptionError.recognitionFailed
    }

    guard !segments.isEmpty else {
      throw AppleTranscriptionError.invalidResult
    }
    return Transcript(
      text: segments.map(\.text).joined(separator: " "),
      segments: segments,
      detectedLanguage: supportedLocale.identifier
    )
  }

  private static var authorizationState: SpeechAuthorizationState {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .notDetermined:
      .notDetermined
    case .denied:
      .denied
    case .restricted:
      .restricted
    case .authorized:
      .authorized
    @unknown default:
      .denied
    }
  }

  private static func modelAssetState(
    for status: AssetInventory.Status
  ) -> SpeechModelAssetState {
    switch status {
    case .installed:
      .installed
    case .supported, .downloading:
      .missing
    case .unsupported:
      .unavailable
    @unknown default:
      .unavailable
    }
  }
}
