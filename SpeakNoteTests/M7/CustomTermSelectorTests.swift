import Foundation
import XCTest

@testable import SpeakNote

final class CustomTermSelectorTests: XCTestCase {
  func testSelectionIsProfileIsolatedEnabledAndPriorityOrdered() {
    let profile = Profile(id: id(1), name: "Work")
    let otherProfile = Profile(id: id(2), name: "Personal")
    let terms = [
      CustomTerm(id: id(11), profileID: profile.id, term: "lower", priority: 1),
      CustomTerm(id: id(12), profileID: profile.id, term: "Zulu", priority: 10),
      CustomTerm(id: id(13), profileID: profile.id, term: "Alpha", priority: 10),
      CustomTerm(
        id: id(14),
        profileID: profile.id,
        term: "disabled",
        priority: 100,
        isEnabled: false
      ),
      CustomTerm(id: id(15), profileID: otherProfile.id, term: "foreign", priority: 200),
      CustomTerm(id: id(16), profileID: profile.id, term: "   ", priority: 300),
    ]

    let selection = CustomTermSelector().select(for: profile, from: terms)

    XCTAssertEqual(selection.terms.map(\.term), ["Alpha", "Zulu", "lower"])
    XCTAssertEqual(
      selection.promptFragment,
      """
      Custom vocabulary. Preserve spelling exactly:
      - Alpha
      - Zulu
      - lower
      """
    )
    XCTAssertFalse(selection.wasTruncated)
    XCTAssertLessThanOrEqual(
      selection.conservativeTokenCount,
      CustomTermSelector.defaultTokenBudget
    )
  }

  func testBudgetKeepsWholeHighPriorityEntriesAndReportsTruncation() {
    let profile = Profile(id: id(1), name: "Work")
    let high = CustomTerm(
      id: id(11),
      profileID: profile.id,
      term: "SpeakNote",
      pronunciationHint: "speak note",
      priority: 100
    )
    let low = CustomTerm(
      id: id(12),
      profileID: profile.id,
      term: "lower priority vocabulary",
      priority: 1
    )
    let selector = CustomTermSelector()
    let exactHighBudget = selector.select(
      for: profile,
      from: [high],
      tokenBudget: 1_000
    ).conservativeTokenCount

    let selection = selector.select(
      for: profile,
      from: [low, high],
      tokenBudget: exactHighBudget
    )

    XCTAssertEqual(selection.terms.map(\.id), [high.id])
    XCTAssertTrue(selection.wasTruncated)
    XCTAssertEqual(selection.conservativeTokenCount, exactHighBudget)
    XCTAssertFalse(selection.promptFragment.contains(low.term))
  }

  func testDefaultBudgetIs224AndNeverPartiallyIncludesAnOversizedTerm() {
    let profile = Profile(id: id(1), name: "Work")
    let oversized = CustomTerm(
      id: id(11),
      profileID: profile.id,
      term: String(repeating: "界", count: 100),
      priority: 100
    )

    let selection = CustomTermSelector().select(for: profile, from: [oversized])

    XCTAssertEqual(CustomTermSelector.defaultTokenBudget, 224)
    XCTAssertEqual(selection.terms, [])
    XCTAssertEqual(selection.promptFragment, "")
    XCTAssertTrue(selection.wasTruncated)
  }

  func testTruncationAndTieBreaksAreIndependentOfInputOrder() {
    let profile = Profile(id: id(1), name: "Work")
    let first = CustomTerm(id: id(11), profileID: profile.id, term: "Alpha", priority: 5)
    let second = CustomTerm(id: id(12), profileID: profile.id, term: "Beta", priority: 5)
    let selector = CustomTermSelector()
    let alphaOnlyBudget = selector.select(
      for: profile,
      from: [first],
      tokenBudget: 1_000
    ).conservativeTokenCount

    let forward = selector.select(
      for: profile,
      from: [first, second],
      tokenBudget: alphaOnlyBudget
    )
    let reverse = selector.select(
      for: profile,
      from: [second, first],
      tokenBudget: alphaOnlyBudget
    )

    XCTAssertEqual(forward, reverse)
    XCTAssertEqual(forward.terms.map(\.term), ["Alpha"])
    XCTAssertTrue(forward.wasTruncated)
  }

  func testDisabledVocabularyScopeProducesNoPrompt() {
    let profile = Profile(
      id: id(1),
      name: "Private",
      vocabularyScope: .disabled
    )
    let term = CustomTerm(id: id(11), profileID: profile.id, term: "Secret", priority: 10)

    let selection = CustomTermSelector().select(for: profile, from: [term])

    XCTAssertEqual(selection.terms, [])
    XCTAssertEqual(selection.promptFragment, "")
    XCTAssertEqual(selection.conservativeTokenCount, 0)
    XCTAssertFalse(selection.wasTruncated)
  }

  func testWhitespaceIsNormalizedBeforeBudgetingAndRendering() {
    let profile = Profile(id: id(1), name: "Work")
    let term = CustomTerm(
      id: id(11),
      profileID: profile.id,
      term: "  Voice\n  Markdown ",
      pronunciationHint: " voice\tmark down "
    )

    let selection = CustomTermSelector().select(for: profile, from: [term])

    XCTAssertTrue(
      selection.promptFragment.contains("- Voice Markdown [pronunciation: voice mark down]")
    )
    XCTAssertEqual(
      selection.conservativeTokenCount,
      selection.promptFragment.utf8.count
    )
  }

  private func id(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
  }
}
