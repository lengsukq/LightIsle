#!/usr/bin/env swift
// Generates the unified LightIsle brand mark (Prismatic Crystalline Isle & Radiant Beacon).
// This single vector master produces the macOS .app iconset & .icns, native SwiftUI
// brand assets, web SVG/favicons, and PWA mobile touch icons.
import AppKit
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

let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-labelledby="title">
  <title id="title">LightIsle 轻屿 Logo</title>
  <defs>
    <!-- Background: Deep Celestial Sapphire into Midnight Indigo -->
    <linearGradient id="cardGrad" x1="12%" y1="8%" x2="88%" y2="92%">
      <stop offset="0%" stop-color="#075985"/>
      <stop offset="28%" stop-color="#0369a1"/>
      <stop offset="60%" stop-color="#1d4ed8"/>
      <stop offset="88%" stop-color="#312e81"/>
      <stop offset="100%" stop-color="#1e1b4b"/>
    </linearGradient>

    <!-- Ambient Sky & Dawn Bloom -->
    <radialGradient id="skyBloom" cx="50%" cy="32%" r="58%">
      <stop offset="0%" stop-color="#38bdf8" stop-opacity="0.45"/>
      <stop offset="32%" stop-color="#818cf8" stop-opacity="0.25"/>
      <stop offset="70%" stop-color="#4f46e5" stop-opacity="0.08"/>
      <stop offset="100%" stop-color="#000000" stop-opacity="0"/>
    </radialGradient>

    <!-- Star Glow -->
    <radialGradient id="starGlow" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="#ffffff" stop-opacity="0.95"/>
      <stop offset="35%" stop-color="#bae6fd" stop-opacity="0.6"/>
      <stop offset="75%" stop-color="#38bdf8" stop-opacity="0.2"/>
      <stop offset="100%" stop-color="#38bdf8" stop-opacity="0"/>
    </radialGradient>

    <!-- Facet 1: Top Crest (Solar Plateau) -->
    <linearGradient id="crestGrad" x1="20%" y1="0%" x2="80%" y2="100%">
      <stop offset="0%" stop-color="#ffffff"/>
      <stop offset="45%" stop-color="#e0f2fe"/>
      <stop offset="100%" stop-color="#bae6fd"/>
    </linearGradient>

    <!-- Facet 2: Left Slope (Azure Dawn) -->
    <linearGradient id="leftSlopeGrad" x1="10%" y1="0%" x2="90%" y2="100%">
      <stop offset="0%" stop-color="#38bdf8"/>
      <stop offset="50%" stop-color="#0284c7"/>
      <stop offset="100%" stop-color="#075985"/>
    </linearGradient>

    <!-- Facet 3: Right Slope (Twilight Amethyst) -->
    <linearGradient id="rightSlopeGrad" x1="0%" y1="10%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#c4b5fd"/>
      <stop offset="48%" stop-color="#7c3aed"/>
      <stop offset="100%" stop-color="#3730a3"/>
    </linearGradient>

    <!-- Horizon Ring Aura -->
    <linearGradient id="ringGrad" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#38bdf8" stop-opacity="0.5"/>
      <stop offset="50%" stop-color="#ffffff" stop-opacity="0.2"/>
      <stop offset="100%" stop-color="#c084fc" stop-opacity="0.45"/>
    </linearGradient>

    <!-- Waterline Ripple Gradient -->
    <linearGradient id="waterGrad" x1="0%" y1="0%" x2="100%" y2="0%">
      <stop offset="0%" stop-color="#38bdf8" stop-opacity="0.15"/>
      <stop offset="30%" stop-color="#e0f2fe" stop-opacity="0.75"/>
      <stop offset="50%" stop-color="#ffffff" stop-opacity="0.95"/>
      <stop offset="70%" stop-color="#e0e7ff" stop-opacity="0.75"/>
      <stop offset="100%" stop-color="#c084fc" stop-opacity="0.15"/>
    </linearGradient>

    <!-- Center Ridge Specular Highlight -->
    <linearGradient id="ridgeGrad" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#ffffff" stop-opacity="0.9"/>
      <stop offset="50%" stop-color="#ffffff" stop-opacity="0.4"/>
      <stop offset="100%" stop-color="#bae6fd" stop-opacity="0.1"/>
    </linearGradient>

    <clipPath id="cardClip">
      <rect x="86" y="86" width="852" height="852" rx="210" ry="210"/>
    </clipPath>
  </defs>

  <!-- Masked Card Canvas -->
  <g clip-path="url(#cardClip)">
    <!-- Base Gradient -->
    <rect x="86" y="86" width="852" height="852" fill="url(#cardGrad)"/>

    <!-- Ambient Sky Glow -->
    <circle cx="512" cy="350" r="420" fill="url(#skyBloom)"/>

    <!-- Ethereal Sanctuary Halo Ring -->
    <circle cx="512" cy="512" r="286" fill="none" stroke="url(#ringGrad)" stroke-width="2.5" opacity="0.4"/>

    <!-- Water Reflection Ambient Glow -->
    <ellipse cx="512" cy="690" rx="260" ry="26" fill="#38bdf8" opacity="0.25"/>

    <!-- The Crystalline Isle -->
    <!-- Facet 2: Left Azure Slope -->
    <polygon points="388,404 512,464 512,680 264,612" fill="url(#leftSlopeGrad)" stroke="#ffffff" stroke-opacity="0.28" stroke-width="1.5" stroke-linejoin="round"/>

    <!-- Facet 3: Right Amethyst Slope -->
    <polygon points="636,404 512,464 512,680 760,612" fill="url(#rightSlopeGrad)" stroke="#ffffff" stroke-opacity="0.28" stroke-width="1.5" stroke-linejoin="round"/>

    <!-- Facet 1: Top Crest (Solar Plateau) -->
    <polygon points="512,252 636,404 512,464 388,404" fill="url(#crestGrad)" stroke="#ffffff" stroke-opacity="0.65" stroke-width="2" stroke-linejoin="round"/>

    <!-- Center Ridge Specular Highlight Line -->
    <line x1="512" y1="464" x2="512" y2="680" stroke="url(#ridgeGrad)" stroke-width="2.5" stroke-linecap="round"/>

    <!-- Calm Sanctuary Waterlines -->
    <rect x="320" y="718" width="384" height="14" rx="7" fill="url(#waterGrad)"/>
    <rect x="404" y="748" width="216" height="10" rx="5" fill="url(#waterGrad)" opacity="0.65"/>

    <!-- Beacon Star of Light -->
    <circle cx="512" cy="214" r="42" fill="url(#starGlow)"/>
    <polygon points="512,186 518,210 542,214 518,218 512,242 506,218 482,214 506,210" fill="#ffffff"/>
    <circle cx="512" cy="214" r="2.5" fill="#ffffff"/>
  </g>

  <!-- Outer Glass Rim Highlight (Apple HIG Standard) -->
  <rect x="86" y="86" width="852" height="852" rx="210" ry="210" fill="none" stroke="#ffffff" stroke-opacity="0.26" stroke-width="4"/>
