import Foundation

/// How a `barback://open` link or an item shortcut names the item to open.
public enum ItemReference: Hashable, Sendable {
    /// A stable item key (see `ItemKey.linkIdentifier`).
    case key(ItemKey)
    /// An app or item name, e.g. "Wi-Fi" or "Dropbox", matched ignoring case, diacritics and width.
    case name(String)
}

/// Everything the `barback://` scheme accepts: the section commands, and opening one item's menu.
public enum BarbackURLRequest: Hashable, Sendable {
    case command(BarbackURLCommand)
    case open(ItemReference)

    public static let openCommand = "open"

    /// Parses any `barback://` URL. Unknown commands and `open` links without a usable item are errors, so the
    /// caller can log why nothing happened.
    public static func parse(_ url: URL) -> Result<BarbackURLRequest, BarbackURLError> {
        guard url.scheme?.lowercased() == BarbackURLCommand.scheme else { return .failure(.unsupportedScheme) }
        let name = BarbackURLCommand.commandName(of: url)
        if let command = BarbackURLCommand.command(named: name) { return .success(.command(command)) }
        guard name == openCommand else { return .failure(.unknownCommand(name)) }

        // `URLComponents` percent-decodes values; `+` stays a literal plus (use %20 for spaces).
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            ?? URLComponents(string: url.absoluteString)?.queryItems
            ?? []
        func value(_ field: String) -> String? {
            let raw = query.first { $0.name.lowercased() == field }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return raw?.isEmpty == false ? raw : nil
        }
        // A key is more precise than a name, so it wins when a link carries both.
        if let raw = value("item") {
            guard let key = ItemKey(linkIdentifier: raw) else { return .failure(.invalidItemKey(raw)) }
            return .success(.open(.key(key)))
        }
        if let name = value("name") { return .success(.open(.name(name))) }
        return .failure(.missingItem)
    }
}

public enum BarbackURLError: Error, Hashable, Sendable {
    case unsupportedScheme
    case unknownCommand(String)
    /// `barback://open` without a non-empty `item` or `name` parameter.
    case missingItem
    case invalidItemKey(String)

    /// For the log.
    public var message: String {
        switch self {
        case .unsupportedScheme: return "not a barback:// URL"
        case .unknownCommand(let name): return "unknown command \"\(name)\""
        case .missingItem: return "open needs an item=<key> or name=<name> parameter"
        case .invalidItemKey(let raw): return "\"\(raw)\" is not an item key"
        }
    }
}

extension ItemKey {
    /// The key as it appears in `barback://open?item=…`: the owner (a bundle identifier), then `/` and the item's
    /// own name when the app has several items, e.g. `com.apple.controlcenter/Wi-Fi`. Bundle identifiers can't
    /// contain `/`, so everything after the first one is the detail. Ordinals are positional and never part of a
    /// link (panel keys always have ordinal 0).
    public var linkIdentifier: String {
        guard let detail, !detail.isEmpty else { return owner }
        return "\(owner)/\(detail)"
    }

    public init?(linkIdentifier: String) {
        let trimmed = linkIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let owner = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard !owner.isEmpty else { return nil }
        let detail = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        self.init(owner: owner, detail: detail.isEmpty ? nil : detail)
    }

    /// `barback://open?item=…`, percent-encoded so any detail survives launchers and scripts.
    public var openURL: URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = linkIdentifier.addingPercentEncoding(withAllowedCharacters: allowed) ?? owner
        return URL(string: "\(BarbackURLCommand.scheme)://\(BarbackURLRequest.openCommand)?item=\(encoded)")!
    }
}

/// An item that a link or shortcut can open, with every name it can be called by.
public struct ItemLinkCandidate: Hashable, Sendable {
    public var key: ItemKey
    public var names: [String]

    public init(key: ItemKey, names: [String]) {
        self.key = key
        self.names = names
    }

    /// Names from an item's title (as the panel shows it), its app name and its own detail, plus "App — detail".
    public init(key: ItemKey, title: String?, appName: String?, detail: String?) {
        var names = [title, appName, detail].compactMap { $0 }
        if let appName, let detail, !appName.isEmpty, !detail.isEmpty, appName != detail {
            names.append("\(appName) — \(detail)")
            names.append("\(appName) - \(detail)")
        }
        self.init(key: key, names: names)
    }
}

public enum ItemLinkMatch: Hashable, Sendable {
    case found(ItemKey)
    case notFound
    /// More than one item fits; nothing is opened rather than guessing.
    case ambiguous([ItemKey])
}

/// Pure lookup of a link's item among the items currently in the menu bar.
public enum ItemLinkResolver {
    public static func resolve(_ reference: ItemReference, among candidates: [ItemLinkCandidate]) -> ItemLinkMatch {
        let unique = uniqueKeys(candidates.map(\.key))
        switch reference {
        case .key(let key):
            if unique.contains(key) { return .found(key) }
            // Tolerate a hand-written link's case or accents, but only when that still points at one item.
            let target = (normalize(key.owner), key.detail.map(normalize))
            return match(unique.filter { (normalize($0.owner), $0.detail.map(normalize)) == target })
        case .name(let name):
            let target = normalize(name)
            guard !target.isEmpty else { return .notFound }
            let keys = candidates
                .filter { $0.names.contains { normalize($0) == target } }
                .map(\.key)
            return match(uniqueKeys(keys))
        }
    }

    /// Case-, diacritic- and width-insensitive comparison form, with Unicode normalization and collapsed spaces.
    public static func normalize(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func uniqueKeys(_ keys: [ItemKey]) -> [ItemKey] {
        var seen = Set<ItemKey>()
        return keys.filter { seen.insert($0).inserted }
    }

    private static func match(_ keys: [ItemKey]) -> ItemLinkMatch {
        switch keys.count {
        case 0: return .notFound
        case 1: return .found(keys[0])
        default: return .ambiguous(keys)
        }
    }
}
