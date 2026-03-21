import Foundation

enum SmartListAction {
    case enter
    case backspace
    case indent
    case unindent
    case moveLineUp
    case moveLineDown
}

struct SmartListEdit {
    let handled: Bool
    let replacementRange: NSRange
    let replacement: String
    let selection: NSRange
}

enum SmartListEditing {
    static let indentUnit = "    "
    static let listMarker = "- "

    /// Decompose a line into its indent whitespace count, whether it has a `- ` marker, and the body text.
    static func lineComponents(_ line: String) -> (indent: Int, hasMarker: Bool, body: String) {
        let indent = normalizedIndentCount(line)
        let rest = String(line.dropFirst(indent))
        let hasMarker = rest.hasPrefix(listMarker)
        let body = hasMarker ? String(rest.dropFirst(listMarker.count)) : rest
        return (indent, hasMarker, body)
    }

    static func makeEdit(text: String, selection: NSRange, action: SmartListAction) -> SmartListEdit {
        let nsText = text as NSString
        switch action {
        case .enter:
            return makeEnterEdit(nsText: nsText, selection: selection)
        case .backspace:
            return makeBackspaceEdit(nsText: nsText, selection: selection)
        case .indent:
            return makeIndentEdit(nsText: nsText, selection: selection)
        case .unindent:
            return makeUnindentEdit(nsText: nsText, selection: selection)
        case .moveLineUp:
            return makeMoveLineUpEdit(nsText: nsText, selection: selection)
        case .moveLineDown:
            return makeMoveLineDownEdit(nsText: nsText, selection: selection)
        }
    }