</svg>
"""

let sourceSvgPath = sourceAssets.appendingPathComponent("lightisle-logo.svg")
let webSvgPath = webPublic.appendingPathComponent("brand-icon.svg")

try svg.write(to: sourceSvgPath, atomically: true, encoding: .utf8)
try svg.write(to: webSvgPath, atomically: true, encoding: .utf8)

guard let svgImage = NSImage(contentsOf: sourceSvgPath) else {
    fatalError("Failed to parse master SVG with NSImage")
}

func renderPNG(size: Int, at location: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "LightIsleBrand", code: 1)
    }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        NSGraphicsContext.restoreGraphicsState()
        throw NSError(domain: "LightIsleBrand", code: 2)
    }
    ctx.imageInterpolation = .high
    ctx.shouldAntialias = true
    NSGraphicsContext.current = ctx
    svgImage.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: NSRect(x: 0, y: 0, width: 1024, height: 1024),
        operation: .copy,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "LightIsleBrand", code: 3)
    }
    try pngData.write(to: location, options: .atomic)
}

let iconsetSizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (name, size) in iconsetSizes {
    try renderPNG(size: size, at: iconset.appendingPathComponent(name))
}

let targets: [(URL, Int)] = [
    (macResources.appendingPathComponent("LightIsleLogo.png"), 512),
    (webPublic.appendingPathComponent("favicon.png"), 32),
    (webPublic.appendingPathComponent("apple-touch-icon.png"), 180),
    (webPublic.appendingPathComponent("brand-icon.png"), 192),
    (webPublic.appendingPathComponent("brand-icon-512.png"), 512)
]

for (file, size) in targets {
    try renderPNG(size: size, at: file)
}

// Synchronize into existing packaged bundle if present so incremental builds/tests pass
let appDist = root.appendingPathComponent("dist/LightIsle.app", isDirectory: true)
let appResources = appDist.appendingPathComponent("Contents/Resources", isDirectory: true)
if fileManager.fileExists(atPath: appResources.path) {
    let appLogo = appResources.appendingPathComponent("LightIsleLogo.png")
    try? fileManager.removeItem(at: appLogo)
    try? fileManager.copyItem(at: macResources.appendingPathComponent("LightIsleLogo.png"), to: appLogo)

    let icnsDestination = appResources.appendingPathComponent("LightIsle.icns")
    let iconutilTask = Process()
    iconutilTask.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutilTask.arguments = ["-c", "icns", "-o", icnsDestination.path, iconset.path]
    try? iconutilTask.run()
    iconutilTask.waitUntilExit()

    let appWeb = appResources.appendingPathComponent("web", isDirectory: true)
    if fileManager.fileExists(atPath: appWeb.path) {
        for name in ["brand-icon.svg", "favicon.png", "apple-touch-icon.png", "brand-icon.png", "brand-icon-512.png"] {
            let src = webPublic.appendingPathComponent(name)
            let dst = appWeb.appendingPathComponent(name)
            try? fileManager.removeItem(at: dst)
            try? fileManager.copyItem(at: src, to: dst)
        }
    }
}

print("Generated consistent LightIsle brand resources (SVG, PNG and macOS iconset).")
