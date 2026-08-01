import Foundation
import XCTest

@testable import SpeakNote

final class VocabularyServiceIntegrationTests: XCTestCase {
  func testRulesPreserveTranscriptIdentityAndHistoryIsExplicitlyGated()
    async throws
  {
    let repository = SwiftDataVocabularyRepository(
      modelContainer: try SpeakNoteModelContainer.inMemory()
    )
    let profile = Profile(id: id(1), name: "Work")
    let rule = ReplacementRule(
      id: id(2),
      profileID: profile.id,
      match: "voice md",
      replacement: "VoiceMD"
    )
    _ = try await repository.createProfile(profile)
    _ = try await repository.createReplacementRule(rule)
    let service = VocabularyService(repository: repository)
    let raw = Transcript(
      id: id(3),
      text: "voice md ships",
      segments: [
        TranscriptSegment(
          id: id(4),
          startTime: 1,
          endTime: 3,
          text: "voice md ships",
          detectedLanguage: "en"
        )
      ],
      detectedLanguage: "en"
    )

    let recorded = try await service.apply(
      to: raw,
      profileID: profile.id,
      recordHistory: true
    )

    XCTAssertEqual(recorded.transcript.id, raw.id)
    XCTAssertEqual(recorded.transcript.segments.map(\.id), raw.segments.map(\.id))
    XCTAssertEqual(recorded.transcript.segments.map(\.startTime), [1])
    XCTAssertEqual(recorded.transcript.segments.map(\.endTime), [3])
    XCTAssertEqual(recorded.transcript.text, "VoiceMD ships")
    XCTAssertEqual(recorded.transcript.segments.first?.text, "VoiceMD ships")
    XCTAssertEqual(raw.text, "voice md ships")
    XCTAssertEqual(raw.segments.first?.text, "voice md ships")
    XCTAssertEqual(recorded.audits.count, 1)
    XCTAssertNotNil(recorded.configurationHash)

    let auditsAfterRecording = try await repository.replacementAudits(
      profileID: profile.id
    )
    let observationsAfterRecording = try await repository.correctionObservations(
      profileID: profile.id
    )
    XCTAssertEqual(auditsAfterRecording.count, 1)
    XCTAssertEqual(observationsAfterRecording.count, 1)

    let privateResult = try await service.apply(
      to: raw,
      profileID: profile.id,
      recordHistory: false
    )
    let auditsAfterPrivateRun = try await repository.replacementAudits(
      profileID: profile.id
    )
    let observationsAfterPrivateRun = try await repository.correctionObservations(
      profileID: profile.id
    )

    XCTAssertEqual(privateResult.transcript.text, "VoiceMD ships")
    XCTAssertEqual(auditsAfterPrivateRun, auditsAfterRecording)
    XCTAssertEqual(observationsAfterPrivateRun, observationsAfterRecording)
  }

  private func id(_ suffix: Int) -> UUID {
    UUID(
      uuidString: String(
        format: "00000000-0000-0000-0000-%012d",
        suffix
      )
    )!
  }
}
