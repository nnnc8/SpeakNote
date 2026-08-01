import Foundation
import XCTest

@testable import SpeakNote

@MainActor
final class M5StructuredNoteProcessorTests: XCTestCase {
  func testRepairsMalformedAndLocallyInvalidJSONOnceInGroupOrder() async throws {
    let transcript = makeTranscript(groupCount: 2)
    let engine = M5MockStructuredNoteEngine(
      generated: [
        0: .data(Data("{".utf8)),
        1: .data(
          try encodedPartial(
            index: 1,
            noteType: .classNotes,
            start: 10,
            end: 14,
            title: "Wrong type",
            summary: "Wrong type"
          )
        ),
      ],
      repaired: [
        0: .data(
          try encodedPartial(
            index: 0,
            start: 0,
            end: 4,
            title: "Title",
            summary: "First"
          )
        ),
        1: .data(
          try encodedPartial(
            index: 1,
            start: 10,
            end: 14,
            title: nil,
            summary: "Second"
          )
        ),
      ]
    )

    let result = try await makeProcessor(engine: engine).process(
      transcript: transcript,
      noteType: .generalNotes
    )

    XCTAssertEqual(result.document.title, "Title")
    XCTAssertEqual(result.document.summary, "First\n\nSecond")
    XCTAssertTrue(result.failures.isEmpty)
    let generatedGroupIndices = await engine.generatedGroupIndices
    let repairedGroupIndices = await engine.repairedGroupIndices
    XCTAssertEqual(generatedGroupIndices, [0, 1])
    XCTAssertEqual(repairedGroupIndices, [0, 1])
  }

  func testPartialProviderAndRepairFailuresPreserveSuccessfulGroups() async throws {
    let transcript = makeTranscript(groupCount: 3)
    let engine = M5MockStructuredNoteEngine(
      generated: [
        0: .data(
          try encodedPartial(
            index: 0,
            start: 0,
            end: 4,
            title: "Kept",
            summary: "Kept summary"
          )
        ),
        1: .providerFailure,
        2: .data(Data("not json".utf8)),
      ],
      repaired: [2: .data(Data("still not json".utf8))]
    )

    let result = try await makeProcessor(engine: engine).process(
      transcript: transcript,
      noteType: .generalNotes
    )

    XCTAssertEqual(result.document.title, "Kept")
    XCTAssertEqual(result.failedGroupIndices, [1, 2])
    XCTAssertEqual(
      result.failures,
      [
        StructuredNotePartialFailure(groupIndex: 1, error: .providerFailure),
        StructuredNotePartialFailure(groupIndex: 2, error: .invalidJSON),
      ]
    )
    let generatedGroupIndices = await engine.generatedGroupIndices
    let repairedGroupIndices = await engine.repairedGroupIndices
    XCTAssertEqual(generatedGroupIndices, [0, 1, 2])
    XCTAssertEqual(repairedGroupIndices, [2])
  }

  func testAllFailedGroupsReturnDeterministicError() async throws {
    let transcript = makeTranscript(groupCount: 2)
    let engine = M5MockStructuredNoteEngine(
      generated: [
        0: .providerFailure,
        1: .data(Data("{".utf8)),
      ],
      repaired: [1: .data(Data("[".utf8))]
    )

    do {
      _ = try await makeProcessor(engine: engine).process(
        transcript: transcript,
        noteType: .generalNotes
      )
      XCTFail("Expected all groups to fail.")
    } catch {
      XCTAssertEqual(
        error as? StructuredNoteValidationError,
        .noUsablePartials(failedGroups: [0, 1])
      )
    }
    let generatedGroupIndices = await engine.generatedGroupIndices
    let repairedGroupIndices = await engine.repairedGroupIndices
    XCTAssertEqual(generatedGroupIndices, [0, 1])
    XCTAssertEqual(repairedGroupIndices, [1])
  }

  func testCancellationDuringRepairStopsLaterGroups() async throws {
    let transcript = makeTranscript(groupCount: 2)
    let engine = M5MockStructuredNoteEngine(
      generated: [
        0: .data(Data("{".utf8)),
        1: .data(
          try encodedPartial(
            index: 1,
            start: 10,
            end: 14,
            title: "Must not run",
            summary: "Must not run"
          )
        ),
      ],
      repaired: [0: .cancellation]
    )

    do {
      _ = try await makeProcessor(engine: engine).process(
        transcript: transcript,
        noteType: .generalNotes
      )
      XCTFail("Expected cancellation.")
    } catch is CancellationError {
      // Expected control flow.
    }
    let generatedGroupIndices = await engine.generatedGroupIndices
    let repairedGroupIndices = await engine.repairedGroupIndices
    XCTAssertEqual(generatedGroupIndices, [0])
    XCTAssertEqual(repairedGroupIndices, [0])
    XCTAssertEqual(transcript.text, "raw transcript")
  }

