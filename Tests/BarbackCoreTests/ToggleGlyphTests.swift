import CoreGraphics
import Foundation
import Testing
@testable import BarbackCore

@Suite("Toggle glyphs")
struct ToggleGlyphTests {
    private let canvas = CGRect(origin: .zero, size: ToggleIconStyle.glyphCanvasSize)

    private func freshDefaults() -> (UserDefaults, String) {
        let suite = "barback.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    /// Points along every curve of a path, to measure distances between shapes.
    private func outline(of path: GlyphPath) -> [CGPoint] {
        var points: [CGPoint] = []
        var current = CGPoint.zero
        for element in path.elements {
            switch element {
            case .move(let p), .line(let p):
                current = p
                points.append(p)
            case .curve(let p, let c1, let c2):
                for i in 1...40 {
                    let t = CGFloat(i) / 40, u = 1 - t
                    points.append(CGPoint(
                        x: u * u * u * current.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p.x,
                        y: u * u * u * current.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p.y
                    ))
                }
                current = p
            case .close:
                break
            }
        }
        return points
    }

    /// The two big shapes of the glyph: the nut and the fruit, smallest first.
    private func bodies(_ layers: [GlyphLayer]) -> [GlyphLayer] {
        let sorted = layers.sorted { $0.path.bounds.width * $0.path.bounds.height < $1.path.bounds.width * $1.path.bounds.height }
        return Array(sorted.suffix(2))
    }

    @Test func everyStyleIsEitherASymbolOrDrawn() {
        for style in ToggleIconStyle.allCases {
            for revealed in [false, true] {
                let hasSymbol = style.symbolName(revealed: revealed) != nil
                let hasGlyph = style.glyphLayers(revealed: revealed, weight: .default) != nil
                #expect(hasSymbol != hasGlyph, "\(style) needs exactly one of an SF Symbol or a drawn glyph")
                #expect(hasGlyph == style.isCustomGlyph)
            }
        }
        for revealed in [false, true] {
            #expect(
                ToggleIconStyle.default.symbolName(revealed: revealed) == ToggleIconStyle.fallbackSymbolName(revealed: revealed),
                "the fallback symbol is the default style's"
            )
        }
    }

    @Test func maranonIsTheLastIconAndKeepsItsRawValue() {
        #expect(ToggleIconStyle.allCases.last == .maranon)
        #expect(ToggleIconStyle.allCases.dropLast().last == .dot)
        #expect(ToggleIconStyle.maranon.rawValue == "maranon")
        #expect(ToggleIconStyle.maranon.id == "maranon")
        #expect(ToggleIconStyle(rawValue: "maranon") == .maranon)
        #expect(ToggleIconStyle.maranon.isCustomGlyph)
        #expect(ToggleIconStyle.allCases.filter(\.isCustomGlyph) == [.maranon])
        #expect(AppearanceStyle.allCases.allSatisfy { $0.toggleIcon != .maranon }, "presets stay as they were")
    }

    @Test func maranonCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(ToggleIconStyle.maranon)
        #expect(String(decoding: data, as: UTF8.self) == "\"maranon\"")
        #expect(try JSONDecoder().decode(ToggleIconStyle.self, from: data) == .maranon)

