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

struct ProviderLanguageOption: Identifiable, Equatable, Sendable {
  let code: String
  let title: String

  var id: String { code }
}

struct ProviderModelOption: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
}

enum ProviderLanguageCatalog {
  static let groqLanguageCodes: Set<String> = [
    "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl",
    "ca", "nl", "ar", "sv", "it", "id", "hi", "fi", "vi", "he", "uk",
    "el", "ms", "cs", "ro", "da", "hu", "ta", "no", "th", "ur", "hr",
    "bg", "lt", "la", "mi", "ml", "cy", "sk", "te", "fa", "lv", "bn",
    "sr", "az", "sl", "kn", "et", "mk", "br", "eu", "is", "hy", "ne",
    "mn", "bs", "kk", "sq", "sw", "gl", "mr", "pa", "si", "km", "sn",
    "yo", "so", "af", "oc", "ka", "be", "tg", "sd", "gu", "am", "yi",
    "lo", "uz", "fo", "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my",
    "bo", "tl", "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw", "su",
    "yue",
  ]

  static let groq: [ProviderLanguageOption] = [
    option("zh-TW"), option("zh-CN"), option("en-US"), option("en-GB"),
    option("ja-JP"), option("ko-KR"), option("es-ES"), option("fr-FR"),
    option("de-DE"), option("it-IT"), option("pt-BR"), option("ru-RU"),
    option("nl-NL"), option("th-TH"), option("vi-VN"), option("id-ID"),
    option("tr-TR"), option("pl-PL"), option("uk-UA"), option("ar-SA"),
    option("hi-IN")
  ] + groqLanguageCodes
    .sorted()
    .filter { code in
      ![
        "zh", "en", "ja", "ko", "es", "fr", "de", "it", "pt", "ru",
        "nl", "th", "vi", "id", "tr", "pl", "uk", "ar", "hi",
      ].contains(code)
    }
    .map(option)

  static func options(for locales: [Locale]) -> [ProviderLanguageOption] {
    locales
      .map { locale in
        let code = locale.identifier.replacingOccurrences(of: "_", with: "-")
        return ProviderLanguageOption(
          code: code,
          title: Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? code
        )
      }
      .reduce(into: [ProviderLanguageOption]()) { result, option in
        guard !result.contains(where: { $0.code == option.code }) else { return }
        result.append(option)
      }
      .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  private static func option(_ code: String) -> ProviderLanguageOption {
    ProviderLanguageOption(
      code: code,
      title: Locale.current.localizedString(forIdentifier: code) ?? code
    )
  }
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
