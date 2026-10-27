// SPDX-License-Identifier: GPL-2.0-or-later
// Draws the PS4 Native app icon into an .iconset directory: a generic gamepad glyph on a dark
// rounded square, at every size `iconutil -c icns` expects. CoreGraphics only; no logos.
//
// Usage: swift make-icon.swift <out.iconset>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <out.iconset>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [r, g, b, a])!
}

/// Draws the icon on a 1024-unit canvas scaled to `ctx`'s size.
func draw(_ ctx: CGContext, size: Int) {
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s)

    // The rounded square on the macOS icon grid (824 units with a 100-unit margin).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.45))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0.09, 0.1, 0.13))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let background = CGGradient(colorsSpace: srgb, colors: [color(0.2, 0.23, 0.29), color(0.07, 0.08, 0.1)] as CFArray,
                                locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // The gamepad body: a wide rounded bar with a grip hanging from each end.
    let body = CGMutablePath()
    body.addRoundedRect(in: CGRect(x: 222, y: 430, width: 580, height: 230), cornerWidth: 115, cornerHeight: 115)
    for x in [222.0, 642.0] {
        body.addRoundedRect(in: CGRect(x: x, y: 300, width: 160, height: 300), cornerWidth: 80, cornerHeight: 80)
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0, 0, 0, 0.5))
    ctx.addPath(body)
    ctx.setFillColor(color(0.9, 0.92, 0.95))
    ctx.fillPath()
    ctx.restoreGState()

    // The d-pad on the left and four face buttons on the right, cut in the body's dark colour.
    ctx.setFillColor(color(0.14, 0.16, 0.2))
    let pad = CGPoint(x: 342, y: 545), arm: CGFloat = 46, half: CGFloat = 17
    ctx.fill(CGRect(x: pad.x - arm, y: pad.y - half, width: arm * 2, height: half * 2))
    ctx.fill(CGRect(x: pad.x - half, y: pad.y - arm, width: half * 2, height: arm * 2))
    let face = CGPoint(x: 682, y: 545), offset: CGFloat = 40, radius: CGFloat = 19
    for (dx, dy) in [(0.0, 1.0), (1.0, 0.0), (0.0, -1.0), (-1.0, 0.0)] {
        let c = CGPoint(x: face.x + dx * offset, y: face.y + dy * offset)
        ctx.fillEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
    }
    // Two small centre buttons.
    for x in [474.0, 550.0] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x - 18, y: 588, width: 36, height: 16), cornerWidth: 8, cornerHeight: 8,
                           transform: nil))
    }
    ctx.fillPath()
}

func writeIcon(points: Int, scale: Int) throws {
    let size = points * scale
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CocoaError(.featureUnsupported)
    }
    ctx.interpolationQuality = .high
    draw(ctx, size: size)
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@\(scale)x.png"
    let url = out.appendingPathComponent(name)
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] { try writeIcon(points: points, scale: scale) }
}
print("make-icon: wrote \(out.path)")
