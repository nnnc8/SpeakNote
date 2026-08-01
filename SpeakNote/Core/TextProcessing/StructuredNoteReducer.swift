import Foundation

struct StructuredNoteValidator: Sendable {
  func decodePartial(
    _ data: Data,
    expectedNoteType: NoteType,
    group: StructuredTranscriptGroup
  ) throws -> StructuredNotePartial {
    let partial: StructuredNotePartial
    do {
      partial = try JSONDecoder().decode(StructuredNotePartial.self, from: data)
    } catch {
      throw StructuredNoteValidationError.invalidJSON
    }
    try validate(
      partial,
      expectedNoteType: expectedNoteType,
      expectedGroupIndex: group.index,
      allowedSourceRange: group.sourceRange
    )
    return partial
  }

  func validate(
    _ partial: StructuredNotePartial,
    expectedNoteType: NoteType,
    expectedGroupIndex: Int,
    allowedSourceRange: StructuredSourceRange
  ) throws {
    guard partial.noteType == expectedNoteType else {
      throw StructuredNoteValidationError.noteTypeMismatch(
        expected: expectedNoteType,
        actual: partial.noteType
      )
    }
    guard partial.groupIndex == expectedGroupIndex else {
      throw StructuredNoteValidationError.groupIndexMismatch(
        expected: expectedGroupIndex,
        actual: partial.groupIndex
      )
    }
    try validateSpecializedFields(partial)
    try validateOptionalText(partial.title, path: "title")
    try validateOptionalText(partial.summary, path: "summary")
    try validateRanges(
      partial.sourceRanges,
      path: "sourceRanges",
      allowed: allowedSourceRange
    )
    for (index, section) in partial.sections.enumerated() {
      try requireText(section.title, path: "sections[\(index)].title")
      try requireText(section.content, path: "sections[\(index)].content")
      try validateRanges(
        section.sourceRanges,
        path: "sections[\(index)].sourceRanges",
        allowed: allowedSourceRange
      )
    }
    try validateItems(
      partial.keyPoints,
      path: "keyPoints",
      allowed: allowedSourceRange
    )
    try validateItems(
      partial.openQuestions,
      path: "openQuestions",
      allowed: allowedSourceRange
    )
    for (index, action) in partial.actions.enumerated() {
      try requireText(action.task, path: "actions[\(index)].task")
      try validateOptionalText(action.owner, path: "actions[\(index)].owner")
      try validateOptionalText(action.dueDate, path: "actions[\(index)].dueDate")
      try validateRanges(
        action.sourceRanges,
        path: "actions[\(index)].sourceRanges",
        allowed: allowedSourceRange
      )
    }
    if let lecture = partial.lecture {
      try validateItems(
        lecture.coreConcepts,
        path: "lecture.coreConcepts",
        allowed: allowedSourceRange
      )
      try validateDefinitions(
        lecture.definitions,
        allowed: allowedSourceRange
      )
      try validateItems(
        lecture.examples,
        path: "lecture.examples",
        allowed: allowedSourceRange
      )
      try validateItems(
        lecture.importantArguments,
        path: "lecture.importantArguments",
        allowed: allowedSourceRange
      )
      try validateItems(
        lecture.reviewQuestions,
        path: "lecture.reviewQuestions",
        allowed: allowedSourceRange
      )
    }
    if let meeting = partial.meeting {
      try validateItems(
        meeting.decisions,
        path: "meeting.decisions",
        allowed: allowedSourceRange
      )
      for (index, section) in meeting.discussion.enumerated() {
        try requireText(
          section.title,
          path: "meeting.discussion[\(index)].title"
        )
        try requireText(
          section.content,
          path: "meeting.discussion[\(index)].content"
        )
        try validateRanges(
          section.sourceRanges,
          path: "meeting.discussion[\(index)].sourceRanges",
          allowed: allowedSourceRange
        )
      }
    }
  }

  private func validateSpecializedFields(
    _ partial: StructuredNotePartial
  ) throws {
    let isValid =
      switch partial.noteType {
      case .classNotes:
        partial.lecture != nil && partial.meeting == nil
      case .meetingMinutes:
        partial.lecture == nil && partial.meeting != nil
      case .generalNotes:
        partial.lecture == nil && partial.meeting == nil
      }
    guard isValid else {
      throw StructuredNoteValidationError.incompatibleSpecializedFields(
        noteType: partial.noteType
      )
    }
  }

  private func validateItems(
    _ items: [StructuredNoteItem],
    path: String,
    allowed: StructuredSourceRange
  ) throws {
    for (index, item) in items.enumerated() {
      try requireText(item.text, path: "\(path)[\(index)].text")
      try validateRanges(
        item.sourceRanges,
        path: "\(path)[\(index)].sourceRanges",
        allowed: allowed
      )
    }
  }

