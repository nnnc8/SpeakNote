import CryptoKit
import Foundation

struct VocabularyTranscriptResult: Equatable, Sendable {
  let transcript: Transcript
  let audits: [ReplacementAudit]
  let configurationHash: String?
}

protocol VocabularyProcessing: Actor {
  func promptFragment(profileID: UUID?) async throws -> String?
  func apply(
    to transcript: Transcript,
    profileID: UUID?,
    recordHistory: Bool
  ) async throws -> VocabularyTranscriptResult
}

actor VocabularyService: VocabularyProcessing {
  private let repository: any VocabularyStoring
  private let termSelector: CustomTermSelector
  private let ruleEngine: ReplacementRuleEngine

  init(
    repository: any VocabularyStoring,
    termSelector: CustomTermSelector = CustomTermSelector(),
    ruleEngine: ReplacementRuleEngine = ReplacementRuleEngine()
  ) {
    self.repository = repository
    self.termSelector = termSelector
    self.ruleEngine = ruleEngine
  }

  func promptFragment(profileID: UUID?) async throws -> String? {
    guard let profile = try await activeProfile(id: profileID) else {
      return nil
    }
    let terms = try await repository.customTerms(profileID: profile.id)
    let selection = termSelector.select(for: profile, from: terms)
    return selection.promptFragment.isEmpty ? nil : selection.promptFragment
  }

  func apply(
    to transcript: Transcript,
    profileID: UUID?,
    recordHistory: Bool
  ) async throws -> VocabularyTranscriptResult {
    guard let profile = try await activeProfile(id: profileID) else {
      return VocabularyTranscriptResult(
        transcript: transcript,
        audits: [],
        configurationHash: nil
      )
    }
    let rules = try await repository.replacementRules(profileID: profile.id)
    let aggregate = ruleEngine.apply(
      toStoredRawTranscript: transcript.text,
      profileID: profile.id,
      rules: rules
    )
    let transformedSegments = transcript.segments.map { segment in
      let result = ruleEngine.apply(
        toStoredRawTranscript: segment.text,
        profileID: profile.id,
        rules: rules
      )
      return TranscriptSegment(
        id: segment.id,
        startTime: segment.startTime,
        endTime: segment.endTime,
        text: result.text,
        detectedLanguage: segment.detectedLanguage
      )
    }
    let transformed = Transcript(
      id: transcript.id,
      text: aggregate.text,
      segments: transformedSegments,
      detectedLanguage: transcript.detectedLanguage
    )

    if recordHistory, !aggregate.auditTrail.isEmpty {
      _ = try await repository.appendReplacementAudits(
        aggregate.auditTrail,
        profileID: profile.id
      )
      _ = try await repository.appendCorrectionObservations(
        aggregate.auditTrail.map {
          VocabularyCorrectionObservation(
            profileID: profile.id,
            original: $0.matchedText,
            replacement: $0.replacementText
          )
        },
        profileID: profile.id
      )
    }
    return VocabularyTranscriptResult(
      transcript: transformed,
      audits: aggregate.auditTrail,
      configurationHash: try Self.configurationHash(
        profile: profile,
        rules: rules
      )
    )
  }

  private func activeProfile(id: UUID?) async throws -> Profile? {
    guard let id, let profile = try await repository.profile(id: id) else {
      return nil
    }
    return profile.vocabularyScope == .profileOnly ? profile : nil
  }

  private static func configurationHash(
    profile: Profile,
    rules: [ReplacementRule]
  ) throws -> String {
    struct Snapshot: Encodable {
      let version: Int
      let profile: Profile
      let rules: [ReplacementRule]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(
      Snapshot(
        version: 1,
        profile: profile,
        rules: rules.sorted { $0.id.uuidString < $1.id.uuidString }
      )
    )
    return SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
