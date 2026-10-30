import AppKit
import SwiftUI

/// Reports when the SwiftUI content wants a different size, so the window can follow.
private final class PanelHostingView: NSHostingView<DropDownPanelView> {
    var onSizeChange: () -> Void = {}

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange()
    }
}

/// A 1pt outline that lets clicks through, for Increase Contrast.
private final class OutlineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = DropDownPanelWindow.cornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = NSColor.labelColor.withAlphaComponent(0.55).cgColor
        }
    }
}

/// Opaque rounded backdrop for Reduce Transparency.
private final class SolidBackdropView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = DropDownPanelWindow.cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}

/// The drop-down panel's window: borderless and rounded like Control Center's, without an arrow, not activating
/// Barback when shown, and able to take the keyboard so the items can be reached without the mouse.
final class DropDownPanelWindow: NSPanel {
    static let cornerRadius: CGFloat = 26

    /// Called when Esc is pressed inside the panel.
    var onCancel: () -> Void = {}
    /// Called when the content wants a different size.
    var onContentSizeChange: () -> Void = {}

    private let host: PanelHostingView

    init(model: DropDownPanelModel, chrome: DropDownPanelChrome, increasedContrast: Bool) {
        let host = PanelHostingView(rootView: DropDownPanelView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        self.host = host
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)

        isOpaque = false
        backgroundColor = .clear
        // The window server shades glass as a plain rectangle, so the glass draws its own edge and depth instead.
        hasShadow = !Self.usesGlass(chrome)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        title = String(localized: "Hidden Items")
        setAccessibilityLabel(String(localized: "Hidden Items"))
        setAccessibilitySubrole(.dialog)

        let content = NSView()
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        if increasedContrast {
            let outline = OutlineView(frame: content.bounds)
            outline.autoresizingMask = [.width, .height]
            content.addSubview(outline)
        }
        contentView = Self.backdrop(for: chrome, around: content)
        host.onSizeChange = { [weak self] in self?.onContentSizeChange() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

    /// The size the content asks for at its fixed width.
    var contentFittingSize: NSSize { host.fittingSize }

    // MARK: - Chrome

    private static func usesGlass(_ chrome: DropDownPanelChrome) -> Bool {
        if #available(macOS 26.0, *) { return chrome == .glass }
        return false
    }

    private static func backdrop(for chrome: DropDownPanelChrome, around content: NSView) -> NSView {
        if chrome == .glass, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }
        let backdrop: NSView
        if chrome == .solid {
            backdrop = SolidBackdropView()
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.blendingMode = .behindWindow
            effect.maskImage = roundedMask(radius: cornerRadius)
            backdrop = effect
        }
        content.frame = backdrop.bounds
        content.autoresizingMask = [.width, .height]
        backdrop.addSubview(content)
        return backdrop
    }

    /// A stretchable rounded rectangle; the visual effect view is clipped to its shape.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: - Showing

    /// Puts the panel at `frame`. Unless Reduce Motion is on it fades in while sliding down a few points.
    func present(at frame: NSRect, animated: Bool) {
        setFrame(frame, display: false)
        defer {
            // The shadow follows the rounded shape only once the content has drawn.
            DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
        }
        guard animated else {
            alphaValue = 1
            orderFrontRegardless()
            makeKey()
            return
        }
        let slide = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        alphaValue = 0
        if slide { setFrame(frame.offsetBy(dx: 0, dy: 10), display: false) }
        orderFrontRegardless()
        makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = slide ? 0.2 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            if slide { animator().setFrame(frame, display: true) }
        }
    }

    /// Moves or resizes the panel (not animated), e.g. when the content changed.
    func resize(to frame: NSRect) {
        guard frame != self.frame else { return }
        setFrame(frame, display: true)
        invalidateShadow()
    }

    /// Fades out and removes the panel, or removes it at once under Reduce Motion.
    func dismiss(animated: Bool, completion: @escaping () -> Void) {
        ignoresMouseEvents = true
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            orderOut(nil)
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: {
            // Strong on purpose: the controller lets go of the window as soon as it starts closing.
            self.orderOut(nil)
            completion()
        })
    }
}
