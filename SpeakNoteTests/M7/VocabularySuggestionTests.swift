import Foundation
import XCTest

@testable import SpeakNote

final class VocabularySuggestionTests: XCTestCase {
  func testHistoryOffAndDisabledVocabularyProduceNoCandidates() {
    let profile = Profile(id: id(1), name: "Work")
    let observation = VocabularyCorrectionObservation(
      profileID: profile.id,
      original: "voice md",
      replacement: "VoiceMD"
    )
    let generator = VocabularySuggestionGenerator()

    XCTAssertEqual(
      generator.generate(
        for: profile,
        historyEnabled: false,
        observations: [observation],
        minimumOccurrences: 1
      ),
      []
    )
    XCTAssertEqual(
      generator.generate(
        for: Profile(id: profile.id, name: profile.name, vocabularyScope: .disabled),
        historyEnabled: true,
        observations: [observation],
        minimumOccurrences: 1
      ),
      []
    )
  }

  func testCandidatesAreProfileIsolatedNormalizedAndDeterministicallyOrdered() {
    let profile = Profile(id: id(1), name: "Work")
    let otherProfile = Profile(id: id(2), name: "Personal")
    let observations = [
      observation(profile.id, " voice   md ", " VoiceMD "),
      observation(profile.id, "voice md", "VoiceMD"),
      observation(profile.id, "SDK", "S D K"),
      observation(profile.id, "SDK", "S D K"),
      observation(profile.id, "SDK", "S D K"),
      observation(otherProfile.id, "SDK", "foreign"),
      observation(profile.id, "same", "same"),
      observation(profile.id, "", "ignored"),
    ]

    let suggestions = VocabularySuggestionGenerator().generate(
      for: profile,
      historyEnabled: true,
      observations: observations
    )

    XCTAssertEqual(suggestions.map(\.original), ["SDK", "voice md"])
    XCTAssertEqual(suggestions.map(\.replacement), ["S D K", "VoiceMD"])
    XCTAssertEqual(suggestions.map(\.occurrenceCount), [3, 2])
    XCTAssertEqual(suggestions.map(\.status), [.pending, .pending])
    XCTAssertTrue(suggestions.allSatisfy { $0.profileID == profile.id })
  }

  func testCandidateIdentityAndOrderDoNotDependOnObservationOrder() {
    let profile = Profile(id: id(1), name: "Work")
    let observations = [
      observation(profile.id, "beta", "Beta"),
      observation(profile.id, "alpha", "Alpha"),
    ]
    let generator = VocabularySuggestionGenerator()

    let forward = generator.generate(
      for: profile,
      historyEnabled: true,
      observations: observations,
      minimumOccurrences: 1
    )
    let reverse = generator.generate(
      for: profile,
      historyEnabled: true,
      observations: Array(observations.reversed()),
      minimumOccurrences: 1
    )

    XCTAssertEqual(forward, reverse)
    XCTAssertEqual(forward.map(\.original), ["alpha", "beta"])
  }

  func testAcceptAndRejectAreExplicitPureOneWayTransitions() throws {
    let profile = Profile(id: id(1), name: "Work")
    let pending = try XCTUnwrap(
      VocabularySuggestionGenerator().generate(
        for: profile,
        historyEnabled: true,
        observations: [observation(profile.id, "voice md", "VoiceMD")],
        minimumOccurrences: 1
      ).first
    )

    let accepted = try VocabularySuggestionTransition.accept(pending)
    let rejected = try VocabularySuggestionTransition.reject(pending)

    XCTAssertEqual(pending.status, .pending)
    XCTAssertEqual(accepted.status, .accepted)
    XCTAssertEqual(rejected.status, .rejected)
    XCTAssertEqual(accepted.id, pending.id)
    XCTAssertEqual(rejected.id, pending.id)
    XCTAssertEqual(
      VocabularySuggestionGenerator().generate(
        for: profile,
        historyEnabled: true,
        observations: [observation(profile.id, "voice md", "VoiceMD")],
        minimumOccurrences: 1
      ).first?.status,
      .pending
    )

    XCTAssertThrowsError(try VocabularySuggestionTransition.reject(accepted)) { error in
      XCTAssertEqual(
        error as? VocabularySuggestionTransitionError,
        .alreadyDecided(.accepted)
      )
    }
    XCTAssertThrowsError(try VocabularySuggestionTransition.accept(rejected)) { error in
      XCTAssertEqual(
        error as? VocabularySuggestionTransitionError,
        .alreadyDecided(.rejected)
      )
    }
  }

  private func observation(
    _ profileID: UUID,
    _ original: String,
    _ replacement: String
  ) -> VocabularyCorrectionObservation {
    VocabularyCorrectionObservation(
      profileID: profileID,
      original: original,
      replacement: replacement
    )
  }

  private func id(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
  }
}
