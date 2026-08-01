import Foundation

struct AppSettings: Codable, Equatable, Sendable {
  var transcriptionProviderID: ProviderID
  var transcriptionModelID: String
  var transcriptionFallbackPolicy: FallbackPolicy
  var localOnly: Bool
  var activeProfileID: UUID?
  var defaultVoiceNoteType: NoteType
  var textProcessingProviderID: ProviderID
  var textProcessingModelID: String
  var structuredTextModelID: String
  var recognitionLanguageCode: String?
  var outputLanguageCode: String?
  var compressionLevel: CompressionLevel
  var dictationHistoryEnabled: Bool
  var hasAcknowledgedGroqCloudProcessing: Bool
  var hasCompletedOnboarding: Bool

  init(
    transcriptionProviderID: ProviderID = .groq,
    transcriptionModelID: String = ProviderDefaults.transcriptionModelID,
    transcriptionFallbackPolicy: FallbackPolicy = .defaultValue,
    localOnly: Bool = false,
    activeProfileID: UUID? = nil,
    defaultVoiceNoteType: NoteType = .generalNotes,
    textProcessingProviderID: ProviderID = .groq,
    textProcessingModelID: String = ProviderDefaults.quickTextModelID,
    structuredTextModelID: String = ProviderDefaults.structuredTextModelID,
    recognitionLanguageCode: String? = nil,
    outputLanguageCode: String? = nil,
    compressionLevel: CompressionLevel = .verbatim,
    dictationHistoryEnabled: Bool = true,
    hasAcknowledgedGroqCloudProcessing: Bool = false,
    hasCompletedOnboarding: Bool = false
  ) {
    self.transcriptionProviderID = transcriptionProviderID
    self.transcriptionModelID = transcriptionModelID
    self.transcriptionFallbackPolicy = transcriptionFallbackPolicy
    self.localOnly = localOnly
    self.activeProfileID = activeProfileID
    self.defaultVoiceNoteType = defaultVoiceNoteType
    self.textProcessingProviderID = textProcessingProviderID
    self.textProcessingModelID = textProcessingModelID
    self.structuredTextModelID = structuredTextModelID
    self.recognitionLanguageCode = recognitionLanguageCode
    self.outputLanguageCode = outputLanguageCode
    self.compressionLevel = compressionLevel
    self.dictationHistoryEnabled = dictationHistoryEnabled
    self.hasAcknowledgedGroqCloudProcessing = hasAcknowledgedGroqCloudProcessing
    self.hasCompletedOnboarding = hasCompletedOnboarding
  }

  static let defaultValue = AppSettings()

  private enum CodingKeys: String, CodingKey {
    case transcriptionProviderID
    case transcriptionModelID
    case transcriptionFallbackPolicy
    case localOnly
    case activeProfileID
    case defaultVoiceNoteType
    case textProcessingProviderID
    case textProcessingModelID
    case structuredTextModelID
    case recognitionLanguageCode
    case outputLanguageCode
    case compressionLevel
    case dictationHistoryEnabled
    case hasAcknowledgedGroqCloudProcessing
    case hasCompletedOnboarding
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    transcriptionProviderID =
      try container.decodeIfPresent(ProviderID.self, forKey: .transcriptionProviderID)
      ?? .groq
    transcriptionModelID =
      try container.decodeIfPresent(String.self, forKey: .transcriptionModelID)
      ?? ProviderDefaults.transcriptionModelID
    transcriptionFallbackPolicy =
      try container.decodeIfPresent(
        FallbackPolicy.self,
        forKey: .transcriptionFallbackPolicy
      ) ?? .defaultValue
    localOnly =
      try container.decodeIfPresent(Bool.self, forKey: .localOnly)
      ?? false
    activeProfileID =
      try container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
    defaultVoiceNoteType =
      try container.decodeIfPresent(NoteType.self, forKey: .defaultVoiceNoteType)
      ?? .generalNotes
    textProcessingProviderID =
      try container.decodeIfPresent(ProviderID.self, forKey: .textProcessingProviderID)
      ?? .groq
    textProcessingModelID =
      try container.decodeIfPresent(String.self, forKey: .textProcessingModelID)
      ?? ProviderDefaults.quickTextModelID
    structuredTextModelID =
      try container.decodeIfPresent(String.self, forKey: .structuredTextModelID)
      ?? ProviderDefaults.structuredTextModelID
    recognitionLanguageCode =
      try container.decodeIfPresent(String.self, forKey: .recognitionLanguageCode)
    outputLanguageCode =
      try container.decodeIfPresent(String.self, forKey: .outputLanguageCode)
    compressionLevel =
      try container.decodeIfPresent(CompressionLevel.self, forKey: .compressionLevel)
      ?? .verbatim
    dictationHistoryEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .dictationHistoryEnabled)
      ?? true
    hasAcknowledgedGroqCloudProcessing =
      try container.decodeIfPresent(
        Bool.self,
        forKey: .hasAcknowledgedGroqCloudProcessing
      ) ?? false
    hasCompletedOnboarding =
      try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)
      ?? false
  }
}
