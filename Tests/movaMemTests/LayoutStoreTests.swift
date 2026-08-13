import Foundation
import Testing
@testable import movaMem

// Each test gets its own temp directory so tests never interfere.
private func makeTempFileURL() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("movamem-test-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("layouts.json")
}

@Test func missingFileStartsEmpty() {
    let store = LayoutStore(fileURL: makeTempFileURL())
    #expect(store.allEntries().isEmpty)
    #expect(store.layout(forBundleID: "com.apple.Safari") == nil)
}

@Test func setThenGetReturnsLayout() {
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.setLayout("com.apple.keylayout.Ukrainian-PC", forBundleID: "com.tinyspeck.slackmacgap")
    #expect(store.layout(forBundleID: "com.tinyspeck.slackmacgap") == "com.apple.keylayout.Ukrainian-PC")
}

@Test func valuesSurviveReload() {
    let url = makeTempFileURL()
    let first = LayoutStore(fileURL: url)
    first.setLayout("com.apple.keylayout.French", forBundleID: "ru.keepcoder.Telegram")

    // A second store reading the same file must see the persisted value.
    let second = LayoutStore(fileURL: url)
    #expect(second.layout(forBundleID: "ru.keepcoder.Telegram") == "com.apple.keylayout.French")
}

@Test func settingSameBundleIDTwiceOverwrites() {
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.setLayout("com.apple.keylayout.Canadian", forBundleID: "com.microsoft.VSCode")
    store.setLayout("com.apple.keylayout.French", forBundleID: "com.microsoft.VSCode")
    #expect(store.layout(forBundleID: "com.microsoft.VSCode") == "com.apple.keylayout.French")
    #expect(store.allEntries().count == 1)
}

@Test func removeDeletesEntry() {
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.setLayout("com.apple.keylayout.Canadian", forBundleID: "com.microsoft.VSCode")
    store.remove(bundleID: "com.microsoft.VSCode")
    #expect(store.layout(forBundleID: "com.microsoft.VSCode") == nil)
    #expect(store.allEntries().isEmpty)
}

// MARK: - Forgotten apps

@Test func removeMarksAppForgotten() {
    // Forget This App must record the rejection, not just delete the entry.
    // Deleting alone is what let a forgotten app be re-learned on its next
    // activation, which read as the forget having silently failed.
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.setLayout("com.apple.keylayout.Canadian", forBundleID: "com.todesktop.230313mzl4w4u92")

    #expect(store.isForgotten(bundleID: "com.todesktop.230313mzl4w4u92") == false)

    store.remove(bundleID: "com.todesktop.230313mzl4w4u92")

    #expect(store.isForgotten(bundleID: "com.todesktop.230313mzl4w4u92") == true)
    #expect(store.isManaged(bundleID: "com.todesktop.230313mzl4w4u92") == false)
}

@Test func removingAnAppNeverSeenStillMarksItForgotten() {
    // remove() is reachable for an app with no entry (a stale menu item, a
    // repeated forget). Marking it anyway is both harmless and more correct:
    // the user has expressed the same rejection either way.
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.remove(bundleID: "com.never.seen")
    #expect(store.isForgotten(bundleID: "com.never.seen") == true)
}

@Test func settingALayoutClearsTheForgottenMark() {
    // Picking a layout by hand is a deliberate act, so it un-forgets. This lives
    // in the store rather than in the menu so no future call site can forget to
    // do it — the same reasoning as the guard inside addAppWithNoLayout.
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.remove(bundleID: "com.a.app")
    #expect(store.isForgotten(bundleID: "com.a.app") == true)

    store.setLayout("com.apple.keylayout.French", forBundleID: "com.a.app")

    #expect(store.isForgotten(bundleID: "com.a.app") == false)
    #expect(store.layout(forBundleID: "com.a.app") == "com.apple.keylayout.French")
}

@Test func addAppWithNoLayoutClearsTheForgottenMark() {
    // Add App... is the other deliberate act, and the primary escape hatch for
    // an app forgotten by mistake.
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.remove(bundleID: "com.a.app")

    store.addAppWithNoLayout(bundleID: "com.a.app")

    #expect(store.isForgotten(bundleID: "com.a.app") == false)
    #expect(store.isManaged(bundleID: "com.a.app") == true)
}

