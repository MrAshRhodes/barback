import Foundation

/// How well a quick-search query matches an item. Lower is better.
public enum QuickSearchMatch: Int, Comparable, Sendable {
    /// A name starts with the query ("wi" in "Wi-Fi").
    case prefix = 0
    /// A word inside a name starts with the query ("fi" in "Wi-Fi", "drop" in "Google Drive — Dropbox").
    case wordPrefix = 1
    /// The query appears somewhere inside a name.
    case substring = 2

    public static func < (lhs: QuickSearchMatch, rhs: QuickSearchMatch) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Pure filtering and ranking for typing in the drop-down panel. Matching ignores case, diacritics and
/// character width, so "cafe" finds "Café" and "ÉCRAN" finds "écran".
public enum QuickSearch {
    /// Folds `text` for comparison: lower case, no diacritics, no width differences, single spaces.
    public static func normalize(_ text: String) -> String {
        let folded = text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// How `query` matches the best of `terms` (e.g. the item's title and its app's name), or nil if it doesn't.
    /// Every word of the query has to be found; the weakest word decides the rank, unless a whole name starts
    /// with the whole query.
    public static func match(query: String, terms: [String]) -> QuickSearchMatch? {
        let needle = normalize(query)
        guard !needle.isEmpty else { return .prefix }
        let fields = terms.map(normalize).filter { !$0.isEmpty }
        if fields.contains(where: { $0.hasPrefix(needle) }) { return .prefix }
        var worst = QuickSearchMatch.prefix
        for token in needle.split(separator: " ").map(String.init) {
            guard let best = fields.compactMap({ match(token: token, in: $0) }).min() else { return nil }
            worst = max(worst, best)
        }
        return worst
    }

    /// The items matching `query`, best first; equally good matches keep their original order. An empty query
    /// returns every item unchanged.
    public static func filter<T>(_ items: [T], query: String, terms: (T) -> [String]) -> [T] {
        guard !normalize(query).isEmpty else { return items }
        return items.enumerated()
            .compactMap { index, item in match(query: query, terms: terms(item)).map { (index, $0, item) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map(\.2)
    }

    /// The text a key press adds to the query, or nil for keys that don't type anything (arrows, Return, Tab,
    /// Delete, function keys, other control characters).
    public static func typedText(_ characters: String?) -> String? {
        guard let characters, !characters.isEmpty else { return nil }
        let typesText = characters.unicodeScalars.allSatisfy { scalar in
            // AppKit reports arrows and function keys in the private-use range U+F700–U+F8FF.
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }
        return typesText ? characters : nil
    }

    private static func match(token: String, in field: String) -> QuickSearchMatch? {
        if field.hasPrefix(token) { return .prefix }
        let words = field.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(token) }) { return .wordPrefix }
        if field.contains(token) { return .substring }
        // "wifi" still finds "Wi-Fi".
        let compact = String(field.filter { $0.isLetter || $0.isNumber })
        if compact.hasPrefix(token) { return .wordPrefix }
        return compact.contains(token) ? .substring : nil
    }
}

/// Moving the highlighted result with the arrow keys.
public enum QuickSearchSelection {
    /// Keeps `index` on a result after the list changed: the first result when there was none, the last when the
    /// list got shorter, nil when there are no results.
    public static func clamped(_ index: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return 0 }
        return min(max(index, 0), count - 1)
    }

    /// Moves `index` by `offset`, wrapping past either end. With nothing selected, Down picks the first result and
    /// Up the last.
    public static func moved(_ index: Int?, by offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return offset >= 0 ? 0 : count - 1 }
        let next = (index + offset) % count
        return next < 0 ? next + count : next
    }
}
