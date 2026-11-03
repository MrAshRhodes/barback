import CoreGraphics
import Foundation

/// A status item as the Accessibility API reports it (`AXExtrasMenuBar` children). Frames use the same
/// global top-left coordinates as `MenuBarItem.frame`.
public struct AccessibilityItem: Equatable, Sendable {
    public var appName: String
    public var bundleID: String?
    public var pid: Int32
    /// Stable canonical label for system hosts; title or description for other apps.
    public var detail: String?
    public var frame: CGRect

    public init(appName: String, bundleID: String? = nil, pid: Int32, description: String? = nil, identifier: String? = nil, frame: CGRect) {
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let bundleID, MenuBarItemParser.systemHostBundleIDs.contains(bundleID) {
            self.detail = SystemItemIdentity.detail(identifier: identifier)
        } else {
            self.detail = trimmed.isEmpty || trimmed == appName ? nil : trimmed
        }
        self.frame = frame
    }

    /// "App — detail", or just the app name.
    public var displayName: String {
        guard let detail else { return appName }
        return appName.isEmpty ? detail : "\(appName) — \(detail)"
    }
}

/// Only identifiers with known, non-localized meanings can become persisted system-item selectors.
public enum SystemItemIdentity {
    private static let labels: [String: String] = [
        "com.apple.menuextra.wifi": "Wi-Fi",
        "com.apple.menuextra.bluetooth": "Bluetooth",
        "com.apple.menuextra.battery": "Battery",
        "com.apple.menuextra.sound": "Sound",
        "com.apple.menuextra.focusmode": "Focus",
        "com.apple.menuextra.now-playing": "Now Playing",
        "com.apple.menuextra.clock": "Clock",
        "com.apple.menuextra.controlcenter": "Control Center",
        "com.apple.menuextra.display": "Display",
    ]

    public static func detail(identifier: String?) -> String? {
        let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return labels[identifier]
    }
}

/// Pure frame matching, used to pair window-list items with Accessibility elements.
public enum FrameMatcher {
    /// AX can describe the icon inside a wider CG window. Match centers in both axes, never empty frames
    /// or competing candidates. Negative coordinates are valid for hidden items and secondary displays.
    public static func bestMatchIndex(for target: CGRect, among frames: [CGRect], tolerance: CGFloat = 2) -> Int? {
        let candidates = frames.indices.filter { matches(target, frames[$0], tolerance: tolerance) }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Mutual uniqueness prevents two CG windows from claiming the same AX element, in either scan order.
    public static func matchIndices(for targets: [CGRect], among frames: [CGRect], tolerance: CGFloat = 2) -> [Int: Int] {
        var candidates: [Int: [Int]] = [:]
        var claims: [Int: Int] = [:]
        for target in targets.indices {
            let indices = frames.indices.filter { matches(targets[target], frames[$0], tolerance: tolerance) }
            candidates[target] = indices
            for index in indices { claims[index, default: 0] += 1 }
        }
        var result: [Int: Int] = [:]
        for (target, indices) in candidates where indices.count == 1 {
            let index = indices[0]
            if claims[index] == 1 { result[target] = index }
        }
        return result
    }

    private static func matches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        guard [a, b].allSatisfy({
            $0.width > 0 && $0.height > 0
                && $0.origin.x.isFinite && $0.origin.y.isFinite
                && $0.width.isFinite && $0.height.isFinite
        }) else { return false }
        return hypot(a.midX - b.midX, a.midY - b.midY) <= tolerance
    }
}