@Test func forgottenAppsSurviveReload() {
    // The whole point is that the forget outlives a relaunch. Held in memory
    // only, the app would learn the entry back the next time it started.
    let url = makeTempFileURL()
    let first = LayoutStore(fileURL: url)
    first.setLayout("com.apple.keylayout.Canadian", forBundleID: "com.a.app")
    first.remove(bundleID: "com.a.app")

    let second = LayoutStore(fileURL: url)
    #expect(second.isForgotten(bundleID: "com.a.app") == true)
    #expect(second.isManaged(bundleID: "com.a.app") == false)
}

@Test func clearingAForgottenMarkSurvivesReload() {
    // The clear has to be persisted too, or an un-forgotten app would come back
    // as forgotten on the next launch and stop being learned again.
    let url = makeTempFileURL()
    let first = LayoutStore(fileURL: url)
    first.remove(bundleID: "com.a.app")
    first.setLayout("com.apple.keylayout.French", forBundleID: "com.a.app")

    let second = LayoutStore(fileURL: url)
    #expect(second.isForgotten(bundleID: "com.a.app") == false)
    #expect(second.layout(forBundleID: "com.a.app") == "com.apple.keylayout.French")
}

@Test func forgottenListIsPersistedSortedForReadability() throws {
    // The owner reads this file by hand, and .sortedKeys only orders object
    // keys — an array's order is whatever we write, so it is sorted explicitly.
    let url = makeTempFileURL()
    let store = LayoutStore(fileURL: url)
    store.remove(bundleID: "zzz.app")
    store.remove(bundleID: "aaa.app")

    let data = try Data(contentsOf: url)
    let decoded = try JSONDecoder().decode(StoredLayouts.self, from: data)
    #expect(decoded.forgotten == ["aaa.app", "zzz.app"])
}

@Test func forgettingTheSameAppTwiceDoesNotDuplicateIt() {
    let url = makeTempFileURL()
    let store = LayoutStore(fileURL: url)
    store.remove(bundleID: "com.a.app")
    store.remove(bundleID: "com.a.app")

    let second = LayoutStore(fileURL: url)
    #expect(second.isForgotten(bundleID: "com.a.app") == true)
}

// MARK: - Listing and un-forgetting

@Test func forgottenBundleIDsIsEmptyWhenNothingForgotten() {
    let store = LayoutStore(fileURL: makeTempFileURL())
    #expect(store.forgottenBundleIDs().isEmpty)
}

@Test func forgottenBundleIDsAreReturnedSorted() {
    // Sorted for the same reason allEntries() is: the menu builds its rows
    // straight from this, and Set iteration order is not stable between runs,
    // so an unsorted return would reshuffle the list every time it is opened.
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.remove(bundleID: "zzz.app")
    store.remove(bundleID: "aaa.app")
    store.remove(bundleID: "mmm.app")

    #expect(store.forgottenBundleIDs() == ["aaa.app", "mmm.app", "zzz.app"])
}

@Test func unforgetClearsTheMarkAndManagesTheAppUnset() {
    // The state the user expects from the Forgotten Apps menu: one click puts
    // the app back in the list, showing "(not set)" until a layout is picked.
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.remove(bundleID: "com.a.app")

    store.unforget(bundleID: "com.a.app")

    #expect(store.isForgotten(bundleID: "com.a.app") == false)
    #expect(store.isManaged(bundleID: "com.a.app") == true)
    #expect(store.layout(forBundleID: "com.a.app") == nil)
    #expect(store.forgottenBundleIDs().isEmpty)
}

@Test func unforgetDoesNotWipeAnExistingLayout() {
    // An app can be both managed and forgotten only through an odd sequence,
    // but if it happens the remembered layout must survive: addAppWithNoLayout
    // guards against overwriting it, and unforget must not defeat that guard.
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.setLayout("com.apple.keylayout.French", forBundleID: "com.a.app")
    store.remove(bundleID: "com.a.app")
    store.setLayout("com.apple.keylayout.French", forBundleID: "com.a.app")

    store.unforget(bundleID: "com.a.app")

    #expect(store.isForgotten(bundleID: "com.a.app") == false)
    #expect(store.layout(forBundleID: "com.a.app") == "com.apple.keylayout.French")
}

@Test func unforgetOnANeverForgottenAppStillManagesIt() {
    // Reachable from a stale menu item. It must not throw or corrupt anything;
    // registering the app unset is the same outcome Add App... would produce.
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.unforget(bundleID: "com.never.forgotten")

    #expect(store.isForgotten(bundleID: "com.never.forgotten") == false)
    #expect(store.isManaged(bundleID: "com.never.forgotten") == true)
}

