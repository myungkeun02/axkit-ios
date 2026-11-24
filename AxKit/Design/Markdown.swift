import SwiftUI

/// Inline markdown (bold, italic, code, links) for chat bubbles. Links are shown, never opened automatically.
struct MarkdownText: View {
    var source: String
    init(_ source: String) { self.source = source }

    var body: some View {
        Text(Self.attributed(source))
    }

    /// Parsed once per text (main thread only, like every view body).
    @MainActor private static var cache: [String: AttributedString] = [:]

    @MainActor static func attributed(_ text: String) -> AttributedString {
        if let hit = cache[text] { return hit }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        if cache.count > 3000 { cache.removeAll(keepingCapacity: true) }
        cache[text] = result
        return result
    }
}

/// Block markdown for documents: headings, bullet and numbered lists, paragraphs.
struct MarkdownDocument: View {
    var source: String

    private enum Block: Hashable {
        case heading(Int, String)
        case bullet(String)
        case numbered(String, String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        for raw in source.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            // Quotes and fences are drawn as plain text; a rule line is dropped.
            if line.hasPrefix("```") || line.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil { continue }
            if let m = line.firstMatch(of: #/^>\s?(.*)$/#) { line = String(m.1) }
            if line.isEmpty { flush(); continue }
            if let match = line.firstMatch(of: #/^(#{1,4})\s+(.*)$/#) {
                flush(); result.append(.heading(match.1.count, String(match.2)))
            } else if let match = line.firstMatch(of: #/^[-*•]\s+(.*)$/#) {
                flush(); result.append(.bullet(String(match.1)))
            } else if let match = line.firstMatch(of: #/^(\d+)[.)]\s+(.*)$/#) {
                flush(); result.append(.numbered(String(match.1), String(match.2)))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(MarkdownText.attributed(text)).font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                        .padding(.top, 6)
                        .accessibilityAddTraits(.isHeader)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); Text(MarkdownText.attributed(text)) }
                case .numbered(let n, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("\(n).").monospacedDigit(); Text(MarkdownText.attributed(text)) }
                case .paragraph(let text):
                    Text(MarkdownText.attributed(text))
                }
            }
        }
        .textSelection(.enabled)
    }
}
