import XCTest

@testable import SpeakNote

final class StructuredTranscriptGrouperTests: XCTestCase {
  func testGroupsDeterministicallyByTimeAndCharacterBudget() throws {
    let segments = [
      segment(id: 3, start: 4, end: 7, text: "cccc"),
      segment(id: 1, start: 0, end: 3, text: "aaaa"),
      segment(id: 2, start: 3, end: 4, text: "bbbb"),
    ]
    let grouper = StructuredTranscriptGrouper(
      configuration: StructuredTranscriptGroupingConfiguration(
        maximumDuration: 5,
        maximumCharacters: 9,
        maximumEstimatedTokens: 100
      )
    )
    let transcript = Transcript(text: "aggregate", segments: segments)

    let first = try grouper.groups(for: transcript)
    let second = try grouper.groups(for: transcript)

    XCTAssertEqual(first, second)
    XCTAssertEqual(first.map(\.index), [0, 1])
    XCTAssertEqual(first[0].text, "aaaa\nbbbb")
    XCTAssertEqual(
      first[0].sourceRange,
      StructuredSourceRange(startTime: 0, endTime: 4)
    )
    XCTAssertEqual(first[1].text, "cccc")
    XCTAssertEqual(
      first[1].sourceRange,
      StructuredSourceRange(startTime: 4, endTime: 7)
    )
    XCTAssertTrue(first.allSatisfy { !$0.isOversized })
  }

  func testTokenBudgetUsesConservativeUTF8Estimate() throws {
    let transcript = Transcript(
      text: "中文 a",
      segments: [
        segment(id: 1, start: 0, end: 1, text: "中文"),
        segment(id: 2, start: 1, end: 2, text: "a"),
      ]
    )
    let groups = try StructuredTranscriptGrouper(
      configuration: StructuredTranscriptGroupingConfiguration(
        maximumDuration: 10,
        maximumCharacters: 100,
        maximumEstimatedTokens: 2
      )
    ).groups(for: transcript)

    XCTAssertEqual(groups.map(\.text), ["中文", "a"])
    XCTAssertEqual(groups.map(\.estimatedTokenCount), [2, 1])
  }

  func testTimeLimitSplitsEvenWhenTextFitsBudgets() throws {
    let transcript = Transcript(
      text: "one two",
      segments: [
        segment(id: 1, start: 0, end: 2, text: "one"),
        segment(id: 2, start: 4, end: 7, text: "two"),
      ]
    )
    let groups = try StructuredTranscriptGrouper(
      configuration: StructuredTranscriptGroupingConfiguration(
        maximumDuration: 5,
        maximumCharacters: 100,
        maximumEstimatedTokens: 100
      )
    ).groups(for: transcript)

    XCTAssertEqual(groups.map(\.text), ["one", "two"])
  }

  func testOversizeSingleSegmentIsDeterministicallySplitWithinEveryBudget() throws {
    let oversized = segment(
      id: 1,
      start: 0,
      end: 20,
      text: "0123456789"
    )
    let groups = try StructuredTranscriptGrouper(
      configuration: StructuredTranscriptGroupingConfiguration(
        maximumDuration: 5,
        maximumCharacters: 5,
        maximumEstimatedTokens: 2
      )
    ).groups(
      for: Transcript(text: oversized.text, segments: [oversized])
    )

    XCTAssertEqual(groups.map(\.text), ["012", "345", "678", "9"])
    XCTAssertEqual(
      groups.map(\.sourceRange),
      [
        StructuredSourceRange(startTime: 0, endTime: 5),
        StructuredSourceRange(startTime: 5, endTime: 10),
        StructuredSourceRange(startTime: 10, endTime: 15),
        StructuredSourceRange(startTime: 15, endTime: 20),
      ]
    )
    XCTAssertTrue(groups.allSatisfy { !$0.isOversized })
    XCTAssertTrue(groups.allSatisfy { $0.characterCount <= 5 })
    XCTAssertTrue(groups.allSatisfy { $0.estimatedTokenCount <= 2 })
  }

  func testUnsplittableTimedSegmentFailsLocally() {
    let oversized = segment(id: 7, start: 0, end: 20, text: "x")

    XCTAssertThrowsError(
      try StructuredTranscriptGrouper(
        configuration: StructuredTranscriptGroupingConfiguration(
          maximumDuration: 5,
          maximumCharacters: 5,
          maximumEstimatedTokens: 2
        )
      ).groups(for: Transcript(text: oversized.text, segments: [oversized]))
    ) { error in
      XCTAssertEqual(
        error as? StructuredTranscriptGroupingError,
        .oversizedSegment(id: oversized.id)
      )
    }
  }

  func testAggregateOnlyTranscriptEmitsTimedOrUntimedGroup() throws {
    let transcript = Transcript(text: "aggregate only")
    let grouper = StructuredTranscriptGrouper()

    let timed = try grouper.groups(for: transcript, sourceDuration: 42.125)
    let untimed = try grouper.groups(for: transcript)

    XCTAssertEqual(timed.count, 1)
    XCTAssertEqual(timed[0].index, 0)
    XCTAssertEqual(timed[0].segments, [])
    XCTAssertEqual(timed[0].text, transcript.text)
    XCTAssertEqual(timed[0].characterCount, transcript.text.count)
    XCTAssertEqual(
      timed[0].sourceRange,
      StructuredSourceRange(startTime: 0, endTime: 42.125)
    )
    XCTAssertFalse(timed[0].isOversized)
    XCTAssertEqual(
      untimed[0].sourceRange,
      StructuredSourceRange(startTime: 0, endTime: 0)
    )
  }

  func testAggregateOnlyTranscriptRejectsInvalidDuration() {
    XCTAssertThrowsError(
      try StructuredTranscriptGrouper().groups(
        for: Transcript(text: "aggregate"),
        sourceDuration: -.infinity
      )
    ) { error in
      XCTAssertEqual(
        error as? StructuredTranscriptGroupingError,
        .invalidSourceDuration
      )
    }
  }

  func testInvalidSegmentFailsWithTypedError() {
    let invalid = segment(id: 9, start: 2, end: 1, text: "bad")

    XCTAssertThrowsError(
      try StructuredTranscriptGrouper().groups(
        for: Transcript(text: "bad", segments: [invalid])
      )
    ) { error in
      XCTAssertEqual(
        error as? StructuredTranscriptGroupingError,
        .invalidSegment(id: invalid.id)
      )
    }
  }

  private func segment(
    id: Int,
    start: TimeInterval,
    end: TimeInterval,
    text: String
  ) -> TranscriptSegment {
    TranscriptSegment(
      id: UUID(
        uuidString: String(
          format: "00000000-0000-0000-0000-%012d",
          id
        )
      )!,
      startTime: start,
      endTime: end,
      text: text
    )
  }
}
