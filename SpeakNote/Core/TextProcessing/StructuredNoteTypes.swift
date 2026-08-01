import Foundation

enum NoteType: CaseIterable, Codable, Equatable, Hashable, RawRepresentable, Sendable {
  case classNotes
  case meetingMinutes
  case generalNotes

  init?(rawValue: String) {
    switch rawValue {
    case "classNotes", "lecture":
      self = .classNotes
    case "meetingMinutes", "meeting":
      self = .meetingMinutes
    case "generalNotes", "general":
      self = .generalNotes
    default:
      return nil
    }
  }

  var rawValue: String {
    switch self {
    case .classNotes:
      "classNotes"
    case .meetingMinutes:
      "meetingMinutes"
    case .generalNotes:
      "generalNotes"
    }
  }

  @available(*, deprecated, renamed: "classNotes")
  static let lecture = Self.classNotes

  @available(*, deprecated, renamed: "meetingMinutes")
  static let meeting = Self.meetingMinutes

  @available(*, deprecated, renamed: "generalNotes")
  static let general = Self.generalNotes

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    guard let value = Self(rawValue: rawValue) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unknown note type: \(rawValue)"
      )
    }
    self = value
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

struct StructuredSourceRange: Codable, Equatable, Hashable, Sendable {
  let startTime: TimeInterval
  let endTime: TimeInterval
}

struct StructuredNoteItem: Codable, Equatable, Sendable {
  let text: String
  let sourceRanges: [StructuredSourceRange]
}

struct StructuredNoteSection: Codable, Equatable, Sendable {
  let title: String
  let content: String
  let sourceRanges: [StructuredSourceRange]
}

struct StructuredActionItem: Codable, Equatable, Sendable {
  let task: String
  let owner: String?
  let dueDate: String?
  let sourceRanges: [StructuredSourceRange]
}

struct StructuredDefinition: Codable, Equatable, Sendable {
  let term: String
  let definition: String
  let sourceRanges: [StructuredSourceRange]
}

struct LectureNoteFields: Codable, Equatable, Sendable {
  let coreConcepts: [StructuredNoteItem]
  let definitions: [StructuredDefinition]
  let examples: [StructuredNoteItem]
  let importantArguments: [StructuredNoteItem]
  let reviewQuestions: [StructuredNoteItem]

  init(
    coreConcepts: [StructuredNoteItem] = [],
    definitions: [StructuredDefinition] = [],
    examples: [StructuredNoteItem] = [],
    importantArguments: [StructuredNoteItem] = [],
    reviewQuestions: [StructuredNoteItem] = []
  ) {
    self.coreConcepts = coreConcepts
    self.definitions = definitions
    self.examples = examples
    self.importantArguments = importantArguments
    self.reviewQuestions = reviewQuestions
  }
}

struct MeetingNoteFields: Codable, Equatable, Sendable {
  let decisions: [StructuredNoteItem]
  let discussion: [StructuredNoteSection]

  init(
    decisions: [StructuredNoteItem] = [],
    discussion: [StructuredNoteSection] = []
  ) {
    self.decisions = decisions
    self.discussion = discussion
  }
}

struct ProcessedDocument: Codable, Equatable, Sendable {
  let noteType: NoteType
  let title: String
  let summary: String
  let sections: [StructuredNoteSection]
  let keyPoints: [StructuredNoteItem]
  let actions: [StructuredActionItem]
  let openQuestions: [StructuredNoteItem]
  let sourceRanges: [StructuredSourceRange]
  let lecture: LectureNoteFields?
  let meeting: MeetingNoteFields?
}

struct StructuredNotePartial: Codable, Equatable, Sendable {
  let groupIndex: Int
  let noteType: NoteType
  let title: String?
  let summary: String?
  let sections: [StructuredNoteSection]
  let keyPoints: [StructuredNoteItem]
  let actions: [StructuredActionItem]
  let openQuestions: [StructuredNoteItem]
  let sourceRanges: [StructuredSourceRange]
  let lecture: LectureNoteFields?
  let meeting: MeetingNoteFields?

  init(
    groupIndex: Int,
    noteType: NoteType,
    title: String? = nil,
    summary: String? = nil,
    sections: [StructuredNoteSection] = [],
    keyPoints: [StructuredNoteItem] = [],
    actions: [StructuredActionItem] = [],
    openQuestions: [StructuredNoteItem] = [],
    sourceRanges: [StructuredSourceRange] = [],
    lecture: LectureNoteFields? = nil,
    meeting: MeetingNoteFields? = nil
  ) {
    self.groupIndex = groupIndex
    self.noteType = noteType
    self.title = title
    self.summary = summary
    self.sections = sections
    self.keyPoints = keyPoints
    self.actions = actions
    self.openQuestions = openQuestions
    self.sourceRanges = sourceRanges
    self.lecture = lecture
    self.meeting = meeting
  }
}

enum StructuredNoteValidationError: Error, Equatable, Sendable {
  case invalidJSON
  case providerFailure
  case invalidSourceDuration
  case noteTypeMismatch(expected: NoteType, actual: NoteType)
  case groupIndexMismatch(expected: Int, actual: Int)
  case incompatibleSpecializedFields(noteType: NoteType)
  case emptyField(path: String)
  case missingSourceRange(path: String)
  case invalidSourceRange(path: String, index: Int)
  case duplicateSourceRange(path: String, range: StructuredSourceRange)
  case outOfRangeSourceRange(
    path: String,
    index: Int,
    allowed: StructuredSourceRange
  )
  case duplicateGroup(index: Int)
  case noUsablePartials(failedGroups: [Int])
}

enum StructuredNotePartialResult: Equatable, Sendable {
  case success(StructuredNotePartial)
  case failure(groupIndex: Int, error: StructuredNoteValidationError)

  var groupIndex: Int {
    switch self {
    case .success(let partial):
      partial.groupIndex
    case .failure(let groupIndex, _):
      groupIndex
    }
  }
}

struct StructuredNotePartialFailure: Equatable, Sendable {
  let groupIndex: Int
  let error: StructuredNoteValidationError
}

struct StructuredNoteReduction: Equatable, Sendable {
  let document: ProcessedDocument
  let failures: [StructuredNotePartialFailure]

  var failedGroupIndices: [Int] {
    failures.map(\.groupIndex)
  }
}
