import Foundation
import XCTest

@testable import SpeakNote

@MainActor
final class ProviderContractsTests: XCTestCase {
  func testProviderIdentifiersKeepCloudAndAppleSpeechDistinct() {
    XCTAssertEqual(ProviderID.groq.rawValue, "groq")
    XCTAssertEqual(ProviderID.appleSpeech.rawValue, "apple-speech")
    XCTAssertNotEqual(ProviderID.groq, .appleSpeech)
  }

  func testFakeTranscriptionEngineReturnsSendableTranscript() async throws {
    let expected = Transcript(
      text: "hello",
      segments: [
        TranscriptSegment(
          startTime: 0,
          endTime: 0.5,
          text: "hello",
          detectedLanguage: "en"
        )
      ],
      detectedLanguage: "en"
    )
    let engine = FakeTranscriptionEngine(transcript: expected)

    let result = try await engine.transcribe(
      audioURL: URL(fileURLWithPath: "/tmp/fixture.m4a"),
      configuration: TranscriptionConfiguration()
    )

    XCTAssertEqual(result, expected)
  }
}
