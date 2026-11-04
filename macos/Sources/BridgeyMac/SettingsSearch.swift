import Foundation

/// One searchable row, its text already in the app's language. `title` is the row's own name; the other fields
/// only help find it. `keywords` are hand-written synonyms in English and Russian.
struct SearchDoc: Equatable {
    var title: String
    var subtitle: String?
    var section: String?
    var page: String?
    var keywords: [String] = []
}

/// A match: the row's index in the list searched, its score, and the character ranges to mark in its title and
/// subtitle (offsets in `Character`s of the original text).
struct SearchHit: Equatable {
    let index: Int
    let score: Int
    let titleRanges: [Range<Int>]
    let subtitleRanges: [Range<Int>]
}

/// Settings search: the same rules as Android (SettingsSearch.kt). Text is folded (case, accents, ё as е,
/// punctuation as spaces); every word typed must match some field of a row. Within a word: whole word, then word
/// start, then anywhere, then one typo (in a whole word, then in a word's start), the row's title always counting
/// more than its other fields. The whole query earns one bonus on top (the title itself, a title that starts with
/// it, a synonym). Pure, so the unit tests pin it.
enum SettingsSearch {
    private static let titleWord = 140
    private static let titlePrefix = 100
    private static let titleSubstring = 40
    private static let titleTypo = 24
    private static let otherWord = 90
    private static let otherPrefix = 70
    private static let otherSubstring = 30
    private static let otherTypo = 20

    /// One character folded to one character, so positions in the folded text match the original.
    private static func foldCharacter(_ character: Character) -> Character {
        let lower = String(character).lowercased()
        guard let base = lower.decomposedStringWithCanonicalMapping.unicodeScalars.first else { return " " }
        if base == "ё" { return "е" }
        return CharacterSet.alphanumerics.contains(base) ? Character(base) : " "
    }

    /// Folded text with the original's length: lower case, no accents, ё as е, anything else a space.
    private static func foldAligned(_ text: String) -> [Character] { text.map(foldCharacter) }

    /// Folded text with single spaces and no spaces at the ends.
    static func fold(_ text: String) -> String {
        String(foldAligned(text)).split(separator: " ").joined(separator: " ")
    }

    private struct Field {
        let text: String
        let words: [String]
        let primary: Bool

        init(_ text: String, primary: Bool) {
            self.text = text
            words = text.split(separator: " ").map(String.init)
            self.primary = primary
        }
    }

    private struct Prepared {
        let title: Field
        let others: [Field]
        let subtitle: String
        let keywords: [String]
    }

    private static func prepare(_ doc: SearchDoc) -> Prepared {
        let title = fold(doc.title)
        let subtitle = doc.subtitle.map(fold) ?? ""
        let keywords = doc.keywords.map(fold).filter { !$0.isEmpty }
        var others: [Field] = []
        if !subtitle.isEmpty { others.append(Field(subtitle, primary: false)) }
        if let section = doc.section.map(fold), !section.isEmpty { others.append(Field(section, primary: false)) }
        if let page = doc.page.map(fold), !page.isEmpty { others.append(Field(page, primary: false)) }
        others += keywords.map { Field($0, primary: false) }
        return Prepared(title: Field(title, primary: true), others: others, subtitle: subtitle, keywords: keywords)
    }

    private static func tokenScore(_ token: String, _ field: Field) -> Int {
        let word = field.primary ? titleWord : otherWord
        let prefix = field.primary ? titlePrefix : otherPrefix
        let substring = field.primary ? titleSubstring : otherSubstring
        let typo = field.primary ? titleTypo : otherTypo
        var best = 0
        for candidate in field.words {
            if candidate == token { return word }
            if candidate.hasPrefix(token) { best = max(best, prefix) }
        }
        if best > 0 { return best }
        if token.count >= 2, field.text.contains(token) { return substring }
        if token.count >= 4, token.contains(where: { !$0.isNumber }) {
            if field.words.contains(where: { isTypo(token, $0) }) { return typo }
            // A typo in a word still being typed is weaker evidence than one in a whole word.
            if field.words.contains(where: { $0.count > token.count && isTypo(token, String($0.prefix(token.count))) }) { return typo / 2 }
        }
        return 0
    }