    private static func makeEnterEdit(nsText: NSString, selection: NSRange) -> SmartListEdit {
        guard selection.length == 0 else {
            return unhandled(selection: selection)
        }

        let caret = min(selection.location, nsText.length)
        let lineRange: NSRange
        let rawLine: String
        if caret == nsText.length, nsText.length > 0 {
            let lastChar = nsText.character(at: nsText.length - 1)
            if lastChar == 10 || lastChar == 13 {
                lineRange = NSRange(location: caret, length: 0)
                rawLine = ""
            } else {
                lineRange = nsText.lineRange(for: NSRange(location: caret - 1, length: 0))
                rawLine = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)
            }
        } else {
            let probe = max(0, min(caret, max(nsText.length - 1, 0)))
            lineRange = nsText.lineRange(for: NSRange(location: probe, length: 0))
            rawLine = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)
        }

        let (leadingSpaces, hasMarker, body) = lineComponents(rawLine)
        let indent = String(repeating: " ", count: leadingSpaces)

        // Empty list item (e.g. "    - ") or empty indented line: clear indent+marker
        if body.isEmpty, (leadingSpaces > 0 || hasMarker) {
            let lineContentRange = contentRangeOfLine(in: nsText, lineRange: lineRange)
            return SmartListEdit(
                handled: true,
                replacementRange: lineContentRange,
                replacement: "",
                selection: NSRange(location: lineContentRange.location, length: 0)
            )
        }

        if !body.isEmpty || hasMarker {
            let prefix = hasMarker ? indent + listMarker : indent
            let insertion = "\n" + prefix
            return SmartListEdit(
                handled: true,
                replacementRange: NSRange(location: caret, length: 0),
                replacement: insertion,
                selection: NSRange(location: caret + insertion.count, length: 0)
            )
        }

        return SmartListEdit(
            handled: true,
            replacementRange: NSRange(location: caret, length: 0),
            replacement: "\n",
            selection: NSRange(location: caret + 1, length: 0)
        )
    }

    private static func makeBackspaceEdit(nsText: NSString, selection: NSRange) -> SmartListEdit {
        guard selection.length == 0, nsText.length > 0 else {
            return unhandled(selection: selection)
        }

        let caret = min(selection.location, nsText.length)
        let probe = max(0, min(caret, max(nsText.length - 1, 0)))
        let lineRange = nsText.lineRange(for: NSRange(location: probe, length: 0))
        let line = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)
        let (indent, hasMarker, _) = lineComponents(line)
        let zoneWidth = indent + (hasMarker ? listMarker.count : 0)
        let offsetInLine = max(0, caret - lineRange.location)

        if offsetInLine > 0, offsetInLine <= zoneWidth {
            return SmartListEdit(
                handled: true,
                replacementRange: NSRange(location: lineRange.location, length: zoneWidth),
                replacement: "",
                selection: NSRange(location: lineRange.location, length: 0)
            )
        }

        return unhandled(selection: selection)
    }

    private static func makeIndentEdit(nsText: NSString, selection: NSRange) -> SmartListEdit {
        if selection.length == 0,
           let emptyLineEdit = makeEmptyLineIndentEditIfApplicable(nsText: nsText, selection: selection) {
            return emptyLineEdit
        }

        guard let target = selectedLineTargetRange(in: nsText, selection: selection) else {
            return unhandled(selection: selection)
        }

        var firstLineDelta = 0
        var totalDelta = 0
        let replacement = target.lines.enumerated().map { index, line -> String in
            if target.syntheticTrailingEmptyLine && index == target.lines.count - 1 {
                return line
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                let existingIndent = normalizedIndentCount(line)
                let newIndent = existingIndent + indentUnit.count
                let result = String(repeating: " ", count: newIndent) + listMarker
                let delta = result.count - line.count
                if index == 0 { firstLineDelta = delta }
                totalDelta += delta
                return result
            }

            let (indent, hasMarker, body) = lineComponents(line)
            let result: String
            if !hasMarker {
                // First indent: just add marker, no spaces yet
                result = listMarker + body
            } else {
                // Already has marker: add indent level
                let newIndent = indent + indentUnit.count
                result = String(repeating: " ", count: newIndent) + listMarker + body
            }
            let delta = result.count - line.count
            if index == 0 { firstLineDelta = delta }
            totalDelta += delta
            return result
        }.joined(separator: "\n")

        let fullText = nsText.replacingCharacters(in: target.range, with: replacement) as NSString
        let newLength = selection.length == 0 ? 0 : selection.length + totalDelta
        let newLocation = min(selection.location + firstLineDelta, fullText.length)

        return SmartListEdit(
            handled: true,
            replacementRange: target.range,
            replacement: replacement,
            selection: NSRange(location: newLocation, length: min(newLength, max(0, fullText.length - newLocation)))
        )
    }

    private static func makeEmptyLineIndentEditIfApplicable(nsText: NSString, selection: NSRange) -> SmartListEdit? {
        let caret = min(selection.location, nsText.length)
        let lineRange: NSRange
        if nsText.length == 0 {
            lineRange = NSRange(location: 0, length: 0)
        } else if caret == nsText.length {
            let lastChar = nsText.character(at: nsText.length - 1)
            if lastChar == 10 || lastChar == 13 {
                lineRange = NSRange(location: caret, length: 0)
            } else {
                lineRange = nsText.lineRange(for: NSRange(location: caret - 1, length: 0))
            }
        } else {
            lineRange = nsText.lineRange(for: NSRange(location: caret, length: 0))
        }

        let contentRange = contentRangeOfLine(in: nsText, lineRange: lineRange)
        let rawLine = nsText.substring(with: contentRange)
        guard rawLine.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }

        let replacement: String
        if let previous = previousLineContentRange(in: nsText, currentLineStart: lineRange.location) {
            let previousLine = nsText.substring(with: previous)
            if !previousLine.trimmingCharacters(in: .whitespaces).isEmpty {
                let (prevIndent, prevHasMarker, _) = lineComponents(previousLine)
                if !prevHasMarker {
                    replacement = listMarker
                } else {
                    replacement = String(repeating: " ", count: prevIndent + indentUnit.count) + listMarker
                }
            } else {
                replacement = listMarker
            }
        } else {
            replacement = listMarker
        }

        return SmartListEdit(
            handled: true,
            replacementRange: contentRange,
            replacement: replacement,
            selection: NSRange(location: contentRange.location + replacement.count, length: 0)
        )
    }

    private static func makeUnindentEdit(nsText: NSString, selection: NSRange) -> SmartListEdit {
        guard let target = selectedLineTargetRange(in: nsText, selection: selection) else {
            return unhandled(selection: selection)
        }

        var removedFromFirst = 0
        var removedTotal = 0
        let replacement = target.lines.enumerated().map { index, line -> String in
            if target.syntheticTrailingEmptyLine && index == target.lines.count - 1 {
                return line
            }

            guard !line.isEmpty else { return line }
            let (indent, hasMarker, body) = lineComponents(line)
            if indent == 0 && hasMarker {
                // Depth 0 with marker: remove marker
                let removed = listMarker.count
                if index == 0 { removedFromFirst = removed }
                removedTotal += removed
                return body
            }
            let removedSpaces = min(indentUnit.count, indent)
            let newIndent = indent - removedSpaces
            let removed = removedSpaces
            if index == 0 { removedFromFirst = removed }
            removedTotal += removed
            return String(repeating: " ", count: newIndent) + (hasMarker ? listMarker : "") + body
        }.joined(separator: "\n")

        let fullText = nsText.replacingCharacters(in: target.range, with: replacement) as NSString
        let newLocation = min(max(target.range.location, selection.location - removedFromFirst), fullText.length)
        let newLength = min(max(0, selection.length - removedTotal), max(0, fullText.length - newLocation))

        return SmartListEdit(
            handled: true,
            replacementRange: target.range,
            replacement: replacement,
            selection: NSRange(location: newLocation, length: newLength)
        )
    }

    private static func makeMoveLineUpEdit(nsText: NSString, selection: NSRange) -> SmartListEdit {
        guard let target = selectedLineTargetRange(in: nsText, selection: selection) else {
            return unhandled(selection: selection)
        }
        let text = nsText as String
        let (allLines, trailingNewline) = splitLines(in: text)
        let realLineCount = trailingNewline ? max(0, allLines.count - 1) : allLines.count
        guard realLineCount > 0 else {
            return unhandled(selection: selection)
        }

        let movedLineCount = target.syntheticTrailingEmptyLine ? max(0, target.lines.count - 1) : target.lines.count
        guard movedLineCount > 0 else {
            return unhandled(selection: selection)
        }

        let startLine = lineIndex(atLocation: target.range.location, in: nsText)
        let endLine = startLine + movedLineCount - 1
        guard startLine > 0, endLine < realLineCount else {
            return unhandled(selection: selection)
        }

        var lines = Array(allLines.prefix(realLineCount))
        let moved = Array(lines[startLine...endLine])
        lines.removeSubrange(startLine...endLine)
        lines.insert(contentsOf: moved, at: startLine - 1)

        let replacement = rebuiltText(fromRealLines: lines, trailingNewline: trailingNewline)
        let replacementRange = NSRange(location: 0, length: nsText.length)
        let replacementText = replacement as NSString
        let newLineStarts = lineStartOffsets(for: lines)
        let newStartLocation = newLineStarts[startLine - 1]
        let delta = newStartLocation - target.range.location
        let newLocation = min(max(0, selection.location + delta), replacementText.length)
        let newLength = min(max(0, selection.length), max(0, replacementText.length - newLocation))
        return SmartListEdit(
            handled: true,
            replacementRange: replacementRange,
            replacement: replacement,
            selection: NSRange(location: newLocation, length: newLength)
        )
    }

    private static func makeMoveLineDownEdit(nsText: NSString, selection: NSRange) -> SmartListEdit {
        guard let target = selectedLineTargetRange(in: nsText, selection: selection) else {
            return unhandled(selection: selection)
        }
        let text = nsText as String
        let (allLines, trailingNewline) = splitLines(in: text)
        let realLineCount = trailingNewline ? max(0, allLines.count - 1) : allLines.count
        guard realLineCount > 0 else {
            return unhandled(selection: selection)
        }

        let movedLineCount = target.syntheticTrailingEmptyLine ? max(0, target.lines.count - 1) : target.lines.count
        guard movedLineCount > 0 else {
            return unhandled(selection: selection)
        }

        let startLine = lineIndex(atLocation: target.range.location, in: nsText)
        let endLine = startLine + movedLineCount - 1
        guard endLine < realLineCount - 1 else {
            return unhandled(selection: selection)
        }

        var lines = Array(allLines.prefix(realLineCount))
        let moved = Array(lines[startLine...endLine])
        lines.removeSubrange(startLine...endLine)
        lines.insert(contentsOf: moved, at: startLine + 1)

        let replacement = rebuiltText(fromRealLines: lines, trailingNewline: trailingNewline)
        let replacementRange = NSRange(location: 0, length: nsText.length)
        let replacementText = replacement as NSString
        let newLineStarts = lineStartOffsets(for: lines)
        let newStartLocation = newLineStarts[startLine + 1]
        let delta = newStartLocation - target.range.location
        let newLocation = min(max(0, selection.location + delta), replacementText.length)
        let newLength = min(max(0, selection.length), max(0, replacementText.length - newLocation))
        return SmartListEdit(
            handled: true,
            replacementRange: replacementRange,
            replacement: replacement,
            selection: NSRange(location: newLocation, length: newLength)
        )
    }

    /// Returns the range covering the current line and all following lines that are
    /// deeper (subitems). Empty lines between subitems are included. Stops at the
    /// first non-empty line with depth ≤ the current line's depth.
    static func subitemRange(in text: NSString, caretLocation: Int) -> NSRange {
        guard text.length > 0 else {
            return NSRange(location: 0, length: 0)
        }

        let safeCaret = min(max(0, caretLocation), max(0, text.length - 1))
        let currentLineRange = text.lineRange(for: NSRange(location: safeCaret, length: 0))
        let currentContent = text.substring(with: currentLineRange).trimmingCharacters(in: .newlines)
        let currentDepth = normalizedIndentCount(currentContent) / indentUnit.count

        var end = currentLineRange.location + currentLineRange.length

        while end < text.length {
            let nextLineRange = text.lineRange(for: NSRange(location: end, length: 0))
            let nextContent = text.substring(with: nextLineRange).trimmingCharacters(in: .newlines)

            if nextContent.trimmingCharacters(in: .whitespaces).isEmpty {
                // Empty line — include tentatively, but only if there are deeper lines after
                end = nextLineRange.location + nextLineRange.length
                continue
            }

            let nextDepth = normalizedIndentCount(nextContent) / indentUnit.count
            if nextDepth <= currentDepth {
                break
            }

            end = nextLineRange.location + nextLineRange.length
        }

        // Trim trailing empty lines: walk backwards from `end` to exclude empty lines
        // that were speculatively included but not followed by deeper content.
        while end > currentLineRange.location + currentLineRange.length {
            // Look at the line just before `end`
            let probe = end - 1
            let lineRange = text.lineRange(for: NSRange(location: probe, length: 0))
            let content = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                end = lineRange.location
            } else {
                break
            }
        }

        return NSRange(location: currentLineRange.location, length: end - currentLineRange.location)
    }

    private static func unhandled(selection: NSRange) -> SmartListEdit {
        SmartListEdit(handled: false, replacementRange: NSRange(location: 0, length: 0), replacement: "", selection: selection)
    }

    private static func selectedLineTargetRange(in text: NSString, selection: NSRange) -> (range: NSRange, lines: [String], lineStarts: [Int], syntheticTrailingEmptyLine: Bool)? {
        let length = text.length
        if length == 0 {
            return (NSRange(location: 0, length: 0), [""], [0], false)
        }

        let start = min(selection.location, length - 1)
        let startLine = text.lineRange(for: NSRange(location: start, length: 0))
        let endProbe: Int
        if selection.length == 0 {
            endProbe = start
        } else {
            let raw = selection.location + selection.length - 1
            endProbe = min(max(raw, 0), length - 1)
        }

        let endLine = text.lineRange(for: NSRange(location: endProbe, length: 0))
        let targetRange = NSRange(location: startLine.location, length: (endLine.location + endLine.length) - startLine.location)
        let targetText = text.substring(with: targetRange)
        let lines = targetText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hasTrailingNewline = targetText.hasSuffix("\n") || targetText.hasSuffix("\r")
        let syntheticTrailingEmptyLine = hasTrailingNewline && lines.last == ""

        var lineStarts: [Int] = []
        lineStarts.reserveCapacity(lines.count)
        var location = targetRange.location
        for (index, line) in lines.enumerated() {
            lineStarts.append(location)
            location += line.count
            if index < lines.count - 1 {
                location += 1
            }
        }

        return (targetRange, lines, lineStarts, syntheticTrailingEmptyLine)
    }

    private static func contentRangeOfLine(in text: NSString, lineRange: NSRange) -> NSRange {
        var length = lineRange.length
        while length > 0 {
            let char = text.character(at: lineRange.location + length - 1)
            if char == 10 || char == 13 {
                length -= 1
            } else {
                break
            }
        }
        return NSRange(location: lineRange.location, length: length)
    }

    private static func previousLineContentRange(in text: NSString, currentLineStart: Int) -> NSRange? {
        guard currentLineStart > 0, text.length > 0 else {
            return nil
        }
        let probe = currentLineStart - 1
        let previousLineRange = text.lineRange(for: NSRange(location: probe, length: 0))
        return contentRangeOfLine(in: text, lineRange: previousLineRange)
    }

    static func normalizedIndentCount(_ line: String) -> Int {
        let spaces = line.prefix { $0 == " " }.count
        return (spaces / indentUnit.count) * indentUnit.count
    }

    private static func splitLines(in text: String) -> (lines: [String], trailingNewline: Bool) {
        let trailingNewline = text.hasSuffix("\n")
        return (text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), trailingNewline)
    }

    private static func rebuiltText(fromRealLines lines: [String], trailingNewline: Bool) -> String {
        let core = lines.joined(separator: "\n")
        return trailingNewline ? core + "\n" : core
    }

    private static func lineStartOffsets(for lines: [String]) -> [Int] {
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        var location = 0
        for (index, line) in lines.enumerated() {
            starts.append(location)
            location += line.count
            if index < lines.count - 1 {
                location += 1
            }
        }
        return starts
    }

    private static func lineIndex(atLocation location: Int, in text: NSString) -> Int {
        guard text.length > 0 else { return 0 }
        let safeLocation = min(max(0, location), text.length)
        if safeLocation == 0 {
            return 0
        }
        let prefix = text.substring(with: NSRange(location: 0, length: safeLocation))
        return prefix.reduce(into: 0) { count, character in
            if character == "\n" {
                count += 1
            }
        }
    }
}
