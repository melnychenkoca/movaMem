// Draws the app icon and writes it as an .icns.
//
// The icon is generated rather than checked in as a binary so it can be
// reviewed as code, and so the whole set regenerates consistently when
// something changes. Both positions below are derived from the rendered font
// metrics rather than hardcoded, which is what keeps the layout correct at
// every size macOS asks for, from 16px in a Finder list to 1024px.
//
// Run via `make icon`, which the bundle step depends on. Do not edit
// Resources/AppIcon.icns by hand; it is a build product.

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.icns>\n".data(using: .utf8)!)
    exit(1)
}
let outputPath = arguments[1]

// Purple, with a vertical gradient. Not a system accent colour: the icon should
// look the same for every user regardless of their accent setting.
let purpleTop = NSColor(calibratedRed: 0.45, green: 0.30, blue: 0.92, alpha: 1)
let purpleBottom = NSColor(calibratedRed: 0.28, green: 0.16, blue: 0.66, alpha: 1)

/// Draws text centred horizontally in `rect`, with its line box bottom at
/// `rect.minY`.
func drawText(
    _ text: String,
    font: NSFont,
    color: NSColor,
    in rect: NSRect,
    kern: CGFloat
) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: style,
        .kern: kern,
    ]
    NSAttributedString(string: text, attributes: attributes).draw(in: rect)
}

func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    // The rounded-rect plate. App icons do not fill their square: the padding
    // and the ~22% corner radius are what make an icon look native next to
    // Apple's own.
    let inset = size * 0.08
    let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let plateRadius = plate.width * 0.2237
    let platePath = NSBezierPath(roundedRect: plate, xRadius: plateRadius, yRadius: plateRadius)
    NSGradient(starting: purpleTop, ending: purpleBottom)?.draw(in: platePath, angle: -90)

    // --- "mova", centred on the plate ---

    let word = "mova"
    let wordFontSize = size * 0.23
    let wordFont = NSFont.systemFont(ofSize: wordFontSize, weight: .bold)
    let wordKern = -wordFontSize * 0.02
    let wordAttributes: [NSAttributedString.Key: Any] = [.font: wordFont, .kern: wordKern]
    let wordMetrics = NSAttributedString(string: word, attributes: wordAttributes).size()

    // Centre on the drawn glyphs, not the line box. A line box carries ascender
    // and descender room that lowercase "mova" never fills, so centring on it
    // would leave the word sitting visibly high. "mova" is entirely x-height
    // letters, so its ink runs from the baseline up to the x-height, and the
    // midpoint of that span is what belongs on the plate's midline.
    let baselineY = plate.midY - wordFont.xHeight / 2
    // drawText positions by the line box, whose bottom sits a descender below
    // the baseline.
    let wordRect = NSRect(
        x: 0,
        y: baselineY + wordFont.descender,
        width: size,
        height: wordMetrics.height
    )
    drawText(word, font: wordFont, color: .white, in: wordRect, kern: wordKern)

    // --- The "mem" badge, above the "va" ---

    let badgeText = "mem"
    let badgeFontSize = size * 0.115
    let badgeFont = NSFont.systemFont(ofSize: badgeFontSize, weight: .semibold)
    let badgeMetrics = NSAttributedString(string: badgeText, attributes: [.font: badgeFont]).size()

    let padX = size * 0.045
    let padY = size * 0.022
    let badgeWidth = badgeMetrics.width + padX * 2
    let badgeHeight = badgeMetrics.height + padY * 2

    // Right edge aligned with the word's right edge, so the two share a clean
    // right margin. "mem" is wider than "va", so the badge reaches back over
    // the "o" — that is the alignment working, not a defect.
    let wordMaxX = (size + wordMetrics.width) / 2
    let alignedRightX = wordMaxX - badgeWidth
    // Measuring "mo" locates where "va" begins without hardcoding a fraction of
    // the word. The clamp keeps the badge from ever starting left of the "va"
    // should font metrics shift between macOS versions.
    let moWidth = NSAttributedString(string: "mo", attributes: wordAttributes).size().width
    let vaStartX = (size - wordMetrics.width) / 2 + moWidth
    let badgeX = max(vaStartX, alignedRightX)

    // Sits just above the word's ink. Measured from the x-height rather than a
    // fixed fraction of the plate, so it cannot collide with the word or drift
    // away as the font size changes.
    let wordInkTop = baselineY + wordFont.xHeight
    let badgeRect = NSRect(
        x: badgeX,
        y: wordInkTop + size * 0.035,
        width: badgeWidth,
        height: badgeHeight
    )

    let badgePath = NSBezierPath(
        roundedRect: badgeRect,
        xRadius: badgeHeight / 2,
        yRadius: badgeHeight / 2
    )
    NSColor.white.setFill()
    badgePath.fill()

    // The badge's own text is centred in the pill by the same line-box rule.
    let badgeTextRect = NSRect(
        x: badgeRect.minX,
        y: badgeRect.midY - badgeMetrics.height / 2,
        width: badgeRect.width,
        height: badgeMetrics.height
    )
    drawText(badgeText, font: badgeFont, color: purpleBottom, in: badgeTextRect, kern: 0)

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to path: String) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "could not encode \(path)",
        ])
    }
    try png.write(to: URL(fileURLWithPath: path))
}

/// Renders at `size` by drawing large and scaling down.
///
/// Drawing directly at 32px produces sharper edges but leaves too few pixels
/// for the "mem" badge, which turns to a smear. Supersampling keeps the badge
/// legible at the small sizes Finder list views and the menu bar actually use.
func renderIconSupersampled(size: CGFloat) -> NSImage {
    // Below this, direct rendering has enough pixels and stays crisper.
    let supersampleThreshold: CGFloat = 128
    if size >= supersampleThreshold {
        return renderIcon(size: size)
    }

    let source = renderIcon(size: size * 8)
    let scaled = NSImage(size: NSSize(width: size, height: size))
    scaled.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: .zero,
        operation: .copy,
        fraction: 1.0
    )
    scaled.unlockFocus()
    return scaled
}

// Every size macOS looks for.
let iconSizes: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let fileManager = FileManager.default
let workDirectory = NSTemporaryDirectory() + "movamem-icon-\(ProcessInfo.processInfo.processIdentifier)"
let iconsetDirectory = workDirectory + "/AppIcon.iconset"

do {
    try fileManager.createDirectory(atPath: iconsetDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(atPath: workDirectory) }

    for entry in iconSizes {
        try writePNG(renderIconSupersampled(size: entry.pixels), to: "\(iconsetDirectory)/\(entry.name)")
    }

    // iconutil is the only supported way to produce an .icns.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconsetDirectory, "-o", outputPath]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
        exit(1)
    }
    print("Wrote \(outputPath)")
} catch {
    FileHandle.standardError.write("icon generation failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
