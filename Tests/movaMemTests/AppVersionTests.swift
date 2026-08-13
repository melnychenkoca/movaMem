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
