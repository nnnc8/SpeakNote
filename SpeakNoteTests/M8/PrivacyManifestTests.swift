import Foundation
import XCTest

@testable import SpeakNote

final class PrivacyManifestTests: XCTestCase {
  func testBundledPrivacyManifestDeclaresCloudContentAndRequiredReasonAPIs()
    throws
  {
    let url = try XCTUnwrap(
      Bundle.main.url(
        forResource: "PrivacyInfo",
        withExtension: "xcprivacy"
      )
    )
    let data = try Data(contentsOf: url)
    let root = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    )

    let collected = try XCTUnwrap(
      root["NSPrivacyCollectedDataTypes"] as? [[String: Any]]
    )
    let collectedTypes = Set(
      collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }
    )
    XCTAssertTrue(
      collectedTypes.contains("NSPrivacyCollectedDataTypeAudioData")
    )
    XCTAssertTrue(
      collectedTypes.contains("NSPrivacyCollectedDataTypeOtherUserContent")
    )
    XCTAssertTrue(
      collected.allSatisfy {
        ($0["NSPrivacyCollectedDataTypeTracking"] as? Bool) == false
      }
    )

    let accessed = try XCTUnwrap(
      root["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
    )
    let reasonPairs: [(String, Set<String>)] = accessed.compactMap { item in
      guard
        let category = item["NSPrivacyAccessedAPIType"] as? String,
        let values = item["NSPrivacyAccessedAPITypeReasons"] as? [String]
      else {
        return nil
      }
      return (category, Set(values))
    }
    let reasons = Dictionary(uniqueKeysWithValues: reasonPairs)
    XCTAssertEqual(
      reasons["NSPrivacyAccessedAPICategoryUserDefaults"],
      ["CA92.1"]
    )
    XCTAssertEqual(
      reasons["NSPrivacyAccessedAPICategoryFileTimestamp"],
      ["C617.1"]
    )
    XCTAssertEqual(
      reasons["NSPrivacyAccessedAPICategorySystemBootTime"],
      ["35F9.1"]
    )
    XCTAssertEqual(
      reasons["NSPrivacyAccessedAPICategoryDiskSpace"],
      ["E174.1"]
    )
  }
}
