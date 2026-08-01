import XCTest

@testable import SpeakNote

final class StructuredNoteMarkdownRendererTests: XCTestCase {
  func testLectureSnapshotAndEscaping() {
    let document = ProcessedDocument(
      noteType: .classNotes,
      title: "# 課程 [A]",
      summary: "*摘要*\n第二行",
      sections: [
        StructuredNoteSection(
          title: "章節 #1",
          content: "內容\n- 列",
          sourceRanges: [range(8, 10)]
        )
      ],
      keyPoints: [
        StructuredNoteItem(
          text: "共通 *重點*",
          sourceRanges: [range(1, 2)]
        )
      ],
      actions: [
        StructuredActionItem(
          task: "讀 [文件]",
          owner: "A|B",
          dueDate: "明天!",
          sourceRanges: [range(6, 7)]
        )
      ],
      openQuestions: [
        StructuredNoteItem(
          text: "為何 <X>?",
          sourceRanges: [range(7, 8)]
        )
      ],
      sourceRanges: [range(0, 10)],
      lecture: LectureNoteFields(
        coreConcepts: [
          StructuredNoteItem(text: "核心", sourceRanges: [range(1, 2)])
        ],
        definitions: [
          StructuredDefinition(
            term: "T*erm",
            definition: "D`ef",
            sourceRanges: [range(2, 3)]
          )
        ],
        examples: [
          StructuredNoteItem(text: "例子", sourceRanges: [range(3, 4)])
        ],
        importantArguments: [
          StructuredNoteItem(text: "論點", sourceRanges: [range(4, 5)])
        ],
        reviewQuestions: [
          StructuredNoteItem(text: "怎麼複習?", sourceRanges: [range(5, 6)])
        ]
      ),
      meeting: nil
    )
    let expected = """
      # \\# 課程 \\[A\\]

      ## 本堂課摘要

      \\*摘要\\*\u{20}\u{20}
      第二行

      來源：[00:00:00.000..00:00:10.000](#t=0-10000)

      ## 核心概念

      - 核心 - [00:00:01.000..00:00:02.000](#t=1000-2000)

      ## 名詞與定義

      - **T\\*erm**：D\\`ef - [00:00:02.000..00:00:03.000](#t=2000-3000)

      ## 老師提供的案例

      - 例子 - [00:00:03.000..00:00:04.000](#t=3000-4000)

      ## 重要論點

      - 論點 - [00:00:04.000..00:00:05.000](#t=4000-5000)

      ## 複習問題

      - 怎麼複習? - [00:00:05.000..00:00:06.000](#t=5000-6000)

      ## 重點

      - 共通 \\*重點\\* - [00:00:01.000..00:00:02.000](#t=1000-2000)

      ## 待辦事項

      - [ ] 讀 \\[文件\\]（負責人：A\\|B；期限：明天\\!） - [00:00:06.000..00:00:07.000](#t=6000-7000)

      ## 需要進一步確認的內容

      - 為何 \\<X\\>? - [00:00:07.000..00:00:08.000](#t=7000-8000)

      ## 完整整理筆記

      ### 章節 #1

      內容\u{20}\u{20}
      \\- 列

      來源：[00:00:08.000..00:00:10.000](#t=8000-10000)

      """

    XCTAssertEqual(StructuredNoteMarkdownRenderer().render(document), expected)
  }

  func testMeetingSnapshot() {
    let document = ProcessedDocument(
      noteType: .meetingMinutes,
      title: "Team > Review",
      summary: "Meeting summary",
      sections: [
        StructuredNoteSection(
          title: "Other",
          content: "Common section",
          sourceRanges: [range(2, 3)]
        )
      ],
      keyPoints: [
        StructuredNoteItem(text: "Point", sourceRanges: [range(0, 1)])
      ],
      actions: [
        StructuredActionItem(
          task: "Ship",
          owner: nil,
          dueDate: nil,
          sourceRanges: [range(1, 2)]
        )
      ],
      openQuestions: [
        StructuredNoteItem(text: "Risk?", sourceRanges: [range(2, 3)])
      ],
      sourceRanges: [range(0, 3)],
      lecture: nil,
      meeting: MeetingNoteFields(
        decisions: [
          StructuredNoteItem(text: "Approved", sourceRanges: [range(0, 1)])
        ],
        discussion: [
          StructuredNoteSection(
            title: "Topic",
            content: "Discussion",
            sourceRanges: [range(1, 2)]
          )
        ]
      )
    )
    let expected = """
      # Team \\> Review

      ## 會議摘要

      Meeting summary

      來源：[00:00:00.000..00:00:03.000](#t=0-3000)

      ## 已確認的決策

      - Approved - [00:00:00.000..00:00:01.000](#t=0-1000)

      ## 重點

      - Point - [00:00:00.000..00:00:01.000](#t=0-1000)

      ## 待辦事項

      - [ ] Ship - [00:00:01.000..00:00:02.000](#t=1000-2000)

      ## 尚未解決的問題

      - Risk? - [00:00:02.000..00:00:03.000](#t=2000-3000)

      ## 討論內容

      ### Topic

      Discussion

      來源：[00:00:01.000..00:00:02.000](#t=1000-2000)

      ### Other

      Common section

      來源：[00:00:02.000..00:00:03.000](#t=2000-3000)

      """

    XCTAssertEqual(StructuredNoteMarkdownRenderer().render(document), expected)
  }

  func testGeneralSnapshot() {
    let document = ProcessedDocument(
      noteType: .generalNotes,
      title: "Voice note",
      summary: "Summary",
      sections: [
        StructuredNoteSection(
          title: "Content",
          content: "Body",
          sourceRanges: [range(2, 3)]
        )
      ],
      keyPoints: [
        StructuredNoteItem(text: "Idea", sourceRanges: [range(0, 1)])
      ],
      actions: [],
      openQuestions: [
        StructuredNoteItem(text: "Next?", sourceRanges: [range(1, 2)])
      ],
      sourceRanges: [range(0, 3)],
      lecture: nil,
      meeting: nil
    )
    let expected = """
      # Voice note

      ## 摘要

      Summary

      來源：[00:00:00.000..00:00:03.000](#t=0-3000)

      ## 主要想法

      - Idea - [00:00:00.000..00:00:01.000](#t=0-1000)

      ## 待辦事項

      ## 延伸問題

      - Next? - [00:00:01.000..00:00:02.000](#t=1000-2000)

      ## 完整內容

      ### Content

      Body

      來源：[00:00:02.000..00:00:03.000](#t=2000-3000)

      """

    XCTAssertEqual(StructuredNoteMarkdownRenderer().render(document), expected)
  }

  private func range(
    _ start: TimeInterval,
    _ end: TimeInterval
  ) -> StructuredSourceRange {
    StructuredSourceRange(startTime: start, endTime: end)
  }
}
