import Foundation

struct TextProcessingPrompt: Equatable, Sendable {
  let system: String
  let user: String
}

enum PromptBuilder {
  static func build(
    transcript: Transcript,
    configuration: TextProcessingConfiguration
  ) -> TextProcessingPrompt {
    let recognitionLanguage =
      normalized(configuration.recognitionLanguageCode) ?? "auto"
    let outputLanguage =
      normalized(configuration.outputLanguageCode) ?? "same as recognition language"

    var lines = [
      "You transform a speech transcript into final text.",
      "Preserve every fact, name, number, decision, and action. Never invent content.",
      "Output only the final text, with no preface or commentary.",
      "Mode: \(modeInstruction(configuration.compressionLevel))",
      "Recognition language: \(recognitionLanguage).",
      "Output language: \(outputLanguage).",
    ]
    if let instruction = trimmed(configuration.instruction) {
      lines.append("Additional instruction: \(instruction)")
    }
    return TextProcessingPrompt(
      system: lines.joined(separator: "\n"),
      user: transcript.text
    )
  }

  private static func modeInstruction(_ level: CompressionLevel) -> String {
    switch level {
    case .verbatim:
      "verbatim — keep wording and order; translate only when the output language differs."
    case .clean:
      "clean — remove filler and accidental repetition; preserve meaning and order."
    case .polished:
      "polished — improve clarity and grammar; preserve all facts and intent."
    case .concise:
      "concise — shorten aggressively while preserving facts, decisions, and actions."
    }
  }

  private static func normalized(_ value: String?) -> String? {
    trimmed(value)?.replacingOccurrences(of: "_", with: "-")
  }

  private static func trimmed(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
