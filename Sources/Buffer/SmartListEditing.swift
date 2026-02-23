import Foundation

enum SmartListAction {
    case enter
    case backspace
    case indent
    case unindent
}

struct SmartListEdit {
    let handled: Bool
    let replacementRange: NSRange
    let replacement: String
    let selection: NSRange
}

enum SmartListEditing {
    static let indentUnit = "  "
    static let listToken = "- "

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

        let leadingSpaces = rawLine.prefix { $0 == " " }.count
        let indent = String(repeating: " ", count: (leadingSpaces / 2) * 2)
        let body = String(rawLine.dropFirst(leadingSpaces))
        let isListLine = body == "-" || body.hasPrefix(listToken)
        let bodyContent = body == "-" ? "" : String(body.dropFirst(min(body.count, listToken.count))).trimmingCharacters(in: .whitespaces)

        if isListLine && bodyContent.isEmpty {
            let lineContentRange = contentRangeOfLine(in: nsText, lineRange: lineRange)
            return SmartListEdit(
                handled: true,
                replacementRange: lineContentRange,
                replacement: "",
                selection: NSRange(location: lineContentRange.location, length: 0)
            )
        }

        if isListLine {
            let insertion = "\n" + indent + listToken
            return SmartListEdit(
                handled: true,
                replacementRange: NSRange(location: caret, length: 0),
                replacement: insertion,
                selection: NSRange(location: caret + insertion.count, length: 0)
            )
        }

        if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
            return SmartListEdit(
                handled: true,
                replacementRange: NSRange(location: caret, length: 0),
                replacement: "\n",
                selection: NSRange(location: caret + 1, length: 0)
            )
        }

        return unhandled(selection: selection)
    }

    private static func makeBackspaceEdit(nsText: NSString, selection: NSRange) -> SmartListEdit {
        guard selection.length == 0, nsText.length > 0 else {
            return unhandled(selection: selection)
        }

        let caret = min(selection.location, nsText.length)
        let probe = max(0, min(caret, max(nsText.length - 1, 0)))
        let lineRange = nsText.lineRange(for: NSRange(location: probe, length: 0))
        let line = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)
        let leadingSpaces = line.prefix { $0 == " " }.count
        let offsetInLine = max(0, caret - lineRange.location)
        let body = String(line.dropFirst(leadingSpaces))
        let listPrefixLength: Int
        if body.hasPrefix(listToken) {
            listPrefixLength = leadingSpaces + listToken.count
        } else if body == "-" {
            listPrefixLength = leadingSpaces + 1
        } else {
            listPrefixLength = leadingSpaces
        }

        if offsetInLine > 0, offsetInLine <= listPrefixLength {
            return SmartListEdit(
                handled: true,
                replacementRange: NSRange(location: lineRange.location, length: offsetInLine),
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

        let effectiveCount = target.syntheticTrailingEmptyLine ? max(0, target.lines.count - 1) : target.lines.count
        let replacement = target.lines.enumerated().map { index, line -> String in
            if target.syntheticTrailingEmptyLine && index == target.lines.count - 1 {
                return line
            }

            let lineStart = target.lineStarts[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if hasParentCandidate(in: nsText, before: lineStart) {
                    return indentUnit + listToken
                }
                return indentUnit
            }
            return indentUnit + normalizeToMarkdownList(line)
        }.joined(separator: "\n")

        let delta = indentUnit.count
        let fullText = nsText.replacingCharacters(in: target.range, with: replacement) as NSString
        let newLength = selection.length == 0 ? 0 : selection.length + (effectiveCount * delta)
        let newLocation = min(selection.location + delta, fullText.length)

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
        if let previous = previousLineContentRange(in: nsText, currentLineRange: lineRange) {
            let previousLine = nsText.substring(with: previous)
            if let indent = listIndentIfListLine(previousLine) {
                replacement = indent + listToken
            } else {
                let currentIndent = String(repeating: " ", count: (rawLine.prefix { $0 == " " }.count / 2) * 2)
                replacement = currentIndent + listToken
            }
        } else {
            let currentIndent = String(repeating: " ", count: (rawLine.prefix { $0 == " " }.count / 2) * 2)
            replacement = currentIndent + listToken
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
            let leading = line.prefix { $0 == " " }.count
            let removed = min(2, leading)
            if index == 0 {
                removedFromFirst = removed
            }
            removedTotal += removed
            let unindented = String(line.dropFirst(removed))
            if unindented.trimmingCharacters(in: .whitespaces).isEmpty {
                return unindented
            }
            return normalizeToMarkdownList(unindented)
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

    private static func normalizeToMarkdownList(_ line: String) -> String {
        let leadingSpaces = line.prefix { $0 == " " }.count
        let indentSpaces = (leadingSpaces / 2) * 2
        let indent = String(repeating: " ", count: indentSpaces)
        let body = String(line.dropFirst(leadingSpaces))
        if body.hasPrefix(listToken) {
            return indent + body
        }
        if body == "-" {
            return indent + listToken
        }
        return indent + listToken + body
    }

    private static func listIndentIfListLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .newlines)
        let leadingSpaces = trimmed.prefix { $0 == " " }.count
        let body = String(trimmed.dropFirst(leadingSpaces))
        guard body == "-" || body.hasPrefix(listToken) else {
            return nil
        }
        let normalizedIndent = String(repeating: " ", count: (leadingSpaces / 2) * 2)
        return normalizedIndent
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

    private static func hasParentCandidate(in text: NSString, before location: Int) -> Bool {
        guard location > 0, text.length > 0 else { return false }
        var probe = min(location - 1, text.length - 1)

        while probe >= 0 {
            let lineRange = text.lineRange(for: NSRange(location: probe, length: 0))
            let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                return true
            }
            if lineRange.location == 0 {
                break
            }
            probe = lineRange.location - 1
        }

        return false
    }

    private static func previousLineContentRange(in text: NSString, currentLineRange: NSRange) -> NSRange? {
        guard currentLineRange.location > 0, text.length > 0 else {
            return nil
        }
        let probe = currentLineRange.location - 1
        let previousLineRange = text.lineRange(for: NSRange(location: probe, length: 0))
        return contentRangeOfLine(in: text, lineRange: previousLineRange)
    }
}
