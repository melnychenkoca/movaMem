import AppKit
import Testing
@testable import movaMem

// The menu row is the only place a user can see which build they are running,
// so the interesting cases are the ones where the bundle cannot tell us: the
// row still has to say something honest rather than look like a broken title.

@Test func versionRowShowsNameAndVersion() {
    let title = AppVersion.menuTitle(appName: "movaMem", version: "1.0.1")
    #expect(title == "movaMem 1.0.1")
}

@Test func missingVersionSaysSoRatherThanShowingNameAlone() {
    // "movaMem" on its own would read as a title, not as a fault.
    let title = AppVersion.menuTitle(appName: "movaMem", version: nil)
    #expect(title == "movaMem (unknown version)")
}

@Test func emptyVersionIsTreatedAsMissing() {
    // The key exists but says nothing, which is the same situation for a reader.
    let title = AppVersion.menuTitle(appName: "movaMem", version: "")
    #expect(title == "movaMem (unknown version)")
}

@Test func whitespaceOnlyVersionIsTreatedAsMissing() {
    let title = AppVersion.menuTitle(appName: "movaMem", version: "   ")
    #expect(title == "movaMem (unknown version)")
}

@Test func surroundingWhitespaceIsTrimmed() {
    // Hand-edited plists pick up stray spaces; the row should not inherit them.
    let title = AppVersion.menuTitle(appName: "movaMem", version: " 1.0.1 ")
    #expect(title == "movaMem 1.0.1")
}

@Test func versionIsNotAssumedToBeThreeNumbers() {
    // Nothing here parses the version, so a pre-release tag passes through
    // unchanged rather than being rejected or reformatted.
    let title = AppVersion.menuTitle(appName: "movaMem", version: "1.1.0-beta.2")
    #expect(title == "movaMem 1.1.0-beta.2")
}

// The version now rides on the Quit row instead of a row of its own, so that row
// has to stay a readable Quit command first and a version display second.

@Test func quitRowCarriesTheVersion() {
    let title = AppVersion.quitTitle(appName: "movaMem", version: "1.0.1")
    #expect(title == "Quit movaMem 1.0.1")
}

@Test func quitRowStillReadsAsQuitWhenVersionIsMissing() {
    // The row is a command before it is a version display: losing the number
    // must not leave a title that fails to say what the item does.
    let title = AppVersion.quitTitle(appName: "movaMem", version: nil)
    #expect(title == "Quit movaMem (unknown version)")
    #expect(title.hasPrefix("Quit movaMem"))
}

@Test func quitRowTrimsVersionWhitespace() {
    let title = AppVersion.quitTitle(appName: "movaMem", version: " 1.0.1 ")
    #expect(title == "Quit movaMem 1.0.1")
}

// The row is drawn in two runs so the version can be greyed while the command
// stays at full contrast. The split has to land in the right place, and the two
// runs have to rejoin into exactly the plain title — that equality is what keeps
// the styled row and the accessibility label from drifting apart.

@Test func quitPartsSplitCommandFromVersion() {
    let parts = AppVersion.quitTitleParts(appName: "movaMem", version: "1.2.0")
    #expect(parts.command == "Quit ")
    #expect(parts.version == "movaMem 1.2.0")
}

@Test func quitPartsRejoinIntoThePlainTitle() {
    // Guards the two from drifting: quitTitle is built from these parts, so a
    // change to either that broke this equality would ship a styled row whose
    // text no longer matched the label VoiceOver reads.
    for version in ["1.2.0", " 1.0.1 ", "1.1.0-beta.2", "", nil] as [String?] {
        let parts = AppVersion.quitTitleParts(appName: "movaMem", version: version)
        #expect(parts.command + parts.version == AppVersion.quitTitle(appName: "movaMem", version: version))
    }
}

@Test func quitPartsKeepTheSeparatingSpaceOnTheCommand() {
    // The space belongs to the ungreyed run. On the version run it would be a
    // dimmed leading space, and the two runs would still concatenate correctly,
    // so only checking the joined string would miss it.
    let parts = AppVersion.quitTitleParts(appName: "movaMem", version: "1.2.0")
    #expect(parts.command.hasSuffix(" "))
    #expect(!parts.version.hasPrefix(" "))
}

@Test func quitPartsGreyTheUnknownVersionToo() {
    // The fallback text is still name-and-version material, so it belongs in the
    // dimmed run rather than at full contrast beside the command.
    let parts = AppVersion.quitTitleParts(appName: "movaMem", version: nil)
    #expect(parts.command == "Quit ")
    #expect(parts.version == "movaMem (unknown version)")
}

// The row is drawn with a tab stop rather than a plain space, so the version
// lands in the same place on every menu open. These pin the parts of that which
// are easy to break silently: a tab that never made it in still renders, just
// with the version jammed against the command.

@MainActor
@Test func styledQuitRowUsesATabToPositionTheVersion() {
    let parts = AppVersion.quitTitleParts(appName: "movaMem", version: "1.2.0")
    let styled = MenuController.styledQuitTitle(parts: parts)
    #expect(styled.string == "Quit\tmovaMem 1.2.0")
}

@MainActor
@Test func styledQuitRowCarriesNoSpaceBesideTheTab() {
    // A leftover space would be drawn before the tab advanced, pushing the
    // version past the stop and undoing the fixed position.
    let parts = AppVersion.quitTitleParts(appName: "movaMem", version: "1.2.0")
    let styled = MenuController.styledQuitTitle(parts: parts)
    #expect(!styled.string.contains(" \t"))
    #expect(!styled.string.contains("\t "))
}

@MainActor
@Test func styledQuitRowDefinesATabStopForTheTabToLandOn() {
    // Without a tab stop the tab falls back to a default interval, which is not
    // the fixed position this row is built around.
    let parts = AppVersion.quitTitleParts(appName: "movaMem", version: "1.2.0")
    let styled = MenuController.styledQuitTitle(parts: parts)
    let style = styled.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    #expect(style?.tabStops.isEmpty == false)
}

@MainActor
@Test func styledQuitRowDimsOnlyTheVersion() {
    // The command must stay at full contrast: dimming the whole row would make
    // Quit look disabled rather than make the version look secondary.
    let parts = AppVersion.quitTitleParts(appName: "movaMem", version: "1.2.0")
    let styled = MenuController.styledQuitTitle(parts: parts)

    let commandColor = styled.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    #expect(commandColor == nil)

    let versionIndex = styled.string.distance(
        from: styled.string.startIndex,
        to: styled.string.firstIndex(of: "m")!
    )
    let versionColor = styled.attribute(.foregroundColor, at: versionIndex, effectiveRange: nil) as? NSColor
    #expect(versionColor == NSColor.disabledControlTextColor)
}

@MainActor
@Test func styledQuitRowSetsAFontOnEveryRun() {
    // Setting attributedTitle drops the font AppKit would supply, so an unstyled
    // run renders in the system font at the wrong size beside the other rows.
    let parts = AppVersion.quitTitleParts(appName: "movaMem", version: "1.2.0")
    let styled = MenuController.styledQuitTitle(parts: parts)

    for index in 0..<styled.length {
        let font = styled.attribute(.font, at: index, effectiveRange: nil) as? NSFont
        #expect(font != nil)
    }
}

@MainActor
@Test func styledQuitRowKeepsTheUnknownVersionText() {
    // The fallback still has to survive the tab-stop assembly intact.
    let parts = AppVersion.quitTitleParts(appName: "movaMem", version: nil)
    let styled = MenuController.styledQuitTitle(parts: parts)
    #expect(styled.string == "Quit\tmovaMem (unknown version)")
}