@Test func unforgetSurvivesReload() {
    // The clear has to reach disk, or the app would come back forgotten on the
    // next launch and silently stop being learned again.
    let url = makeTempFileURL()
    let first = LayoutStore(fileURL: url)
    first.remove(bundleID: "com.a.app")
    first.unforget(bundleID: "com.a.app")

    let second = LayoutStore(fileURL: url)
    #expect(second.isForgotten(bundleID: "com.a.app") == false)
    #expect(second.isManaged(bundleID: "com.a.app") == true)
    #expect(second.forgottenBundleIDs().isEmpty)
}

@Test func unforgetWithALayoutStoresThatLayout() {
    // Adding an app back captures whatever layout is active at that moment, so the
    // app is immediately useful instead of sitting at "(not set)" until the user
    // switches layouts inside it once.
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.remove(bundleID: "com.a.app")

    store.unforget(bundleID: "com.a.app", layoutID: "com.apple.keylayout.Ukrainian-PC")

    #expect(store.isForgotten(bundleID: "com.a.app") == false)
    #expect(store.layout(forBundleID: "com.a.app") == "com.apple.keylayout.Ukrainian-PC")
}

@Test func unforgetWithNilLayoutLeavesTheAppUnset() {
    // currentLayoutID is documented as nil-able. The app must still come back —
    // falling back to unset is strictly better than refusing to add it.
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.remove(bundleID: "com.a.app")

    store.unforget(bundleID: "com.a.app", layoutID: nil)

    #expect(store.isForgotten(bundleID: "com.a.app") == false)
    #expect(store.isManaged(bundleID: "com.a.app") == true)
    #expect(store.layout(forBundleID: "com.a.app") == nil)
}

@Test func unforgetWithALayoutOverwritesAStaleRememberedLayout() {
    // An app can carry an old layout from before it was forgotten. The layout
    // active now is the more recent expression of intent, so it wins — otherwise
    // adding an app back would silently restore a layout the user had moved on
    // from, with no indication of where it came from.
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.setLayout("com.apple.keylayout.French", forBundleID: "com.a.app")
    store.remove(bundleID: "com.a.app")

    store.unforget(bundleID: "com.a.app", layoutID: "com.apple.keylayout.Canadian")

    #expect(store.layout(forBundleID: "com.a.app") == "com.apple.keylayout.Canadian")
}

@Test func unforgetWithALayoutSurvivesReload() {
    let url = makeTempFileURL()
    let first = LayoutStore(fileURL: url)
    first.remove(bundleID: "com.a.app")
    first.unforget(bundleID: "com.a.app", layoutID: "com.apple.keylayout.Canadian")

    let second = LayoutStore(fileURL: url)
    #expect(second.isForgotten(bundleID: "com.a.app") == false)
    #expect(second.layout(forBundleID: "com.a.app") == "com.apple.keylayout.Canadian")
}

@Test func addAppWithALayoutStoresIt() {
    // Add App... captures the active layout the same way, so a newly added app is
    // useful immediately rather than starting unset.
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.addApp(bundleID: "com.a.app", layoutID: "com.apple.keylayout.Ukrainian-PC")

    #expect(store.isManaged(bundleID: "com.a.app") == true)
    #expect(store.layout(forBundleID: "com.a.app") == "com.apple.keylayout.Ukrainian-PC")
}

@Test func addAppWithNilLayoutLeavesItUnset() {
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.addApp(bundleID: "com.a.app", layoutID: nil)

    #expect(store.isManaged(bundleID: "com.a.app") == true)
    #expect(store.layout(forBundleID: "com.a.app") == nil)
}

@Test func addAppDoesNotOverwriteAnAlreadyManagedApp() {
    // Add App... is reachable for an app already in the list. Capturing the
    // current layout must not clobber the one the user deliberately chose — the
    // same protection addAppWithNoLayout has always had.
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.setLayout("com.apple.keylayout.French", forBundleID: "com.a.app")

    store.addApp(bundleID: "com.a.app", layoutID: "com.apple.keylayout.Canadian")

    #expect(store.layout(forBundleID: "com.a.app") == "com.apple.keylayout.French")
}

@Test func unforgetLeavesOtherForgottenAppsAlone() {
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.remove(bundleID: "com.a.app")
    store.remove(bundleID: "com.b.app")

    store.unforget(bundleID: "com.a.app")

    #expect(store.forgottenBundleIDs() == ["com.b.app"])
    #expect(store.isForgotten(bundleID: "com.b.app") == true)
}

