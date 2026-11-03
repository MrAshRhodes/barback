import Foundation

/// Commands accepted through the `barback://` URL scheme, e.g. `open -g barback://toggle`.
/// They only show or hide Barback's own sections or open Settings; no URL can change settings.
/// `barback://open?item=…` (see `BarbackURLRequest`) opens one item's own menu, which changes no settings either.
public enum BarbackURLCommand: String, CaseIterable, Sendable {
    case toggle
    case show
    case hide
    case showAll = "show-all"
    case toggleAll = "toggle-all"
    case settings

    public static let scheme = "barback"

    private static let aliases: [String: BarbackURLCommand] = [
        "reveal": .show,
        "showall": .showAll,
        "reveal-all": .showAll,
        "toggleall": .toggleAll,
        "preferences": .settings,
        "open-settings": .settings,
    ]

    /// Parses `barback://<command>` (also `barback:<command>` and `barback:///<command>`), case-insensitively.
    public static func parse(_ url: URL) -> BarbackURLCommand? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        return command(named: commandName(of: url))
    }

    /// A command or one of its aliases, given in lowercase.
    static func command(named name: String) -> BarbackURLCommand? {
        BarbackURLCommand(rawValue: name) ?? aliases[name]
    }

    /// The lowercased command part of a `barback:` URL, without its query.
    static func commandName(of url: URL) -> String {
        let name: String
        if let host = url.host, !host.isEmpty {
            name = host
        } else {
            let trimmed = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !trimmed.isEmpty {
                name = trimmed
            } else {
                // `barback:toggle` has neither host nor path on some Foundation versions.
                let s = url.absoluteString
                name = String(s.dropFirst(scheme.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
        }
        return name.lowercased().split(separator: "?").first.map(String.init) ?? ""
    }

    /// The section action this command performs, if any (`settings` has none).
    public var sectionAction: SectionAction? {
        switch self {
        case .toggle: return .toggle
        case .show: return .show
        case .hide: return .hide
        case .showAll: return .showAll
        case .toggleAll: return .toggleAll
        case .settings: return nil
        }
    }

    /// Example URL for documentation and Settings.
    public var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }
}
