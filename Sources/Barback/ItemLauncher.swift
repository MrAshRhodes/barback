import AppKit
import ApplicationServices
import BarbackCore

/// Opens one item's own menu for an item shortcut or a `barback://open` link: scans the menu bar, finds the item
/// without guessing, reveals it if it is hidden and presses it through Accessibility (no synthetic events).
@MainActor
final class ItemLauncher {
    private let items: ItemsModel
    private let opener = ItemOpener()
    /// Reveals hidden items in the menu bar (`.show`, or `.showAll` for the always-hidden section).
    var reveal: (SectionAction) -> Void = { _ in }
    var onOpeningChange: (Bool) -> Void = { _ in }
    var onConfirmedOpen: (ItemKey) -> Void = { _ in }
    private var isOpening = false {
        didSet { if oldValue != isOpening { onOpeningChange(isOpening) } }
    }

    init(items: ItemsModel) {
        self.items = items
        opener.onConfirmedOpen = { [weak self] in self?.onConfirmedOpen($0) }
    }

    /// The panel candidates, with every name a link can use for them.
    static func candidates(from rows: [MenuBarItemRow]) -> [ItemLinkCandidate] {
        rows.map { row in
            ItemLinkCandidate(
                key: row.key,
                title: row.panelTitle,
                // A system item's owner is always Control Center, which names none of them in particular.
                appName: row.item.isSystemItem ? nil : row.item.displayName,
                detail: row.item.detail
            )
        }
    }

    /// - Parameter source: for the log, e.g. "URL" or "shortcut".
    func open(_ reference: ItemReference, source: String) {
        guard AXIsProcessTrusted() else {
            Log.items.notice("\(source, privacy: .public): opening an item needs Accessibility access; nothing opened")
            return
        }
        opener.cancel()
        isOpening = false
        items.refresh { [weak self] in self?.resolveAndOpen(reference, source: source) }
    }

    func cancel() {
        opener.cancel()
        isOpening = false
    }

    private func resolveAndOpen(_ reference: ItemReference, source: String) {
        let rows = items.panelCandidates
        let described = Self.describe(reference)
        switch ItemLinkResolver.resolve(reference, among: Self.candidates(from: rows)) {
        case .notFound:
            Log.items.notice("\(source, privacy: .public): no menu bar item matches \(described, privacy: .public); nothing opened")
        case .ambiguous(let keys):
            let names = keys.map(\.linkIdentifier).joined(separator: ", ")
            Log.items.notice("\(source, privacy: .public): \(described, privacy: .public) matches \(keys.count) items (\(names, privacy: .public)); nothing opened. Use barback://open?item=<key> instead.")
        case .found(let key):
            guard let row = rows.first(where: { $0.key == key }) else { return }
            Log.items.info("\(source, privacy: .public): opening \(key.linkIdentifier, privacy: .public)")
            if row.visibility != .shown { reveal(row.section == .alwaysHidden ? .showAll : .show) }
            isOpening = true
            opener.open(key: key, display: row.display) { [weak self] _ in
                self?.isOpening = false
            }
        }
    }

    private static func describe(_ reference: ItemReference) -> String {
        switch reference {
        case .key(let key): return "item \"\(key.linkIdentifier)\""
        case .name(let name): return "name \"\(name)\""
        }
    }
}
