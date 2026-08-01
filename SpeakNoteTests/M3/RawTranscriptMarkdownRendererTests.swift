import Foundation
import XCTest
@testable import SpeakNote

final class RawTranscriptMarkdownRendererTests: XCTestCase {
  func testRendersDeterministicEscapedTimestampedMarkdown() {
    let sessionID = UUID(
      uuidString: "00000000-0000-0000-0000-000000000701"
    )!
    let session = RecordingSessionDTO(
      id: sessionID,
      title: "# Review [draft]\nline",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
      source: .imported,
      status: .completed,
      duration: 3_661.004,
      currentJobID: nil,
      needsRepair: false
    )
    let transcript = Transcript(
      text: "ignored aggregate",
      segments: [
        TranscriptSegment(
          startTime: 0,
          endTime: 62.345,
          text: "*raw* [link](url)\n- next"
        ),
        TranscriptSegment(
          startTime: 3_600.5,
          endTime: 3_661.004,
          text: "Use <tag> | done!"
        ),
      ]
    )
    let renderer = RawTranscriptMarkdownRenderer()
    let expected = """
      # \\# Review \\[draft\\] line

      - Session: `00000000-0000-0000-0000-000000000701`
      - Source: `imported`
      - Duration: `01:01:01.004`
      - Created: `2023-11-14T22:13:20.000Z`

      ## Raw transcript

      ### [00:00:00.000 → 00:01:02.345]

      \\*raw\\* \\[link\\](url)\u{20}\u{20}
      \\- next

      ### [01:00:00.500 → 01:01:01.004]

      Use \\<tag\\> \\| done\\!

      """

    XCTAssertEqual(renderer.render(session: session, transcript: transcript), expected)
    XCTAssertEqual(renderer.render(session: session, transcript: transcript), expected)
  }

  func testUsesAggregateTextWhenSegmentsAreUnavailable() {
    let session = makeSession(duration: 10)
    let transcript = Transcript(text: "# first\r\nsecond *raw*")

    let markdown = RawTranscriptMarkdownRenderer().render(
      session: session,
      transcript: transcript
    )

    XCTAssertTrue(markdown.hasSuffix("\\# first  \nsecond \\*raw\\*\n"))
    XCTAssertFalse(markdown.contains("### ["))
  }

  func testInvalidTimesRenderAsStableZeroTimestamp() {
    let session = makeSession(duration: -.infinity)
    let transcript = Transcript(
      text: "raw",
      segments: [
        TranscriptSegment(
          startTime: .nan,
          endTime: -.infinity,
          text: "raw"
        )
      ]
    )

    let markdown = RawTranscriptMarkdownRenderer().render(
      session: session,
      transcript: transcript
    )

    XCTAssertTrue(markdown.contains("- Duration: `00:00:00.000`"))
    XCTAssertTrue(markdown.contains("### [00:00:00.000 → 00:00:00.000]"))
  }

  private func makeSession(duration: TimeInterval) -> RecordingSessionDTO {
    RecordingSessionDTO(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000702")!,
      title: "Title",
      createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 0),
      source: .recorded,
      status: .completed,
      duration: duration,
      currentJobID: nil,
      needsRepair: false
    )
  }
}
