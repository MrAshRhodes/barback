import CoreGraphics

/// Camera-housing ("notch") geometry for built-in displays.
public enum NotchGeometry {
    /// Returns the notch rect in global AppKit coordinates, or nil when the screen has no notch.
    ///
    /// `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` are the unobscured menu bar areas either side of the notch
    /// (`NSScreen` properties). They are accepted in either global or screen-local coordinates.
    public static func notchRect(
        screenFrame: CGRect,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?
    ) -> CGRect? {
        guard let rawLeft = auxiliaryTopLeftArea, let rawRight = auxiliaryTopRightArea,
              !rawLeft.isEmpty, !rawRight.isEmpty else { return nil }
        let left = globalize(rawLeft, in: screenFrame)
        let right = globalize(rawRight, in: screenFrame)
        let width = right.minX - left.maxX
        guard width > 0 else { return nil }
        let height = max(left.height, right.height)
        return CGRect(x: left.maxX, y: screenFrame.maxY - height, width: width, height: height)
    }

    /// True if the horizontal extent of `rect` intersects the notch (menu bar items only differ along x).
    public static func overlapsNotch(minX: CGFloat, maxX: CGFloat, notch: CGRect) -> Bool {
        guard maxX > minX, notch.width > 0 else { return false }
        return minX < notch.maxX && maxX > notch.minX
    }

    public static func overlapsNotch(_ rect: CGRect, notch: CGRect) -> Bool {
        overlapsNotch(minX: rect.minX, maxX: rect.maxX, notch: notch)
    }

    private static func globalize(_ r: CGRect, in screen: CGRect) -> CGRect {
        let slack: CGFloat = 0.5
        let insideGlobal = r.minX >= screen.minX - slack && r.maxX <= screen.maxX + slack
            && r.minY >= screen.minY - slack && r.maxY <= screen.maxY + slack
        return insideGlobal ? r : r.offsetBy(dx: screen.minX, dy: screen.minY)
    }
}
