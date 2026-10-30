import CoreGraphics

/// A status-bar window reported by `CGWindowListCopyWindowInfo`. Frames are in CoreGraphics global
/// coordinates (origin top-left of the primary display); x matches AppKit's x.
public struct MenuBarItem: Identifiable, Hashable, Sendable {
    public var windowID: UInt32
    public var ownerName: String
    public var ownerPID: Int32
    /// `kCGWindowName`; usually nil without Screen Recording permission.
    public var title: String?
    public var frame: CGRect
    public var isOnScreen: Bool
    /// App name resolved by other means (e.g. Accessibility) when the window owner is a system host.
    public var resolvedName: String?
    /// Bundle identifier of the app that really owns the item, when known.
    public var bundleID: String?
    /// The item's own Accessibility title or description (e.g. "Wi-Fi"), when known.
    public var detail: String?
    /// Process that really owns the item when it differs from the window owner (system-hosted items).
    public var sourcePID: Int32?

    public var id: UInt32 { windowID }

    public init(
        windowID: UInt32,
        ownerName: String,
        ownerPID: Int32,
        title: String? = nil,
        frame: CGRect,
        isOnScreen: Bool,
        resolvedName: String? = nil,
        bundleID: String? = nil,
        detail: String? = nil,
        sourcePID: Int32? = nil
    ) {
        self.windowID = windowID
        self.ownerName = ownerName
        self.ownerPID = ownerPID
        self.title = title
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.resolvedName = resolvedName
        self.bundleID = bundleID
        self.detail = detail
        self.sourcePID = sourcePID
    }

    /// On macOS 26 every status item window is hosted by Control Center, so the owner is not the real app.
    public var isHostedBySystem: Bool { MenuBarItemParser.systemHostOwners.contains(ownerName) }

    /// Best available name for display.
    public var displayName: String {
        if let resolvedName, !resolvedName.isEmpty { return resolvedName }
        if let title, !title.isEmpty, isHostedBySystem { return title }
        return ownerName
    }

    /// True for items of the system itself, e.g. Wi-Fi or Battery, which macOS 26 hosts in Control Center.
    public var isSystemItem: Bool {
        if let bundleID { return MenuBarItemParser.systemHostBundleIDs.contains(bundleID) }
        return isHostedBySystem && sourcePID == nil
    }

    /// Short name for the drop-down panel: just "Wi-Fi" for a system item (its owner is always Control Center),
    /// "App — detail" or the app's name otherwise.
    public var panelName: String {
        if isSystemItem, let detail, !detail.isEmpty { return detail }
        return displayName
    }

    /// True if the item is drawn on any of the given screens (CG coordinates).
    public func isVisible(onScreens screens: [CGRect]) -> Bool {
        guard isOnScreen, frame.width > 0 else { return false }
        return screens.contains { $0.intersects(frame) }
    }
}

/// Pure parsing of `CGWindowListCopyWindowInfo` dictionaries.
public enum MenuBarItemParser {
    /// `kCGStatusWindowLevel`.
    public static let statusWindowLayer = 25
    /// `kCGPopUpMenuWindowLevel` — open menus (including status-item menus).
    public static let popUpMenuLayer = 101
    /// Status items are short; taller windows on the status layer are panels/popovers.
    public static let maxItemHeight: CGFloat = 60
    public static let excludedOwners: Set<String> = ["Window Server", "WindowServer"]
    public static let systemHostOwners: Set<String> = ["Control Center", "Control Centre", "SystemUIServer"]
    public static let systemHostBundleIDs: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver"]

    // Raw CGWindowList keys (kCGWindow* constants), spelled out so tests can build dictionaries directly.
    public enum Key {
        public static let number = "kCGWindowNumber"
        public static let layer = "kCGWindowLayer"
        public static let ownerName = "kCGWindowOwnerName"
        public static let ownerPID = "kCGWindowOwnerPID"
        public static let name = "kCGWindowName"
        public static let bounds = "kCGWindowBounds"
        public static let isOnScreen = "kCGWindowIsOnscreen"
    }

