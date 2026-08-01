import Foundation
import XCTest

@testable import SpeakNote

final class ReplacementRuleEngineTests: XCTestCase {
  private let engine = ReplacementRuleEngine()

  func testUnicodeCaseFoldingAndWordBoundariesAvoidEmbeddedWords() {
    let profileID = id(1)
    let cafe = ReplacementRule(
      id: id(11),
      profileID: profileID,
      match: "café",
      replacement: "咖啡館"
    )
    let bank = ReplacementRule(
      id: id(12),
      profileID: profileID,
      match: "銀行",
      replacement: "Bank"
    )

    let result = engine.apply(
      toStoredRawTranscript: "CAFÉ cafe\u{301} cafés decafé；銀行 銀行家，銀行",
      profileID: profileID,
      rules: [bank, cafe]
    )

    XCTAssertEqual(result.text, "咖啡館 咖啡館 cafés decafé；Bank 銀行家，Bank")
    XCTAssertEqual(result.auditTrail.map(\.matchedText), ["CAFÉ", "cafe\u{301}", "銀行", "銀行"])
  }

  func testWholeWordSettingCanBeDisabledForIntentionalSubstringRules() {
    let profileID = id(1)
    let wholeWord = ReplacementRule(
      id: id(11),
      profileID: profileID,
      match: "cat",
      replacement: "dog"
    )
    var substring = wholeWord
    substring.requiresWordBoundaries = false

    XCTAssertEqual(
      engine.apply(
        toStoredRawTranscript: "cat concatenate cat_name",
        profileID: profileID,
        rules: [wholeWord]
      ).text,
      "dog concatenate cat_name"
    )
    XCTAssertEqual(
      engine.apply(
        toStoredRawTranscript: "cat concatenate cat_name",
        profileID: profileID,
        rules: [substring]
      ).text,
      "dog condogenate dog_name"
    )
  }

  func testHigherPriorityWinsOverLongerOverlappingRule() {
    let profileID = id(1)
    let phrase = ReplacementRule(
      id: id(11),
      profileID: profileID,
      match: "New York",
      replacement: "NYC",
      priority: 5
    )
    let word = ReplacementRule(
      id: id(12),
      profileID: profileID,
      match: "York",
      replacement: "Y",
      priority: 10
    )

    let result = engine.apply(
      toStoredRawTranscript: "New York",
      profileID: profileID,
      rules: [phrase, word]
    )

    XCTAssertEqual(result.text, "New Y")
    XCTAssertEqual(result.auditTrail.map(\.ruleID), [word.id])
    XCTAssertEqual(result.conflictPolicy, .highestPriorityThenLongestMatch)
  }

  func testLongerRuleWinsWhenPrioritiesTie() {
    let profileID = id(1)
    let phrase = ReplacementRule(
      id: id(11),
      profileID: profileID,
      match: "New York",
      replacement: "NYC",
      priority: 10
    )
    let word = ReplacementRule(
      id: id(12),
      profileID: profileID,
      match: "York",
      replacement: "Y",
      priority: 10
    )

    let result = engine.apply(
      toStoredRawTranscript: "New York",
      profileID: profileID,
      rules: [word, phrase]
    )

    XCTAssertEqual(result.text, "NYC")
    XCTAssertEqual(result.auditTrail.map(\.ruleID), [phrase.id])
  }

  func testStableRuleIDBreaksExactConflictRegardlessOfInputOrder() {
    let profileID = id(1)
    let first = ReplacementRule(
      id: id(11),
      profileID: profileID,
      match: "term",
      replacement: "first",
      priority: 10
    )
    let second = ReplacementRule(
      id: id(12),
      profileID: profileID,
      match: "term",
      replacement: "second",
      priority: 10
    )

    let forward = engine.apply(
      toStoredRawTranscript: "term",
      profileID: profileID,
      rules: [first, second]
    )
    let reverse = engine.apply(
      toStoredRawTranscript: "term",
      profileID: profileID,
      rules: [second, first]
    )

    XCTAssertEqual(forward, reverse)
    XCTAssertEqual(forward.text, "first")
  }

  func testRulesAreNonCascading() {
    let profileID = id(1)
    let first = ReplacementRule(
      id: id(11),
      profileID: profileID,
      match: "cat",
      replacement: "dog",
      priority: 10
    )
    let second = ReplacementRule(
      id: id(12),
      profileID: profileID,
      match: "dog",
      replacement: "wolf",
      priority: 5
    )

    let result = engine.apply(
      toStoredRawTranscript: "cat",
      profileID: profileID,
      rules: [second, first]
    )

    XCTAssertEqual(result.text, "dog")
    XCTAssertEqual(result.auditTrail.map(\.ruleID), [first.id])
  }

  func testDisabledWrongProfileAndCaseSensitiveRulesDoNotLeak() {
    let profileID = id(1)
    let otherProfileID = id(2)
    let disabled = ReplacementRule(
      id: id(11),
      profileID: profileID,
      match: "foo",
      replacement: "disabled",
      priority: 100,
      isEnabled: false
    )
    let foreign = ReplacementRule(
      id: id(12),
      profileID: otherProfileID,
      match: "foo",
      replacement: "foreign",
      priority: 200
    )
    let enabled = ReplacementRule(
      id: id(13),
      profileID: profileID,
      match: "foo",
      replacement: "local",
      isCaseSensitive: true
    )

    let result = engine.apply(
      toStoredRawTranscript: "Foo foo",
      profileID: profileID,
      rules: [disabled, foreign, enabled]
    )

    XCTAssertEqual(result.text, "Foo local")
    XCTAssertEqual(result.auditTrail.map(\.ruleID), [enabled.id])
  }

  func testAuditUsesUTF16SourceAndShiftedOutputRanges() {
    let profileID = id(1)
    let rule = ReplacementRule(
      id: id(11),
      profileID: profileID,
      match: "foo",
      replacement: "x"
    )

    let result = engine.apply(
      toStoredRawTranscript: "🙂 foo foo",
      profileID: profileID,
      rules: [rule]
    )

    XCTAssertEqual(result.text, "🙂 x x")
    XCTAssertEqual(
      result.auditTrail,
      [
        ReplacementAudit(
          ruleID: rule.id,
          sourceRange: UTF16TextRange(location: 3, length: 3),
          outputRange: UTF16TextRange(location: 3, length: 1),
          matchedText: "foo",
          replacementText: "x",
          rulePriority: 0
        ),
        ReplacementAudit(
          ruleID: rule.id,
          sourceRange: UTF16TextRange(location: 7, length: 3),
          outputRange: UTF16TextRange(location: 5, length: 1),
          matchedText: "foo",
          replacementText: "x",
          rulePriority: 0
        ),
      ]
    )
  }

  private func id(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
  }
}
