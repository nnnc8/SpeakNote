import Foundation

enum GroqTextModelCatalog {
  static let candidates = [
    ProviderDefaults.quickTextModelID,
    ProviderDefaults.structuredTextModelID,
    ProviderDefaults.jsonObjectTextModelID,
  ]

  static func availableModels(from remoteModelIDs: [String]) -> [String] {
    let remote = Set(remoteModelIDs)
    return candidates.filter(remote.contains)
  }
}