@Test func aVersion2FileLoadsWithNothingForgotten() throws {
    // The upgrade case that matters for existing installs: a v2 file has no
    // forgotten key at all, and must load with an empty list rather than
    // failing to decode and being quarantined.
    let url = makeTempFileURL()
    let v2 = #"{"version":2,"apps":{"com.microsoft.VSCode":"com.apple.keylayout.Canadian"}}"#
    try v2.write(to: url, atomically: true, encoding: .utf8)

    let store = LayoutStore(fileURL: url)

    #expect(store.didFailToLoad == false)
    #expect(store.layout(forBundleID: "com.microsoft.VSCode") == "com.apple.keylayout.Canadian")
    #expect(store.isForgotten(bundleID: "com.microsoft.VSCode") == false)
}

@Test func aVersion2FileUpgradesToVersion3OnTheNextWrite() throws {
    let url = makeTempFileURL()
    let v2 = #"{"version":2,"apps":{"com.microsoft.VSCode":"com.apple.keylayout.Canadian"}}"#
    try v2.write(to: url, atomically: true, encoding: .utf8)

    let store = LayoutStore(fileURL: url)
    store.remove(bundleID: "com.microsoft.VSCode")

    let data = try Data(contentsOf: url)
    let decoded = try JSONDecoder().decode(StoredLayouts.self, from: data)
    #expect(decoded.version == 3)
    #expect(decoded.forgotten == ["com.microsoft.VSCode"])
}

@Test func aForgottenAppIsNotListedAsAnEntry() {
    // The forgotten list must not leak into the menu as a row. It is bookkeeping
    // about apps that are deliberately absent.
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.setLayout("com.apple.keylayout.Canadian", forBundleID: "com.a.app")
    store.remove(bundleID: "com.a.app")

    #expect(store.allEntries().isEmpty)
}

@Test func allEntriesIsSortedByBundleID() {
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.setLayout("com.apple.keylayout.Canadian", forBundleID: "zzz.app")
    store.setLayout("com.apple.keylayout.French", forBundleID: "aaa.app")
    let entries = store.allEntries()
    #expect(entries.count == 2)
    #expect(entries[0].bundleID == "aaa.app")
    #expect(entries[1].bundleID == "zzz.app")
}

@Test func malformedJSONStartsEmptyAndQuarantinesFile() throws {
    let url = makeTempFileURL()
    try "this is not json at all".write(to: url, atomically: true, encoding: .utf8)

    let store = LayoutStore(fileURL: url)
    #expect(store.allEntries().isEmpty)

    // The bad file must be renamed aside, never deleted — a parsing bug must not
    // silently destroy the user's data.
    let dir = url.deletingLastPathComponent()
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    let quarantined = names.filter { name in name.contains("corrupt") }
    #expect(quarantined.count == 1)
}

@Test func schemaVersionIsPersisted() throws {
    let url = makeTempFileURL()
    let store = LayoutStore(fileURL: url)
    store.setLayout("com.apple.keylayout.Canadian", forBundleID: "com.microsoft.VSCode")

    let data = try Data(contentsOf: url)
    let decoded = try JSONDecoder().decode(StoredLayouts.self, from: data)
    // Version 3 as of the authoritative-forget change, which added the forgotten
    // list. It was 2 before that (the optional-layout change) and 1 originally.
    // See writesUseCurrentSchemaVersion for the dedicated version test.
    #expect(decoded.version == 3)
    #expect(decoded.apps["com.microsoft.VSCode"] == "com.apple.keylayout.Canadian")
}

@Test func loadingAnOlderFileUpgradesItsVersionOnTheNextWrite() throws {
    // Found by running the real store against a copy of the owner's actual v1
    // file: the null for an unset app was written correctly, but the file kept
    // claiming "version": 1 forever, because load() adopted the file's own
    // version and save() wrote it straight back.
    //
    // That is a real problem now that v2 introduced nulls: the file would hold
    // v2 content while advertising v1, so a v1-only reader would misinterpret it
    // rather than quarantining it as a format it does not understand.
    let url = makeTempFileURL()
    let v1 = #"{"version":1,"apps":{"com.microsoft.VSCode":"com.apple.keylayout.Canadian"}}"#
    try v1.write(to: url, atomically: true, encoding: .utf8)

    let store = LayoutStore(fileURL: url)
    #expect(store.didFailToLoad == false)
    // The existing layout must survive the upgrade untouched.
    #expect(store.layout(forBundleID: "com.microsoft.VSCode") == "com.apple.keylayout.Canadian")

    // Any write is enough to persist the upgraded version.
    store.addAppWithNoLayout(bundleID: "com.tinyspeck.slackmacgap")

    let data = try Data(contentsOf: url)
    let decoded = try JSONDecoder().decode(StoredLayouts.self, from: data)
    #expect(decoded.version == 3)
    #expect(decoded.apps["com.microsoft.VSCode"] == "com.apple.keylayout.Canadian")
    // And the newly added app is present-but-nil, not missing.
    let slackEntry = decoded.apps["com.tinyspeck.slackmacgap"]
    #expect(slackEntry != nil)
    #expect(slackEntry == .some(nil))
}

