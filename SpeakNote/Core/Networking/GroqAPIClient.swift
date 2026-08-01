import Foundation

public enum GroqTranscriptionModel {
  public static let largeV3 = "whisper-large-v3"
  public static let largeV3Turbo = "whisper-large-v3-turbo"
  public static let supported = [largeV3Turbo, largeV3]
}

public struct GroqTranscriptionResponse: Sendable, Equatable {
  public struct Segment: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
  }

  public let text: String
  public let language: String?
  public let segments: [Segment]
}

public enum GroqAPIError: Error, Sendable, Equatable {
  case invalidConfiguration
  case unsupportedModel
  case invalidLanguage
  case invalidAudioFile
  case audioFileTooLarge(maximumBytes: Int64)
  case invalidResponse
  case httpStatus(Int)
  case transportFailed
  case ambiguousCompletion
}

extension GroqAPIError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      String(localized: "The Groq provider configuration is invalid.")
    case .unsupportedModel:
      String(localized: "The selected Groq speech model is not supported.")
    case .invalidLanguage:
      String(localized: "The transcription language code is invalid.")
    case .invalidAudioFile:
      String(localized: "The recorded audio file could not be prepared for upload.")
    case .audioFileTooLarge(let maximumBytes):
      String(
        localized:
          "The recording exceeds the \(maximumBytes / 1_048_576) MiB upload limit."
      )
    case .invalidResponse:
      String(localized: "Groq returned an unreadable transcription response.")
    case .httpStatus(let status):
      switch status {
      case 400:
        String(localized: "Groq rejected the transcription request.")
      case 401:
        String(localized: "The Groq API key is invalid. Update it in SpeakNote Settings.")
      case 403:
        String(localized: "The Groq API key is not allowed to use this resource.")
      case 413:
        String(localized: "Groq rejected the recording because it is too large.")
      case 429:
        String(localized: "Groq is rate-limiting requests. Try again shortly.")
      case 500...599:
        String(localized: "Groq is temporarily unavailable. Try again later.")
      default:
        String(
          localized: "Groq could not complete the transcription request (HTTP \(status))."
        )
      }
    case .transportFailed:
      String(localized: "SpeakNote could not reach Groq. Check the network connection.")
    case .ambiguousCompletion:
      String(
        localized:
          "The network disconnected before Groq's result was confirmed. Please retry."
      )
    }
  }
}

public struct GroqAPIClient: Sendable {
  public static let maximumAudioBytes: Int64 = 20 * 1024 * 1024

  private let apiKey: String
  private let baseURL: URL
  private let transport: any HTTPTransport
  private let retryPolicy: RetryPolicy
  private let sleep: @Sendable (TimeInterval) async throws -> Void

