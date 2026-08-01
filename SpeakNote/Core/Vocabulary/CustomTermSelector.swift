import Foundation

struct CustomTermSelector: Sendable {
  static let defaultTokenBudget = 224

  private static let promptHeader = "Custom vocabulary. Preserve spelling exactly:"

  func select(
    for profile: Profile,
    from terms: [CustomTerm],
    tokenBudget: Int = Self.defaultTokenBudget
  ) -> CustomTermSelection {
    guard profile.vocabularyScope == .profileOnly else {
      return CustomTermSelection(
        terms: [],
        promptFragment: "",
        conservativeTokenCount: 0,
        wasTruncated: false
      )
    }

    let candidates =
      terms
      .filter { $0.profileID == profile.id && $0.isEnabled }
      .compactMap { term -> (term: CustomTerm, line: String)? in
        let value = normalizedWhitespace(term.term)
        guard !value.isEmpty else { return nil }

        let hint = term.pronunciationHint.map(normalizedWhitespace)
        let suffix = hint.flatMap { $0.isEmpty ? nil : " [pronunciation: \($0)]" } ?? ""
        return (term, "- \(value)\(suffix)")
      }
      .sorted { lhs, rhs in
        if lhs.term.priority != rhs.term.priority {
          return lhs.term.priority > rhs.term.priority
        }
        if lhs.line != rhs.line {
          return lhs.line < rhs.line
        }
        return lhs.term.id.uuidString < rhs.term.id.uuidString
      }

    guard tokenBudget > 0 else {
      return CustomTermSelection(
        terms: [],
        promptFragment: "",
        conservativeTokenCount: 0,
        wasTruncated: !candidates.isEmpty
      )
    }

    var selected: [CustomTerm] = []
    var lines: [String] = []
    var wasTruncated = false

    for candidate in candidates {
      let proposedLines = lines + [candidate.line]
      let proposedPrompt = Self.render(lines: proposedLines)
      if Self.conservativeTokenCount(for: proposedPrompt) <= tokenBudget {
        selected.append(candidate.term)
        lines = proposedLines
      } else {
        wasTruncated = true
        break
      }
    }

    let prompt = Self.render(lines: lines)
    return CustomTermSelection(
      terms: selected,
      promptFragment: prompt,
      conservativeTokenCount: Self.conservativeTokenCount(for: prompt),
      wasTruncated: wasTruncated
    )
  }

  static func conservativeTokenCount(for text: String) -> Int {
    text.utf8.count
  }

  private static func render(lines: [String]) -> String {
    guard !lines.isEmpty else { return "" }
    return ([promptHeader] + lines).joined(separator: "\n")
  }

  private func normalizedWhitespace(_ value: String) -> String {
    value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }
}
