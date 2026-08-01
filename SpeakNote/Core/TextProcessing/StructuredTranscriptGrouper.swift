import Foundation

struct StructuredTranscriptGroupingConfiguration: Equatable, Sendable {
  static let standard = StructuredTranscriptGroupingConfiguration(
    maximumDuration: 10 * 60,
    maximumCharacters: 12_000,
    maximumEstimatedTokens: 4_000
  )

  let maximumDuration: TimeInterval
  let maximumCharacters: Int
  let maximumEstimatedTokens: Int
}

struct StructuredTranscriptGroup: Equatable, Identifiable, Sendable {
  var id: Int { index }

  let index: Int
  let segments: [TranscriptSegment]
  let text: String
  let sourceRange: StructuredSourceRange
  let characterCount: Int
  let estimatedTokenCount: Int
  let isOversized: Bool
}

enum StructuredTranscriptGroupingError: Error, Equatable, Sendable {
  case invalidConfiguration
  case invalidSourceDuration
  case invalidSegment(id: UUID)
  case oversizedSegment(id: UUID)
}

struct StructuredTranscriptGrouper: Sendable {
  let configuration: StructuredTranscriptGroupingConfiguration

  init(
    configuration: StructuredTranscriptGroupingConfiguration = .standard
  ) {
    self.configuration = configuration
  }

  func groups(
    for transcript: Transcript,
    sourceDuration: TimeInterval? = nil
  ) throws -> [StructuredTranscriptGroup] {
    guard configuration.maximumDuration.isFinite,
      configuration.maximumDuration > 0,
      configuration.maximumCharacters > 0,
      configuration.maximumEstimatedTokens > 0
    else {
      throw StructuredTranscriptGroupingError.invalidConfiguration
    }
    if let sourceDuration {
      guard sourceDuration.isFinite, sourceDuration >= 0 else {
        throw StructuredTranscriptGroupingError.invalidSourceDuration
      }
    }

    let ordered = try transcript.segments.sorted(by: Self.segmentOrder).map {
      guard $0.startTime.isFinite,
        $0.endTime.isFinite,
        $0.startTime >= 0,
        $0.endTime >= $0.startTime
      else {
        throw StructuredTranscriptGroupingError.invalidSegment(id: $0.id)
      }
      return $0
    }
    guard !ordered.isEmpty else {
      guard !transcript.text.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty else {
        return []
      }
      let aggregate = TranscriptSegment(
        id: transcript.id,
        startTime: 0,
        endTime: sourceDuration ?? 0,
        text: transcript.text,
        detectedLanguage: transcript.detectedLanguage
      )
      return try splitIfNeeded(aggregate).enumerated().map { index, segment in
        makeGroup(
          index: index,
          segments: [],
          text: segment.text,
          sourceRange: StructuredSourceRange(
            startTime: segment.startTime,
            endTime: segment.endTime
          )
        )
      }
    }

    let budgeted = try ordered.flatMap(splitIfNeeded)
    var output: [StructuredTranscriptGroup] = []
    var pending: [TranscriptSegment] = []
    for segment in budgeted {
      if !pending.isEmpty, exceedsLimits(pending + [segment]) {
        output.append(makeGroup(index: output.count, segments: pending))
        pending = []
      }
      pending.append(segment)
    }
    if !pending.isEmpty {
      output.append(makeGroup(index: output.count, segments: pending))
    }
    return output
  }

  private func splitIfNeeded(
    _ segment: TranscriptSegment
  ) throws -> [TranscriptSegment] {
    guard exceedsLimits([segment]) else { return [segment] }

    let characters = Array(segment.text)
    let duration = segment.endTime - segment.startTime
    let durationChunkCount = ceil(duration / configuration.maximumDuration)
    guard
      !characters.isEmpty,
      durationChunkCount <= Double(characters.count)
    else {
      throw StructuredTranscriptGroupingError.oversizedSegment(id: segment.id)
    }

    let requiredChunks = max(1, Int(durationChunkCount))
    let durationCharacterLimit = Int(
      ceil(Double(characters.count) / Double(requiredChunks))
    )
    let characterLimit = min(
      configuration.maximumCharacters,
      durationCharacterLimit
    )
    let (tokenByteLimit, overflow) =
      configuration.maximumEstimatedTokens.multipliedReportingOverflow(by: 3)
    let byteLimit = overflow ? Int.max : tokenByteLimit

    var texts: [String] = []
    var offset = 0
    while offset < characters.count {
      var end = offset
      var byteCount = 0
      while end < characters.count, end - offset < characterLimit {
        let nextByteCount = String(characters[end]).utf8.count
        guard nextByteCount <= byteLimit else {
          throw StructuredTranscriptGroupingError.oversizedSegment(id: segment.id)
        }
        if byteCount + nextByteCount > byteLimit { break }
        byteCount += nextByteCount
        end += 1
      }
      guard end > offset else {
        throw StructuredTranscriptGroupingError.oversizedSegment(id: segment.id)
      }
      texts.append(String(characters[offset..<end]))
      offset = end
    }

    let count = Double(texts.count)
    return texts.enumerated().map { index, text in
      let start = segment.startTime + duration * Double(index) / count
      let end = index == texts.count - 1
        ? segment.endTime
        : segment.startTime + duration * Double(index + 1) / count
      return TranscriptSegment(
        id: segment.id,
        startTime: start,
        endTime: end,
        text: text,
        detectedLanguage: segment.detectedLanguage
      )
    }
  }

  private func exceedsLimits(_ segments: [TranscriptSegment]) -> Bool {
    guard let first = segments.first,
      let endTime = segments.map(\.endTime).max()
    else {
      return false
    }
    let text = segments.map(\.text).joined(separator: "\n")
    return exceedsLimits(
      text: text,
      sourceRange: StructuredSourceRange(
        startTime: first.startTime,
        endTime: endTime
      )
    )
  }

  private func exceedsLimits(
    text: String,
    sourceRange: StructuredSourceRange
  ) -> Bool {
    sourceRange.endTime - sourceRange.startTime > configuration.maximumDuration
      || text.count > configuration.maximumCharacters
      || Self.estimatedTokens(in: text) > configuration.maximumEstimatedTokens
  }

  private func makeGroup(
    index: Int,
    segments: [TranscriptSegment]
  ) -> StructuredTranscriptGroup {
    let text = segments.map(\.text).joined(separator: "\n")
    return makeGroup(
      index: index,
      segments: segments,
      text: text,
      sourceRange: StructuredSourceRange(
        startTime: segments.first?.startTime ?? 0,
        endTime: segments.map(\.endTime).max() ?? 0
      )
    )
  }

  private func makeGroup(
    index: Int,
    segments: [TranscriptSegment],
    text: String,
    sourceRange: StructuredSourceRange
  ) -> StructuredTranscriptGroup {
    return StructuredTranscriptGroup(
      index: index,
      segments: segments,
      text: text,
      sourceRange: sourceRange,
      characterCount: text.count,
      estimatedTokenCount: Self.estimatedTokens(in: text),
      isOversized: exceedsLimits(text: text, sourceRange: sourceRange)
    )
  }

  private static func estimatedTokens(in text: String) -> Int {
    max(1, (text.utf8.count + 2) / 3)
  }

  private static func segmentOrder(
    _ lhs: TranscriptSegment,
    _ rhs: TranscriptSegment
  ) -> Bool {
    (lhs.startTime, lhs.endTime, lhs.id.uuidString)
      < (rhs.startTime, rhs.endTime, rhs.id.uuidString)
  }
}
