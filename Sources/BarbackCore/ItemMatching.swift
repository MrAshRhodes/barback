import CoreGraphics
import Foundation

/// A status item as the Accessibility API reports it (`AXExtrasMenuBar` children). Frames use the same
/// global top-left coordinates as `MenuBarItem.frame`.
public struct AccessibilityItem: Equatable, Sendable {
    public var appName: String
    public var bundleID: String?
    public var pid: Int32
    /// The element's title or description when it adds something to the app name, e.g. "Wi-Fi".
    public var detail: String?
    public var frame: CGRect

    public init(appName: String, bundleID: String? = nil, pid: Int32, description: String? = nil, frame: CGRect) {
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.detail = trimmed.isEmpty || trimmed == appName ? nil : trimmed
        self.frame = frame
    }

    /// "App — detail", or just the app name.
    public var displayName: String {
        guard let detail else { return appName }
        return appName.isEmpty ? detail : "\(appName) — \(detail)"
    }
}

/// Pure frame matching, used to pair window-list items with Accessibility elements.
public enum FrameMatcher {
    /// Index of the frame that best matches `target`: left edges within `tolerance` and widths within twice that,
    /// preferring the smallest difference. Heights and y are ignored (status items share the menu bar's row).
    public static func bestMatchIndex(for target: CGRect, among frames: [CGRect], tolerance: CGFloat = 2) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, frame) in frames.enumerated() {
            let dx = abs(frame.minX - target.minX)
            let dw = abs(frame.width - target.width)
            guard dx <= tolerance, dw <= tolerance * 2 else { continue }
            let distance = dx + dw
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best?.index
    }
}
