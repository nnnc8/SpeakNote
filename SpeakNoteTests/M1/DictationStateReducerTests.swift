import XCTest

@testable import SpeakNote

final class DictationStateReducerTests: XCTestCase {
  func testHappyPathUsesEveryMilestoneOneState() {
    let startedAt = Date(timeIntervalSince1970: 100)
    var state = DictationState.idle

    state = DictationStateReducer.reduce(state, .startRequested)
    XCTAssertEqual(state, .preparing)
    state = DictationStateReducer.reduce(state, .recorderStarted(startedAt))
    XCTAssertEqual(state, .recording(startedAt: startedAt))
    state = DictationStateReducer.reduce(state, .stopRequested)
    XCTAssertEqual(state, .stopping)
    state = DictationStateReducer.reduce(state, .recorderStopped)
    XCTAssertEqual(state, .transcribing)
    state = DictationStateReducer.reduce(state, .transcriptReady("hello"))
    XCTAssertEqual(state, .processing)
    state = DictationStateReducer.reduce(state, .processedTextReady("hello"))
    XCTAssertEqual(state, .inserting)
    state = DictationStateReducer.reduce(state, .insertionCompleted("hello"))
    XCTAssertEqual(state, .success(text: "hello"))
  }

  func testOverlappingStartIsIgnored() {
    let state = DictationStateReducer.reduce(
      .recording(startedAt: Date(timeIntervalSince1970: 100)),
      .startRequested
    )

    XCTAssertEqual(state, .recording(startedAt: Date(timeIntervalSince1970: 100)))
  }

  func testCancellationAndFailureAreExplicit() {
    XCTAssertEqual(
      DictationStateReducer.reduce(.transcribing, .cancellationRequested),
      .cancelling
    )
    XCTAssertEqual(
      DictationStateReducer.reduce(.cancelling, .cancelled),
      .cancelled
    )
    XCTAssertEqual(
      DictationStateReducer.reduce(.inserting, .failed("Paste failed")),
      .failure(message: "Paste failed")
    )
    XCTAssertEqual(
      DictationStateReducer.reduce(.transcribing, .transcriptReady("")),
      .failure(message: String(localized: "Transcription returned no text."))
    )
    XCTAssertEqual(
      DictationStateReducer.reduce(.processing, .processedTextReady("")),
      .failure(message: String(localized: "Text processing returned no text."))
    )
    XCTAssertEqual(
      DictationStateReducer.reduce(.processing, .cancellationRequested),
      .cancelling
    )
  }
}
