import Foundation

struct M5StructuredGroupRequest: Equatable, Sendable {
  let noteType: NoteType
  let group: StructuredTranscriptGroup
  let modelID: String
}

protocol M5StructuredNoteEngine: Sendable {
  func generatePartial(
    for request: M5StructuredGroupRequest
  ) async throws -> Data

  func repairPartial(
    _ invalidJSON: Data,
    for request: M5StructuredGroupRequest
  ) async throws -> Data
}

struct M5StructuredNoteProcessor: Sendable {
  private let engine: any M5StructuredNoteEngine
  private let grouper: StructuredTranscriptGrouper
  private let validator = StructuredNoteValidator()
  private let reducer = StructuredNoteReducer()

  init(
    engine: any M5StructuredNoteEngine,
    grouper: StructuredTranscriptGrouper = StructuredTranscriptGrouper()
  ) {
    self.engine = engine
    self.grouper = grouper
  }

  func process(
    transcript: Transcript,
    noteType: NoteType,
    sourceDuration: TimeInterval? = nil,
    modelID: String = ProviderDefaults.structuredTextModelID
  ) async throws -> StructuredNoteReduction {
    let resolvedSourceDuration = sourceDuration
      ?? transcript.segments.map(\.endTime).max()
      ?? 0
    let groups = try grouper.groups(
      for: transcript,
      sourceDuration: resolvedSourceDuration
    ).sorted {
      $0.index < $1.index
    }
    if let oversized = groups.first(where: \.isOversized) {
      throw StructuredTranscriptGroupingError.oversizedSegment(
        id: oversized.segments.first?.id ?? transcript.id
      )
    }
    var results: [StructuredNotePartialResult] = []
    results.reserveCapacity(groups.count)

    for group in groups {
      try Task.checkCancellation()
      let request = M5StructuredGroupRequest(
        noteType: noteType,
        group: group,
        modelID: modelID
      )
      do {
        let initialJSON = try await engine.generatePartial(for: request)
        let partial = try await validatedPartial(
          initialJSON,
          request: request
        )
        results.append(.success(partial))
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as StructuredNoteValidationError {
        results.append(.failure(groupIndex: group.index, error: error))
      } catch {
        results.append(.failure(groupIndex: group.index, error: .providerFailure))
      }
    }

    try Task.checkCancellation()
    return try reducer.reduce(
      noteType: noteType,
      results: results,
      sourceDuration: resolvedSourceDuration
    )
  }

  private func validatedPartial(
    _ initialJSON: Data,
    request: M5StructuredGroupRequest
  ) async throws -> StructuredNotePartial {
    do {
      return try validator.decodePartial(
        initialJSON,
        expectedNoteType: request.noteType,
        group: request.group
      )
    } catch is StructuredNoteValidationError {
      try Task.checkCancellation()
      let repairedJSON = try await engine.repairPartial(
        initialJSON,
        for: request
      )
      return try validator.decodePartial(
        repairedJSON,
        expectedNoteType: request.noteType,
        group: request.group
      )
    }
  }
}
