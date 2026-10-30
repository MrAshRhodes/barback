#!/usr/bin/env swift
//
// make_icon.swift - draws the Barback app icon procedurally and builds AppIcon.icns.
//
//   swift Scripts/make_icon.swift [--keep-iconset]
//
// Outputs (the project root is found from this script's location):
//   Resources/AppIcon.icns       bundled into Barback.app by Scripts/build_app.sh
//   docs/assets/icon-1024.png    full-size render for the README
//   Resources/AppIcon.iconset/   intermediate PNGs, deleted afterwards unless --keep-iconset
//
// Only AppKit / CoreGraphics are used. The artwork is vector code that is re-run at every
// pixel size (nothing is downscaled from one bitmap), and small sizes drop fine detail and
// thicken strokes so the icon stays legible at 16 px.
//
// Geometry follows the macOS 26 (Tahoe) app icon grid: a 1024 x 1024 canvas with the body
// at 824 x 824, centred (100 px margins), using Apple's continuous-curvature ("squircle")
// corners with a 185.4 px radius. Nothing is drawn outside the body, so macOS can apply its
// own shadow and Liquid Glass treatment without placing the icon on a fallback plate.
//
// Design: a deep teal-to-ink body lit softly from above, a frosted-glass menu bar strip with
// a few item glyphs (the ones left of the divider fade out, as Barback hides them), and a
// single bold glass chevron - the control you click to reveal hidden items.

import AppKit

// MARK: - Colour helpers

let sRGBSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: sRGBSpace,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha,
        ]
    )!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: sRGBSpace,
        colors: stops.map { $0.1 } as CFArray,
        locations: stops.map { $0.0 }
    )!
}

// MARK: - Shapes

/// Apple's continuous-corner rounded rectangle (the shape SwiftUI calls `.continuous`).
/// Each corner blends into its edges over 1.528 x radius, which gives the smooth "squircle".
func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866483)
    let path = CGMutablePath()

    // (corner, direction of the edge arriving at it, direction of the edge leaving it), clockwise
    // in CoreGraphics' y-up space starting at the top-right corner.
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
    ]

    for (index, (corner, incoming, outgoing)) in corners.enumerated() {
        // p: distance back along the incoming edge, q: distance forward along the outgoing edge.
        func pt(_ p: CGFloat, _ q: CGFloat) -> CGPoint {
            CGPoint(
                x: corner.x - incoming.dx * p * r + outgoing.dx * q * r,
                y: corner.y - incoming.dy * p * r + outgoing.dy * q * r
            )
        }
        if index == 0 {
            path.move(to: pt(1.52866483, 0))
        } else {
            path.addLine(to: pt(1.52866483, 0))
        }
        path.addCurve(to: pt(0.66993427, 0.06549600), control1: pt(1.08849323, 0), control2: pt(0.86840689, 0))
        path.addLine(to: pt(0.63149399, 0.07491100))
        path.addCurve(to: pt(0.07491100, 0.63149399), control1: pt(0.37282392, 0.16905899), control2: pt(0.16905899, 0.37282392))
        path.addLine(to: pt(0.06549600, 0.66993427))
        path.addCurve(to: pt(0, 1.52866483), control1: pt(0, 0.86840689), control2: pt(0, 1.08849323))
    }
    path.closeSubpath()
    return path
}

/// The chevron ("‹") as an open polyline: top arm, point, bottom arm.
func chevronPath(center: CGPoint, halfHeight: CGFloat, depth: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: center.x + depth / 2, y: center.y + halfHeight))
    path.addLine(to: CGPoint(x: center.x - depth / 2, y: center.y))
    path.addLine(to: CGPoint(x: center.x + depth / 2, y: center.y - halfHeight))
    return path
}

// MARK: - Drawing

enum Detail: Int, Comparable {
    case tiny = 0    // 16-32 px: body + chevron only, heavier strokes
    case small = 1   // 64-128 px: plus a simplified menu bar strip
    case full = 2    // 256 px and up: every layer

    static func < (a: Detail, b: Detail) -> Bool { a.rawValue < b.rawValue }

    init(pixels: Int) {
        switch pixels {
        case ..<48: self = .tiny
        case ..<200: self = .small
        default: self = .full
        }
    }
}

