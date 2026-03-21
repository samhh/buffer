import XCTest
@testable import Buffer

final class CodeStylingTests: XCTestCase {

    // MARK: - Inline code detection

    func testDetectsInlineCode() {
        let spans = CodeStyling.detectSpans(in: "some `code here` text" as NSString)
        XCTAssertEqual(spans.count, 1)
        let span = spans[0]
        XCTAssertEqual(span.kind, .inline)
        XCTAssertEqual(span.fullRange, NSRange(location: 5, length: 11))       // `code here`
        XCTAssertEqual(span.contentRange, NSRange(location: 6, length: 9))     // code here
        XCTAssertEqual(span.openDelimiterRange, NSRange(location: 5, length: 1))
        XCTAssertEqual(span.closeDelimiterRange, NSRange(location: 15, length: 1))
    }

    func testDetectsMultipleInlineSpans() {
        let spans = CodeStyling.detectSpans(in: "`a` and `b`" as NSString)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].kind, .inline)
        XCTAssertEqual(spans[1].kind, .inline)
        XCTAssertEqual(spans[0].contentRange, NSRange(location: 1, length: 1))  // a
        XCTAssertEqual(spans[1].contentRange, NSRange(location: 9, length: 1))  // b
    }

    func testInlineCodeAtStartOfString() {
        let spans = CodeStyling.detectSpans(in: "`start` of text" as NSString)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].fullRange, NSRange(location: 0, length: 7))
    }

    func testInlineCodeAtEndOfString() {
        let spans = CodeStyling.detectSpans(in: "text at `end`" as NSString)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].fullRange, NSRange(location: 8, length: 5))
    }

    func testEmptyInlineCodeNotMatched() {
        let spans = CodeStyling.detectSpans(in: "empty `` backticks" as NSString)
        XCTAssertEqual(spans.count, 0)
    }

    func testInlineCodeDoesNotCrossLines() {
        let spans = CodeStyling.detectSpans(in: "`cross\nline`" as NSString)
        XCTAssertEqual(spans.count, 0)
    }

    func testUnclosedInlineCodeNotMatched() {
        let spans = CodeStyling.detectSpans(in: "unclosed `backtick" as NSString)
        XCTAssertEqual(spans.count, 0)
    }

    func testInlineCodeInListItem() {
        let spans = CodeStyling.detectSpans(in: "    - run `make build`" as NSString)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .inline)
        // Content is "make build"
        let text = "    - run `make build`" as NSString
        XCTAssertEqual(text.substring(with: spans[0].contentRange), "make build")
    }

    func testTripleBackticksNotMatchedAsInline() {
        // ``` should not produce inline matches because of the negative lookaround
        let spans = CodeStyling.detectSpans(in: "some ```not inline``` text" as NSString)
        // The triple backticks won't match the inline pattern due to lookaround,
        // and won't match block pattern because they're not on their own line.
        XCTAssertEqual(spans.count, 0)
    }

    // MARK: - Block code detection

    func testDetectsBlockCode() {
        let text = "before\n```\nline 1\nline 2\n```\nafter" as NSString
        let spans = CodeStyling.detectSpans(in: text)
        XCTAssertEqual(spans.count, 1)
        let span = spans[0]
        XCTAssertEqual(span.kind, .block)
        XCTAssertEqual(text.substring(with: span.contentRange), "line 1\nline 2")
    }

    func testBlockCodeWithLanguageTag() {
        let text = "```swift\nlet x = 1\n```" as NSString
        let spans = CodeStyling.detectSpans(in: text)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .block)
        XCTAssertEqual(text.substring(with: spans[0].contentRange), "let x = 1")
    }

    func testEmptyBlockCode() {
        let text = "```\n```" as NSString
        let spans = CodeStyling.detectSpans(in: text)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .block)
        XCTAssertEqual(spans[0].contentRange.length, 0)
    }

    func testBlockCodeWithIndentedFences() {
        let text = "    ```\n    code\n    ```" as NSString
        let spans = CodeStyling.detectSpans(in: text)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .block)
    }

    func testUnclosedBlockCodeNotMatched() {
        let text = "```\nsome code\nno closing fence" as NSString
        let spans = CodeStyling.detectSpans(in: text)
        // Only one fence line found, no pair → no block span
        XCTAssertEqual(spans.filter { $0.kind == .block }.count, 0)
    }

    func testMultipleBlockSpans() {
        let text = "```\nblock 1\n```\ntext\n```\nblock 2\n```" as NSString
        let spans = CodeStyling.detectSpans(in: text)
        let blocks = spans.filter { $0.kind == .block }
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(text.substring(with: blocks[0].contentRange), "block 1")
        XCTAssertEqual(text.substring(with: blocks[1].contentRange), "block 2")
    }

    // MARK: - Inline inside block suppression

    func testInlineCodeInsideBlockIsIgnored() {
        let text = "```\n`inline` inside block\n```" as NSString
        let spans = CodeStyling.detectSpans(in: text)
        // Should only have the block span, no inline span
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .block)
    }

    // MARK: - Mixed

    func testMixedInlineAndBlock() {
        let text = "use `cmd` here\n```\nblock code\n```\nand `another`" as NSString
        let spans = CodeStyling.detectSpans(in: text)
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[0].kind, .inline)
        XCTAssertEqual(text.substring(with: spans[0].contentRange), "cmd")
        XCTAssertEqual(spans[1].kind, .block)
        XCTAssertEqual(text.substring(with: spans[1].contentRange), "block code")
        XCTAssertEqual(spans[2].kind, .inline)
        XCTAssertEqual(text.substring(with: spans[2].contentRange), "another")
    }

    // MARK: - Empty text

    func testEmptyTextReturnsNoSpans() {
        let spans = CodeStyling.detectSpans(in: "" as NSString)
        XCTAssertEqual(spans.count, 0)
    }

    // MARK: - Adjacent inline spans

    func testAdjacentInlineSpansWithSpace() {
        // Adjacent backtick runs like `a``b` are ambiguous; use a space separator.
        let spans = CodeStyling.detectSpans(in: "`a` `b`" as NSString)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].contentRange, NSRange(location: 1, length: 1))  // a
        XCTAssertEqual(spans[1].contentRange, NSRange(location: 5, length: 1))  // b
    }

    func testDirectlyAdjacentBackticksNotMatched() {
        // `a``b` is ambiguous — the lookaround prevents partial matching
        let spans = CodeStyling.detectSpans(in: "`a``b`" as NSString)
        XCTAssertEqual(spans.count, 0)
    }
}
