import Foundation

struct ProviderID: RawRepresentable, Codable, Hashable, Sendable {
  let rawValue: String

  static let groq = ProviderID(rawValue: "groq")
  static let appleSpeech = ProviderID(rawValue: "apple-speech")
}

enum ProviderDefaults {
  static let transcriptionModelID = "whisper-large-v3-turbo"
  static let quickTextModelID = "openai/gpt-oss-20b"
  static let structuredTextModelID = "openai/gpt-oss-120b"
  static let jsonObjectTextModelID = "llama-3.3-70b-versatile"
}

struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  let startTime: TimeInterval
  let endTime: TimeInterval
  let text: String
  let detectedLanguage: String?

  init(
    id: UUID = UUID(),
    startTime: TimeInterval,
    endTime: TimeInterval,
    text: String,
    detectedLanguage: String? = nil
  ) {
    self.id = id
    self.startTime = startTime
    self.endTime = endTime
    self.text = text
    self.detectedLanguage = detectedLanguage
  }
}

struct Transcript: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  let text: String
  let segments: [TranscriptSegment]
  let detectedLanguage: String?

  init(
    id: UUID = UUID(),
    text: String,
    segments: [TranscriptSegment] = [],
    detectedLanguage: String? = nil
  ) {
    self.id = id
    self.text = text
    self.segments = segments
    self.detectedLanguage = detectedLanguage
  }
}

struct TranscriptionConfiguration: Codable, Equatable, Sendable {
  var providerID: ProviderID
  var modelID: String
  var languageCode: String?
  var prompt: String?

  init(
    providerID: ProviderID = .groq,
    modelID: String = ProviderDefaults.transcriptionModelID,
    languageCode: String? = nil,
    prompt: String? = nil
  ) {
    self.providerID = providerID
    self.modelID = modelID
    self.languageCode = languageCode
    self.prompt = prompt
  }
}

protocol TranscriptionEngine: Sendable {
  func transcribe(
    audioURL: URL,
    configuration: TranscriptionConfiguration
  ) async throws -> Transcript
}

enum CompressionLevel: String, CaseIterable, Codable, Equatable, Sendable {
  case verbatim
  case clean
  case polished
  case concise
}

struct TextProcessingConfiguration: Codable, Equatable, Sendable {
  var providerID: ProviderID
  var modelID: String
  var compressionLevel: CompressionLevel
  var recognitionLanguageCode: String?
  var outputLanguageCode: String?
  var instruction: String?

  init(
    providerID: ProviderID = .groq,
    modelID: String = ProviderDefaults.quickTextModelID,
    compressionLevel: CompressionLevel = .verbatim,
    recognitionLanguageCode: String? = nil,
    outputLanguageCode: String? = nil,
    instruction: String? = nil
  ) {
    self.providerID = providerID
    self.modelID = modelID
    self.compressionLevel = compressionLevel
    self.recognitionLanguageCode = recognitionLanguageCode
    self.outputLanguageCode = outputLanguageCode
    self.instruction = instruction
  }
}

struct ProcessedText: Codable, Equatable, Sendable {
  let text: String
}

protocol TextProcessingEngine: Sendable {
  func process(
    transcript: Transcript,
    configuration: TextProcessingConfiguration
  ) async throws -> ProcessedText
}