    /// Extracts menu bar items, skipping malformed entries, sorted left to right.
    ///
    /// - Parameter menuBarTops: y values (CG coordinates) of the top of each screen with a menu bar. When given,
    ///   only windows whose top edge sits on one of them are kept, which filters out stray status-level panels.
    public static func parse(_ windows: [[String: Any]], menuBarTops: [CGFloat]? = nil) -> [MenuBarItem] {
        var items: [MenuBarItem] = []
        items.reserveCapacity(64)
        for w in windows {
            guard let layer = integer(w[Key.layer]), layer == statusWindowLayer,
                  let number = integer(w[Key.number]), number > 0, number <= Int(UInt32.max),
                  let frame = rect(w[Key.bounds]), frame.width > 0, frame.height > 0,
                  frame.height <= maxItemHeight
            else { continue }
            let owner = (w[Key.ownerName] as? String) ?? ""
            if excludedOwners.contains(owner) { continue }
            if let tops = menuBarTops, !tops.isEmpty, !tops.contains(where: { abs($0 - frame.minY) <= 1 }) { continue }
            let pid = integer(w[Key.ownerPID]).map { Int32(truncatingIfNeeded: $0) } ?? 0
            let onScreen = bool(w[Key.isOnScreen]) ?? false
            let title = (w[Key.name] as? String).flatMap { $0.isEmpty ? nil : $0 }
            items.append(MenuBarItem(
                windowID: UInt32(number),
                ownerName: owner.isEmpty ? "Unknown" : owner,
                ownerPID: pid,
                title: title,
                frame: frame,
                isOnScreen: onScreen
            ))
        }
        return items.sorted { $0.frame.minX == $1.frame.minX ? $0.windowID < $1.windowID : $0.frame.minX < $1.frame.minX }
    }

    /// True if any on-screen pop-up menu window exists (someone has a menu open).
    public static func containsOpenMenu(_ windows: [[String: Any]]) -> Bool {
        windows.contains { w in
            guard let layer = integer(w[Key.layer]), layer == popUpMenuLayer else { return false }
            return bool(w[Key.isOnScreen]) ?? true
        }
    }

    /// Fills `resolvedName` by matching item x positions to externally known items (e.g. Accessibility).
    public static func resolveNames(
        _ items: [MenuBarItem],
        using candidates: [(name: String, minX: CGFloat, width: CGFloat)],
        tolerance: CGFloat = 2
    ) -> [MenuBarItem] {
        guard !candidates.isEmpty else { return items }
        return items.map { item in
            var item = item
            if let match = candidates.first(where: {
                abs($0.minX - item.frame.minX) <= tolerance && abs($0.width - item.frame.width) <= tolerance * 2
            }) {
                item.resolvedName = match.name
            }
            return item
        }
    }

    /// Fills the name, bundle identifier, detail and real process of items that match an Accessibility item's frame.
    public static func resolve(
        _ items: [MenuBarItem],
        using candidates: [AccessibilityItem],
        tolerance: CGFloat = 2
    ) -> [MenuBarItem] {
        guard !candidates.isEmpty else { return items }
        let frames = candidates.map(\.frame)
        return items.map { item in
            guard let index = FrameMatcher.bestMatchIndex(for: item.frame, among: frames, tolerance: tolerance)
            else { return item }
            let match = candidates[index]
            var item = item
            item.resolvedName = match.displayName
            if let id = match.bundleID, !id.isEmpty { item.bundleID = id }
            item.detail = match.detail
            item.sourcePID = match.pid
            return item
        }
    }

    // MARK: - Lenient value extraction

    static func integer(_ v: Any?) -> Int? {
        switch v {
        case let i as Int: return i
        case let i as Int32: return Int(i)
        case let i as Int64: return Int(exactly: i)
        case let u as UInt32: return Int(u)
        case let d as Double: return d.isFinite ? Int(exactly: d.rounded()) : nil
        default: return nil
        }
    }

    static func double(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d.isFinite ? d : nil
        case let f as CGFloat: return f.isFinite ? Double(f) : nil
        case let f as Float: return f.isFinite ? Double(f) : nil
        case let i as Int: return Double(i)
        case let i as Int32: return Double(i)
        case let i as Int64: return Double(i)
        default: return nil
        }
    }

    static func bool(_ v: Any?) -> Bool? {
        switch v {
        case let b as Bool: return b
        case let i as Int: return i != 0
        default: return nil
        }
    }

    static func rect(_ v: Any?) -> CGRect? {
        guard let d = v as? [String: Any],
              let x = double(d["X"]), let y = double(d["Y"]),
              let w = double(d["Width"]), let h = double(d["Height"]),
              w >= 0, h >= 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