@Test func unreadableFileIsQuarantinedAndMarksLoadFailure() throws {
    let url = makeTempFileURL()
    try "{\"version\":1,\"apps\":{}}".write(to: url, atomically: true, encoding: .utf8)

    // Remove all permissions so Data(contentsOf:) throws, simulating a file the
    // OS will not let us read (permissions, ACL, I/O error, etc). This test
    // assumes it is not running as root, since root ignores POSIX permissions.
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

    defer {
        // Restore permissions so the temp directory can be deleted by whatever
        // cleans up NSTemporaryDirectory() later.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    let store = LayoutStore(fileURL: url)

    #expect(store.allEntries().isEmpty)
    #expect(store.didFailToLoad == true)

    // The original file must still exist somewhere — moved aside, not deleted.
    let dir = url.deletingLastPathComponent()
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    let originalStillPresent = names.contains("layouts.json")
    let quarantined = names.filter { name in name.contains("corrupt") }
    #expect(originalStillPresent == false)
    #expect(quarantined.count == 1)
}

@Test func failedLoadThenSetLayoutDoesNotDestroyQuarantinedCopy() throws {
    let url = makeTempFileURL()
    try "{\"version\":1,\"apps\":{\"com.apple.Safari\":\"com.apple.keylayout.US\"}}"
        .write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

    let dir = url.deletingLastPathComponent()

    defer {
        // moveItem preserves permissions, so the quarantined copy is still
        // chmod 000 under its new name. Restore permissions on whatever ended
        // up in the directory so the temp directory can be cleaned up.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for name in names {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: dir.appendingPathComponent(name).path
                )
            }
        }
    }

    let store = LayoutStore(fileURL: url)
    #expect(store.didFailToLoad == true)

    // A quarantine copy should exist right after the failed load.
    let namesAfterLoad = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    let quarantinedAfterLoad = namesAfterLoad.filter { name in name.contains("corrupt") }
    #expect(quarantinedAfterLoad.count == 1)

    // Writing a new value must not touch or remove the quarantined file.
    store.setLayout("com.apple.keylayout.French", forBundleID: "com.tinyspeck.slackmacgap")

    let namesAfterWrite = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    let quarantinedAfterWrite = namesAfterWrite.filter { name in name.contains("corrupt") }
    #expect(quarantinedAfterWrite.count == 1)
    #expect(quarantinedAfterWrite == quarantinedAfterLoad)

    // Restore permissions before reading, to confirm the quarantined file's
    // contents are exactly what was there originally — proof nothing touched it.
    let quarantineURL = dir.appendingPathComponent(quarantinedAfterWrite[0])
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: quarantineURL.path)
    let quarantinedContents = try String(contentsOf: quarantineURL, encoding: .utf8)
    #expect(quarantinedContents.contains("com.apple.Safari"))
}

