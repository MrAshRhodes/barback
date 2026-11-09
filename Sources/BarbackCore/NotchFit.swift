import CoreGraphics

/// Geometry of an observed, revealed status strip. This does not predict items that macOS omitted from a scan.
public enum NotchFit {
    public struct Item: Equatable, Sendable {
        public var id: UInt32
        public var frame: CGRect
        public var display: Int?
        public var section: MenuBarSection
        public var isOnScreen: Bool

        public init(id: UInt32, frame: CGRect, display: Int?, section: MenuBarSection, isOnScreen: Bool) {
            self.id = id
            self.frame = frame
            self.display = display
            self.section = section
            self.isOnScreen = isOnScreen
        }
    }

    public struct Result: Equatable, Sendable {
        public var display: Int
        public var availableWidth: CGFloat
        /// Observed, drawn items that do not fit entirely in the area to the right of this display's notch.
        public var unreachableIDs: [UInt32]
        /// Not-drawn or invalid frames cannot establish whether an item is hidden by the notch.
        public var unknownIDs: [UInt32]

        public var unreachableCount: Int { unreachableIDs.count }
    }

    /// All coordinates must be from the same CG snapshot. Pass explicit display ownership rather than
    /// attributing a pushed-off-screen item to a neighbouring display by its x coordinate.
    public static func evaluate(items: [Item], displays: [MenuBarDisplay], state: SectionState) -> [Result] {
        guard state.isRevealed else { return [] }
        return displays.enumerated().compactMap { index, display in
            guard let notch = display.notch, valid(display.frame), valid(notch),
                  notch.minX >= display.frame.minX, notch.maxX < display.frame.maxX,
                  notch.minY >= display.frame.minY, notch.maxY <= display.frame.maxY else { return nil }
            var unreachable: [UInt32] = []
            var unknown: [UInt32] = []
            var seen = Set<UInt32>()
            for item in items where item.display == index {
                guard item.section != .alwaysHidden || state == .shownAll,
                      seen.insert(item.id).inserted else { continue }
                guard valid(item.frame),
                      abs(item.frame.minY - display.frame.minY) <= SectionLayout.tolerance,
                      item.isOnScreen else {
                    unknown.append(item.id)
                    continue
                }
                // Testing only intersection with the notch misses items that have moved completely past it.
                if item.frame.minX < notch.maxX || item.frame.maxX > display.frame.maxX {
                    unreachable.append(item.id)
                }
            }
            return Result(
                display: index, availableWidth: display.frame.maxX - notch.maxX,
                unreachableIDs: unreachable, unknownIDs: unknown
            )
        }
    }

    /// AppKit coordinates: a panel below the menu bar, confined to the right of the camera housing.
    public static func panelFrame(
        screen: CGRect, visible: CGRect, notch: CGRect,
        preferredHeight: CGFloat = 240, maximumWidth: CGFloat = 680, inset: CGFloat = 8
    ) -> CGRect? {
        guard valid(screen), valid(visible), valid(notch),
              preferredHeight.isFinite, preferredHeight > 0,
              maximumWidth.isFinite, maximumWidth > 0, inset.isFinite, inset >= 0,
              notch.minX >= screen.minX, notch.maxX < screen.maxX,
              notch.minY >= screen.minY, notch.maxY <= screen.maxY else { return nil }
        let left = max(notch.maxX, visible.minX) + inset
        let right = min(screen.maxX, visible.maxX) - inset
        let top = min(notch.minY, visible.maxY) - inset
        let bottom = max(screen.minY, visible.minY) + inset
        let width = min(maximumWidth, right - left)
        let height = min(preferredHeight, top - bottom)
        guard width >= 240, height >= 220 else { return nil }
        return CGRect(x: right - width, y: top - height, width: width, height: height)
    }

    private static func valid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.maxX.isFinite && frame.maxY.isFinite
            && frame.size.width > 0 && frame.size.height > 0
    }
}
