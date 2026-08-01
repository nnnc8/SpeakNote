import XCTest

@testable import SpeakNote

@MainActor
final class TextProcessingTests: XCTestCase {
  func testVerbatimSameLanguageUsesLocalPassthrough() async throws {
    let engine = RecordingTextProcessingEngine()
    let service = TextProcessingService(engine: engine)
    let transcript = Transcript(text: "keep  spacing")

    let result = try await service.process(
      transcript: transcript,
      configuration: TextProcessingConfiguration(
        compressionLevel: .verbatim,
        recognitionLanguageCode: "en_US",
        outputLanguageCode: "EN-us"
      )
    )

    XCTAssertEqual(result, ProcessedText(text: "keep  spacing"))
    let requestCount = await engine.requestCount
    XCTAssertEqual(requestCount, 0)
  }

  func testTranslationAndNonVerbatimLevelsUseEngine() async throws {
    let engine = RecordingTextProcessingEngine(
      result: ProcessedText(text: "processed")
    )
    let service = TextProcessingService(engine: engine)
    let transcript = Transcript(text: "hello")

    let translated = try await service.process(
      transcript: transcript,
      configuration: TextProcessingConfiguration(
        compressionLevel: .verbatim,
        recognitionLanguageCode: "en",
        outputLanguageCode: "zh-TW"
      )
    )
    let cleaned = try await service.process(
      transcript: transcript,
      configuration: TextProcessingConfiguration(
        compressionLevel: .clean,
        recognitionLanguageCode: "zh-TW",
        outputLanguageCode: "zh-TW"
      )
    )

    XCTAssertEqual(translated.text, "processed")
    XCTAssertEqual(cleaned.text, "processed")
    let requestCount = await engine.requestCount
    XCTAssertEqual(requestCount, 2)
  }

  func testUnknownRecognitionLanguageRequiresEngineWhenOutputIsSpecified() {
    XCTAssertEqual(
      TextProcessingPolicy.route(
        for: TextProcessingConfiguration(
          compressionLevel: .verbatim,
          recognitionLanguageCode: "auto",
          outputLanguageCode: "zh-TW"
        )
      ),
      .engine
    )
    XCTAssertEqual(
      TextProcessingPolicy.route(
        for: TextProcessingConfiguration(
          compressionLevel: .verbatim,
          recognitionLanguageCode: "auto"
        )
      ),
      .localPassthrough
    )
  }
}

private actor RecordingTextProcessingEngine: TextProcessingEngine {
  let result: ProcessedText
  private(set) var requestCount = 0

  init(result: ProcessedText = ProcessedText(text: "unused")) {
    self.result = result
  }

  func process(
    transcript: Transcript,
    configuration: TextProcessingConfiguration
  ) async throws -> ProcessedText {
    requestCount += 1
    return result
  }
}
