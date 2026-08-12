import Foundation
import Testing
@testable import movaMem

private func makeTempStore() -> LayoutStore {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("movamem-coord-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return LayoutStore(fileURL: dir.appendingPathComponent("layouts.json"))
}

private let canadian = "com.apple.keylayout.Canadian"
private let ukrainian = "com.apple.keylayout.Ukrainian-PC"
private let french = "com.apple.keylayout.French"

// MARK: - Restoring on activation

@Test func activatingKnownAppWithDifferentLayoutRestoresIt() {
    let input = FakeInputSource(current: canadian, installed: [canadian, ukrainian])
    let monitor = FakeAppMonitor()
    let store = makeTempStore()
    store.setLayout(ukrainian, forBundleID: "com.tinyspeck.slackmacgap")

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    monitor.simulateActivation(of: "com.tinyspeck.slackmacgap")
    #expect(input.selectCalls == [ukrainian])
}

@Test func activatingKnownAppWhoseLayoutIsAlreadyActiveDoesNothing() {
    let input = FakeInputSource(current: ukrainian, installed: [canadian, ukrainian])
    let monitor = FakeAppMonitor()
    let store = makeTempStore()
    store.setLayout(ukrainian, forBundleID: "com.tinyspeck.slackmacgap")

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    monitor.simulateActivation(of: "com.tinyspeck.slackmacgap")
    // A redundant select must be avoided: the real API fires no notification for
    // it, which would leave stale suppression state behind.
    #expect(input.selectCalls.isEmpty)
}

@Test func activatingUnknownAppDoesNothing() {
    let input = FakeInputSource(current: canadian, installed: [canadian, ukrainian])
    let monitor = FakeAppMonitor()
    let store = makeTempStore()

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    monitor.simulateActivation(of: "com.unknown.app")
    #expect(input.selectCalls.isEmpty)
    #expect(store.allEntries().isEmpty)   // first encounter must not record anything
}

@Test func failedSelectMarksLayoutUnavailableAndKeepsEntry() {
    // Ukrainian is remembered but no longer installed.
    let input = FakeInputSource(current: canadian, installed: [canadian])
    let monitor = FakeAppMonitor()
    let store = makeTempStore()
    store.setLayout(ukrainian, forBundleID: "com.tinyspeck.slackmacgap")

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    monitor.simulateActivation(of: "com.tinyspeck.slackmacgap")
    #expect(coordinator.unavailableLayoutIDs.contains(ukrainian))
    // The entry stays — it becomes valid again if the layout is reinstalled.
    #expect(store.layout(forBundleID: "com.tinyspeck.slackmacgap") == ukrainian)
}

@Test func reinstalledLayoutBecomesAvailableAgainOnNextActivation() {
    // Ukrainian starts out remembered but not installed, so the first
    // activation marks it unavailable.
    let input = FakeInputSource(current: canadian, installed: [canadian])
    let monitor = FakeAppMonitor()
    let store = makeTempStore()
    store.setLayout(ukrainian, forBundleID: "com.tinyspeck.slackmacgap")

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    monitor.simulateActivation(of: "com.tinyspeck.slackmacgap")
    #expect(coordinator.unavailableLayoutIDs.contains(ukrainian))

    // The layout gets reinstalled (e.g. the user re-adds it in System Settings).
    input.installedLayoutIDs = [canadian, ukrainian]

    // Revisiting the app should select it successfully and clear the
    // unavailable marker. Without the `remove` at the successful-select site,
    // this would stay dimmed in the menu forever even though it now works.
    monitor.simulateActivation(of: "com.tinyspeck.slackmacgap")
    #expect(coordinator.unavailableLayoutIDs.isEmpty)
    #expect(input.selectCalls.last == ukrainian)
}

@Test func userChangeToPreviouslyUnavailableLayoutClearsItsUnavailableMark() {
    // French starts out remembered but not installed.
    let input = FakeInputSource(current: canadian, installed: [canadian])
    let monitor = FakeAppMonitor()
    let store = makeTempStore()
    store.setLayout(french, forBundleID: "ru.keepcoder.Telegram")

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    monitor.simulateActivation(of: "ru.keepcoder.Telegram")
    #expect(coordinator.unavailableLayoutIDs.contains(french))

    // The user manually installs French and switches to it by hand while
    // Telegram is frontmost. This is a genuine user change, recorded the
    // normal way, and it should also clear the stale unavailable mark.
    input.installedLayoutIDs = [canadian, french]
    monitor.frontmostBundleID = "ru.keepcoder.Telegram"
    input.simulateUserSwitch(to: french)

    #expect(coordinator.unavailableLayoutIDs.isEmpty)
    #expect(store.layout(forBundleID: "ru.keepcoder.Telegram") == french)
}

@Test func layoutChangeWithUnknownCurrentLayoutIsIgnored() {
    // currentLayoutID is documented as nil-able in InputSourceProviding; this
    // is the state where the OS reports a change but we cannot determine what
    // the new layout actually is.
    let input = FakeInputSource(current: nil, installed: [canadian, french])
    let monitor = FakeAppMonitor(frontmost: "ru.keepcoder.Telegram")
    let store = makeTempStore()

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    input.fireLayoutChangedNotification()
    #expect(store.allEntries().isEmpty)
}

// MARK: - Recording user changes

@Test func userLayoutChangeIsRecordedAgainstFrontmostApp() {
    let input = FakeInputSource(current: canadian, installed: [canadian, french])
    let monitor = FakeAppMonitor(frontmost: "ru.keepcoder.Telegram")
    let store = makeTempStore()

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    input.simulateUserSwitch(to: french)
    #expect(store.layout(forBundleID: "ru.keepcoder.Telegram") == french)
}

@Test func ourOwnRestoreIsNotRecorded() {
    let input = FakeInputSource(current: canadian, installed: [canadian, ukrainian])
    let monitor = FakeAppMonitor()
    let store = makeTempStore()
    store.setLayout(ukrainian, forBundleID: "com.tinyspeck.slackmacgap")

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    monitor.simulateActivation(of: "com.tinyspeck.slackmacgap")
    // The real API fires a notification for our own select. It must be ignored.
    input.fireLayoutChangedNotification()

    // Still exactly the one entry we started with, unchanged.
    #expect(store.allEntries().count == 1)
    #expect(store.layout(forBundleID: "com.tinyspeck.slackmacgap") == ukrainian)
}

// MARK: - Probe-derived regression tests
// These two cover measured Carbon behavior. Both failures are intermittent, so
// without these tests the bugs would ship and corrupt layouts occasionally
// rather than failing visibly.

@Test func duplicateNotificationsForOneSelectAreBothIgnored() {
    let input = FakeInputSource(current: canadian, installed: [canadian, ukrainian])
    let monitor = FakeAppMonitor()
    let store = makeTempStore()
    store.setLayout(ukrainian, forBundleID: "com.tinyspeck.slackmacgap")

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    monitor.simulateActivation(of: "com.tinyspeck.slackmacgap")

    // One select, two notifications — measured behavior on macOS 26.5. A boolean
    // flag would clear on the first and record the second as a user change.
    input.fireLayoutChangedNotification()
    input.fireLayoutChangedNotification()

    #expect(store.allEntries().count == 1)
    #expect(store.layout(forBundleID: "com.tinyspeck.slackmacgap") == ukrainian)
}

@Test func coalescedNotificationLeavesStaleStateButNextUserChangeStillRecords() {
    let input = FakeInputSource(current: canadian, installed: [canadian, ukrainian, french])
    let monitor = FakeAppMonitor()
    let store = makeTempStore()
    store.setLayout(ukrainian, forBundleID: "com.tinyspeck.slackmacgap")

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    // Activation triggers our select, but the OS coalesces the notification away
    // and it never arrives. Suppression state is now stale.
    monitor.simulateActivation(of: "com.tinyspeck.slackmacgap")

    // A genuine user change must still be recorded despite the stale state.
    input.simulateUserSwitch(to: french)
    #expect(store.layout(forBundleID: "com.tinyspeck.slackmacgap") == french)
}

@Test func userSwitchBackToStaleSuppressedLayoutIsStillIgnored() {
    // Sharper version of the coalescing case above: the notification for our
    // own select never arrives, so layoutWeSelected is left pointing at
    // "ukrainian" with currentLayoutID already "ukrainian" too. If the user's
    // next action happens to land back on that same layout, the change
    // handler cannot distinguish "the user genuinely chose this" from "this
    // is the coalesced notification finally arriving" — both look identical.
    // This is acceptable: the layout was already active and already the
    // stored value for this app, so the store entry is unchanged either way.
    let input = FakeInputSource(current: canadian, installed: [canadian, ukrainian])
    let monitor = FakeAppMonitor()
    let store = makeTempStore()
    store.setLayout(ukrainian, forBundleID: "com.tinyspeck.slackmacgap")

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    // Activation selects ukrainian and sets layoutWeSelected = ukrainian, but
    // (as in the test above) the notification is coalesced away and never
    // simulated, so the suppression state is stale but still set.
    monitor.simulateActivation(of: "com.tinyspeck.slackmacgap")

    // The user "switches" to the very layout layoutWeSelected already points
    // at. Current documented behavior: this is ignored, same as our own change
    // would be.
    input.simulateUserSwitch(to: ukrainian)

    #expect(store.allEntries().count == 1)
    #expect(store.layout(forBundleID: "com.tinyspeck.slackmacgap") == ukrainian)
}

@Test func layoutChangeWithNoFrontmostAppIsIgnored() {
    let input = FakeInputSource(current: canadian, installed: [canadian, french])
    let monitor = FakeAppMonitor(frontmost: nil)
    let store = makeTempStore()

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    input.simulateUserSwitch(to: french)
    #expect(store.allEntries().isEmpty)
}

@Test func activatingAnUnsetAppDoesNothing() {
    // An app added via Add App... but never given a layout must behave exactly
    // like an app the store has never seen: no switch, and nothing recorded.
    let input = FakeInputSource(current: canadian, installed: [canadian, ukrainian])
    let monitor = FakeAppMonitor()
    let store = makeTempStore()
    store.addAppWithNoLayout(bundleID: "com.unset.app")

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    monitor.simulateActivation(of: "com.unset.app")
    #expect(input.selectCalls.isEmpty)
}

@Test func userSwitchInAnUnsetAppRecordsTheLayout() {
    // The app is managed but unset; switching layout by hand should fill it in.
    let input = FakeInputSource(current: canadian, installed: [canadian, french])
    let monitor = FakeAppMonitor(frontmost: "com.unset.app")
    let store = makeTempStore()
    store.addAppWithNoLayout(bundleID: "com.unset.app")

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    input.simulateUserSwitch(to: french)
    #expect(store.layout(forBundleID: "com.unset.app") == french)
}

// MARK: - Menu-initiated selects (chooseLayout's caller of select())

@Test func menuSelectDoesNotOverwriteAnotherAppWhenFrontmostChangesFirst() {
    // Reproduces the phase 2 data-loss defect: MenuController.chooseLayout calls
    // select() directly. If it does not also tell the coordinator which layout
    // it is about to select, the coordinator has no way to know the resulting
    // notification belongs to the app the menu was editing rather than
    // whatever app happens to be frontmost when the notification arrives.
    //
    // Sequence: VS Code and Telegram are both stored as Canadian. The menu sets
    // VS Code to French while VS Code is frontmost, then the user Cmd-Tabs to
    // Telegram BEFORE the layout-changed notification is delivered (this is
    // realistic: DistributedNotificationCenter delivery is asynchronous).
    // Telegram's stored Canadian preference must survive untouched.
    let input = FakeInputSource(current: canadian, installed: [canadian, french])
    let monitor = FakeAppMonitor(frontmost: "com.microsoft.VSCode")
    let store = makeTempStore()
    store.setLayout(canadian, forBundleID: "com.microsoft.VSCode")
    store.setLayout(canadian, forBundleID: "ru.keepcoder.Telegram")

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    // What MenuController.chooseLayout does, in order: declare the select,
    // persist the new choice, then actually select it.
    coordinator.noteLayoutWeAreAboutToSelect(french)
    store.setLayout(french, forBundleID: "com.microsoft.VSCode")
    _ = input.select(layoutID: french)

    // The user switches apps before the notification arrives.
    monitor.frontmostBundleID = "ru.keepcoder.Telegram"
    input.fireLayoutChangedNotification()

    // Telegram's preference must be untouched: the notification was caused by
    // our own select for VS Code, not a real user change in Telegram.
    #expect(store.layout(forBundleID: "ru.keepcoder.Telegram") == canadian)
    #expect(store.layout(forBundleID: "com.microsoft.VSCode") == french)
}

@Test func menuSelectWhileStillFrontmostAppliesCleanly() {
    // The ordinary case: the menu sets a new layout for the app that is still
    // frontmost when the notification arrives. The new layout must stick for
    // that app, and no other app's entry should be touched.
    let input = FakeInputSource(current: canadian, installed: [canadian, french])
    let monitor = FakeAppMonitor(frontmost: "com.microsoft.VSCode")
    let store = makeTempStore()
    store.setLayout(canadian, forBundleID: "com.microsoft.VSCode")
    store.setLayout(canadian, forBundleID: "ru.keepcoder.Telegram")

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    coordinator.noteLayoutWeAreAboutToSelect(french)
    store.setLayout(french, forBundleID: "com.microsoft.VSCode")
    _ = input.select(layoutID: french)

    // Frontmost app has not changed, and the notification arrives normally.
    input.fireLayoutChangedNotification()

    #expect(store.layout(forBundleID: "com.microsoft.VSCode") == french)
    #expect(store.layout(forBundleID: "ru.keepcoder.Telegram") == canadian)
}

@Test func switchingBetweenThreeAppsRestoresEachLayout() {
    // The end-to-end scenario from the spec's success criteria.
    let input = FakeInputSource(current: canadian, installed: [canadian, ukrainian, french])
    let monitor = FakeAppMonitor()
    let store = makeTempStore()

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    // Teach it three apps, the way the user would.
    monitor.simulateActivation(of: "com.microsoft.VSCode")
    input.simulateUserSwitch(to: canadian)

    monitor.simulateActivation(of: "com.tinyspeck.slackmacgap")
    input.simulateUserSwitch(to: ukrainian)

    monitor.simulateActivation(of: "ru.keepcoder.Telegram")
    input.simulateUserSwitch(to: french)

    // Now revisit each app; the right layout must be restored.
    input.selectCalls = []
    monitor.simulateActivation(of: "com.microsoft.VSCode")
    #expect(input.selectCalls == [canadian])

    input.selectCalls = []
    monitor.simulateActivation(of: "com.tinyspeck.slackmacgap")
    #expect(input.selectCalls == [ukrainian])

    input.selectCalls = []
    monitor.simulateActivation(of: "ru.keepcoder.Telegram")
    #expect(input.selectCalls == [french])
}

@Test func cancellingANoteAfterAFailedSelectKeepsRecordingUserChanges() {
    // The menu can try to select a layout that vanished between the menu being
    // opened and the row being clicked. That select fails and fires no
    // notification, so nothing would clear the note unless the caller cancels it.
    //
    // Reproduced before cancelNotedLayout() existed: the stale note swallowed the
    // user's later genuine switch to that same layout, recording nothing at all.
    let input = FakeInputSource(current: canadian, installed: [canadian])
    let monitor = FakeAppMonitor(frontmost: "com.a.app")
    let store = makeTempStore()

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    // What MenuController.chooseLayout does when its select fails: note, save,
    // select (returns false because french is not installed), then cancel.
    coordinator.noteLayoutWeAreAboutToSelect(french)
    store.setLayout(french, forBundleID: "com.a.app")
    let didSelect = input.select(layoutID: french)
    #expect(didSelect == false)
    coordinator.cancelNotedLayout()

    // Later the layout becomes available and the user switches to it by hand in a
    // different app. That is a genuine choice and must be recorded.
    monitor.frontmostBundleID = "com.b.app"
    input.installedLayoutIDs.append(french)
    input.simulateUserSwitch(to: french)

    #expect(store.layout(forBundleID: "com.b.app") == french)
}
