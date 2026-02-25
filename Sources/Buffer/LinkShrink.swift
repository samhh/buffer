import Foundation

struct ShrunkLinkSpan: Equatable {
    let range: NSRange
    let urlString: String
    let displayText: String

    func contains(characterIndex: Int) -> Bool {
        characterIndex >= range.location && characterIndex < (range.location + range.length)
    }

    func intersects(_ selection: NSRange) -> Bool {
        if selection.location == NSNotFound {
            return false
        }
        if selection.length == 0 {
            return contains(characterIndex: selection.location)
        }
        return NSIntersectionRange(range, selection).length > 0
    }
}

enum LinkShrink {
    private static let detector: NSDataDetector? = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let shortURLThreshold = 36
    private static let fallbackMaxLength = 34
    private static let fallbackHeadLength = 16
    private static let fallbackTailLength = 12

    static func detectLinks(in text: NSString) -> [ShrunkLinkSpan] {
        guard text.length > 0, let detector else {
            return []
        }

        let fullRange = NSRange(location: 0, length: text.length)
        let matches = detector.matches(in: text as String, options: [], range: fullRange)
        var spans: [ShrunkLinkSpan] = []
        spans.reserveCapacity(matches.count)

        for match in matches {
            guard match.resultType == .link,
                  match.range.location != NSNotFound,
                  match.range.length > 0,
                  NSMaxRange(match.range) <= text.length else {
                continue
            }

            guard let adjustedRange = trimmedRange(from: match.range, in: text) else {
                continue
            }
            let normalizedURLString = text.substring(with: adjustedRange)
            guard !normalizedURLString.isEmpty else {
                continue
            }

            spans.append(
                ShrunkLinkSpan(
                    range: adjustedRange,
                    urlString: normalizedURLString,
                    displayText: displayText(for: normalizedURLString)
                )
            )
        }

        return spans.sorted { lhs, rhs in
            lhs.range.location < rhs.range.location
        }
    }

    static func displayText(for urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return urlString }

        if let components = URLComponents(string: trimmed) {
            let scheme = components.scheme
            let schemeLower = scheme?.lowercased()
            let isHTTPS = schemeLower == "https"
            let host = components.host.map { isHTTPS ? normalizedPreviewHost($0) : $0 }
            let pathSegments = components.path
                .split(separator: "/")
                .map(String.init)
                .filter { !$0.isEmpty }
            let pathTail = pathSegments.last
            let queryTail = queryTailText(from: components)

            if let host, !host.isEmpty {
                guard trimmed.count > shortURLThreshold || host != components.host else {
                    return trimmed
                }
                let prefix: String
                if isHTTPS {
                    prefix = ""
                } else if let scheme, !scheme.isEmpty {
                    prefix = "\(scheme)://"
                } else {
                    prefix = ""
                }
                if let pathTail, !pathTail.isEmpty {
                    return "\(prefix)\(host)/.../\(pathTail)"
                }
                if let queryTail, !queryTail.isEmpty {
                    return "\(prefix)\(host)/...?\(queryTail)"
                }
                return prefix + host
            }

            if let scheme = components.scheme, !scheme.isEmpty {
                guard trimmed.count > shortURLThreshold else {
                    return trimmed
                }
                if let pathTail, !pathTail.isEmpty {
                    return "\(scheme):.../\(pathTail)"
                }
                if let queryTail, !queryTail.isEmpty {
                    return "\(scheme):...?\(queryTail)"
                }
                return scheme + ":"
            }
        }

        guard trimmed.count > shortURLThreshold else { return trimmed }
        return middleEllipsis(trimmed)
    }

    static func activeLinkRange(in spans: [ShrunkLinkSpan], selection: NSRange) -> NSRange? {
        spans.first(where: { $0.intersects(selection) })?.range
    }

    static func activeLinkRanges(in spans: [ShrunkLinkSpan], selection: NSRange) -> [NSRange] {
        guard selection.location != NSNotFound else {
            return []
        }
        if selection.length == 0 {
            guard let activeRange = activeLinkRange(in: spans, selection: selection) else {
                return []
            }
            return [activeRange]
        }
        return spans
            .filter { $0.intersects(selection) }
            .map(\.range)
    }

    static func span(containing characterIndex: Int, in spans: [ShrunkLinkSpan]) -> ShrunkLinkSpan? {
        spans.first(where: { $0.contains(characterIndex: characterIndex) })
    }

    private static func trimmedRange(from range: NSRange, in text: NSString) -> NSRange? {
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= text.length else {
            return nil
        }

        let whitespace = CharacterSet.whitespacesAndNewlines
        var lower = range.location
        var upper = NSMaxRange(range)

        while lower < upper {
            guard let scalar = UnicodeScalar(text.character(at: lower)), whitespace.contains(scalar) else {
                break
            }
            _ = scalar
            lower += 1
        }

        while upper > lower {
            guard let scalar = UnicodeScalar(text.character(at: upper - 1)), whitespace.contains(scalar) else {
                break
            }
            _ = scalar
            upper -= 1
        }

        let length = upper - lower
        guard length > 0 else {
            return nil
        }
        return NSRange(location: lower, length: length)
    }

    private static func queryTailText(from components: URLComponents) -> String? {
        if let items = components.queryItems, !items.isEmpty {
            let item = items[items.count - 1]
            if let value = item.value, !value.isEmpty {
                return "\(item.name)=\(value)"
            }
            return item.name
        }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            return String(query.suffix(12))
        }
        if let fragment = components.fragment, !fragment.isEmpty {
            return "#" + fragment
        }
        return nil
    }

    private static func normalizedPreviewHost(_ host: String) -> String {
        guard host.count > 4, host.lowercased().hasPrefix("www.") else {
            return host
        }
        let remainder = String(host.dropFirst(4))
        // Only collapse "www." for simple hosts like "www.example.com".
        // Preserve it for deeper subdomains such as "www.foo.example.com".
        let dotCount = remainder.reduce(into: 0) { count, character in
            if character == "." {
                count += 1
            }
        }
        guard dotCount == 1 else {
            return host
        }
        return remainder
    }

    private static func middleEllipsis(_ text: String) -> String {
        guard text.count > fallbackMaxLength else {
            return text
        }
        let head = String(text.prefix(fallbackHeadLength))
        let tail = String(text.suffix(fallbackTailLength))
        return "\(head)...\(tail)"
    }
}