@Test func whenQuarantineFailsSaveRefusesToOverwriteOriginal() throws {
    // This test must prove the `quarantineFailed` guard in save() itself is
    // doing the work — not some unrelated permissions failure. So the
    // directory here is left fully writable throughout: the only thing that
    // can stop the write is the guard.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("movamem-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("layouts.json")

    // Recognizable content with a known byte length, so a later check that
    // the file was "not overwritten" is a real check and not a coincidence.
    let originalContents = "this is not valid JSON, but here is some recognizable " +
        "content: com.apple.Safari, com.tinyspeck.slackmacgap, com.microsoft.VSCode"
    try originalContents.write(to: url, atomically: true, encoding: .utf8)
    let originalByteCount = try Data(contentsOf: url).count

    // This content is not valid JSON, so load() will fail to decode it and
    // call quarantineCorruptFile() — the same path a permissions failure
    // would take, without needing any permissions games.

    // quarantineCorruptFile() computes its destination as
    // "layouts.json.corrupt-<Int(Date().timeIntervalSince1970)>". To make its
    // moveItem call fail, pre-create a directory at that exact path — moving
    // a file onto an existing directory always fails, whereas a pre-existing
    // file might be handled differently depending on the filesystem. Because
    // the timestamp only has one-second granularity, there is a small chance
    // the clock ticks forward between when we compute "now" here and when
    // quarantineCorruptFile() computes its own "now". To make the collision
    // certain regardless of that timing, create obstruction directories for
    // the current second and the following two seconds.
    let nowInSeconds = Int(Date().timeIntervalSince1970)
    for secondOffset in 0...2 {
        let obstructionURL = dir.appendingPathComponent(
            "layouts.json.corrupt-\(nowInSeconds + secondOffset)"
        )
        try FileManager.default.createDirectory(at: obstructionURL, withIntermediateDirectories: true)
    }

    let store = LayoutStore(fileURL: url)

    // The malformed file failed to load, and the quarantine move failed
    // (blocked by our obstruction directory), so the original file must
    // still be sitting there, byte-for-byte unchanged.
    #expect(store.didFailToLoad == true)
    let byteCountAfterLoad = try Data(contentsOf: url).count
    #expect(byteCountAfterLoad == originalByteCount)

    // This is the critical step: with quarantining having failed, save() must
    // refuse to write at all, because the directory is writable and nothing
    // else would stop an ordinary .atomic write from succeeding and
    // destroying the original file.
    store.setLayout("com.apple.keylayout.French", forBundleID: "com.tinyspeck.slackmacgap")

    // The original file must be untouched...
    let byteCountAfterSave = try Data(contentsOf: url).count
    #expect(byteCountAfterSave == originalByteCount)
    // ...the menu must be told persistence is broken...
    #expect(store.isWritable == false)
    // ...but the session must still work from memory.
    #expect(store.layout(forBundleID: "com.tinyspeck.slackmacgap") == "com.apple.keylayout.French")
}

