import XCTest

@testable import SpeakNote

final class SystemKeychainContractTests: XCTestCase {
  func testSystemKeychainRoundTripUsesIsolatedServiceAndDeletesSecret()
    async throws
  {
    let identifier = UUID().uuidString
    let keychain = SystemKeychainService(
      service: "com.nc8.SpeakNote.tests.\(identifier)",
      account: "contract"
    )
    let secret = "integration-secret-\(identifier)"

    try await keychain.deleteAPIKey()
    do {
      try await keychain.saveAPIKey(secret)
      let loaded = try await keychain.loadAPIKey()
      XCTAssertEqual(loaded, secret)
    } catch {
      try? await keychain.deleteAPIKey()
      throw error
    }

    try await keychain.deleteAPIKey()
    let deleted = try await keychain.loadAPIKey()
    XCTAssertNil(deleted)
  }
}
