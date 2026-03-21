import AppKit

struct CodeSpan: Equatable {
    enum Kind { case inline, block }
    let kind: Kind
    let fullRange: NSRange
    let contentRange: NSRange
    let openDelimiterRange: NSRange
    let closeDelimiterRange: NSRange
}

enum CodeStyling {
    // MARK: - Block fence pattern

    // Matches a line that is just ``` optionally followed by a language tag.
    // Allows leading whitespace (for indented list items) but nothing after the
    // optional tag except whitespace.
    private static let blockFencePattern = try! NSRegularExpression(
        pattern: #"^[ \t]*```[^\n`]*$"#,
        options: .anchorsMatchLines
    )

    // MARK: - Inline code pattern

    // Single backtick delimiters, content must be non-empty, no newlines, and
    // must not be inside a `` ` `` run (negative lookaround prevents matching
    // inside ``` fences that happen to sit mid-line, though the block pass
    // already excludes those ranges).
    private static let inlineCodePattern = try! NSRegularExpression(
        pattern: #"(?<!`)`([^`\n]+)`(?!`)"#,
        options: []
    )

    // MARK: - Public API

    static func detectSpans(in text: NSString) -> [CodeSpan] {
        guard text.length > 0 else { return [] }

        var spans: [CodeSpan] = []
        let fullRange = NSRange(location: 0, length: text.length)

        // 1. Detect block code fences first.
        let fenceMatches = blockFencePattern.matches(in: text as String, options: [], range: fullRange)
        let fenceLineRanges: [NSRange] = fenceMatches.map(\.range)

        // Pair up fences: first opens, second closes, etc.
        var i = 0
        while i + 1 < fenceLineRanges.count {
            let openFence = fenceLineRanges[i]
            let closeFence = fenceLineRanges[i + 1]

            // Content is everything between the end of the open fence line
            // and the start of the close fence line.
            let contentStart = NSMaxRange(openFence)
            let contentEnd = closeFence.location

            let blockFullStart = openFence.location
            let blockFullEnd = NSMaxRange(closeFence)

            if contentEnd >= contentStart {
                let contentRange: NSRange
                if contentEnd > contentStart {
                    // Strip leading newline from content if present.
                    let firstChar = text.character(at: contentStart)
                    let adjustedStart = (firstChar == 0x0A || firstChar == 0x0D) ? contentStart + 1 : contentStart
                    // Strip trailing newline before close fence if present.
                    var adjustedEnd = contentEnd
                    if adjustedEnd > adjustedStart {
                        let lastChar = text.character(at: adjustedEnd - 1)
                        if lastChar == 0x0A || lastChar == 0x0D {
                            adjustedEnd -= 1
                        }
                    }
                    if adjustedEnd > adjustedStart {
                        contentRange = NSRange(location: adjustedStart, length: adjustedEnd - adjustedStart)
                    } else {
                        contentRange = NSRange(location: contentStart, length: 0)
                    }
                } else {
                    contentRange = NSRange(location: contentStart, length: 0)
                }

                spans.append(CodeSpan(
                    kind: .block,
                    fullRange: NSRange(location: blockFullStart, length: blockFullEnd - blockFullStart),
                    contentRange: contentRange,
                    openDelimiterRange: openFence,
                    closeDelimiterRange: closeFence
                ))
            }

            i += 2
        }

        // 2. Detect inline code spans, skipping anything inside block ranges.
        let inlineMatches = inlineCodePattern.matches(in: text as String, options: [], range: fullRange)
        for match in inlineMatches {
            let matchRange = match.range
            // Skip if this inline span overlaps any block span.
            if spans.contains(where: { NSIntersectionRange($0.fullRange, matchRange).length > 0 }) {
                continue
            }

            let contentRange = match.range(at: 1)
            let openDelimiterRange = NSRange(location: matchRange.location, length: 1)
            let closeDelimiterRange = NSRange(location: NSMaxRange(matchRange) - 1, length: 1)

            spans.append(CodeSpan(
                kind: .inline,
                fullRange: matchRange,
                contentRange: contentRange,
                openDelimiterRange: openDelimiterRange,
                closeDelimiterRange: closeDelimiterRange
            ))
        }

        return spans.sorted { $0.fullRange.location < $1.fullRange.location }
    }

    // MARK: - Attribute application

    /// Custom attribute key used to tag ranges styled by code styling,
    /// so they can be efficiently cleared before re-application.
    static let isCodeStyledKey = NSAttributedString.Key("BufferCodeStyled")

    @MainActor static let codeFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    @MainActor private static let delimiterColor = NSColor.tertiaryLabelColor
    static let codeBackgroundColor = NSColor.quaternaryLabelColor

    @MainActor static func applyAttributes(
        to textStorage: NSTextStorage,
        spans: [CodeSpan],
        linkSpans: [ShrunkLinkSpan]
    ) {
        let fullLength = textStorage.length
        guard fullLength > 0 else { return }

        // Clear previous code styling.
        let fullRange = NSRange(location: 0, length: fullLength)
        textStorage.beginEditing()
        textStorage.enumerateAttribute(isCodeStyledKey, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            textStorage.removeAttribute(isCodeStyledKey, range: range)
            textStorage.addAttribute(.font, value: NSFont.systemFont(ofSize: 14), range: range)
            textStorage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        }
        textStorage.endEditing()

        guard !spans.isEmpty else { return }

        textStorage.beginEditing()
        for span in spans {
            // Skip spans that overlap with link URLs.
            if linkSpans.contains(where: { NSIntersectionRange($0.range, span.fullRange).length > 0 }) {
                continue
            }

            guard NSMaxRange(span.fullRange) <= fullLength else { continue }

            // Mark the full range so we can clear it next time.
            textStorage.addAttribute(isCodeStyledKey, value: true, range: span.fullRange)

            // Dim delimiters.
            textStorage.addAttribute(.foregroundColor, value: delimiterColor, range: span.openDelimiterRange)
            textStorage.addAttribute(.foregroundColor, value: delimiterColor, range: span.closeDelimiterRange)
            textStorage.addAttribute(.font, value: codeFont, range: span.openDelimiterRange)
            textStorage.addAttribute(.font, value: codeFont, range: span.closeDelimiterRange)

            // Style content with monospaced font.
            if span.contentRange.length > 0 {
                textStorage.addAttribute(.font, value: codeFont, range: span.contentRange)
            }

            // For blocks, apply monospaced font to all visible characters
            // (but NOT newlines — changing font on newlines alters line height).
            if span.kind == .block {
                let nsText = textStorage.string as NSString
                var loc = span.fullRange.location
                let end = NSMaxRange(span.fullRange)
                while loc < end {
                    let lineRange = nsText.lineRange(for: NSRange(location: loc, length: 0))
                    // Apply font to the line content (excluding trailing newline).
                    var lineContentEnd = NSMaxRange(lineRange)
                    if lineContentEnd > loc && lineContentEnd <= nsText.length {
                        let lastChar = nsText.character(at: lineContentEnd - 1)
                        if lastChar == 0x0A || lastChar == 0x0D {
                            lineContentEnd -= 1
                        }
                    }
                    let clippedStart = max(loc, span.fullRange.location)
                    let clippedEnd = min(lineContentEnd, end)
                    if clippedEnd > clippedStart {
                        textStorage.addAttribute(.font, value: codeFont, range: NSRange(location: clippedStart, length: clippedEnd - clippedStart))
                    }
                    loc = NSMaxRange(lineRange)
                }
            }

            // Background is drawn by ListBulletLayoutManager, not via .backgroundColor.
        }
        textStorage.endEditing()
    }
}
