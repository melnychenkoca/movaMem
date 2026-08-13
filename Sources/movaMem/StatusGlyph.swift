import AppKit
import Foundation

/// The "mM" glyph shown in the menu bar.
///
/// Drawn rather than shipped as an image asset: the menu bar height is not
/// fixed, and drawing lets the glyph be measured and centred against real font
/// metrics at whatever size is asked for.
///
/// The result is a *template* image, which is what lets macOS own its
/// appearance — inverting it for light and dark menu bars and dimming it while
/// the menu is open. A non-template image would render as a solid dark blob on
/// a dark menu bar.
enum StatusGlyph {
    /// The text is deliberately mixed-case, echoing "movaMem".
    static let text = "mM"

    /// Whether to draw a rounded border around the letters.
    ///
    /// Kept as a switch rather than deleted so the two treatments can be
    /// compared by flipping one value. Bordered is the current choice: it echoes
    /// the pill in the app icon. The trade is that most menu bar items are
    /// unenclosed, so this one sits louder than its neighbours.
    static let isBordered = true

    /// Border stroke width, as a fraction of the glyph height.
    private static let strokeRatio: CGFloat = 0.055
    /// Space between the letters and the border, as a fraction of the height.
    private static let horizontalPadRatio: CGFloat = 0.22
    /// Corner radius, as a fraction of the border box height. Half gives a full
    /// pill; this is a little less, so the corners read as rounded rather than
    /// as a capsule.
    private static let cornerRatio: CGFloat = 0.35
    /// Side padding when there is no border to sit inside. Smaller, because the
    /// padding only has to keep the letters off their neighbours.
    private static let borderlessPadRatio: CGFloat = 0.1

    /// Canvas width for `text` at the given height, including padding and, when
    /// bordered, the stroke.
    ///
    /// A square canvas is wrong here: "m" and "M" are two of the widest letters
    /// in the alphabet, and a square one clips the second outright.
    static func width(forHeight height: CGFloat, font: NSFont) -> CGFloat {
        let measured = NSAttributedString(string: text, attributes: [.font: font]).size()
        guard isBordered else {
            return ceil(measured.width) + height * borderlessPadRatio * 2
        }
        let stroke = max(1, height * strokeRatio)
        let boxWidth = ceil(measured.width) + height * horizontalPadRatio * 2
        // The extra stroke keeps the border from being clipped by the canvas
        // edge, since a stroke straddles the path it follows.
        return boxWidth + stroke
    }

    /// The font used for the glyph at a given menu bar height.
    static func font(forHeight height: CGFloat) -> NSFont {
        // The bordered version needs a smaller face: the border takes room, and
        // letters that crowd it read as cramped. Without a border the letters
        // are the whole glyph, so they can fill the height.
        //
        // Bold either way, because at menu bar size a lighter weight looks thin
        // beside SF Symbols, which carry more visual weight than their stroke
        // width suggests.
        let ratio: CGFloat = isBordered ? 0.48 : 0.62
        return NSFont.systemFont(ofSize: height * ratio, weight: .bold)
    }

    /// Renders the glyph as a template image.
    static func image(height: CGFloat = 18) -> NSImage {
        let glyphFont = font(forHeight: height)
        let canvasWidth = width(forHeight: height, font: glyphFont)

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: glyphFont,
            .foregroundColor: NSColor.black,
            .paragraphStyle: style,
            .kern: -glyphFont.pointSize * 0.03,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let measured = attributed.size()

        let image = NSImage(size: NSSize(width: canvasWidth, height: height))
        image.lockFocus()

        // The area the letters are centred within: the border box when there is
        // a border, the whole canvas when there is not.
        let box: NSRect
        if isBordered {
            // Inset by half the stroke width on every side, because a stroke
            // straddles its path: without the inset the outer half would be
            // clipped by the canvas edge and the border would look thinner on
            // the outside than it is.
            let stroke = max(1, height * strokeRatio)
            box = NSRect(
                x: stroke / 2,
                y: stroke / 2,
                width: canvasWidth - stroke,
                height: height - stroke
            )
            let radius = box.height * cornerRatio
            let border = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
            NSColor.black.setStroke()
            border.lineWidth = stroke
            border.stroke()
        } else {
            box = NSRect(x: 0, y: 0, width: canvasWidth, height: height)
        }

        // Centre on the drawn ink, not the line box. "mM" mixes an x-height
        // letter with a cap-height one, so the ink runs from the baseline to the
        // cap height; the line box adds ascender and descender room that neither
        // letter fills, and centring on it leaves the glyph sitting high.
        let baselineY = box.midY - glyphFont.capHeight / 2
        let textRect = NSRect(
            x: box.minX,
            y: baselineY + glyphFont.descender,
            width: box.width,
            height: measured.height
        )
        attributed.draw(in: textRect)
        image.unlockFocus()

        // Without this the menu bar would show solid black on a dark menu bar.
        image.isTemplate = true
        return image
    }
}
