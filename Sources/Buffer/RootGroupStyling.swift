import Foundation

struct ParsedIndentedLine {
    let lineIndex: Int
    let contentRange: NSRange
    let text: String
    let depth: Int
    let isEmpty: Bool
}

struct RootGroupStyle {
    let lineIndices: [Int]
    let colorIndex: Int
}

enum RootGroupStyling {
    static func parseLines(in text: NSString) -> [ParsedIndentedLine] {
        var lines: [ParsedIndentedLine] = []
        var location = 0
        var lineIndex = 0

        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let contentRange = contentRangeOfLine(in: text, lineRange: lineRange)
            let content = contentRange.length > 0 ? text.substring(with: contentRange) : ""
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            let depth = content.prefix { $0 == " " }.count / 2
            lines.append(
                ParsedIndentedLine(
                    lineIndex: lineIndex,
                    contentRange: contentRange,
                    text: content,
                    depth: depth,
                    isEmpty: trimmed.isEmpty
                )
            )
            lineIndex += 1

            let next = lineRange.location + lineRange.length
            if next <= location { break }
            location = next
        }

        return lines
    }

    static func rootGroups(from lines: [ParsedIndentedLine], paletteCount: Int) -> [RootGroupStyle] {
        guard paletteCount > 0 else { return [] }

        var groups: [RootGroupStyle] = []
        var currentRootLineIndex: Int?
        var lineIndicesByRoot: [Int: [Int]] = [:]
        var hasChildByRoot: [Int: Bool] = [:]

        for line in lines where !line.isEmpty {
            if line.depth == 0 {
                currentRootLineIndex = line.lineIndex
                lineIndicesByRoot[line.lineIndex] = [line.lineIndex]
                hasChildByRoot[line.lineIndex] = false
                continue
            }

            if let root = currentRootLineIndex {
                lineIndicesByRoot[root, default: [root]].append(line.lineIndex)
                hasChildByRoot[root] = true
            }
        }

        var ordinal = 0
        for line in lines where !line.isEmpty && line.depth == 0 {
            guard hasChildByRoot[line.lineIndex] == true else { continue }
            guard let lineIndices = lineIndicesByRoot[line.lineIndex] else { continue }
            let colorIndex = ordinal % paletteCount
            groups.append(RootGroupStyle(lineIndices: lineIndices, colorIndex: colorIndex))
            ordinal += 1
        }

        return groups
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
}