/// Draws into a context whose user space is 1024 x 1024 (y up).
func drawIcon(_ ctx: CGContext, detail: Detail, pixelScale: CGFloat) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = continuousRoundedRect(body, radius: 185.4)

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // 1. Body: deep teal at the top settling into ink at the bottom.
    ctx.drawLinearGradient(
        gradient([
            (0.00, color(0x2C8A97)),
            (0.42, color(0x145466)),
            (1.00, color(0x0A1E2D)),
        ]),
        start: CGPoint(x: 512, y: body.maxY),
        end: CGPoint(x: 512, y: body.minY),
        options: []
    )

    // 2. Soft key light from the upper left, and a faint cool bounce light from below.
    ctx.drawRadialGradient(
        gradient([(0, color(0xBFF4F7, 0.30)), (1, color(0xBFF4F7, 0))]),
        startCenter: CGPoint(x: 330, y: 860), startRadius: 0,
        endCenter: CGPoint(x: 330, y: 860), endRadius: 620,
        options: []
    )
    ctx.drawRadialGradient(
        gradient([(0, color(0x3FC9D6, 0.16)), (1, color(0x3FC9D6, 0))]),
        startCenter: CGPoint(x: 700, y: 60), startRadius: 0,
        endCenter: CGPoint(x: 700, y: 60), endRadius: 520,
        options: []
    )

    // 3. Frosted-glass menu bar strip across the top.
    if detail >= .small {
        drawMenuBarStrip(ctx, detail: detail, pixelScale: pixelScale)
    }

    // 4. The chevron, the single hero motif.
    drawChevron(ctx, detail: detail, pixelScale: pixelScale)

    // 5. Rim light: a thin specular edge, bright at the top and fading toward the bottom.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setLineWidth(detail == .tiny ? 16 : 7)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([
            (0.00, color(0xFFFFFF, 0.55)),
            (0.25, color(0xFFFFFF, 0.16)),
            (0.70, color(0xFFFFFF, 0.04)),
            (1.00, color(0x000000, 0.25)),
        ]),
        start: CGPoint(x: 0, y: body.maxY),
        end: CGPoint(x: 0, y: body.minY),
        options: []
    )
    ctx.restoreGState()

    ctx.restoreGState()
}

func drawMenuBarStrip(_ ctx: CGContext, detail: Detail, pixelScale: CGFloat) {
    let strip = CGRect(x: 172, y: 716, width: 680, height: 104)
    let stripPath = CGPath(roundedRect: strip, cornerWidth: 52, cornerHeight: 52, transform: nil)

    // Depth: a soft shadow under the glass.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * pixelScale), blur: 30 * pixelScale, color: color(0x02121C, 0.45))
    ctx.addPath(stripPath)
    ctx.setFillColor(color(0x0E3A4A, 0.55))
    ctx.fillPath()
    ctx.restoreGState()

    // Glass fill: brighter at the top edge.
    ctx.saveGState()
    ctx.addPath(stripPath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, color(0xFFFFFF, 0.30)), (0.55, color(0xFFFFFF, 0.14)), (1, color(0xFFFFFF, 0.10))]),
        start: CGPoint(x: 0, y: strip.maxY),
        end: CGPoint(x: 0, y: strip.minY),
        options: []
    )
    ctx.restoreGState()

    // Specular edge.
    ctx.saveGState()
    ctx.addPath(stripPath)
    ctx.setLineWidth(3)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, color(0xFFFFFF, 0.75)), (0.5, color(0xFFFFFF, 0.15)), (1, color(0xFFFFFF, 0.30))]),
        start: CGPoint(x: 0, y: strip.maxY),
        end: CGPoint(x: 0, y: strip.minY),
        options: []
    )
    ctx.restoreGState()

    let midY = strip.midY
    // Visible items to the right of the divider.
    let visible: [CGFloat] = detail == .full ? [640, 712, 784] : [668, 768]
    for (i, x) in visible.enumerated() {
        let size: CGFloat = detail == .full ? 34 : 44
        let rect = CGRect(x: x - size / 2, y: midY - size / 2, width: size, height: size)
        ctx.setFillColor(color(0xFFFFFF, 0.92))
        if i % 2 == 0 {
            ctx.fillEllipse(in: rect)
        } else {
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: size * 0.28, cornerHeight: size * 0.28, transform: nil))
            ctx.fillPath()
        }
    }

    guard detail == .full else { return }

    // Divider (Barback's separator) and the hidden items fading out to its left.
    ctx.setFillColor(color(0xFFFFFF, 0.55))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 574, y: midY - 26, width: 6, height: 52), cornerWidth: 3, cornerHeight: 3, transform: nil))
    ctx.fillPath()

    for (x, alpha) in [(512, 0.34), (448, 0.20), (384, 0.10)] as [(CGFloat, CGFloat)] {
        let size: CGFloat = 30
        let rect = CGRect(x: x - size / 2, y: midY - size / 2, width: size, height: size)
        ctx.setFillColor(color(0xFFFFFF, alpha))
        ctx.fillEllipse(in: rect)
    }
}

