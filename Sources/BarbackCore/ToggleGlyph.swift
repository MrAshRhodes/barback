import CoreGraphics

/// A path as plain value data, in a glyph canvas (origin bottom-left), so glyph geometry is testable
/// without drawing anything.
public struct GlyphPath: Equatable, Sendable {
    public enum Element: Equatable, Sendable {
        case move(CGPoint)
        case line(CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
        case close
    }

    public var elements: [Element]

    public init(_ elements: [Element]) {
        self.elements = elements
    }

    public var cgPath: CGPath {
        let path = CGMutablePath()
        for element in elements {
            switch element {
            case .move(let p): path.move(to: p)
            case .line(let p): path.addLine(to: p)
            case .curve(let p, let c1, let c2): path.addCurve(to: p, control1: c1, control2: c2)
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    /// Tight bounds of the path itself (not its stroke).
    public var bounds: CGRect { cgPath.boundingBoxOfPath }

    /// The same path rotated by `angle` radians around `center`, then moved by `offset`.
    func rotated(by angle: CGFloat, around center: CGPoint = .zero, then offset: CGPoint = .zero) -> GlyphPath {
        let cosine = cos(angle), sine = sin(angle)
        func map(_ p: CGPoint) -> CGPoint {
            let x = p.x - center.x, y = p.y - center.y
            return CGPoint(x: x * cosine - y * sine + center.x + offset.x, y: x * sine + y * cosine + center.y + offset.y)
        }
        return GlyphPath(elements.map { element in
            switch element {
            case .move(let p): return .move(map(p))
            case .line(let p): return .line(map(p))
            case .curve(let p, let c1, let c2): return .curve(to: map(p), control1: map(c1), control2: map(c2))
            case .close: return .close
            }
        })
    }
}

/// One shape of a drawn toggle glyph: filled, stroked with round caps and joins, or both.
public struct GlyphLayer: Equatable, Sendable {
    public var path: GlyphPath
    public var fillsInterior: Bool
    /// Stroke width in points; 0 draws no stroke.
    public var lineWidth: CGFloat

    public init(path: GlyphPath, fillsInterior: Bool, lineWidth: CGFloat) {
        self.path = path
        self.fillsInterior = fillsInterior
        self.lineWidth = lineWidth
    }

    /// Bounds including the stroke.
    public var visualBounds: CGRect { path.bounds.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2) }
}

extension IconWeight {
    /// Stroke width of drawn (non-SF Symbol) toggle glyphs, matched to the weight of the SF Symbols.
    public var glyphLineWidth: CGFloat {
        switch self {
        case .regular: return 1.0
        case .medium: return 1.15
        case .semibold: return 1.3
        case .bold: return 1.55
        }
    }
}

/// Carlos’ Marañon: a cashew apple (marañón) with its nut hanging from the bottom. Hidden items hidden shows
/// the outline; revealed shows it filled. The nut stays clear of the fruit so both read at menu bar size.
public enum MaranonGlyph {
    /// Canvas in points; the glyph sits inside it with room for the stroke.
    public static let canvasSize = CGSize(width: 18, height: 18)

    public static func layers(revealed: Bool, weight: IconWeight) -> [GlyphLayer] {
        let line = weight.glyphLineWidth
        return [
            GlyphLayer(path: nut, fillsInterior: revealed, lineWidth: line),
            GlyphLayer(path: fruit, fillsInterior: revealed, lineWidth: line),
            GlyphLayer(path: stem, fillsInterior: false, lineWidth: line),
            GlyphLayer(path: leaf, fillsInterior: true, lineWidth: leafLineWidth),
        ]
    }

    static let leafLineWidth: CGFloat = 0.5

    /// Bell shape: narrow shoulders, wide rounded bottom.
    static let fruit = GlyphPath([
        .move(CGPoint(x: 6.7, y: 15.0)),
        .curve(to: CGPoint(x: 10.75, y: 10.3), control1: CGPoint(x: 8.2, y: 15.0), control2: CGPoint(x: 10.75, y: 12.5)),
        .curve(to: CGPoint(x: 6.7, y: 7.15), control1: CGPoint(x: 10.75, y: 8.7), control2: CGPoint(x: 9.3, y: 7.15)),
        .curve(to: CGPoint(x: 2.65, y: 10.3), control1: CGPoint(x: 4.1, y: 7.15), control2: CGPoint(x: 2.65, y: 8.7)),
        .curve(to: CGPoint(x: 6.7, y: 15.0), control1: CGPoint(x: 2.65, y: 12.5), control2: CGPoint(x: 5.2, y: 15.0)),
        .close,
    ])

    /// Kidney-shaped nut hanging off the fruit's lower right, tilted along the way it hangs.
    static let nut = GlyphPath([
        .move(CGPoint(x: -2.8, y: 0.1)),
        .curve(to: CGPoint(x: 0, y: -1.6), control1: CGPoint(x: -2.8, y: -0.85), control2: CGPoint(x: -1.7, y: -1.6)),
        .curve(to: CGPoint(x: 2.8, y: 0.1), control1: CGPoint(x: 1.7, y: -1.6), control2: CGPoint(x: 2.8, y: -0.85)),
        .curve(to: CGPoint(x: 1.4, y: 1.6), control1: CGPoint(x: 2.8, y: 1.0), control2: CGPoint(x: 2.1, y: 1.6)),
        .curve(to: CGPoint(x: 0, y: 0.9), control1: CGPoint(x: 0.8, y: 1.6), control2: CGPoint(x: 0.55, y: 0.9)),
        .curve(to: CGPoint(x: -1.4, y: 1.6), control1: CGPoint(x: -0.55, y: 0.9), control2: CGPoint(x: -0.8, y: 1.6)),
        .curve(to: CGPoint(x: -2.8, y: 0.1), control1: CGPoint(x: -2.1, y: 1.6), control2: CGPoint(x: -2.8, y: 1.0)),
        .close,
    ]).rotated(by: -0.7, then: CGPoint(x: 12.8, y: 3.95))

    static let stem = GlyphPath([
        .move(CGPoint(x: 6.7, y: 15.0)),
        .curve(to: CGPoint(x: 7.5, y: 16.1), control1: CGPoint(x: 6.7, y: 15.6), control2: CGPoint(x: 7.0, y: 15.9)),
    ])

    static let leaf = GlyphPath([
        .move(CGPoint(x: 7.35, y: 15.9)),
        .curve(to: CGPoint(x: 10.85, y: 16.3), control1: CGPoint(x: 8.2, y: 16.75), control2: CGPoint(x: 9.85, y: 16.9)),
        .curve(to: CGPoint(x: 7.35, y: 15.9), control1: CGPoint(x: 10.15, y: 15.4), control2: CGPoint(x: 8.55, y: 15.3)),
        .close,
    ])
}

extension ToggleIconStyle {
    /// Whether this style is drawn rather than an SF Symbol (see `symbolName(revealed:)`).
    public var isCustomGlyph: Bool { self == .maranon }

    /// Shapes to draw for styles without an SF Symbol, in `glyphCanvasSize`; nil for symbol-backed styles.
    public func glyphLayers(revealed: Bool, weight: IconWeight) -> [GlyphLayer]? {
        switch self {
        case .maranon: return MaranonGlyph.layers(revealed: revealed, weight: weight)
        default: return nil
        }
    }

    /// Canvas of drawn glyphs, in points.
    public static let glyphCanvasSize = MaranonGlyph.canvasSize
}
