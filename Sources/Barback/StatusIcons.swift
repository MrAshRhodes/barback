import AppKit
import BarbackCore

/// Renders Barback's own menu bar glyphs from `AppearanceSettings`. All images are templates, so the system
/// tints them for light, dark and tinted menu bars and for Increase Contrast.
@MainActor
enum StatusIcons {
    static let togglePointSize: CGFloat = 13

    static func toggleImage(style: ToggleIconStyle, weight: IconWeight, revealed: Bool, label: String?) -> NSImage? {
        if let layers = style.glyphLayers(revealed: revealed, weight: weight) {
            return glyphImage(layers: layers, size: ToggleIconStyle.glyphCanvasSize, label: label)
        }
        let config = NSImage.SymbolConfiguration(pointSize: togglePointSize, weight: weight.fontWeight)
        let name = style.symbolName(revealed: revealed) ?? ToggleIconStyle.fallbackSymbolName(revealed: revealed)
        let image = (NSImage(systemSymbolName: name, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: ToggleIconStyle.fallbackSymbolName(revealed: revealed), accessibilityDescription: label))?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// Small image of a style for the icon picker's rows: the SF Symbol is drawn by the row itself, drawn glyphs
    /// need an image at menu icon size.
    static func pickerImage(style: ToggleIconStyle, size: CGFloat = 16) -> NSImage? {
        guard let layers = style.glyphLayers(revealed: false, weight: .regular) else { return nil }
        return glyphImage(layers: layers, size: CGSize(width: size, height: size), label: nil)
    }

    /// Draws vector layers on the glyph canvas, scaled to `size`. A template image, so only alpha matters.
    private static func glyphImage(layers: [GlyphLayer], size: CGSize, label: String?) -> NSImage {
        let canvas = ToggleIconStyle.glyphCanvasSize
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: rect.width / canvas.width, y: rect.height / canvas.height)
            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for layer in layers {
                context.addPath(layer.path.cgPath)
                switch (layer.fillsInterior, layer.lineWidth > 0) {
                case (true, true):
                    context.setLineWidth(layer.lineWidth)
                    context.drawPath(using: .fillStroke)
                case (true, false):
                    context.fillPath()
                case (false, true):
                    context.setLineWidth(layer.lineWidth)
                    context.strokePath()
                case (false, false):
                    context.beginPath()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }

    /// Divider glyph, or nil for `.none` (the status item then shows as a narrow empty gap).
    static func dividerImage(style: DividerStyle, label: String) -> NSImage? {
        guard style.isVisible else { return nil }
        let canvas = DividerStyle.canvasSize
        let symbol = style.symbolName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        }
        let segments = style.segments
        let image = NSImage(size: canvas, flipped: false) { rect in
            // Template images only use alpha; keep dividers subtle unless the user asked for more contrast.
            let alpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1.0 : 0.55
            if let symbol {
                let s = symbol.size
                let scale = min(1, rect.width / max(s.width, 1), rect.height / max(s.height, 1))
                let size = NSSize(width: s.width * scale, height: s.height * scale)
                let target = NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2, width: size.width, height: size.height)
                symbol.draw(in: target, from: .zero, operation: .sourceOver, fraction: alpha)
            } else {
                NSColor.black.withAlphaComponent(alpha).setFill()
                for segment in segments {
                    NSBezierPath(roundedRect: segment.rect, xRadius: segment.cornerRadius, yRadius: segment.cornerRadius).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }
}

extension IconWeight {
    var fontWeight: NSFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }

    var displayName: String {
        switch self {
        case .regular: return String(localized: "Regular")
        case .medium: return String(localized: "Medium")
        case .semibold: return String(localized: "Semibold")
        case .bold: return String(localized: "Bold")
        }
    }
}

extension ToggleIconStyle {
    var displayName: String {
        switch self {
        case .chevron: return String(localized: "Chevron")
        case .chevronCircle: return String(localized: "Chevron in Circle")
        case .triangle: return String(localized: "Triangle")
        case .eye: return String(localized: "Eye")
        case .ellipsis: return String(localized: "Ellipsis")
        case .lines: return String(localized: "Lines")
        case .wineglass: return String(localized: "Wine Glass")
        case .mug: return String(localized: "Mug")
        case .dot: return String(localized: "Dot")
        case .maranon: return String(localized: "Carlos’ Marañon")
        }
    }
}

extension DividerStyle {
    var displayName: String {
        switch self {
        case .line: return String(localized: "Line")
        case .dashed: return String(localized: "Dashed")
        case .dot: return String(localized: "Dot")
        case .doubleLine: return String(localized: "Double Line")
        case .chevron: return String(localized: "Chevron")
        case .none: return String(localized: "Invisible")
        }
    }
}

extension AppearanceStyle {
    var displayName: String {
        switch self {
        case .classic: return String(localized: "Classic")
        case .minimal: return String(localized: "Minimal")
        case .cocktail: return String(localized: "Cocktail")
        case .eye: return String(localized: "Eye")
        case .arrows: return String(localized: "Arrows")
        }
    }
}
