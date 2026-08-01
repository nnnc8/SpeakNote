import Foundation

struct ChunkTranscript: Equatable, Sendable {
  let chunk: AudioChunk
  let transcript: Transcript
}

struct TranscriptMerger: Sendable {
  let overlapDuration: TimeInterval

  init(overlapDuration: TimeInterval = 2) {
    self.overlapDuration = max(0, overlapDuration)
  }

  func merge(
    _ inputs: [ChunkTranscript],
    sourceDuration: TimeInterval,
    transcriptID: UUID = UUID()
  ) -> Transcript {
    let duration = max(0, sourceDuration)
    var merged: [TranscriptSegment] = []
    var coveredUntil: TimeInterval = 0

    for input in inputs.sorted(by: Self.chunkOrder) {
      let priorSegments = merged
      let overlapEnd = min(
        input.chunk.endTime,
        min(coveredUntil, input.chunk.startTime + overlapDuration)
      )
      let candidates = relativeSegments(from: input)

      for candidate in candidates {
        let absolute = absoluteSegment(
          candidate,
          chunk: input.chunk,
          sourceDuration: duration
        )
        let priorOverlap = priorSegments.filter {
          $0.endTime >= input.chunk.startTime
            && $0.startTime <= overlapEnd
            && Self.intersects($0, absolute)
        }

        if absolute.startTime <= overlapEnd,
          priorOverlap.contains(where: {
            Self.words(in: $0.text).normalized
              == Self.words(in: absolute.text).normalized
          })
        {
          continue
        }

        let duplicatePrefix =
          absolute.startTime <= overlapEnd
          ? Self.duplicatePrefixLength(
            priorText: priorOverlap.map(\.text).joined(separator: " "),
            candidateText: absolute.text
          )
          : 0
        let text = Self.droppingWords(duplicatePrefix, from: absolute.text)
        guard !text.isEmpty else { continue }

        let previousStart = merged.last?.startTime ?? 0
        let previousEnd = merged.last?.endTime ?? 0
        let start = min(duration, max(previousStart, absolute.startTime))
        let end = min(duration, max(start, previousEnd, absolute.endTime))
        merged.append(
          TranscriptSegment(
            id: absolute.id,
            startTime: start,
            endTime: end,
            text: text,
            detectedLanguage: absolute.detectedLanguage
          )
        )
      }
      coveredUntil = max(coveredUntil, min(duration, input.chunk.endTime))
    }

    return Transcript(
      id: transcriptID,
      text: merged.map(\.text).joined(separator: " "),
      segments: merged,
      detectedLanguage: merged.lazy.compactMap(\.detectedLanguage).first
    )
  }

  private func relativeSegments(from input: ChunkTranscript) -> [TranscriptSegment] {
    if !input.transcript.segments.isEmpty {
      return input.transcript.segments.enumerated()
        .sorted {
          ($0.element.startTime, $0.element.endTime, $0.offset)
            < ($1.element.startTime, $1.element.endTime, $1.offset)
        }
        .map(\.element)
    }
    guard !input.transcript.text.isEmpty else { return [] }
    return [
      TranscriptSegment(
        id: input.transcript.id,
        startTime: 0,
        endTime: input.chunk.endTime - input.chunk.startTime,
        text: input.transcript.text,
        detectedLanguage: input.transcript.detectedLanguage
      )
    ]
  }

  private func absoluteSegment(
    _ segment: TranscriptSegment,
    chunk: AudioChunk,
    sourceDuration: TimeInterval
  ) -> TranscriptSegment {
    let chunkStart = min(sourceDuration, max(0, chunk.startTime))
    let chunkEnd = min(sourceDuration, max(chunkStart, chunk.endTime))
    let start = min(chunkEnd, max(chunkStart, chunkStart + segment.startTime))
    let end = min(chunkEnd, max(start, chunkStart + segment.endTime))
    return TranscriptSegment(
      id: segment.id,
      startTime: start,
      endTime: end,
      text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
      detectedLanguage: segment.detectedLanguage
    )
  }

  private static func chunkOrder(
    _ lhs: ChunkTranscript,
    _ rhs: ChunkTranscript
  ) -> Bool {
    (lhs.chunk.index, lhs.chunk.startTime, lhs.chunk.url.path)
      < (rhs.chunk.index, rhs.chunk.startTime, rhs.chunk.url.path)
  }

  private static func intersects(
    _ lhs: TranscriptSegment,
    _ rhs: TranscriptSegment
  ) -> Bool {
    lhs.startTime <= rhs.endTime && rhs.startTime <= lhs.endTime
  }

  private static func duplicatePrefixLength(
    priorText: String,
    candidateText: String
  ) -> Int {
    let prior = words(in: priorText).normalized
    let candidate = words(in: candidateText).normalized
    let maximum = min(prior.count, candidate.count)
    guard maximum > 0 else { return 0 }
    for count in stride(from: maximum, through: 1, by: -1)
    where Array(prior.suffix(count)) == Array(candidate.prefix(count)) {
      return count
    }
    return 0
  }

  private static func droppingWords(_ count: Int, from text: String) -> String {
    words(in: text).original.dropFirst(count).joined(separator: " ")
  }

  private static func words(
    in text: String
  ) -> (original: [Substring], normalized: [String]) {
    let original = text.split(whereSeparator: \.isWhitespace)
    let normalized = original.map {
      $0.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
    return (original, normalized)
  }
}