  func testAggregateTranscriptUsesSuppliedSessionDurationForSourceRanges()
    async throws
  {
    let engine = M5MockStructuredNoteEngine(
      generated: [
        0: .data(
          try encodedPartial(
            index: 0,
            start: 0,
            end: 42,
            title: "Timed aggregate",
            summary: "Summary"
          )
        )
      ]
    )
    let processor = M5StructuredNoteProcessor(
      engine: engine,
      grouper: StructuredTranscriptGrouper(
        configuration: StructuredTranscriptGroupingConfiguration(
          maximumDuration: 60,
          maximumCharacters: 1_000,
          maximumEstimatedTokens: 1_000
        )
      )
    )

    let result = try await processor.process(
      transcript: Transcript(text: "aggregate without segments"),
      noteType: .generalNotes,
      sourceDuration: 42
    )

    XCTAssertEqual(
      result.document.sourceRanges,
      [StructuredSourceRange(startTime: 0, endTime: 42)]
    )
  }

  func testUnsplittableInputFailsBeforeAnyProviderRequest() async throws {
    let transcript = Transcript(text: "x")
    let engine = M5MockStructuredNoteEngine(generated: [:])
    let processor = M5StructuredNoteProcessor(
      engine: engine,
      grouper: StructuredTranscriptGrouper(
        configuration: StructuredTranscriptGroupingConfiguration(
          maximumDuration: 1,
          maximumCharacters: 1,
          maximumEstimatedTokens: 1
        )
      )
    )

    do {
      _ = try await processor.process(
        transcript: transcript,
        noteType: .generalNotes,
        sourceDuration: 10
      )
      XCTFail("An unsplittable group must fail locally.")
    } catch {
      XCTAssertEqual(
        error as? StructuredTranscriptGroupingError,
        .oversizedSegment(id: transcript.id)
      )
    }
    let generatedGroupIndices = await engine.generatedGroupIndices
    XCTAssertTrue(generatedGroupIndices.isEmpty)
  }

  private func makeProcessor(
    engine: any M5StructuredNoteEngine
  ) -> M5StructuredNoteProcessor {
    M5StructuredNoteProcessor(
      engine: engine,
      grouper: StructuredTranscriptGrouper(
        configuration: StructuredTranscriptGroupingConfiguration(
          maximumDuration: 5,
          maximumCharacters: 1_000,
          maximumEstimatedTokens: 1_000
        )
      )
    )
  }

  private func makeTranscript(groupCount: Int) -> Transcript {
    Transcript(
      text: "raw transcript",
      segments: (0..<groupCount).map { index in
        TranscriptSegment(
          id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
          startTime: TimeInterval(index * 10),
          endTime: TimeInterval(index * 10 + 4),
          text: "segment \(index)"
        )
      }
    )
  }

  private func encodedPartial(
    index: Int,
    noteType: NoteType = .generalNotes,
    start: TimeInterval,
    end: TimeInterval,
    title: String?,
    summary: String?
  ) throws -> Data {
    try JSONEncoder().encode(
      StructuredNotePartial(
        groupIndex: index,
        noteType: noteType,
        title: title,
        summary: summary,
        sourceRanges: [
          StructuredSourceRange(startTime: start, endTime: end)
        ],
        lecture: noteType == .classNotes ? LectureNoteFields() : nil,
        meeting: noteType == .meetingMinutes ? MeetingNoteFields() : nil
      )
    )
  }
}

private enum M5MockStructuredStep: Sendable {
  case data(Data)
  case providerFailure
  case cancellation
}

private enum M5MockStructuredProviderError: Error, Sendable {
  case failed
}

private actor M5MockStructuredNoteEngine: M5StructuredNoteEngine {
  private let generated: [Int: M5MockStructuredStep]
  private let repaired: [Int: M5MockStructuredStep]
  private(set) var generatedGroupIndices: [Int] = []
  private(set) var repairedGroupIndices: [Int] = []

  init(
    generated: [Int: M5MockStructuredStep],
    repaired: [Int: M5MockStructuredStep] = [:]
  ) {
    self.generated = generated
    self.repaired = repaired
  }

  func generatePartial(
    for request: M5StructuredGroupRequest
  ) async throws -> Data {
    generatedGroupIndices.append(request.group.index)
    return try resolve(generated[request.group.index])
  }

  func repairPartial(
    _ invalidJSON: Data,
    for request: M5StructuredGroupRequest
  ) async throws -> Data {
    repairedGroupIndices.append(request.group.index)
    return try resolve(repaired[request.group.index])
  }

  private func resolve(_ step: M5MockStructuredStep?) throws -> Data {
    switch step {
    case .data(let data):
      data
    case .cancellation:
      throw CancellationError()
    case .providerFailure, nil:
      throw M5MockStructuredProviderError.failed
    }
  }
}