  public init(
    apiKey: String,
    baseURL: URL = URL(string: "https://api.groq.com")!,
    transport: any HTTPTransport = URLSessionHTTPTransport(),
    retryPolicy: RetryPolicy = RetryPolicy(),
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
      try await Task.sleep(for: .seconds(seconds))
    }
  ) throws {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty,
      !key.contains("\r"),
      !key.contains("\n"),
      baseURL.scheme?.lowercased() == "https",
      baseURL.host != nil
    else {
      throw GroqAPIError.invalidConfiguration
    }
    self.apiKey = key
    self.baseURL = baseURL
    self.transport = transport
    self.retryPolicy = retryPolicy
    self.sleep = sleep
  }

  public func transcribe(
    audioURL: URL,
    model: String = GroqTranscriptionModel.largeV3Turbo,
    language: String? = nil,
    prompt: String? = nil
  ) async throws -> GroqTranscriptionResponse {
    guard GroqTranscriptionModel.supported.contains(model) else {
      throw GroqAPIError.unsupportedModel
    }
    if let language, !Self.isValidLanguage(language) {
      throw GroqAPIError.invalidLanguage
    }

    let values: URLResourceValues
    do {
      values = try audioURL.resourceValues(forKeys: [
        .isRegularFileKey, .isReadableKey, .fileSizeKey,
      ])
    } catch {
      throw GroqAPIError.invalidAudioFile
    }
    guard audioURL.isFileURL,
      values.isRegularFile == true,
      values.isReadable == true,
      let size = values.fileSize,
      size > 0
    else {
      throw GroqAPIError.invalidAudioFile
    }
    guard Int64(size) <= Self.maximumAudioBytes else {
      throw GroqAPIError.audioFileTooLarge(maximumBytes: Self.maximumAudioBytes)
    }

    var fields = [
      MultipartTextField(name: "model", value: model),
      MultipartTextField(name: "response_format", value: "verbose_json"),
    ]
    if let language { fields.append(MultipartTextField(name: "language", value: language)) }
    if let prompt, !prompt.isEmpty {
      fields.append(MultipartTextField(name: "prompt", value: prompt))
    }

    let form: FileBackedMultipartForm
    do {
      form = try MultipartFormData.write(
        fields: fields,
        file: MultipartFilePart(
          name: "file",
          fileURL: audioURL,
          fileName: Self.safeFileName(audioURL.lastPathComponent),
          contentType: Self.contentType(for: audioURL)
        )
      )
    } catch {
      throw GroqAPIError.invalidAudioFile
    }
    defer { form.remove() }

    var request = URLRequest(url: try endpoint(path: "/openai/v1/audio/transcriptions"))
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
    request.setValue(String(form.contentLength), forHTTPHeaderField: "Content-Length")

    let response = try await execute(HTTPRequest(request: request, body: .file(form.fileURL)))
    let decoded: TranscriptionDTO
    do {
      decoded = try JSONDecoder().decode(TranscriptionDTO.self, from: response.body)
    } catch {
      throw GroqAPIError.invalidResponse
    }
    guard
      decoded.segments.allSatisfy({
        $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start
      })
    else {
      throw GroqAPIError.invalidResponse
    }
    return GroqTranscriptionResponse(
      text: decoded.text,
      language: decoded.language,
      segments: decoded.segments.map { .init(start: $0.start, end: $0.end, text: $0.text) }
    )
  }

  public func availableTranscriptionModels() async throws -> [String] {
    var request = URLRequest(url: try endpoint(path: "/openai/v1/models"))
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let response = try await execute(HTTPRequest(request: request))
    let decoded: ModelsDTO
    do {
      decoded = try JSONDecoder().decode(ModelsDTO.self, from: response.body)
    } catch {
      throw GroqAPIError.invalidResponse
    }
    let remote = Set(decoded.data.map(\.id))
    return GroqTranscriptionModel.supported.filter(remote.contains)
  }

  private func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    var retryCount = 0
    while true {
      let response: HTTPResponse
      do {
        response = try await transport.send(request)
      } catch is CancellationError {
        throw CancellationError()
      } catch HTTPTransportError.ambiguousCompletion {
        throw GroqAPIError.ambiguousCompletion
      } catch {
        throw GroqAPIError.transportFailed
      }

      if (200...299).contains(response.statusCode) {
        return response
      }
      guard retryPolicy.shouldRetry(statusCode: response.statusCode, retryCount: retryCount) else {
        throw GroqAPIError.httpStatus(response.statusCode)
      }
      let delay = retryPolicy.delay(headers: response.headers, retryCount: retryCount)
      retryCount += 1
      try await sleep(delay)
    }
  }

  private func endpoint(path: String) throws -> URL {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw GroqAPIError.invalidConfiguration
    }
    components.path = path
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { throw GroqAPIError.invalidConfiguration }
    return url
  }

  private static func safeFileName(_ value: String) -> String {
    let cleaned = value.map { character in
      character == "\"" || character == "\r" || character == "\n" ? "_" : character
    }
    return cleaned.isEmpty ? "audio" : String(cleaned)
  }

  private static func isValidLanguage(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.count <= 35
      && value.unicodeScalars.allSatisfy {
        (65...90).contains($0.value)
          || (97...122).contains($0.value)
          || (48...57).contains($0.value)
          || $0.value == 45
      }
  }

  private static func contentType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "m4a": "audio/mp4"
    case "mp3": "audio/mpeg"
    case "wav": "audio/wav"
    case "aiff", "aif": "audio/aiff"
    case "caf": "audio/x-caf"
    default: "application/octet-stream"
    }
  }
}

private struct TranscriptionDTO: Decodable {
  struct Segment: Decodable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
  }

  let text: String
  let language: String?
  let segments: [Segment]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    text = try container.decode(String.self, forKey: .text)
    language = try container.decodeIfPresent(String.self, forKey: .language)
    segments = try container.decodeIfPresent([Segment].self, forKey: .segments) ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case text, language, segments
  }
}

private struct ModelsDTO: Decodable {
  struct Model: Decodable { let id: String }
  let data: [Model]
}
