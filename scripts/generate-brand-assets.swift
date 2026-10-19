#!/usr/bin/env swift
// Generates the fixed LightIsle brand mark from one original hexagonal geometry.
// Unlike the temporary SF Symbol used in the prototype intro, this mark may be
// used as the app icon, favicon, splash logo and web brand artwork.
import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fileManager = FileManager.default
let macResources = root.appendingPathComponent("apps/macos/Resources", isDirectory: true)
let webPublic = root.appendingPathComponent("apps/web/public", isDirectory: true)
let sourceAssets = root.appendingPathComponent("assets/brand", isDirectory: true)
let iconset = root.appendingPathComponent("dist/LightIsle.iconset", isDirectory: true)

for directory in [macResources, webPublic, sourceAssets, iconset] {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
}

let hexCenters: [(CGFloat, CGFloat)] = [
    (512, 512), (358, 512), (666, 512),
    (435, 378), (589, 378), (435, 646), (589, 646)
]
let radius: CGFloat = 83
func hexPoints(_ cx: CGFloat, _ cy: CGFloat) -> [CGPoint] {
    (0..<6).map { index in
        let angle = CGFloat(index) * .pi / 3 - .pi / 2
        return CGPoint(x: cx + radius * cos(angle), y: cy + radius * sin(angle))
    }
}
func pathForHex(_ cx: CGFloat, _ cy: CGFloat) -> CGPath {
    let points = hexPoints(cx, cy)
    let path = CGMutablePath()
    path.move(to: points[0])
    for point in points.dropFirst() { path.addLine(to: point) }
    path.closeSubpath()
    return path
}
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}
let cardGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(0.96,0.99,1), color(0.79,0.88,1), color(0.75,0.77,0.98)] as CFArray,
    locations: [0,0.52,1])!
let markGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(0.05,0.79,0.89), color(0.09,0.48,0.93), color(0.42,0.29,0.88)] as CFArray,
    locations: [0,0.48,1])!

func draw(in ctx: CGContext) {
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    let card = CGPath(roundedRect: CGRect(x: 86,y: 86,width: 852,height: 852),
                      cornerWidth: 210,cornerHeight: 210,transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0,height: -12), blur: 28,
                  color: color(0.12,0.31,0.65,0.26))
    ctx.addPath(card)
    ctx.setFillColor(color(0.75,0.88,1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(card)
    ctx.clip()
    ctx.drawLinearGradient(cardGradient, start: CGPoint(x: 150,y: 910),
                           end: CGPoint(x: 870,y: 110), options: [])
    // Frosted upper-left illumination.
    ctx.setFillColor(color(1,1,1,0.24))
    ctx.fillEllipse(in: CGRect(x: 85,y: 625,width: 740,height: 380))
    ctx.restoreGState()
    ctx.addPath(card)
    ctx.setStrokeColor(color(1,1,1,0.74))
    ctx.setLineWidth(12)
    ctx.strokePath()

    ctx.saveGState()
    ctx.setLineWidth(28)
    ctx.addEllipse(in: CGRect(x: 176,y: 176,width: 672,height: 672))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(markGradient, start: CGPoint(x: 250,y: 800),
                           end: CGPoint(x: 790,y: 190), options: [])
    ctx.restoreGState()

    for (cx, cy) in hexCenters {
        let hex = pathForHex(cx,cy)
        ctx.saveGState()
        ctx.addPath(hex)
        ctx.clip()
        ctx.drawLinearGradient(markGradient, start: CGPoint(x: 260,y: 760),
                               end: CGPoint(x: 750,y: 240), options: [])
        ctx.restoreGState()
        ctx.addPath(hex)
        ctx.setLineWidth(9)
        ctx.setStrokeColor(color(1,1,1,0.74))
        ctx.strokePath()
    }
}

func render(_ size: Int, at location: URL) throws {
    guard let context = CGContext(data:nil,width:size,height:size,bitsPerComponent:8,
                                 bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain:"LightIsleBrand",code:1)
    }
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(size)/1024, y: CGFloat(size)/1024)
    draw(in:context)
    guard let cgImage = context.makeImage(),
          let png = NSBitmapImageRep(cgImage:cgImage).representation(using:.png,properties:[:]) else {
        throw NSError(domain:"LightIsleBrand",code:2)
    }
    try png.write(to: location, options: .atomic)
}
let iconsetSizes: [(String,Int)] = [
    ("icon_16x16.png",16),("icon_16x16@2x.png",32),
    ("icon_32x32.png",32),("icon_32x32@2x.png",64),
    ("icon_128x128.png",128),("icon_128x128@2x.png",256),
    ("icon_256x256.png",256),("icon_256x256@2x.png",512),
    ("icon_512x512.png",512),("icon_512x512@2x.png",1024)
]
for (name,size) in iconsetSizes {
    try render(size,at:iconset.appendingPathComponent(name))
}
for (file,size) in [
    (macResources.appendingPathComponent("LightIsleLogo.png"),512),
    (webPublic.appendingPathComponent("favicon.png"),32),
    (webPublic.appendingPathComponent("apple-touch-icon.png"),180),
    (webPublic.appendingPathComponent("brand-icon.png"),192),
    (webPublic.appendingPathComponent("brand-icon-512.png"),512)
] {
    try render(size,at:file)
}

func hexSVG(_ cx:CGFloat,_ cy:CGFloat)->String {
    let points=hexPoints(cx,cy)
    return "<polygon points=\"" + points.map {
        String(format:"%.2f,%.2f",Double($0.x),Double(1024-$0.y))
    }.joined(separator:" ") + "\" fill=\"url(#mark)\" stroke=\"#fff\" stroke-opacity=\".74\" stroke-width=\"9\" stroke-linejoin=\"round\"/>"
}
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-labelledby="title">
  <title id="title">LightIsle 轻屿 Logo</title>
  <defs>
    <linearGradient id="card" x1="15%" y1="5%" x2="90%" y2="90%">
      <stop stop-color="#f5fcff"/><stop offset=".52" stop-color="#c9e0ff"/><stop offset="1" stop-color="#bfc4fa"/>
    </linearGradient>
    <linearGradient id="mark" x1="15%" y1="12%" x2="85%" y2="90%">
      <stop stop-color="#0dc9e3"/><stop offset=".48" stop-color="#177aed"/><stop offset="1" stop-color="#6b4ae0"/>
    </linearGradient>
    <clipPath id="cardClip"><rect x="86" y="86" width="852" height="852" rx="210"/></clipPath>
  </defs>
  <rect x="86" y="86" width="852" height="852" rx="210" fill="url(#card)" stroke="#fff" stroke-opacity=".74" stroke-width="12"/>
  <ellipse cx="455" cy="209" rx="370" ry="190" fill="#fff" opacity=".24" clip-path="url(#cardClip)"/>
  <circle cx="512" cy="512" r="336" fill="none" stroke="url(#mark)" stroke-width="28"/>
  \(hexCenters.map { hexSVG($0.0,$0.1) }.joined(separator:"\n  "))
</svg>
"""
try svg.write(to:sourceAssets.appendingPathComponent("lightisle-logo.svg"),atomically:true,encoding:.utf8)
try svg.write(to:webPublic.appendingPathComponent("brand-icon.svg"),atomically:true,encoding:.utf8)
print("Generated consistent LightIsle brand resources (SVG, PNG and macOS iconset).")
