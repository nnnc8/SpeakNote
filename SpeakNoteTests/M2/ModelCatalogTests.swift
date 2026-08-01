import XCTest

@testable import SpeakNote

final class ModelCatalogTests: XCTestCase {
  func testIntersectsRemoteModelsInCentralPriorityOrder() {
    XCTAssertEqual(
      GroqTextModelCatalog.availableModels(
        from: [
          "unrelated",
          ProviderDefaults.structuredTextModelID,
          ProviderDefaults.quickTextModelID,
        ]
      ),
      [
        ProviderDefaults.quickTextModelID,
        ProviderDefaults.structuredTextModelID,
      ]
    )
  }
}
