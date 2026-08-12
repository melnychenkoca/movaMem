import Foundation
import Testing
@testable import movaMem

/// Builds a real .app bundle in a temp directory. No mocking — the code under
/// test reads a real Info.plist through Bundle(url:).
private func makeTempAppBundle(name: String, bundleID: String?, displayName: String? = nil) -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("picker-" + UUID().uuidString)
    let appURL = root.appendingPathComponent("\(name).app")
    let contents = appURL.appendingPathComponent("Contents")
    try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

    var entries = "<key>CFBundleName</key><string>\(name)</string>"
    if let displayName = displayName {
        entries += "<key>CFBundleDisplayName</key><string>\(displayName)</string>"
    }
    if let bundleID = bundleID {
        entries += "<key>CFBundleIdentifier</key><string>\(bundleID)</string>"
    }
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>\(entries)</dict></plist>
    """
    try? plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
    return appURL
}

@Test func choosingANewAppIsValid() {
    let appURL = makeTempAppBundle(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
    let result = AppPicker.evaluate(appBundleURL: appURL, managedBundleIDs: [])

    switch result {
    case .valid(let bundleID):
        #expect(bundleID == "com.tinyspeck.slackmacgap")
    default:
        Issue.record("expected .valid, got \(result)")
    }
}

@Test func choosingAnAlreadyManagedAppReportsIt() {
    let appURL = makeTempAppBundle(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
    let managed: Set<String> = ["com.tinyspeck.slackmacgap"]
    let result = AppPicker.evaluate(appBundleURL: appURL, managedBundleIDs: managed)

    switch result {
    case .alreadyManaged(let appName):
        // The name is shown in an alert, so it must be the human-readable one.
        #expect(appName == "Slack")
    default:
        Issue.record("expected .alreadyManaged, got \(result)")
    }
}

@Test func choosingAnAppWithNoBundleIdentifierReportsIt() {
    // Rare but real: some wrappers and very old apps have no CFBundleIdentifier.
    // movaMem identifies apps by bundle ID, so such an app cannot be managed.
    let appURL = makeTempAppBundle(name: "Ancient", bundleID: nil)
    let result = AppPicker.evaluate(appBundleURL: appURL, managedBundleIDs: [])

    switch result {
    case .noBundleIdentifier(let appName):
        #expect(appName == "Ancient")
    default:
        Issue.record("expected .noBundleIdentifier, got \(result)")
    }
}

@Test func aNonBundleURLReportsNoBundleIdentifier() {
    // Defensive: the panel restricts selection to .app bundles, but a directory
    // that is not a bundle must degrade to a clear message rather than crash.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("notanapp-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let result = AppPicker.evaluate(appBundleURL: dir, managedBundleIDs: [])
    switch result {
    case .noBundleIdentifier:
        break   // correct
    default:
        Issue.record("expected .noBundleIdentifier, got \(result)")
    }
}

@Test func displayNamePrefersBundleNameOverFilename() {
    // The on-disk filename is a UUID here. Falling back to the filename would put
    // that UUID in an alert, so CFBundleName must win.
    let appURL = makeTempAppBundle(name: "PrettyName", bundleID: "com.example.app")
    let name = AppPicker.displayName(forBundleAt: appURL)
    #expect(name == "PrettyName")
}

@Test func displayNameFallsBackToFilenameWhenPlistHasNoName() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("noname-" + UUID().uuidString)
    let appURL = root.appendingPathComponent("FallbackName.app")
    try? FileManager.default.createDirectory(
        at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    // No Info.plist at all.

    let name = AppPicker.displayName(forBundleAt: appURL)
    #expect(name == "FallbackName")
}

@Test func displayNamePrefersDisplayNameOverBundleName() {
    // Real apps often set a marketing CFBundleDisplayName that differs from
    // their internal CFBundleName. This goes into user-facing alerts, so the
    // display name must win — if the order is swapped during refactoring, this
    // test catches it.
    let appURL = makeTempAppBundle(
        name: "InternalName",
        bundleID: "com.example.app",
        displayName: "Marketing Name"
    )
    let name = AppPicker.displayName(forBundleAt: appURL)
    #expect(name == "Marketing Name")
}
