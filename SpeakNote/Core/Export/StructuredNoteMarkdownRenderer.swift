import Foundation

struct StructuredNoteMarkdownRenderer: Sendable {
  func render(_ document: ProcessedDocument) -> String {
    var lines = [
      "# \(Self.escapeLine(Self.singleLine(document.title)))",
      "",
    ]
    switch document.noteType {
    case .classNotes:
      renderLecture(document, into: &lines)
    case .meetingMinutes:
      renderMeeting(document, into: &lines)
    case .generalNotes:
      renderGeneral(document, into: &lines)
    }
    return lines.joined(separator: "\n")
  }

  private func renderLecture(
    _ document: ProcessedDocument,
    into lines: inout [String]
  ) {
    appendSummary("本堂課摘要", document: document, to: &lines)
    appendItems(
      "核心概念",
      document.lecture?.coreConcepts ?? [],
      to: &lines
    )
    appendDefinitions(
      "名詞與定義",
      document.lecture?.definitions ?? [],
      to: &lines
    )
    appendItems(
      "老師提供的案例",
      document.lecture?.examples ?? [],
      to: &lines
    )
    appendItems(
      "重要論點",
      document.lecture?.importantArguments ?? [],
      to: &lines
    )
    appendItems(
      "複習問題",
      document.lecture?.reviewQuestions ?? [],
      to: &lines
    )
    appendItems("重點", document.keyPoints, to: &lines)
    appendActions(document.actions, to: &lines)
    appendItems("需要進一步確認的內容", document.openQuestions, to: &lines)
    appendSections("完整整理筆記", document.sections, to: &lines)
  }

  private func renderMeeting(
    _ document: ProcessedDocument,
    into lines: inout [String]
  ) {
    appendSummary("會議摘要", document: document, to: &lines)
    appendItems(
      "已確認的決策",
      document.meeting?.decisions ?? [],
      to: &lines
    )
    appendItems("重點", document.keyPoints, to: &lines)
    appendActions(document.actions, to: &lines)
    appendItems("尚未解決的問題", document.openQuestions, to: &lines)
    appendSections(
      "討論內容",
      (document.meeting?.discussion ?? []) + document.sections,
      to: &lines
    )
  }

  private func renderGeneral(
    _ document: ProcessedDocument,
    into lines: inout [String]
  ) {
    appendSummary("摘要", document: document, to: &lines)
    appendItems("主要想法", document.keyPoints, to: &lines)
    appendActions(document.actions, to: &lines)
    appendItems("延伸問題", document.openQuestions, to: &lines)
    appendSections("完整內容", document.sections, to: &lines)
  }

  private func appendSummary(
    _ heading: String,
    document: ProcessedDocument,
    to lines: inout [String]
  ) {
    lines.append("## \(heading)")
    lines.append("")
    lines.append(Self.escapeBlock(document.summary))
    lines.append("")
    if !document.sourceRanges.isEmpty {
      lines.append("來源：\(Self.sourceSuffix(document.sourceRanges))")
      lines.append("")
    }
  }

  private func appendItems(
    _ heading: String,
    _ items: [StructuredNoteItem],
    to lines: inout [String]
  ) {
    lines.append("## \(heading)")
    lines.append("")
    for item in items {
      lines.append(
        "- \(Self.escapeLine(Self.singleLine(item.text)))"
          + Self.suffixedRanges(item.sourceRanges)
      )
    }
    if !items.isEmpty {
      lines.append("")
    }
  }

  private func appendActions(
    _ actions: [StructuredActionItem],
    to lines: inout [String]
  ) {
    lines.append("## 待辦事項")
    lines.append("")
    for action in actions {
      var details: [String] = []
      if let owner = action.owner {
        details.append("負責人：\(Self.escapeLine(Self.singleLine(owner)))")
      }
      if let dueDate = action.dueDate {
        details.append("期限：\(Self.escapeLine(Self.singleLine(dueDate)))")
      }
      let detail = details.isEmpty ? "" : "（\(details.joined(separator: "；"))）"
      lines.append(
        "- [ ] \(Self.escapeLine(Self.singleLine(action.task)))\(detail)"
          + Self.suffixedRanges(action.sourceRanges)
      )
    }
    if !actions.isEmpty {
      lines.append("")
    }
  }

  private func appendDefinitions(
    _ heading: String,
    _ definitions: [StructuredDefinition],
    to lines: inout [String]
  ) {
    lines.append("## \(heading)")
    lines.append("")
    for definition in definitions {
      lines.append(
        "- **\(Self.escapeLine(Self.singleLine(definition.term)))**："
          + "\(Self.escapeLine(Self.singleLine(definition.definition)))"
          + Self.suffixedRanges(definition.sourceRanges)
      )
    }
    if !definitions.isEmpty {
      lines.append("")
    }
  }

  private func appendSections(
    _ heading: String,
    _ sections: [StructuredNoteSection],
    to lines: inout [String]
  ) {
    lines.append("## \(heading)")
    lines.append("")
    for section in sections {
      lines.append("### \(Self.escapeLine(Self.singleLine(section.title)))")
      lines.append("")
      lines.append(Self.escapeBlock(section.content))
      lines.append("")
      lines.append("來源：\(Self.sourceSuffix(section.sourceRanges))")
      lines.append("")
    }
  }

  private static func suffixedRanges(
    _ ranges: [StructuredSourceRange]
  ) -> String {
    ranges.isEmpty ? "" : " - \(sourceSuffix(ranges))"
  }

  private static func sourceSuffix(
    _ ranges: [StructuredSourceRange]
  ) -> String {
    ranges.sorted {
      ($0.startTime, $0.endTime) < ($1.startTime, $1.endTime)
    }.map {
      sourceLink($0)
    }.joined(separator: ", ")
  }

  // Session previews resolve this context-local fragment against the current
  // transcript: #t=<startMilliseconds>-<endMilliseconds>.
  private static func sourceLink(_ range: StructuredSourceRange) -> String {
    let start = milliseconds(range.startTime)
    let end = milliseconds(range.endTime)
    return "[\(timestamp(start))..\(timestamp(end))](#t=\(start)-\(end))"
  }

  private static func timestamp(_ milliseconds: Int64) -> String {
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

  private static func milliseconds(_ seconds: TimeInterval) -> Int64 {
    guard seconds.isFinite,
      seconds >= 0,
      seconds <= Double(Int64.max) / 1_000
    else {
      return 0
    }
    return Int64((seconds * 1_000).rounded())
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
