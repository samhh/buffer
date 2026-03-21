import XCTest
@testable import Buffer

final class LinkShrinkTests: XCTestCase {
    func testDetectLinksFindsMultipleSchemes() {
        let text = "See https://example.com/a/b and mailto:team@example.com then slack://channel?id=42"
        let spans = LinkShrink.detectLinks(in: text as NSString)

        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans.map(\.urlString), [
            "https://example.com/a/b",
            "mailto:team@example.com",
            "slack://channel?id=42"
        ])
    }

    func testDetectLinksExcludesTrailingPunctuation() {
        let text = "Check this out: https://example.com/path/end."
        let spans = LinkShrink.detectLinks(in: text as NSString)

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].urlString, "https://example.com/path/end")
    }

    func testDetectLinksExcludesTrailingPunctuationWhenPathEndsInNumber() {
        let text = "See github.com/org/repo/issues/14821."
        let spans = LinkShrink.detectLinks(in: text as NSString)

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].urlString, "github.com/org/repo/issues/14821")
    }

    func testDetectLinksExcludesTrailingPunctuationForHTTPSNumericSegments() {
        let text = "See https://raycast.com/0123456789/012345."
        let spans = LinkShrink.detectLinks(in: text as NSString)

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].urlString, "https://raycast.com/0123456789/012345")
        XCTAssertEqual(spans[0].displayText, "raycast.com/.../012345")
    }

    func testDetectLinksDoesNotConsumeTrailingWhitespace() {
        let text = "before https://example.com/long/path after"
        let nsText = text as NSString
        let spans = LinkShrink.detectLinks(in: nsText)

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].urlString, "https://example.com/long/path")
        XCTAssertEqual(nsText.substring(with: spans[0].range), "https://example.com/long/path")
        XCTAssertEqual(nsText.substring(with: NSRange(location: spans[0].range.location + spans[0].range.length, length: 1)), " ")
    }

    func testDisplayTextUsesHostAndTailForDeepPath() {
        let url = "https://docs.google.com/document/d/1abc1234567890/edit?usp=sharing"
        XCTAssertEqual(LinkShrink.displayText(for: url), "docs.google.com/.../edit")
    }

    func testDisplayTextPreservesTrailingSlashInPathTail() {
        let url = "https://github.com/org/repo/issues/14821/"
        XCTAssertEqual(LinkShrink.displayText(for: url), "github.com/.../14821/")
    }

    func testDisplayTextDropsLeadingWWWSubdomain() {
        let url = "https://www.raycast.com/blog/notes"
        XCTAssertEqual(LinkShrink.displayText(for: url), "raycast.com/.../notes")
    }

    func testDisplayTextKeepsWWWForDeeperSubdomains() {
        let url = "https://www.foo.bar.com/path/notes"
        XCTAssertEqual(LinkShrink.displayText(for: url), url)
    }

    func testDisplayTextKeepsProtocolForNonHTTPS() {
        let url = "http://example.com/a/very/long/path/with/segments/notes"
        XCTAssertEqual(LinkShrink.displayText(for: url), "http://example.com/.../notes")
    }

    func testDisplayTextDoesNotDropWWWForNonHTTPS() {
        let url = "http://www.raycast.com/a/very/long/path/notes"
        XCTAssertEqual(LinkShrink.displayText(for: url), "http://www.raycast.com/.../notes")
    }

    func testDisplayTextFallsBackToQueryTail() {
        let url = "https://api.example.com?query=something-long&source=buffer"
        XCTAssertEqual(LinkShrink.displayText(for: url), "api.example.com/...?source=buffer")
    }

    func testDisplayTextLeavesShortLinksUnchanged() {
        let url = "https://example.com/a"
        XCTAssertEqual(LinkShrink.displayText(for: url), url)
    }

    func testDisplayTextFallsBackForInvalidLongValue() {
        let raw = "this-is-not-a-url-but-it-is-definitely-long-enough-to-truncate-cleanly"
        let display = LinkShrink.displayText(for: raw)
        XCTAssertTrue(display.contains("..."))
        XCTAssertNotEqual(display, raw)
    }

    func testActiveLinkRangeForCaretAndSelection() {
        let spans: [ShrunkLinkSpan] = [
            .init(range: NSRange(location: 4, length: 8), urlString: "https://a.com", displayText: "a.com")
        ]

        XCTAssertEqual(LinkShrink.activeLinkRange(in: spans, selection: NSRange(location: 6, length: 0)), spans[0].range)
        XCTAssertNil(LinkShrink.activeLinkRange(in: spans, selection: NSRange(location: 2, length: 0)))
        XCTAssertEqual(LinkShrink.activeLinkRange(in: spans, selection: NSRange(location: 10, length: 4)), spans[0].range)
    }

    func testActiveLinkRangesReturnsAllMatchesForExpandedSelection() {
        let spans: [ShrunkLinkSpan] = [
            .init(range: NSRange(location: 4, length: 8), urlString: "https://a.com", displayText: "a"),
            .init(range: NSRange(location: 18, length: 8), urlString: "https://b.com", displayText: "b"),
            .init(range: NSRange(location: 32, length: 8), urlString: "https://c.com", displayText: "c")
        ]

        let selection = NSRange(location: 10, length: 20)
        XCTAssertEqual(
            LinkShrink.activeLinkRanges(in: spans, selection: selection),
            [spans[0].range, spans[1].range]
        )
    }

    func testActiveLinkRangesReturnsSingleRangeForCaretSelection() {
        let spans: [ShrunkLinkSpan] = [
            .init(range: NSRange(location: 4, length: 8), urlString: "https://a.com", displayText: "a"),
            .init(range: NSRange(location: 18, length: 8), urlString: "https://b.com", displayText: "b")
        ]

        XCTAssertEqual(
            LinkShrink.activeLinkRanges(in: spans, selection: NSRange(location: 20, length: 0)),
            [spans[1].range]
        )
    }

    func testActiveLinkRangesReturnsEmptyWhenSelectionMissesLinks() {
        let spans: [ShrunkLinkSpan] = [
            .init(range: NSRange(location: 4, length: 8), urlString: "https://a.com", displayText: "a"),
            .init(range: NSRange(location: 18, length: 8), urlString: "https://b.com", displayText: "b")
        ]

        XCTAssertEqual(
            LinkShrink.activeLinkRanges(in: spans, selection: NSRange(location: 27, length: 3)),
            []
        )
    }

    func testSpanContainingCharacterIndexResolvesInsideRange() {
        let spanA = ShrunkLinkSpan(range: NSRange(location: 0, length: 5), urlString: "a://x", displayText: "a")
        let spanB = ShrunkLinkSpan(range: NSRange(location: 10, length: 4), urlString: "b://y", displayText: "b")
        let spans = [spanA, spanB]

        XCTAssertEqual(LinkShrink.span(containing: 2, in: spans), spanA)
        XCTAssertEqual(LinkShrink.span(containing: 11, in: spans), spanB)
        XCTAssertNil(LinkShrink.span(containing: 8, in: spans))
    }

    // MARK: - Code span exclusion

    func testDetectLinksExcludesURLInsideInlineCode() {
        let text = "see `https://example.com/a/b` for details"
        let nsText = text as NSString
        let codeSpans = CodeStyling.detectSpans(in: nsText)
        let links = LinkShrink.detectLinks(in: nsText, excluding: codeSpans)

        XCTAssertEqual(codeSpans.count, 1)
        XCTAssertEqual(links.count, 0)
    }

    func testDetectLinksExcludesURLInsideCodeFence() {
        let text = "before\n```\nhttps://example.com/long/path\n```\nafter https://other.com/ok"
        let nsText = text as NSString
        let codeSpans = CodeStyling.detectSpans(in: nsText)
        let links = LinkShrink.detectLinks(in: nsText, excluding: codeSpans)

        XCTAssertEqual(codeSpans.count, 1)
        XCTAssertEqual(codeSpans[0].kind, .block)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].urlString, "https://other.com/ok")
    }

    func testDetectLinksKeepsURLOutsideCode() {
        let text = "visit https://example.com/path and `some code`"
        let nsText = text as NSString
        let codeSpans = CodeStyling.detectSpans(in: nsText)
        let links = LinkShrink.detectLinks(in: nsText, excluding: codeSpans)

        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].urlString, "https://example.com/path")
    }

    func testDetectLinksExcludesMultipleURLsInCodeFence() {
        let text = "```\nhttps://a.com\nhttps://b.com\n```"
        let nsText = text as NSString
        let codeSpans = CodeStyling.detectSpans(in: nsText)
        let links = LinkShrink.detectLinks(in: nsText, excluding: codeSpans)

        XCTAssertEqual(links.count, 0)
    }
}
