import Foundation

struct ExtractedTextContent {
    let title: String
    let metaDescription: String?
    let bodyText: String
    let combinedText: String
    let chunks: [String]
}

enum HTMLTextExtractor {
    static func extractContent(from html: String, maxChunkSize: Int = 3500) -> ExtractedTextContent {
        let title = extractTitle(from: html)
        let metaDescription = extractMetaDescription(from: html)
        let body = extractReadableText(from: html)

        var mergedParts: [String] = []
        if !title.isEmpty && title != "Untitled Page" {
            mergedParts.append(title)
        }
        if let metaDescription, !metaDescription.isEmpty {
            mergedParts.append(metaDescription)
        }
        if !body.isEmpty {
            mergedParts.append(body)
        }

        let combined = normalizeWhitespaceKeepingParagraphs(mergedParts.joined(separator: "\n\n"))
        let chunks = chunk(text: combined, maxChunkSize: max(800, maxChunkSize))

        return ExtractedTextContent(
            title: title,
            metaDescription: metaDescription,
            bodyText: body,
            combinedText: combined,
            chunks: chunks
        )
    }

    static func extractTitle(from html: String) -> String {
        let pattern = "<title[^>]*>(.*?)</title>"
        if let match = html.firstMatch(for: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let cleaned = cleanupHTML(match)
            return cleaned.isEmpty ? "Untitled Page" : cleaned
        }
        return "Untitled Page"
    }

    static func extractMetaDescription(from html: String) -> String? {
        let pattern = "<meta[^>]*(?:name\\s*=\\s*[\"']description[\"']|property\\s*=\\s*[\"']og:description[\"'])[^>]*content\\s*=\\s*[\"'](.*?)[\"'][^>]*>"
        guard let match = html.firstMatch(for: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let cleaned = cleanupHTML(match)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func extractReadableText(from html: String) -> String {
        let stripped = removeNonContentBlocks(from: html)
        let blockPattern = "<(h[1-6]|p|li|blockquote|article|section|main|pre|td)[^>]*>(.*?)</\\1>"
        let matches = stripped.captureGroups(for: blockPattern, options: [.caseInsensitive, .dotMatchesLineSeparators], captureCount: 2)

        var lines: [String] = []
        lines.reserveCapacity(matches.count)

        for match in matches {
            guard match.count == 2 else { continue }
            let tag = match[0].lowercased()
            let payload = cleanupHTML(removeHTMLTags(from: match[1]))

            guard shouldKeepLine(payload) else { continue }
            if tag == "li" {
                lines.append("- \(payload)")
            } else {
                lines.append(payload)
            }
        }

        if lines.isEmpty {
            let fallback = cleanupHTML(removeHTMLTags(from: stripped))
            return normalizeWhitespaceKeepingParagraphs(fallback)
        }

        return normalizeWhitespaceKeepingParagraphs(lines.joined(separator: "\n\n"))
    }

    static func chunk(text: String, maxChunkSize: Int) -> [String] {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        guard normalized.count > maxChunkSize else { return [normalized] }

        var chunks: [String] = []
        var currentChunk = ""

        for paragraph in normalized.components(separatedBy: "\n\n") {
            let candidate = currentChunk.isEmpty ? paragraph : "\(currentChunk)\n\n\(paragraph)"
            if candidate.count <= maxChunkSize {
                currentChunk = candidate
                continue
            }

            if !currentChunk.isEmpty {
                chunks.append(currentChunk)
                currentChunk = ""
            }

            if paragraph.count <= maxChunkSize {
                currentChunk = paragraph
            } else {
                var start = paragraph.startIndex
                while start < paragraph.endIndex {
                    let end = paragraph.index(start, offsetBy: maxChunkSize, limitedBy: paragraph.endIndex) ?? paragraph.endIndex
                    chunks.append(String(paragraph[start..<end]))
                    start = end
                }
            }
        }

        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        return chunks
    }

    static func cleanupHTML(_ text: String) -> String {
        var result = text
        let replacements: [String: String] = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&lt;": "<",
            "&gt;": ">"
        ]
        for (key, value) in replacements {
            result = result.replacingOccurrences(of: key, with: value)
        }
        result = decodeNumericHTMLEntities(in: result)
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeNonContentBlocks(from html: String) -> String {
        var text = html
        let removalPatterns = [
            "<script\\b[^<]*(?:(?!</script>)<[^<]*)*</script>",
            "<style\\b[^<]*(?:(?!</style>)<[^<]*)*</style>",
            "<noscript\\b[^<]*(?:(?!</noscript>)<[^<]*)*</noscript>",
            "<svg\\b[^<]*(?:(?!</svg>)<[^<]*)*</svg>",
            "<iframe\\b[^<]*(?:(?!</iframe>)<[^<]*)*</iframe>",
            "<template\\b[^<]*(?:(?!</template>)<[^<]*)*</template>",
            "<!--.*?-->",
            "<(nav|footer|header|aside|form|button)\\b[^<]*(?:(?!</\\1>)<[^<]*)*</\\1>"
        ]

        for pattern in removalPatterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return text
    }

    private static func removeHTMLTags(from value: String) -> String {
        value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    private static func shouldKeepLine(_ line: String) -> Bool {
        guard line.count > 2 else { return false }
        let lower = line.lowercased()
        let noisyHints = [
            "cookie",
            "consent",
            "accept all",
            "privacy choices",
            "newsletter",
            "advertisement",
            "skip to content"
        ]

        if noisyHints.contains(where: { lower.contains($0) }) && line.count < 160 {
            return false
        }

        return true
    }

    private static func normalizeWhitespaceKeepingParagraphs(_ input: String) -> String {
        let lines = input
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.joined(separator: "\n\n")
    }

    private static func decodeNumericHTMLEntities(in text: String) -> String {
        var result = text
        let pattern = "&#(x?[0-9A-Fa-f]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).reversed()
        for match in matches {
            guard let range = Range(match.range(at: 1), in: result) else { continue }
            let rawNumber = String(result[range])
            let scalarValue: UInt32?
            if rawNumber.lowercased().hasPrefix("x") {
                scalarValue = UInt32(rawNumber.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(rawNumber, radix: 10)
            }
            guard let scalarValue, let scalar = UnicodeScalar(scalarValue),
                  let fullRange = Range(match.range(at: 0), in: result) else { continue }
            result.replaceSubrange(fullRange, with: String(scalar))
        }

        return result
    }
}

private extension String {
    func firstMatch(for pattern: String, options: NSRegularExpression.Options = []) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regex.firstMatch(in: self, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[valueRange])
    }

    func captureGroups(for pattern: String, options: NSRegularExpression.Options = [], captureCount: Int) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(startIndex..<endIndex, in: self)
        let matches = regex.matches(in: self, options: [], range: range)

        return matches.map { match in
            (1...captureCount).compactMap { index in
                guard match.numberOfRanges > index, let valueRange = Range(match.range(at: index), in: self) else { return nil }
                return String(self[valueRange])
            }
        }
    }
}
