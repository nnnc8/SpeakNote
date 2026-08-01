import XCTest

@testable import SpeakNote

final class TranscriptMergerTests: XCTestCase {
  func testMakesTimestampsAbsoluteMonotonicAndClamped() {
    let inputs = [
      chunkTranscript(
        index: 1,
        start: 2,
        end: 6,
        segments: [
          segment(start: -1, end: 1, text: "second"),
          segment(start: 3, end: 8, text: "last"),
        ]
      ),
      chunkTranscript(
        index: 0,
        start: 0,
        end: 4,
        segments: [
          segment(start: 1, end: 2, text: "first")
        ]
      ),
    ]

    let merged = TranscriptMerger().merge(
      inputs,
      sourceDuration: 5,
      transcriptID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    )

    XCTAssertEqual(merged.segments.map(\.text), ["first", "second", "last"])
    XCTAssertTrue(
      zip(merged.segments, merged.segments.dropFirst()).allSatisfy {
        $0.startTime <= $1.startTime && $0.endTime <= $1.endTime
      }
    )
    XCTAssertTrue(
      merged.segments.allSatisfy {
        $0.startTime >= 0 && $0.endTime >= $0.startTime && $0.endTime <= 5
      }
    )
  }

  func testOverlapDropsDuplicatesButKeepsNewPhrase() {
    let inputs = [
      chunkTranscript(
        index: 0,
        start: 0,
        end: 4,
        segments: [
          segment(start: 2.5, end: 3.5, text: "Hello world"),
          segment(start: 3.5, end: 4, text: "unique A"),
        ]
      ),
      chunkTranscript(
        index: 1,
        start: 2,
        end: 6,
        segments: [
          segment(start: 0.5, end: 1.5, text: "hello world"),
          segment(start: 1.5, end: 2.5, text: "unique A and B"),
          segment(start: 2.5, end: 3, text: "outside overlap"),
        ]
      ),
    ]

    let merged = TranscriptMerger().merge(inputs, sourceDuration: 6)

    XCTAssertEqual(
      merged.segments.map(\.text),
      ["Hello world", "unique A", "and B", "outside overlap"]
    )
    XCTAssertEqual(
      merged.text,
      "Hello world unique A and B outside overlap"
    )
  }

  func testTextOnlyChunkIsNotDropped() {
    let transcript = Transcript(text: "text without timestamp segments")
    let input = ChunkTranscript(
      chunk: AudioChunk(
        index: 0,
        url: URL(fileURLWithPath: "/tmp/chunk.wav"),
        startTime: 0,
        endTime: 2,
        byteCount: 1,
        sha256: "fixture"
      ),
      transcript: transcript
    )

    let merged = TranscriptMerger().merge([input], sourceDuration: 2)

    XCTAssertEqual(merged.text, transcript.text)
    XCTAssertEqual(merged.segments.count, 1)
    XCTAssertEqual(merged.segments[0].startTime, 0)
    XCTAssertEqual(merged.segments[0].endTime, 2)
  }

  private func chunkTranscript(
    index: Int,
    start: TimeInterval,
    end: TimeInterval,
    segments: [TranscriptSegment]
  ) -> ChunkTranscript {
    ChunkTranscript(
      chunk: AudioChunk(
        index: index,
        url: URL(fileURLWithPath: "/tmp/chunk-\(index).wav"),
        startTime: start,
        endTime: end,
        byteCount: 1,
        sha256: "fixture-\(index)"
      ),
      transcript: Transcript(
        text: segments.map(\.text).joined(separator: " "),
        segments: segments
      )
    )
  }

  private func segment(
    start: TimeInterval,
    end: TimeInterval,
    text: String
  ) -> TranscriptSegment {
    TranscriptSegment(
      id: UUID(),
      startTime: start,
      endTime: end,
      text: text
    )
  }
}
