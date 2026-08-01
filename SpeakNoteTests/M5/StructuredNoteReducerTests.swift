import Foundation
import XCTest

@testable import SpeakNote

final class StructuredNoteReducerTests: XCTestCase {
  func testNoteTypeUsesCanonicalValuesAndDecodesLegacyValues() throws {
    let canonical: [(NoteType, String)] = [
      (.classNotes, "classNotes"),
      (.meetingMinutes, "meetingMinutes"),
      (.generalNotes, "generalNotes"),
    ]

    for (noteType, rawValue) in canonical {
      XCTAssertEqual(noteType.rawValue, rawValue)
      XCTAssertEqual(
        String(decoding: try JSONEncoder().encode(noteType), as: UTF8.self),
        "\"\(rawValue)\""
      )
      XCTAssertEqual(
        try JSONDecoder().decode(
          NoteType.self,
          from: Data("\"\(rawValue)\"".utf8)
        ),
        noteType
      )
    }
    let legacy: [(String, NoteType)] = [
      ("lecture", .classNotes),
      ("meeting", .meetingMinutes),
      ("general", .generalNotes),
    ]
    for (rawValue, noteType) in legacy {
      XCTAssertEqual(NoteType(rawValue: rawValue), noteType)
      XCTAssertEqual(
        try JSONDecoder().decode(
          NoteType.self,
          from: Data("\"\(rawValue)\"".utf8)
        ),
        noteType
      )
    }
  }

  func testThreeSchemasRoundTripThroughLocalJSONValidation() throws {
    let validator = StructuredNoteValidator()
    let group = makeGroup(index: 0, start: 0, end: 10)
    let partials = [
      StructuredNotePartial(
        groupIndex: 0,
        noteType: .classNotes,
        title: "Lecture",
        summary: "Summary",
        sourceRanges: [range(0, 10)],
        lecture: LectureNoteFields(
          reviewQuestions: [
            StructuredNoteItem(
              text: "Review?",
              sourceRanges: [range(0, 10)]
            )
          ]
        )
      ),
      StructuredNotePartial(
        groupIndex: 0,
        noteType: .meetingMinutes,
        title: "Meeting",
        summary: "Summary",
        sourceRanges: [range(0, 10)],
        meeting: MeetingNoteFields()
      ),
      StructuredNotePartial(
        groupIndex: 0,
        noteType: .generalNotes,
        title: "General",
        summary: "Summary",
        sourceRanges: [range(0, 10)]
      ),
    ]

    for partial in partials {
      let data = try JSONEncoder().encode(partial)
      let decoded = try validator.decodePartial(
        data,
        expectedNoteType: partial.noteType,
        group: group
      )
      XCTAssertEqual(decoded, partial)
    }
  }