  private func validateDefinitions(
    _ definitions: [StructuredDefinition],
    allowed: StructuredSourceRange
  ) throws {
    for (index, definition) in definitions.enumerated() {
      try requireText(
        definition.term,
        path: "lecture.definitions[\(index)].term"
      )
      try requireText(
        definition.definition,
        path: "lecture.definitions[\(index)].definition"
      )
      try validateRanges(
        definition.sourceRanges,
        path: "lecture.definitions[\(index)].sourceRanges",
        allowed: allowed
      )
    }
  }

  private func validateRanges(
    _ ranges: [StructuredSourceRange],
    path: String,
    allowed: StructuredSourceRange
  ) throws {
    guard !ranges.isEmpty else {
      throw StructuredNoteValidationError.missingSourceRange(path: path)
    }
    var seen: Set<StructuredSourceRange> = []
    for (index, range) in ranges.enumerated() {
      guard range.startTime.isFinite,
        range.endTime.isFinite,
        range.startTime >= 0,
        range.endTime >= range.startTime
      else {
        throw StructuredNoteValidationError.invalidSourceRange(
          path: path,
          index: index
        )
      }
      guard range.startTime >= allowed.startTime,
        range.endTime <= allowed.endTime
      else {
        throw StructuredNoteValidationError.outOfRangeSourceRange(
          path: path,
          index: index,
          allowed: allowed
        )
      }
      guard seen.insert(range).inserted else {
        throw StructuredNoteValidationError.duplicateSourceRange(
          path: path,
          range: range
        )
      }
    }
  }

  private func validateOptionalText(
    _ text: String?,
    path: String
  ) throws {
    if let text {
      try requireText(text, path: path)
    }
  }

  private func requireText(_ text: String, path: String) throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw StructuredNoteValidationError.emptyField(path: path)
    }
  }
}

struct StructuredNoteReducer: Sendable {
  func reduce(
    noteType: NoteType,
    results: [StructuredNotePartialResult],
    sourceDuration: TimeInterval
  ) throws -> StructuredNoteReduction {
    guard sourceDuration.isFinite, sourceDuration >= 0 else {
      throw StructuredNoteValidationError.invalidSourceDuration
    }
    let ordered = results.sorted {
      if $0.groupIndex == $1.groupIndex {
        return Self.resultOrder($0) < Self.resultOrder($1)
      }
      return $0.groupIndex < $1.groupIndex
    }
    var seenGroups: Set<Int> = []
    for result in ordered {
      guard seenGroups.insert(result.groupIndex).inserted else {
        throw StructuredNoteValidationError.duplicateGroup(
          index: result.groupIndex
        )
      }
    }

    let allowed = StructuredSourceRange(
      startTime: 0,
      endTime: sourceDuration
    )
    var partials: [StructuredNotePartial] = []
    var failures: [StructuredNotePartialFailure] = []
    let validator = StructuredNoteValidator()
    for result in ordered {
      switch result {
      case .success(let partial):
        try validator.validate(
          partial,
          expectedNoteType: noteType,
          expectedGroupIndex: partial.groupIndex,
          allowedSourceRange: allowed
        )
        partials.append(partial)
      case .failure(let groupIndex, let error):
        failures.append(
          StructuredNotePartialFailure(
            groupIndex: groupIndex,
            error: error
          )
        )
      }
    }
    guard !partials.isEmpty else {
      throw StructuredNoteValidationError.noUsablePartials(
        failedGroups: failures.map(\.groupIndex)
      )
    }

    guard let title = partials.compactMap(\.title).first else {
      throw StructuredNoteValidationError.emptyField(path: "document.title")
    }
    let summaries = Self.uniqueText(partials.compactMap(\.summary))
    guard !summaries.isEmpty else {
      throw StructuredNoteValidationError.emptyField(path: "document.summary")
    }

    let document = ProcessedDocument(
      noteType: noteType,
      title: title,
      summary: summaries.joined(separator: "\n\n"),
      sections: Self.mergeSections(partials.flatMap(\.sections)),
      keyPoints: Self.mergeItems(partials.flatMap(\.keyPoints)),
      actions: Self.mergeActions(partials.flatMap(\.actions)),
      openQuestions: Self.mergeItems(partials.flatMap(\.openQuestions)),
      sourceRanges: Self.mergeRanges(partials.flatMap(\.sourceRanges)),
      lecture: noteType == .classNotes ? Self.mergeLecture(partials) : nil,
      meeting: noteType == .meetingMinutes ? Self.mergeMeeting(partials) : nil
    )
    return StructuredNoteReduction(
      document: document,
      failures: failures
    )
  }

