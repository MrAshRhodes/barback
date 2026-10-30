import CoreGraphics
import Foundation

/// Pure geometry for the drop-down panel: where it sits under the icon and how its boxes are packed.
public enum DropDownPlacement {
    /// Space between the bottom of the menu bar item and the top of the panel.
    public static let gap: CGFloat = 5
    /// Space kept between the panel and the edges of the screen's usable area.
    public static let margin: CGFloat = 8

    /// The panel's frame in screen coordinates (origin bottom-left): its right edge lines up with the icon's right
    /// edge and its top edge hangs `gap` below the icon, the way Control Center drops down from its own icon. The
    /// panel is then kept inside `visible` (the screen's `visibleFrame`) with `margin` to spare, so an icon near
    /// the left edge shifts the panel right and it never ends up wider or taller than the screen allows.
    public static func frame(
        size: CGSize,
        anchor: CGRect,
        visible: CGRect,
        gap: CGFloat = DropDownPlacement.gap,
        margin: CGFloat = DropDownPlacement.margin
    ) -> CGRect {
        let top = min(anchor.minY - gap, visible.maxY)
        let width = min(size.width, max(0, visible.width - 2 * margin))
        let height = min(size.height, max(0, top - visible.minY - margin))
        let lowestX = visible.minX + margin
        let highestX = max(lowestX, visible.maxX - margin - width)
        let x = min(max(anchor.maxX - width, lowestX), highestX)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    /// The tallest the panel may be when hung from `anchor` on a screen with the `visible` area.
    public static func maxHeight(
        anchor: CGRect,
        visible: CGRect,
        gap: CGFloat = DropDownPlacement.gap,
        margin: CGFloat = DropDownPlacement.margin
    ) -> CGFloat {
        let top = min(anchor.minY - gap, visible.maxY)
        return max(0, top - visible.minY - margin)
    }
}

/// How the panel's boxes share its width, like the module grid in Control Center: small boxes sit two to a row,
/// everything else takes a row of its own.
public enum DropDownModuleGrid {
    /// Most items a box may hold and still count as small: a 2 × 2 block of buttons, or three list rows.
    public static func isCompact(itemCount: Int, layout: DropDownLayout) -> Bool {
        switch layout {
        case .grid: return itemCount <= 4
        case .list: return itemCount <= 3
        }
    }

    /// Row by row, the indices of the boxes in it (one or two each). Boxes keep their order; only neighbours
    /// that are both small share a row, and a small box left without a partner is given the whole row.
    public static func rows(compact: [Bool]) -> [[Int]] {
        var rows: [[Int]] = []
        var index = 0
        while index < compact.count {
            if compact[index], index + 1 < compact.count, compact[index + 1] {
                rows.append([index, index + 1])
                index += 2
            } else {
                rows.append([index])
                index += 1
            }
        }
        return rows
    }
}
