import AppKit
import BarbackCore

/// Finds an icon for a menu bar item: its app's icon, or a symbol when the app can't be told.
@MainActor
enum ItemIcons {
    /// Stands in for the system's own items (Wi-Fi, Battery…), which macOS 26 hosts in Control Center.
    static let systemSymbol = DropDownContent.genericSystemSymbol
    static let unknownSymbol = "questionmark.app"

    static func symbol(for item: MenuBarItem) -> String {
        item.isSystemItem ? DropDownContent.systemSymbol(forDetail: item.detail) : unknownSymbol
    }

    static func image(for item: MenuBarItem) -> NSImage? {
        // Control Center's own icon would say nothing about a system item such as Wi-Fi.
        if item.isSystemItem { return nil }
        let pid = item.sourcePID ?? item.ownerPID
        if pid > 0, let icon = NSRunningApplication(processIdentifier: pid)?.icon { return icon }
        if let id = item.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}
