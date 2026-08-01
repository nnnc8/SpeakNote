import Foundation

struct ReplacementRuleEngine: Sendable {
  static let conflictPolicy = ReplacementConflictPolicy.highestPriorityThenLongestMatch

  /// The caller persists the raw transcript before invoking this transformation.
  func apply(
    toStoredRawTranscript text: String,
    profileID: UUID,
    rules: [ReplacementRule]
  ) -> ReplacementResult {
    let candidates =
      rules
      .filter { $0.profileID == profileID && $0.isEnabled && !$0.match.isEmpty }
      .flatMap { matches(for: $0, in: text) }
      .sorted(by: outranks)

    var selected: [Candidate] = []
    for candidate in candidates where !selected.contains(where: { $0.overlaps(candidate) }) {
      selected.append(candidate)
    }
    selected.sort { lhs, rhs in
      if lhs.sourceRange.location != rhs.sourceRange.location {
        return lhs.sourceRange.location < rhs.sourceRange.location
      }
      return lhs.rule.id.uuidString < rhs.rule.id.uuidString
    }

    var output = ""
    var cursor = text.startIndex
    var auditTrail: [ReplacementAudit] = []

    for candidate in selected {
      output.append(contentsOf: text[cursor..<candidate.range.lowerBound])
      let outputLocation = output.utf16.count
      output.append(candidate.rule.replacement)
      auditTrail.append(
        ReplacementAudit(
          ruleID: candidate.rule.id,
          sourceRange: candidate.sourceRange,
          outputRange: UTF16TextRange(
            location: outputLocation,
            length: candidate.rule.replacement.utf16.count
          ),
          matchedText: String(text[candidate.range]),
          replacementText: candidate.rule.replacement,
          rulePriority: candidate.rule.priority
        )
      )
      cursor = candidate.range.upperBound
    }
    output.append(contentsOf: text[cursor...])

    return ReplacementResult(
      text: output,
      auditTrail: auditTrail,
      conflictPolicy: Self.conflictPolicy
    )
  }

  private func matches(for rule: ReplacementRule, in text: String) -> [Candidate] {
    guard !text.isEmpty else { return [] }

    let options: String.CompareOptions = rule.isCaseSensitive ? [] : [.caseInsensitive]
    let locale = Locale(identifier: "en_US_POSIX")
    var candidates: [Candidate] = []
    var searchStart = text.startIndex

    while searchStart < text.endIndex,
      let range = text.range(
        of: rule.match,
        options: options,
        range: searchStart..<text.endIndex,
        locale: locale
      )
    {
      if !rule.requiresWordBoundaries || hasWordBoundaries(range, in: text) {
        let sourceRange = NSRange(range, in: text)
        candidates.append(
          Candidate(
            rule: rule,
            range: range,
            sourceRange: UTF16TextRange(
              location: sourceRange.location,
              length: sourceRange.length
            )
          )
        )
      }
      searchStart = range.upperBound
    }

    return candidates
  }

  private func hasWordBoundaries(_ range: Range<String.Index>, in text: String) -> Bool {
    let precedingScalar = text[..<range.lowerBound].unicodeScalars.last
    let followingScalar = text[range.upperBound...].unicodeScalars.first
    let hasLeadingBoundary = precedingScalar.map { !isWordScalar($0) } ?? true
    let hasTrailingBoundary = followingScalar.map { !isWordScalar($0) } ?? true
    return hasLeadingBoundary && hasTrailingBoundary
  }

  private func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter,
      .lowercaseLetter,
      .titlecaseLetter,
      .modifierLetter,
      .otherLetter,
      .nonspacingMark,
      .spacingMark,
      .enclosingMark,
      .decimalNumber,
      .letterNumber,
      .otherNumber,
      .connectorPunctuation:
      true
    default:
      false
    }
  }

  private func outranks(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
    if lhs.rule.priority != rhs.rule.priority {
      return lhs.rule.priority > rhs.rule.priority
    }
    if lhs.sourceRange.length != rhs.sourceRange.length {
      return lhs.sourceRange.length > rhs.sourceRange.length
    }
    if lhs.sourceRange.location != rhs.sourceRange.location {
      return lhs.sourceRange.location < rhs.sourceRange.location
    }
    return lhs.rule.id.uuidString < rhs.rule.id.uuidString
  }

  private struct Candidate {
    let rule: ReplacementRule
    let range: Range<String.Index>
    let sourceRange: UTF16TextRange

    func overlaps(_ other: Candidate) -> Bool {
      sourceRange.location < other.sourceRange.location + other.sourceRange.length
        && other.sourceRange.location < sourceRange.location + sourceRange.length
    }
  }
}