@Test func unwritableDirectorySetsIsWritableFalse() throws {
    // This is a separate scenario from the quarantine guard above: here the
    // parent directory itself is read-only, so the .atomic write fails at
    // the OS level (not because of the quarantineFailed guard). It is kept
    // as its own test because "a read-only directory degrades gracefully" is
    // still a real behavior worth covering, just not the quarantine guard.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("movamem-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("layouts.json")
    try "{\"version\":1,\"apps\":{\"com.apple.Safari\":\"com.apple.keylayout.US\"}}"
        .write(to: url, atomically: true, encoding: .utf8)

    // No write permission on the directory means the .atomic write's
    // temp-file-plus-rename cannot happen there at all.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)

    defer {
        // Restore permissions so the temp directory can be cleaned up.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    let store = LayoutStore(fileURL: url)
    store.setLayout("com.apple.keylayout.French", forBundleID: "com.tinyspeck.slackmacgap")

    #expect(store.isWritable == false)
    // In-memory read still works even though persistence failed.
    #expect(store.layout(forBundleID: "com.tinyspeck.slackmacgap") == "com.apple.keylayout.French")
}

@Test func newerSchemaVersionIsQuarantinedRatherThanAdopted() throws {
    let url = makeTempFileURL()
    // A version one higher than this app understands, carrying a field its
    // StoredLayouts does not know about. Codable ignores the unknown field
    // silently, so without an explicit version check this file would decode as if
    // it were a normal current-version file and the next save would write it back
    // downgraded, dropping futureField for good. Version 4 because the
    // authoritative-forget change bumped currentSchemaVersion to 3.
    try """
    {"version":4,"apps":{"com.apple.Safari":"com.apple.keylayout.US"},"futureField":"x"}
    """.write(to: url, atomically: true, encoding: .utf8)

    let store = LayoutStore(fileURL: url)

    #expect(store.allEntries().isEmpty)
    #expect(store.didFailToLoad == true)

    let dir = url.deletingLastPathComponent()
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    let quarantined = names.filter { name in name.contains("corrupt") }
    #expect(quarantined.count == 1)
    #expect(names.contains("layouts.json") == false)
}

@Test func olderSchemaVersionStillLoadsNormally() throws {
    let url = makeTempFileURL()
    try """
    {"version":1,"apps":{"com.apple.Safari":"com.apple.keylayout.US"}}
    """.write(to: url, atomically: true, encoding: .utf8)

    let store = LayoutStore(fileURL: url)

    #expect(store.didFailToLoad == false)
    #expect(store.layout(forBundleID: "com.apple.Safari") == "com.apple.keylayout.US")
}

@Test func unwritablePathSetsIsWritableFalseButKeepsMemoryValue() {
    // A directory that cannot be created — the store must degrade, not crash.
    let badURL = URL(fileURLWithPath: "/System/movamem-cannot-write-here/layouts.json")
    let store = LayoutStore(fileURL: badURL)
    store.setLayout("com.apple.keylayout.French", forBundleID: "com.microsoft.VSCode")

    // In-memory read still works, so the session behaves normally.
    #expect(store.layout(forBundleID: "com.microsoft.VSCode") == "com.apple.keylayout.French")
    // But the menu needs to know persistence failed.
    #expect(store.isWritable == false)
}

@Test func version1FileLoadsWithoutMigrationCode() throws {
    // A phase-1 file has plain string values and no nulls. It must load as-is:
    // Swift decodes plain strings into non-nil optionals, so no migration is needed.
    let url = makeTempFileURL()
    let v1 = #"{"version":1,"apps":{"com.microsoft.VSCode":"com.apple.keylayout.Canadian"}}"#
    try v1.write(to: url, atomically: true, encoding: .utf8)

    let store = LayoutStore(fileURL: url)
    #expect(store.didFailToLoad == false)
    #expect(store.layout(forBundleID: "com.microsoft.VSCode") == "com.apple.keylayout.Canadian")
    #expect(store.allEntries().count == 1)
}

@Test func addAppWithNoLayoutMakesAppManagedButWithoutLayout() {
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.addAppWithNoLayout(bundleID: "com.tinyspeck.slackmacgap")

    // Managed, so it appears in the menu...
    #expect(store.isManaged(bundleID: "com.tinyspeck.slackmacgap") == true)
    // ...but has no layout, so the coordinator does nothing for it.
    #expect(store.layout(forBundleID: "com.tinyspeck.slackmacgap") == nil)
}

@Test func unsetIsDistinguishableFromAbsent() {
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.addAppWithNoLayout(bundleID: "com.unset.app")

    // Both return nil from layout(forBundleID:) — that conflation is deliberate,
    // because the coordinator wants to do nothing in both cases.
    #expect(store.layout(forBundleID: "com.unset.app") == nil)
    #expect(store.layout(forBundleID: "com.never.seen") == nil)

    // isManaged is what tells them apart.
    #expect(store.isManaged(bundleID: "com.unset.app") == true)
    #expect(store.isManaged(bundleID: "com.never.seen") == false)
}

@Test func unsetEntryAppearsInAllEntriesWithNilLayout() {
    // Verifies the behavior the menu depends on: an unset app appears in
    // allEntries() with a nil layoutID rather than being left out entirely.
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.setLayout("com.apple.keylayout.Canadian", forBundleID: "aaa.app")
    store.addAppWithNoLayout(bundleID: "bbb.app")

    let entries = store.allEntries()
    #expect(entries.count == 2)
    #expect(entries[0].bundleID == "aaa.app")
    #expect(entries[0].layoutID == "com.apple.keylayout.Canadian")
    #expect(entries[1].bundleID == "bbb.app")
    #expect(entries[1].layoutID == nil)
}

@Test func unsetPersistsAsJSONNullAndSurvivesReload() throws {
    let url = makeTempFileURL()
    let first = LayoutStore(fileURL: url)
    first.addAppWithNoLayout(bundleID: "com.unset.app")
    first.setLayout("com.apple.keylayout.French", forBundleID: "com.set.app")

    // The on-disk form must be an explicit null, not an omitted key. If the key
    // were omitted, unset would be indistinguishable from absent after a reload.
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("null"))

    let second = LayoutStore(fileURL: url)
    #expect(second.isManaged(bundleID: "com.unset.app") == true)
    #expect(second.layout(forBundleID: "com.unset.app") == nil)
    #expect(second.layout(forBundleID: "com.set.app") == "com.apple.keylayout.French")
}

@Test func writesUseCurrentSchemaVersion() throws {
    let url = makeTempFileURL()
    let store = LayoutStore(fileURL: url)
    store.setLayout("com.apple.keylayout.Canadian", forBundleID: "com.a.app")

    let data = try Data(contentsOf: url)
    let decoded = try JSONDecoder().decode(StoredLayouts.self, from: data)
    #expect(decoded.version == 3)
}