  func testClassSchemaRequiresReviewQuestions() {
    let json = #"""
      {
        "groupIndex": 0,
        "noteType": "classNotes",
        "sections": [],
        "keyPoints": [],
        "actions": [],
        "openQuestions": [],
        "sourceRanges": [{"startTime": 0, "endTime": 10}],
        "lecture": {
          "coreConcepts": [],
          "definitions": [],
          "examples": [],
          "importantArguments": []
        }
      }
      """#

    XCTAssertThrowsError(
      try StructuredNoteValidator().decodePartial(
        Data(json.utf8),
        expectedNoteType: .classNotes,
        group: makeGroup(index: 0, start: 0, end: 10)
      )
    ) { error in
      XCTAssertEqual(error as? StructuredNoteValidationError, .invalidJSON)
    }
  }

  func testInvalidJSONAndSpecializedSchemaReturnTypedErrors() throws {
    let validator = StructuredNoteValidator()
    let group = makeGroup(index: 0, start: 0, end: 10)

    XCTAssertThrowsError(
      try validator.decodePartial(
        Data("{".utf8),
        expectedNoteType: .generalNotes,
        group: group
      )
    ) { error in
      XCTAssertEqual(error as? StructuredNoteValidationError, .invalidJSON)
    }

    let invalid = StructuredNotePartial(
      groupIndex: 0,
      noteType: .generalNotes,
      sourceRanges: [range(0, 10)],
      lecture: LectureNoteFields()
    )
    XCTAssertThrowsError(
      try validator.validate(
        invalid,
        expectedNoteType: .generalNotes,
        expectedGroupIndex: 0,
        allowedSourceRange: range(0, 10)
      )
    ) { error in
      XCTAssertEqual(
        error as? StructuredNoteValidationError,
        .incompatibleSpecializedFields(noteType: .generalNotes)
      )
    }
  }

  func testDuplicateAndOutOfRangeSourcesAreRejected() {
    let validator = StructuredNoteValidator()
    let duplicate = range(1, 2)
    let duplicatePartial = StructuredNotePartial(
      groupIndex: 0,
      noteType: .generalNotes,
      keyPoints: [
        StructuredNoteItem(
          text: "point",
          sourceRanges: [duplicate, duplicate]
        )
      ],
      sourceRanges: [range(0, 10)]
    )

    XCTAssertThrowsError(
      try validator.validate(
        duplicatePartial,
        expectedNoteType: .generalNotes,
        expectedGroupIndex: 0,
        allowedSourceRange: range(0, 10)
      )
    ) { error in
      XCTAssertEqual(
        error as? StructuredNoteValidationError,
        .duplicateSourceRange(
          path: "keyPoints[0].sourceRanges",
          range: duplicate
        )
      )
    }

    let outOfRange = StructuredNotePartial(
      groupIndex: 0,
      noteType: .generalNotes,
      openQuestions: [
        StructuredNoteItem(
          text: "question",
          sourceRanges: [range(9, 11)]
        )
      ],
      sourceRanges: [range(0, 10)]
    )
    XCTAssertThrowsError(
      try validator.validate(
        outOfRange,
        expectedNoteType: .generalNotes,
        expectedGroupIndex: 0,
        allowedSourceRange: range(0, 10)
      )
    ) { error in
      XCTAssertEqual(
        error as? StructuredNoteValidationError,
        .outOfRangeSourceRange(
          path: "openQuestions[0].sourceRanges",
          index: 0,
          allowed: range(0, 10)
        )
      )
    }

    let invalidRange = StructuredNotePartial(
      groupIndex: 0,
      noteType: .generalNotes,
      keyPoints: [
        StructuredNoteItem(
          text: "invalid",
          sourceRanges: [range(3, 2)]
        )
      ],
      sourceRanges: [range(0, 10)]
    )
    XCTAssertThrowsError(
      try validator.validate(
        invalidRange,
        expectedNoteType: .generalNotes,
        expectedGroupIndex: 0,
        allowedSourceRange: range(0, 10)
      )
    ) { error in
      XCTAssertEqual(
        error as? StructuredNoteValidationError,
        .invalidSourceRange(
          path: "keyPoints[0].sourceRanges",
          index: 0
        )
      )
    }
  }

  func testPartialFailureReducesSuccessesAndReportsFailedGroup() throws {
    let raw = Transcript(text: "raw transcript must remain independent")
    let first = StructuredNotePartial(
      groupIndex: 0,
      noteType: .classNotes,
      title: "Course",
      summary: "First summary",
      keyPoints: [
        StructuredNoteItem(text: "Same point", sourceRanges: [range(0, 1)])
      ],
      sourceRanges: [range(0, 4)],
      lecture: LectureNoteFields(
        coreConcepts: [
          StructuredNoteItem(text: "Concept", sourceRanges: [range(0, 2)])
        ],
        reviewQuestions: [
          StructuredNoteItem(text: "Review?", sourceRanges: [range(0, 2)])
        ]
      )
    )
    let last = StructuredNotePartial(
      groupIndex: 2,
      noteType: .classNotes,
      title: "Ignored later title",
      summary: "Last summary",
      keyPoints: [
        StructuredNoteItem(text: " same   point ", sourceRanges: [range(8, 9)])
      ],
      sourceRanges: [range(8, 10)],
      lecture: LectureNoteFields(
        reviewQuestions: [
          StructuredNoteItem(
            text: " review? ",
            sourceRanges: [range(8, 9)]
          )
        ]
      )
    )

    let reduction = try StructuredNoteReducer().reduce(
      noteType: .classNotes,
      results: [
        .success(last),
        .failure(groupIndex: 1, error: .providerFailure),
        .success(first),
      ],
      sourceDuration: 10
    )

    XCTAssertEqual(reduction.failedGroupIndices, [1])
    XCTAssertEqual(
      reduction.failures,
      [StructuredNotePartialFailure(groupIndex: 1, error: .providerFailure)]
    )
    XCTAssertEqual(reduction.document.title, "Course")
    XCTAssertEqual(reduction.document.summary, "First summary\n\nLast summary")
    XCTAssertEqual(reduction.document.keyPoints.count, 1)
    XCTAssertEqual(
      reduction.document.keyPoints[0].sourceRanges,
      [range(0, 1), range(8, 9)]
    )
    XCTAssertEqual(
      reduction.document.lecture?.reviewQuestions,
      [
        StructuredNoteItem(
          text: "Review?",
          sourceRanges: [range(0, 2), range(8, 9)]
        )
      ]
    )
    XCTAssertEqual(raw.text, "raw transcript must remain independent")
  }

  func testDuplicateGroupAndAllFailuresAreDeterministicErrors() {
    let partial = StructuredNotePartial(
      groupIndex: 0,
      noteType: .generalNotes,
      title: "Title",
      summary: "Summary",
      sourceRanges: [range(0, 1)]
    )

    XCTAssertThrowsError(
      try StructuredNoteReducer().reduce(
        noteType: .generalNotes,
        results: [.success(partial), .success(partial)],
        sourceDuration: 1
      )
    ) { error in
      XCTAssertEqual(
        error as? StructuredNoteValidationError,
        .duplicateGroup(index: 0)
      )
    }

    XCTAssertThrowsError(
      try StructuredNoteReducer().reduce(
        noteType: .generalNotes,
        results: [
          .failure(groupIndex: 2, error: .invalidJSON),
          .failure(groupIndex: 0, error: .invalidJSON),
        ],
        sourceDuration: 1
      )
    ) { error in
      XCTAssertEqual(
        error as? StructuredNoteValidationError,
        .noUsablePartials(failedGroups: [0, 2])
      )
    }
  }

  private func makeGroup(
    index: Int,
    start: TimeInterval,
    end: TimeInterval
  ) -> StructuredTranscriptGroup {
    StructuredTranscriptGroup(
      index: index,
      segments: [],
      text: "fixture",
      sourceRange: range(start, end),
      characterCount: 7,
      estimatedTokenCount: 3,
      isOversized: false
    )
  }

  private func range(
    _ start: TimeInterval,
    _ end: TimeInterval
  ) -> StructuredSourceRange {
    StructuredSourceRange(startTime: start, endTime: end)
  }
}