  private static func mergeLecture(
    _ partials: [StructuredNotePartial]
  ) -> LectureNoteFields {
    let fields = partials.compactMap(\.lecture)
    return LectureNoteFields(
      coreConcepts: mergeItems(fields.flatMap(\.coreConcepts)),
      definitions: mergeDefinitions(fields.flatMap(\.definitions)),
      examples: mergeItems(fields.flatMap(\.examples)),
      importantArguments: mergeItems(fields.flatMap(\.importantArguments)),
      reviewQuestions: mergeItems(fields.flatMap(\.reviewQuestions))
    )
  }

  private static func mergeMeeting(
    _ partials: [StructuredNotePartial]
  ) -> MeetingNoteFields {
    let fields = partials.compactMap(\.meeting)
    return MeetingNoteFields(
      decisions: mergeItems(fields.flatMap(\.decisions)),
      discussion: mergeSections(fields.flatMap(\.discussion))
    )
  }

  private static func mergeItems(
    _ items: [StructuredNoteItem]
  ) -> [StructuredNoteItem] {
    var output: [StructuredNoteItem] = []
    var indices: [String: Int] = [:]
    for item in items {
      let key = normalized(item.text)
      if let index = indices[key] {
        output[index] = StructuredNoteItem(
          text: output[index].text,
          sourceRanges: mergeRanges(
            output[index].sourceRanges + item.sourceRanges
          )
        )
      } else {
        indices[key] = output.count
        output.append(
          StructuredNoteItem(
            text: item.text,
            sourceRanges: mergeRanges(item.sourceRanges)
          )
        )
      }
    }
    return output
  }

  private static func mergeSections(
    _ sections: [StructuredNoteSection]
  ) -> [StructuredNoteSection] {
    var output: [StructuredNoteSection] = []
    var indices: [String: Int] = [:]
    for section in sections {
      let key = normalized(section.title) + "\u{0}" + normalized(section.content)
      if let index = indices[key] {
        output[index] = StructuredNoteSection(
          title: output[index].title,
          content: output[index].content,
          sourceRanges: mergeRanges(
            output[index].sourceRanges + section.sourceRanges
          )
        )
      } else {
        indices[key] = output.count
        output.append(
          StructuredNoteSection(
            title: section.title,
            content: section.content,
            sourceRanges: mergeRanges(section.sourceRanges)
          )
        )
      }
    }
    return output
  }

  private static func mergeActions(
    _ actions: [StructuredActionItem]
  ) -> [StructuredActionItem] {
    var output: [StructuredActionItem] = []
    var indices: [String: Int] = [:]
    for action in actions {
      let key = [
        normalized(action.task),
        normalized(action.owner ?? ""),
        normalized(action.dueDate ?? ""),
      ].joined(separator: "\u{0}")
      if let index = indices[key] {
        output[index] = StructuredActionItem(
          task: output[index].task,
          owner: output[index].owner,
          dueDate: output[index].dueDate,
          sourceRanges: mergeRanges(
            output[index].sourceRanges + action.sourceRanges
          )
        )
      } else {
        indices[key] = output.count
        output.append(
          StructuredActionItem(
            task: action.task,
            owner: action.owner,
            dueDate: action.dueDate,
            sourceRanges: mergeRanges(action.sourceRanges)
          )
        )
      }
    }
    return output
  }

  private static func mergeDefinitions(
    _ definitions: [StructuredDefinition]
  ) -> [StructuredDefinition] {
    var output: [StructuredDefinition] = []
    var indices: [String: Int] = [:]
    for definition in definitions {
      let key =
        normalized(definition.term) + "\u{0}"
        + normalized(definition.definition)
      if let index = indices[key] {
        output[index] = StructuredDefinition(
          term: output[index].term,
          definition: output[index].definition,
          sourceRanges: mergeRanges(
            output[index].sourceRanges + definition.sourceRanges
          )
        )
      } else {
        indices[key] = output.count
        output.append(
          StructuredDefinition(
            term: definition.term,
            definition: definition.definition,
            sourceRanges: mergeRanges(definition.sourceRanges)
          )
        )
      }
    }
    return output
  }

  private static func mergeRanges(
    _ ranges: [StructuredSourceRange]
  ) -> [StructuredSourceRange] {
    Array(Set(ranges)).sorted {
      ($0.startTime, $0.endTime) < ($1.startTime, $1.endTime)
    }
  }

  private static func uniqueText(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { seen.insert(normalized($0)).inserted }
  }

  private static func normalized(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .lowercased()
  }

  private static func resultOrder(_ result: StructuredNotePartialResult) -> Int {
    switch result {
    case .success:
      0
    case .failure:
      1
    }
  }
}