func drawChevron(_ ctx: CGContext, detail: Detail, pixelScale: CGFloat) {
    let center: CGPoint
    let halfHeight: CGFloat
    let depth: CGFloat
    let lineWidth: CGFloat
    switch detail {
    case .tiny:
        center = CGPoint(x: 494, y: 512)
        halfHeight = 250
        depth = 250
        lineWidth = 150
    case .small:
        center = CGPoint(x: 494, y: 418)
        halfHeight = 200
        depth = 200
        lineWidth = 118
    case .full:
        center = CGPoint(x: 494, y: 418)
        halfHeight = 200
        depth = 200
        lineWidth = 104
    }

    let stroke = chevronPath(center: center, halfHeight: halfHeight, depth: depth)
        .copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
        .normalized()

    // Depth: the glass chevron floats above the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22 * pixelScale), blur: (detail == .tiny ? 24 : 46) * pixelScale, color: color(0x010A12, 0.55))
    ctx.addPath(stroke)
    ctx.setFillColor(color(0xD9F7FA))
    ctx.fillPath()
    ctx.restoreGState()

    // Glass body: near-white at the top, cool aqua toward the bottom.
    ctx.saveGState()
    ctx.addPath(stroke)
    ctx.clip()
    let top = center.y + halfHeight + lineWidth / 2
    let bottom = center.y - halfHeight - lineWidth / 2
    ctx.drawLinearGradient(
        gradient([(0, color(0xFFFFFF)), (0.5, color(0xD8F6F8)), (1, color(0x8ADBE4))]),
        start: CGPoint(x: 0, y: top),
        end: CGPoint(x: 0, y: bottom),
        options: []
    )

    if detail >= .small {
        // Inner specular highlight hugging the upper edge of each arm.
        let highlight = chevronPath(
            center: CGPoint(x: center.x + lineWidth * 0.10, y: center.y + lineWidth * 0.20),
            halfHeight: halfHeight,
            depth: depth
        ).copy(strokingWithWidth: lineWidth * 0.30, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.addPath(highlight)
        ctx.setFillColor(color(0xFFFFFF, 0.55))
        ctx.setBlendMode(.softLight)
        ctx.fillPath()
        ctx.setBlendMode(.normal)
    }
    ctx.restoreGState()

    // Crisp glass edge.
    if detail >= .small {
        ctx.saveGState()
        ctx.addPath(stroke)
        ctx.setLineWidth(max(2, 1.2 / pixelScale))
        ctx.setStrokeColor(color(0xFFFFFF, 0.65))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

// MARK: - Output

func renderPNG(pixels: Int) -> Data {
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGBSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a \(pixels)px bitmap context")
    }
    let scale = CGFloat(pixels) / 1024
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: scale, y: scale)
    drawIcon(ctx, detail: Detail(pixels: pixels), pixelScale: scale)
    guard
        let image = ctx.makeImage(),
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else {
        fatalError("Could not encode the \(pixels)px PNG")
    }
    return png
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make_icon: \(message)\n".utf8))
    exit(1)
}

func main() {
    let keepIconset = CommandLine.arguments.dropFirst().contains("--keep-iconset")
    let script = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let root = script.deletingLastPathComponent().deletingLastPathComponent()
    let fm = FileManager.default

    let iconset = root.appendingPathComponent("Resources/AppIcon.iconset", isDirectory: true)
    let icns = root.appendingPathComponent("Resources/AppIcon.icns")
    let readme = root.appendingPathComponent("docs/assets/icon-1024.png")

    // Every file iconutil expects in a macOS .iconset: 16-512 pt at @1x and @2x.
    let files: [(String, Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]

    do {
        try? fm.removeItem(at: iconset)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        try fm.createDirectory(at: readme.deletingLastPathComponent(), withIntermediateDirectories: true)

        var rendered: [Int: Data] = [:]
        for (name, pixels) in files {
            let png = rendered[pixels] ?? renderPNG(pixels: pixels)
            rendered[pixels] = png
            try png.write(to: iconset.appendingPathComponent(name))
        }
        try (rendered[1024] ?? renderPNG(pixels: 1024)).write(to: readme)
    } catch {
        fail("could not write the iconset: \(error)")
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", "-o", icns.path, iconset.path]
    do {
        try iconutil.run()
    } catch {
        fail("could not run iconutil: \(error)")
    }
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        fail("iconutil failed with status \(iconutil.terminationStatus)")
    }

    if !keepIconset {
        try? fm.removeItem(at: iconset)
    }
    print("wrote \(icns.path)")
    print("wrote \(readme.path)")
}

main()
