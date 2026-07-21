#if !os(watchOS)
import CoFleetUI
import XCTest

final class RichNoteEditorTests: XCTestCase {
    func testCodecRoundTripsEverySupportedFormat() {
        let markdown = """
        ## Release notes
        Plain **bold** and _italic_ with [a link](https://example.com/docs) and `inline code`.
        - Bullet
        3. Numbered
        > Quoted
        - [ ] Pending
        - [x] Complete
        ```swift
        let answer = 42
        print(answer)
        ```
        """
        let document = CoFleetRichNoteMarkdownCodec.parse(markdown)
        XCTAssertEqual(CoFleetRichNoteMarkdownCodec.serialize(document), markdown)
        XCTAssertEqual(document.blocks.count, 8)
        XCTAssertEqual(document.blocks[0].kind, .heading(level: 2))
        XCTAssertEqual(document.blocks[2].kind, .unorderedList)
        XCTAssertEqual(document.blocks[3].kind, .orderedList(ordinal: 3))
        XCTAssertEqual(document.blocks[4].kind, .quote)
        XCTAssertEqual(document.blocks[5].kind, .checklist(isChecked: false))
        XCTAssertEqual(document.blocks[6].kind, .checklist(isChecked: true))
        XCTAssertEqual(document.blocks[7].kind, .codeBlock(language: "swift"))
    }

    func testCodecNormalizesWindowsLineEndings() {
        let document = CoFleetRichNoteMarkdownCodec.parse("# Title\r\n\r\n- [ ] Task")
        XCTAssertEqual(CoFleetRichNoteMarkdownCodec.serialize(document), "# Title\n\n- [ ] Task")
    }

    func testCodecPreservesEscapedMarkdownAsLiteralText() {
        let source = #"Literal \*star\* and \[brackets\]"#
        let document = CoFleetRichNoteMarkdownCodec.parse(source)
        XCTAssertEqual(document.blocks.first?.plainText, "Literal *star* and [brackets]")
        XCTAssertEqual(CoFleetRichNoteMarkdownCodec.serialize(document), source)
    }

    func testNestedInlineStylesRemainSemantic() {
        let document = CoFleetRichNoteMarkdownCodec.parse("**Bold and _italic_**")
        XCTAssertEqual(document.blocks[0].runs.count, 2)
        XCTAssertEqual(document.blocks[0].runs[0].styles, [.bold])
        XCTAssertEqual(document.blocks[0].runs[1].styles, [.bold, .italic])
        let canonical = CoFleetRichNoteMarkdownCodec.serialize(document)
        XCTAssertEqual(CoFleetRichNoteMarkdownCodec.parse(canonical), document)
    }

    func testFencedCodeUsesLongerFenceWhenContentContainsTripleBackticks() {
        let document = CoFleetRichNoteDocument(blocks: [
            .init(kind: .codeBlock(language: nil), runs: [.init(text: "before ``` after")]),
        ])
        XCTAssertEqual(CoFleetRichNoteMarkdownCodec.serialize(document), "````\nbefore ``` after\n````")
    }

    func testCommandsAppendPortableMarkdownBlocks() {
        XCTAssertEqual(CoFleetMarkdownCommand.orderedList.applying(to: "Existing"), "Existing\n\n1. List item")
        XCTAssertEqual(CoFleetMarkdownCommand.checklist.applying(to: ""), "- [ ] Task")
        XCTAssertEqual(CoFleetMarkdownCommand.codeBlock.applying(to: ""), "```\ncode\n```")
    }
}
#endif