        let appearance = AppearanceSettings(toggleIcon: .maranon, iconWeight: .bold, tintWhenShowing: true)
        let encoded = try JSONEncoder().encode(appearance)
        #expect(try JSONDecoder().decode(AppearanceSettings.self, from: encoded) == appearance)
        #expect(appearance.style == nil, "no preset uses the Marañon icon, so it shows as Custom")
    }

    @Test func maranonSurvivesTheSettingsStore() {
        let (d, suite) = freshDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: d)
        let custom = BarbackSettings(appearance: AppearanceSettings(toggleIcon: .maranon, iconWeight: .medium))
        store.save(custom)
        #expect(d.string(forKey: SettingsKey.toggleIcon.rawValue) == "maranon", "stored as a plain string for `defaults write`")
        #expect(store.load() == custom)

        for icon in ToggleIconStyle.allCases {
            store.save(BarbackSettings(appearance: AppearanceSettings(toggleIcon: icon)))
            #expect(store.load().appearance.toggleIcon == icon)
        }
    }

    @Test func unknownIconNamesStillFallBackToTheDefault() {
        let (d, suite) = freshDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        for unknown in ["marañon", "Maranon", "cashew", ""] {
            d.set(unknown, forKey: SettingsKey.toggleIcon.rawValue)
            #expect(SettingsStore(defaults: d).load().appearance.toggleIcon == .default, "\(unknown.debugDescription)")
        }
    }

    @Test func maranonHasGeometryInEveryStateAndWeight() {
        for revealed in [false, true] {
            for weight in IconWeight.allCases {
                let layers = MaranonGlyph.layers(revealed: revealed, weight: weight)
                #expect(layers == ToggleIconStyle.maranon.glyphLayers(revealed: revealed, weight: weight))
                #expect(layers.count == 4, "nut, fruit, stem and leaf")
                for layer in layers {
                    #expect(layer.path.elements.count > 1)
                    #expect(layer.path.bounds.width > 0 && layer.path.bounds.height > 0)
                    #expect(layer.fillsInterior || layer.lineWidth > 0, "every layer draws something")
                }
            }
        }
    }

    @Test func maranonShowsStateByOutlineVersusFill() {
        for weight in IconWeight.allCases {
            let hidden = MaranonGlyph.layers(revealed: false, weight: weight)
            let revealed = MaranonGlyph.layers(revealed: true, weight: weight)
            #expect(hidden != revealed)
            #expect(hidden.map(\.path) == revealed.map(\.path), "the silhouette doesn't change, only the fill")
            #expect(hidden.map(\.lineWidth) == revealed.map(\.lineWidth))

            #expect(bodies(hidden).allSatisfy { !$0.fillsInterior && $0.lineWidth > 0 }, "outline while items are hidden")
            #expect(bodies(revealed).allSatisfy { $0.fillsInterior }, "filled while items are showing")
            #expect(hidden.contains { $0.fillsInterior }, "the small leaf is solid in both states")
        }
    }

    @Test func maranonStrokeFollowsTheIconWeight() {
        let widths = IconWeight.allCases.map(\.glyphLineWidth)
        #expect(widths == widths.sorted() && Set(widths).count == widths.count, "heavier weights draw thicker strokes")
        #expect(widths.allSatisfy { (0.8...2.0).contains($0) })
        for weight in IconWeight.allCases {
            let outlined = MaranonGlyph.layers(revealed: false, weight: weight).filter { !$0.fillsInterior }
            #expect(!outlined.isEmpty)
            #expect(outlined.allSatisfy { $0.lineWidth == weight.glyphLineWidth })
        }
    }

    @Test func maranonFitsInsideTheCanvasWithItsStroke() {
        #expect(ToggleIconStyle.glyphCanvasSize == CGSize(width: 18, height: 18))
        for revealed in [false, true] {
            for weight in IconWeight.allCases {
                let layers = MaranonGlyph.layers(revealed: revealed, weight: weight)
                for layer in layers {
                    #expect(canvas.contains(layer.visualBounds), "\(layer.visualBounds) leaves the canvas")
                }
                let glyph = layers.map(\.visualBounds).reduce(CGRect.null) { $0.union($1) }
                #expect((12...17).contains(glyph.height), "menu bar glyphs are about 14–16 pt tall, got \(glyph.height)")
                #expect((11...17).contains(glyph.width), "got \(glyph.width)")
                #expect(abs(glyph.midX - canvas.midX) < 1 && abs(glyph.midY - canvas.midY) < 1, "keep the glyph centred")
            }
        }
    }

    @Test func maranonNutHangsClearOfTheFruit() {
        for weight in IconWeight.allCases {
            let layers = MaranonGlyph.layers(revealed: true, weight: weight)
            let nut = layers[0], fruit = layers[1]
            #expect(nut.path == MaranonGlyph.nut && fruit.path == MaranonGlyph.fruit)
            let nutPoints = outline(of: nut.path), fruitPoints = outline(of: fruit.path)
            var nearest = CGFloat.infinity
            for a in nutPoints {
                for b in fruitPoints { nearest = min(nearest, hypot(a.x - b.x, a.y - b.y)) }
            }
            #expect(nearest - weight.glyphLineWidth >= 0.75, "\(weight): only \(nearest - weight.glyphLineWidth) pt between fruit and nut")
        }
    }

    @Test func maranonStemGrowsFromTheTopOfTheFruit() {
        #expect(MaranonGlyph.stem.elements.first == MaranonGlyph.fruit.elements.first)
        #expect(MaranonGlyph.stem.bounds.maxY > MaranonGlyph.fruit.bounds.maxY)
        #expect(MaranonGlyph.leaf.bounds.minY > MaranonGlyph.fruit.bounds.maxY - 1, "the leaf sits on top of the fruit")
    }
}