@Test func settingALayoutReplacesUnset() {
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.addAppWithNoLayout(bundleID: "com.a.app")
    store.setLayout("com.apple.keylayout.French", forBundleID: "com.a.app")

    #expect(store.layout(forBundleID: "com.a.app") == "com.apple.keylayout.French")
    #expect(store.allEntries().count == 1)
}

@Test func addAppWithNoLayoutDoesNotClearAnAlreadyManagedLayout() {
    // If the user re-adds an app movaMem already learned a layout for, that
    // layout must survive. The store must not rely on its caller (Task 4's
    // AppPicker) to prevent this — the guard belongs here.
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.setLayout("com.apple.keylayout.Ukrainian-PC", forBundleID: "com.tinyspeck.slackmacgap")

    store.addAppWithNoLayout(bundleID: "com.tinyspeck.slackmacgap")

    #expect(store.layout(forBundleID: "com.tinyspeck.slackmacgap") == "com.apple.keylayout.Ukrainian-PC")
}

@Test func removeOnAnUnsetEntryRemovesIt() {
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.addAppWithNoLayout(bundleID: "com.unset.app")

    store.remove(bundleID: "com.unset.app")

    #expect(store.isManaged(bundleID: "com.unset.app") == false)
    #expect(store.allEntries().isEmpty)
}

@Test func addAppWithNoLayoutCalledTwiceIsIdempotent() {
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.addAppWithNoLayout(bundleID: "com.unset.app")
    store.addAppWithNoLayout(bundleID: "com.unset.app")

    #expect(store.isManaged(bundleID: "com.unset.app") == true)
    #expect(store.layout(forBundleID: "com.unset.app") == nil)
    #expect(store.allEntries().count == 1)
}

// MARK: - Pruning uninstalled apps

@Test func pruneForgottenDropsAppsThatAreNoLongerInstalled() {
    // The point of the feature: an app uninstalled from the Mac should stop
    // showing up in Forgotten Apps.
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.remove(bundleID: "com.gone.app")
    store.remove(bundleID: "com.still.here")

    store.pruneForgotten { bundleID in bundleID == "com.still.here" }

    #expect(store.isForgotten(bundleID: "com.gone.app") == false)
    #expect(store.isForgotten(bundleID: "com.still.here") == true)
    #expect(store.forgottenBundleIDs() == ["com.still.here"])
}

@Test func pruneForgottenLeavesManagedAppsAlone() {
    // Managed entries hold a deliberately chosen layout. Pruning must never
    // touch them, however the installed check answers — an uninstalled managed
    // app is hidden by the menu, not deleted from the store.
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.setLayout("com.apple.keylayout.French", forBundleID: "com.gone.app")

    store.pruneForgotten { _ in false }

    #expect(store.layout(forBundleID: "com.gone.app") == "com.apple.keylayout.French")
    #expect(store.allEntries().count == 1)
}

@Test func pruneForgottenSurvivesReload() {
    let url = makeTempFileURL()
    let first = LayoutStore(fileURL: url)
    first.remove(bundleID: "com.gone.app")
    first.remove(bundleID: "com.still.here")

    first.pruneForgotten { bundleID in bundleID == "com.still.here" }

    let second = LayoutStore(fileURL: url)
    #expect(second.forgottenBundleIDs() == ["com.still.here"])
}

@Test func pruneForgottenWithNothingToDropDoesNotRewriteTheFile() throws {
    // Every launch calls this. When nothing changed it must not touch the file,
    // so an unchanged store keeps its modification date and a read-only disk
    // does not get flagged unwritable for no reason.
    let url = makeTempFileURL()
    let store = LayoutStore(fileURL: url)
    store.remove(bundleID: "com.still.here")

    let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    store.pruneForgotten { _ in true }
    let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

    #expect(before == after)
}

@Test func pruneForgottenAsksAboutEachBundleIDOnlyOnce() {
    // The predicate is a Launch Services call behind a cache. Prune must not
    // turn a large forgotten list into repeated lookups for the same ID.
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.remove(bundleID: "com.a.app")
    store.remove(bundleID: "com.b.app")

    var asked: [String] = []
    store.pruneForgotten { bundleID in
        asked.append(bundleID)
        return true
    }

    #expect(asked.sorted() == ["com.a.app", "com.b.app"])
}

@Test func pruneForgottenOnAnEmptyListIsHarmless() {
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.pruneForgotten { _ in false }
    #expect(store.forgottenBundleIDs().isEmpty)
}
