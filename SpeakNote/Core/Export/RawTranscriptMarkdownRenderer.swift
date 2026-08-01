import Foundation

struct RawTranscriptMarkdownRenderer: RawTranscriptRendering, Sendable {
  func render(session: RecordingSessionDTO, transcript: Transcript) -> String {
    var lines = [
      "# \(Self.escapeLine(Self.singleLine(session.title)))",
      "",
      "- Session: `\(session.id.uuidString)`",
      "- Source: `\(session.source.rawValue)`",
      "- Duration: `\(Self.timestamp(session.duration))`",
      "- Created: `\(Self.iso8601(session.createdAt))`",
      "",
      "## Raw transcript",
      "",
    ]

    if transcript.segments.isEmpty {
      lines.append(Self.escapeBlock(transcript.text))
      lines.append("")
    } else {
      for segment in transcript.segments {
        lines.append(
          "### [\(Self.timestamp(segment.startTime)) → "
            + "\(Self.timestamp(segment.endTime))]"
        )
        lines.append("")
        lines.append(Self.escapeBlock(segment.text))
        lines.append("")
      }
    }

    return lines.joined(separator: "\n")
  }

  private static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }

  private static func timestamp(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite,
      seconds >= 0,
      seconds <= Double(Int64.max) / 1_000
    else {
      return "00:00:00.000"
    }
    let milliseconds = Int64((seconds * 1_000).rounded())
    let hours = milliseconds / 3_600_000
    let minutes = milliseconds / 60_000 % 60
    let wholeSeconds = milliseconds / 1_000 % 60
    let remainder = milliseconds % 1_000
    return String(
      format: "%02lld:%02lld:%02lld.%03lld",
      hours,
      minutes,
      wholeSeconds,
      remainder
    )
  }

  private static func singleLine(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .joined(separator: " ")
  }

  private static func escapeBlock(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { escapeLine(String($0)) }
      .joined(separator: "  \n")
  }

  private static func escapeLine(_ text: String) -> String {
    let inlineEscapable = CharacterSet(charactersIn: "\\`*_[]<>|!")
    var escaped = text.unicodeScalars.reduce(into: "") { result, scalar in
      if inlineEscapable.contains(scalar) {
        result.append("\\")
      }
      result.unicodeScalars.append(scalar)
    }
    if let first = text.first, "#>+-".contains(first) {
      escaped.insert("\\", at: escaped.startIndex)
    }
    return escaped
  }
}
