import Foundation

/// Finding documents the way people type in Korean: spaces and case ignored, part of a word is enough,
/// marks like / · - too, and a query of initial consonants only ("ㄱㅈ") matches by first sounds ("결제").
public enum KoreanSearch {
    static let initials: [Character] = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")

    /// Lowercased letters and digits only (spaces and marks like / · - are ignored).
    public static func normalize(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// "결제 화면" → "ㄱㅈㅎㅁ" (other characters kept as they are, spaces dropped).
    public static func initialSounds(_ text: String) -> String {
        var out = ""
        for scalar in normalize(text).unicodeScalars {
            if (0xAC00...0xD7A3).contains(scalar.value) {
                out.append(initials[Int((scalar.value - 0xAC00) / 588)])
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    public static func isInitialsOnly(_ query: String) -> Bool {
        let q = normalize(query)
        return !q.isEmpty && q.allSatisfy { initials.contains($0) }
    }

    public static func matches(_ text: String, _ query: String) -> Bool {
        let q = normalize(query)
        guard !q.isEmpty else { return true }
        if isInitialsOnly(q) { return initialSounds(text).contains(q) }
        return normalize(text).contains(q)
    }

    /// Where the query sits in `text` (ignoring spaces), as a range of the original text — for highlighting.
    public static func range(in text: String, of query: String) -> Range<String.Index>? {
        let q = normalize(query)
        guard !q.isEmpty else { return nil }
        let initialsOnly = isInitialsOnly(q)
        // Map each kept character back to its index in `text`.
        var kept: [(Character, String.Index)] = []
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch.isLetter || ch.isNumber {
                var key = Character(String(ch).lowercased())
                if initialsOnly, let s = ch.unicodeScalars.first, (0xAC00...0xD7A3).contains(s.value) {
                    key = initials[Int((s.value - 0xAC00) / 588)]
                }
                kept.append((key, i))
            }
            i = text.index(after: i)
        }
        let needle = Array(q)
        guard needle.count <= kept.count else { return nil }
        for start in 0...(kept.count - needle.count) where (0..<needle.count).allSatisfy({ kept[start + $0].0 == needle[$0] }) {
            let last = kept[start + needle.count - 1].1
            return kept[start].1..<text.index(after: last)
        }
        return nil
    }

    /// The line of a document that contains the query, trimmed around the hit — shown under a result.
    public static func snippet(_ body: String, _ query: String, width: Int = 70) -> String? {
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^[#>*\-•\s]+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "**", with: "")
            guard let r = range(in: line, of: query) else { continue }
            let before = line.distance(from: line.startIndex, to: r.lowerBound)
            if line.count <= width || before < width / 3 { return line.count > width ? String(line.prefix(width)) + "…" : line }
            let start = line.index(r.lowerBound, offsetBy: -(width / 3))
            let tail = line[start...]
            return "…" + (tail.count > width ? String(tail.prefix(width)) + "…" : String(tail))
        }
        return nil
    }
}
