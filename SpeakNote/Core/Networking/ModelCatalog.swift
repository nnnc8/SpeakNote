import Foundation

enum GroqTextModelCatalog {
  static let candidates = [
    ProviderDefaults.quickTextModelID,
    ProviderDefaults.structuredTextModelID,
    ProviderDefaults.jsonObjectTextModelID,
  ]

  static let options = [
    ProviderModelOption(
      id: ProviderDefaults.quickTextModelID,
      title: "GPT-OSS 20B"
    ),
    ProviderModelOption(
      id: ProviderDefaults.structuredTextModelID,
      title: "GPT-OSS 120B"
    ),
    ProviderModelOption(
      id: ProviderDefaults.jsonObjectTextModelID,
      title: "Llama 3.3 70B"
    ),
  ]

  static func availableModels(from remoteModelIDs: [String]) -> [String] {
    let remote = Set(remoteModelIDs)
    return candidates.filter(remote.contains)
  }
}

enum GroqTranscriptionModelCatalog {
  static let options = [
    ProviderModelOption(
      id: GroqTranscriptionModel.largeV3Turbo,
      title: "Whisper Large V3 Turbo"
    ),
    ProviderModelOption(
      id: GroqTranscriptionModel.largeV3,
      title: "Whisper Large V3"
    ),
  ]
}

enum BreezeTranscriptionModel {
  static let q5_0 = "breeze-q5_0"
  static let supported: Set<String> = [q5_0]
  static let defaultID = q5_0
}

enum BreezeTranscriptionModelCatalog {
  static let options = [
    ProviderModelOption(
      id: BreezeTranscriptionModel.q5_0,
      title: "Breeze ASR 26 Q5_0（約 1.1 GB）"
    )
  ]
}
