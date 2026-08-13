import AppKit
import Testing
@testable import movaMem

// The glyph's one real failure mode is clipping: "m" and "M" are two of the
// widest letters there are, and an earlier draft drew them on a square canvas,
// which cut the second one off entirely. These tests pin the sizing that
// prevents that.

@MainActor
@Test func glyphIsWiderThanItIsTall() {
    // The bug this guards against produced a square image and a missing letter.
    let image = StatusGlyph.image(height: 18)
    #expect(image.size.width > image.size.height)
}

@MainActor
@Test func glyphCanvasFitsTheTextPlusPadding() {
    let height: CGFloat = 18
    let font = StatusGlyph.font(forHeight: height)
    let textWidth = NSAttributedString(
        string: StatusGlyph.text,
        attributes: [.font: font]
    ).size().width

    let canvas = StatusGlyph.width(forHeight: height, font: font)
    #expect(canvas > textWidth)
}

@MainActor
@Test func glyphIsATemplateImage() {
    // Without this the menu bar shows a solid black blob in dark mode instead of
    // letting macOS invert the glyph.
    let image = StatusGlyph.image(height: 18)
    #expect(image.isTemplate)
}

@MainActor
@Test func glyphScalesWithRequestedHeight() {
    let small = StatusGlyph.image(height: 18)
    let large = StatusGlyph.image(height: 36)
    #expect(large.size.height > small.size.height)
    #expect(large.size.width > small.size.width)
}

@MainActor
@Test func glyphHeightMatchesWhatWasAskedFor() {
    let image = StatusGlyph.image(height: 22)
    #expect(image.size.height == 22)
}

@MainActor
@Test func glyphTextIsMixedCase() {
    // Echoes "movaMem"; a plain "MM" was the earlier version.
    #expect(StatusGlyph.text == "mM")
}

@MainActor
@Test func glyphCanvasLeavesRoomForPaddingInEitherMode() {
    // The canvas has to hold the letters plus padding on both sides, and when
    // bordered also a stroke that straddles the border path. Too tight and the
    // border clips or the letters touch their neighbours.
    //
    // Written against whichever mode is currently selected, so it keeps testing
    // the real configuration when StatusGlyph.isBordered is flipped.
    let height: CGFloat = 18
    let font = StatusGlyph.font(forHeight: height)
    let textWidth = NSAttributedString(
        string: StatusGlyph.text,
        attributes: [.font: font]
    ).size().width

    let canvas = StatusGlyph.width(forHeight: height, font: font)
    // Bordered pads 0.22 of the height per side, borderless 0.1.
    let padRatio: CGFloat = StatusGlyph.isBordered ? 0.22 : 0.1
    #expect(canvas >= textWidth + height * padRatio * 2)
}
