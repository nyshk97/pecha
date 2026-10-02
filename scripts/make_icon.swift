#!/usr/bin/env swift
import AppKit

// Pecha のアプリアイコン（macOS 26 向けフルブリード。角丸・余白・外周の影はシステムが付けるので描かない）。
// デザイン: 珊瑚色の地に白い吹き出し、中に声の波形の縦棒 5 本。
// 使い方: swift scripts/make_icon.swift          → Sources/Assets.xcassets/AppIcon.appiconset
//         swift scripts/make_icon.swift --dev    → Sources/Assets.xcassets/AppIconDev.appiconset（DEV の帯付き）
// 生成物の PNG はコミットする（毎ビルドで作らない）。

let dev = CommandLine.arguments.contains("--dev")
let outDir = "Sources/Assets.xcassets/\(dev ? "AppIconDev" : "AppIcon").appiconset"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func render(_ px: Int) -> NSBitmapImageRep {
    // alpha 無し（noneSkipLast）で作る
    let cg = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
    let s = CGFloat(px)
    // 座標は 1024 角・上から下への値で書き、ここで変換する
    let u = s / 1024
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x * u, y: s - (y + h) * u, width: w * u, height: h * u)
    }

    // 地: 珊瑚色のグラデーション
    NSGradient(starting: color(0xFF8A6B), ending: color(0xE8505B))!.draw(in: CGRect(x: 0, y: 0, width: s, height: s), angle: -90)

    // 吹き出し（角丸の四角＋左下のしっぽ）
    let bubble = rect(196, 232, 632, 470)
    let radius = 150 * u
    let path = CGMutablePath()
    path.addRoundedRect(in: bubble, cornerWidth: radius, cornerHeight: radius)
    path.move(to: CGPoint(x: 300 * u, y: s - 660 * u))
    path.addLine(to: CGPoint(x: 268 * u, y: s - 820 * u))
    path.addLine(to: CGPoint(x: 460 * u, y: s - 690 * u))
    path.closeSubpath()
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -18 * u), blur: 40 * u, color: color(0x7A1E2A, 0.28).cgColor)
    cg.addPath(path)
    cg.setFillColor(color(0xFFF8F4).cgColor)
    cg.fillPath()
    cg.restoreGState()

    // 声の波形（中央が高い 5 本）
    let heights: [CGFloat] = [120, 230, 320, 230, 120]
    let barWidth: CGFloat = 58
    let gap: CGFloat = 44
    let total = barWidth * 5 + gap * 4
    let left = 512 - total / 2
    let centerY: CGFloat = 467
    cg.setFillColor(color(0xE8505B).cgColor)
    for (i, h) in heights.enumerated() {
        let r = rect(left + CGFloat(i) * (barWidth + gap), centerY - h / 2, barWidth, h)
        cg.addPath(CGPath(roundedRect: r, cornerWidth: r.width / 2, cornerHeight: r.width / 2, transform: nil))
    }
    cg.fillPath()

    if dev {
        let band = CGRect(x: 0, y: 0, width: s, height: s * 0.19)
        color(0x2F6FED).setFill()
        NSBezierPath(rect: band).fill()
        let font = NSFont.systemFont(ofSize: s * 0.12, weight: .heavy)
        let str = NSAttributedString(string: "DEV", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: s * 0.012])
        let line = CTLineCreateWithAttributedString(str)
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        str.draw(at: CGPoint(x: band.midX - b.midX, y: band.midY - b.midY))
    }
    NSGraphicsContext.restoreGraphicsState()
    return NSBitmapImageRep(cgImage: cg.makeImage()!)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let png = render(px).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(px).png"))
}
let contents = """
{
  "images" : [
    { "filename" : "icon_16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

"""
try! contents.write(toFile: "\(outDir)/Contents.json", atomically: true, encoding: .utf8)
print("OK: \(outDir)")