    /// One insertion, deletion, substitution or swap of neighbours; the first letter stays unless it was swapped.
    static func isTypo(_ token: String, _ word: String) -> Bool {
        if token == word { return false }
        if osaDistance(token, word) != 1 { return false }
        let a = Array(token), b = Array(word)
        if a.count == b.count, a.count >= 2 {
            let diff = a.indices.filter { a[$0] != b[$0] }
            if diff.count == 2, diff[1] == diff[0] + 1, a[diff[0]] == b[diff[1]], a[diff[1]] == b[diff[0]] { return true }
        }
        return a.first == b.first
    }

    /// Optimal string alignment distance (Levenshtein plus swaps of neighbours).
    static func osaDistance(_ lhs: String, _ rhs: String) -> Int {
        if lhs == rhs { return 0 }
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { value = min(value, d[i - 2][j - 2] + 1) }
                d[i][j] = value
            }
        }
        return d[a.count][b.count]
    }

    private static func phraseBonus(_ query: String, _ p: Prepared) -> Int {
        let title = p.title.text
        if title == query { return 1200 }
        if title.hasPrefix(query) { return 900 }
        if title.contains(" " + query) { return 700 }
        if p.keywords.contains(query) { return 600 }
        if p.keywords.contains(where: { $0.hasPrefix(query) }) { return 500 }
        if p.subtitle.contains(query) { return 200 }
        return 0
    }

    /// The score of a row for an already folded query, or nil when a word of it matches nothing.
    private static func score(_ query: String, _ tokens: [String], _ p: Prepared) -> Int? {
        var total = 0
        for token in tokens {
            let best = max(tokenScore(token, p.title), p.others.map { tokenScore(token, $0) }.max() ?? 0)
            if best == 0 { return nil }
            total += best
        }
        return total + phraseBonus(query, p)
    }

    /// The rows matching `query`, best first; equal scores keep the order of `docs`. An empty query finds nothing.
    static func search(_ query: String, in docs: [SearchDoc]) -> [SearchHit] {
        let folded = fold(query)
        guard !folded.isEmpty else { return [] }
        let tokens = folded.split(separator: " ").map(String.init)
        return docs.enumerated().compactMap { index, doc -> SearchHit? in
            guard let value = score(folded, tokens, prepare(doc)) else { return nil }
            return SearchHit(index: index, score: value, titleRanges: highlight(doc.title, query: query),
                             subtitleRanges: doc.subtitle.map { highlight($0, query: query) } ?? [])
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
    }

    /// Where each typed word literally appears in `text`: its first match at a word start, else its first match
    /// anywhere. Words that only matched with a typo mark nothing; a guess has no honest range.
    static func highlight(_ text: String, query: String) -> [Range<Int>] {
        let folded = foldAligned(text)
        var ranges: [Range<Int>] = []
        for token in fold(query).split(separator: " ").map(Array.init) where !token.isEmpty {
            guard token.count <= folded.count else { continue }
            var start: Int?
            var anywhere: Int?
            for offset in 0...(folded.count - token.count) where Array(folded[offset..<(offset + token.count)]) == token {
                if anywhere == nil { anywhere = offset }
                if offset == 0 || folded[offset - 1] == " " {
                    start = offset
                    break
                }
            }
            if let found = start ?? anywhere { ranges.append(found..<(found + token.count)) }
        }
        return merge(ranges)
    }

    private static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, range.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }

    /// For "No results": the `count` rows whose title, a title word or a synonym is the fewest edits away from the
    /// query. Always offers `count` rows when there are that many.
    static func closest(_ query: String, in docs: [SearchDoc], count: Int = 3) -> [Int] {
        let q = fold(query)
        guard !q.isEmpty else { return [] }
        let ranked = docs.enumerated().map { index, doc -> (Int, Int) in
            let p = prepare(doc)
            var candidates = [p.title.text] + p.title.words
            for keyword in p.keywords { candidates.append(keyword); candidates += keyword.split(separator: " ").map(String.init) }
            let distance = candidates.filter { !$0.isEmpty }.map { osaDistance(q, $0) }.min() ?? Int.max
            return (index, distance)
        }
        .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
        var seen = Set<String>()
        var out: [Int] = []
        for (index, _) in ranked where seen.insert(docs[index].title).inserted {
            out.append(index)
            if out.count == count { break }
        }
        return out
    }
}
