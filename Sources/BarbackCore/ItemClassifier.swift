import CoreGraphics

/// A display that shows a menu bar, in CoreGraphics global coordinates (origin top-left of the primary display).
public struct MenuBarDisplay: Equatable, Sendable {
    public var frame: CGRect
    /// Camera housing on this display (x/width are what matter), if any.
    public var notch: CGRect?

    public init(frame: CGRect, notch: CGRect? = nil) {
        self.frame = frame
        self.notch = notch
    }
}

/// Whether a status item window is actually drawn.
public enum ItemVisibility: Equatable, Sendable {
    /// Drawn in a menu bar.
    case shown
    /// Pushed past the edge of its display, e.g. by an expanded Barback separator.
    case offScreen
    /// The window sits inside a menu bar but macOS isn't drawing it (for example, the item is turned off in
    /// System Settings › Menu Bar, or its app has hidden it). Barback isn't what hides it.
    case notDrawn
}

/// Where one menu bar item is and which Barback section it belongs to.
public struct ItemPlacement: Equatable, Sendable {
    /// Index into the displays passed to the classifier; nil when it can't be told.
    public var display: Int?
    public var section: MenuBarSection
    public var visibility: ItemVisibility
    public var overlapsNotch: Bool

    public init(display: Int?, section: MenuBarSection, visibility: ItemVisibility, overlapsNotch: Bool) {
        self.display = display
        self.section = section
        self.visibility = visibility
        self.overlapsNotch = overlapsNotch
    }
}

/// Classifies menu bar items per display, so multi-display setups compare each item only with the separators
/// and notch of the display it is on.
public enum ItemClassifier {
    /// The display an item (or one of Barback's own items) belongs to.
    ///
    /// Items drawn on a display intersect it. Items pushed off-screen by an expanded separator sit left of their
    /// display, on the same menu bar row, so they belong to the nearest display to their right on that row.
    public static func displayIndex(for frame: CGRect, in displays: [MenuBarDisplay]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (i, d) in displays.enumerated() {
            let r = d.frame.intersection(frame)
            guard !r.isNull, r.width > 0, r.height > 0 else { continue }
            let area = r.width * r.height
            if best == nil || area > best!.area { best = (i, area) }
        }
        if let best { return best.index }
        let tolerance = SectionLayout.tolerance
        return displays.enumerated()
            .filter { abs($0.element.frame.minY - frame.minY) <= tolerance && frame.maxX <= $0.element.frame.minX + tolerance }
            .min { $0.element.frame.minX < $1.element.frame.minX }?
            .offset
    }

    /// Classifies `item` against Barback's separators (CG frames; nil when unknown).
    public static func classify(
        _ item: MenuBarItem,
        displays: [MenuBarDisplay],
        hiddenSeparator: CGRect?,
        alwaysHiddenSeparator: CGRect?
    ) -> ItemPlacement {
        let index = displayIndex(for: item.frame, in: displays)
        let drawnOnDisplay = index.map { displays[$0].frame.intersects(item.frame) } ?? false
        let visibility: ItemVisibility
        if item.frame.width <= 0 || !drawnOnDisplay {
            visibility = .offScreen
        } else {
            visibility = item.isOnScreen ? .shown : .notDrawn
        }

        // An expanded separator is 10,000 pt wide and may span displays; its right edge is where it really is.
        func separatorDisplayIndex(_ frame: CGRect?) -> Int? {
            guard let frame, frame.width > 0 else { return nil }
            let edge = CGRect(x: frame.maxX - min(1, frame.width), y: frame.minY, width: min(1, frame.width), height: frame.height)
            return displayIndex(for: edge, in: displays)
        }
        let separatorDisplay = separatorDisplayIndex(hiddenSeparator)
        let section: MenuBarSection
        if let index, let separatorDisplay, index == separatorDisplay {
            let alwaysOnSameDisplay = separatorDisplayIndex(alwaysHiddenSeparator) == index
            section = SectionLayout.section(
                ofItemMinX: item.frame.minX,
                hiddenSeparatorMaxX: hiddenSeparator?.maxX,
                alwaysHiddenSeparatorMaxX: alwaysOnSameDisplay ? alwaysHiddenSeparator?.maxX : nil
            )
        } else {
            section = .unknown
        }

        var underNotch = false
        if visibility == .shown, let index, let notch = displays[index].notch {
            underNotch = NotchGeometry.overlapsNotch(item.frame, notch: notch)
        }
        return ItemPlacement(display: index, section: section, visibility: visibility, overlapsNotch: underNotch)
    }
}
