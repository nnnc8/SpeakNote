import XCTest

@testable import SpeakNote

final class PromptBuilderTests: XCTestCase {
  func testBuildsDeterministicCleanTranslationPrompt() {
    let prompt = PromptBuilder.build(
      transcript: Transcript(text: "  raw words  "),
      configuration: TextProcessingConfiguration(
        compressionLevel: .clean,
        recognitionLanguageCode: "en_US",
        outputLanguageCode: "zh_TW",
        instruction: "Use Taiwan terminology."
      )
    )

    XCTAssertEqual(
      prompt.system,
      """
      You transform a speech transcript into final text.
      Preserve every fact, name, number, decision, and action. Never invent content.
      Output only the final text, with no preface or commentary.
      Mode: clean — remove filler and accidental repetition; preserve meaning and order.
      Recognition language: en-US.
      Output language: zh-TW.
      Additional instruction: Use Taiwan terminology.
      """
    )
    XCTAssertEqual(prompt.user, "  raw words  ")
  }

  func testEveryCompressionLevelHasAStableContract() {
    let expected = [
      CompressionLevel.verbatim:
        "Mode: verbatim — keep wording and order; translate only when the output language differs.",
      .clean:
        "Mode: clean — remove filler and accidental repetition; preserve meaning and order.",
      .polished:
        "Mode: polished — improve clarity and grammar; preserve all facts and intent.",
      .concise:
        "Mode: concise — shorten aggressively while preserving facts, decisions, and actions.",
    ]

    for level in CompressionLevel.allCases {
      let prompt = PromptBuilder.build(
        transcript: Transcript(text: "fixture"),
        configuration: TextProcessingConfiguration(compressionLevel: level)
      )
      XCTAssertTrue(prompt.system.contains(expected[level]!))
    }
  }
}
