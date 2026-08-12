# movaMem Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the read-only status menu into a complete editor — set a layout per app, forget an app, and add an app that has never been visited.

**Architecture:** Three changes on top of phase 1. `LayoutStore`'s value type becomes optional (`String?`) so an app can be managed with no layout, bumping the schema to version 2. A new `AppPicker` splits a pure, tested decision function from a thin `NSOpenPanel` shell. `MenuController` gains submenus and three actions.

**Tech Stack:** Swift 6.3, SwiftPM (no Xcode), AppKit, Foundation, os_log, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-12-movamem-phase-2-design.md`

## Global Constraints

These apply to every task. A task's requirements implicitly include this section.

- **Readability over idiom — hard constraint.** The owner does not write Swift and reviews
  every line personally. Explicit `if`/`for` over `map`/`filter`/`reduce`/`compactMap`. Named
  intermediate variables over nested one-liners. No force-unwraps, no implicitly-unwrapped
  optionals, no generics, no result builders, no Combine. Comments explain *why* in plain
  English. Longer-but-clearer is the intended trade.
- **Verify with `rm -rf .build && make test`, never bare `make test`.** During phase 1 a warm
  `.build` masked a link failure for three tasks and every reported green run was
  unreproducible. Incremental runs are fine while iterating; the run you report and commit
  against must start clean.
- **Baseline: 35 tests passing, zero build warnings.** Both must hold at every commit, plus
  whatever tests the task adds. Expected counts per task: 42 after Task 1 step 5, 44 after
  Task 1 step 6, 50 after Task 2, unchanged thereafter. **Treat these as a sanity check, not a
  gate** — if your actual count differs but every test passes and nothing was deleted, trust
  the run and report the real number. Phase 1 had stale counts in its plan cause confusion.
- Files under 500 lines; functions under 50 lines. **`MenuController` reached 358 lines after
  Task 3** and Task 4 adds an `Add App…` action plus an `NSAlert` helper — realistically
  60-90 more, landing around 420-450. Under the cap but past the report threshold, so Task 4's
  implementer must **stop and report the line count** rather than splitting on their own
  judgment.

  If a split is needed, the seam identified during Task 3's review is **presentation vs.
  command handling**: `LayoutChoice`/`ForgetTarget`/`rowTitle`/`makeSubmenu`/`addAppEntries`
  render the menu, while `chooseLayout`/`forgetApp`/`addApp` plus the alert helper handle
  commands. That split was deliberately deferred at Task 3 because the command side was only
  37 lines — too thin to justify a file. Task 4's alert plumbing is what makes it a real unit.
- Logging: `os_log` only. No `print` in shipped code.
- No third-party dependencies. Only Apple frameworks.
- `Sources/movaMem/main.swift` — the filename is load-bearing. Swift permits top-level code
  only in a file named exactly `main.swift`. Never rename or delete it.
- `CFBundleIdentifier` is `com.movamem.app` and must not change. `AppMonitor.ignoredBundleIDs`
  matches that exact string so the app does not treat its own menu as an app switch.
- Prefer `@MainActor` where a type is not referenced by tests; use `@unchecked Sendable` only
  where `@MainActor` would force a synchronous test API to become async (as `AppMonitor` does).
  `MenuController` is already `@MainActor`.

## Probe Findings — Verified Before Writing This Plan

Every claim below was checked by compiling and running real code on this machine
(macOS 26.5, Swift 6.3, Command Line Tools only). Do not re-derive these; do not "fix" code
that looks odd because of them.

**1. A v1 file decodes into `[String: String?]` with no migration code.**
`{"version":1,"apps":{"com.a":"layout.A"}}` decodes cleanly; plain strings become non-nil
optionals. **No migration code is needed or wanted.**

**2. Encoding `nil` emits JSON `null`, not an omitted key.** Verified output:

```json
{ "apps" : { "com.set" : "layout.X", "com.unset" : null }, "version" : 2 }
```

This is load-bearing. Had Swift omitted the key, unset would be indistinguishable from absent
after a reload and the whole design would need rework.

**3. Round-tripping preserves the unset key** — it decodes back as present-with-nil.

**4. THE TRAP — `apps[bundleID]` is a DOUBLE optional (`String??`).**

```swift
// WRONG — this branch is ENTERED for an unset app, because the outer optional
// only asks "is the key present?". An unset app therefore looks like it has a layout.
if let layout = apps["unset"] { ... }   // layout is String?, and it is nil here
```

Verified: that branch executes with `layout == nil`. **Always flatten with `?? nil` first:**

```swift
let layoutID: String? = apps[bundleID] ?? nil   // nil for BOTH unset and absent
```

To distinguish unset from absent, test key presence separately:

```swift
let isManaged = apps.index(forKey: bundleID) != nil
```

**Correction, found during execution by mutation testing.** An earlier version of this plan
claimed the wrong `if let` idiom would silently drop unset apps from the menu. That is **false**
for the element type this task produces, and the claim was removed after a reviewer mutated both
call sites back to `if let` and all tests still passed.

The two idioms diverge **only when the key is absent**. `allEntries()` iterates
`layouts.apps.keys`, so every key is present by construction and the idioms are provably
equivalent there. `layout(forBundleID:)` falls through to `return nil` for an absent key, so it
coincides too. The trap is real for `String??` in general — and it WAS a live bug while the
tuple element type was non-optional `String`, because the wrong idiom would not compile or would
drop entries — but once the element type becomes `String?`, the wrong idiom silently becomes
correct.

Keep the `?? nil` form: it is explicit and correct, and it protects against a future refactor
that reads a key which might be absent. But comment it as *defensive explicitness*, not as a
fix for a live bug, or the comment misleads the next reader.

**5. Bundle ID extraction works and fails safely.** `Bundle(url:)?.bundleIdentifier` returns
`com.apple.mail` for Mail, and `nil` (no crash) for a hand-built `.app` with no
`CFBundleIdentifier`.

**6. `NSOpenPanel.allowedContentTypes = [.application]` is the correct restriction API** on
macOS 11+. Configuring the panel off-screen works.

**7. Display names must not come from the filename.** For a bundle at
`/tmp/NoID-CAB9A1E1-….app`, `url.deletingPathExtension().lastPathComponent` returns the whole
UUID filename. Resolve `CFBundleDisplayName`, then `CFBundleName`, and fall back to the filename
only as a last resort — `MenuController.displayName(forBundleID:)` already does this and is the
pattern to follow.

**The precedence between the two plist keys needs its own test.** A test bundle that writes only
`CFBundleName` cannot detect the two checks being swapped, and many real apps set a marketing
`CFBundleDisplayName` different from their internal `CFBundleName`. Since this string goes into a
user-facing alert, a test must build a bundle where the two keys differ and assert the display
name wins. (Found during execution: the first version of Task 2 had exactly this gap.)

**8. Safari is not at `/System/Applications/Safari.app`** on macOS 26. Do not hardcode app
paths in tests; build temp bundles instead.

---

### Task 1: `LayoutStore` — optional layouts and schema version 2

The riskiest task in phase 2. Changing the value type touches every reader.

**Files:**
- Modify: `Sources/movaMem/LayoutStore.swift`
- Modify: `Tests/movaMemTests/LayoutStoreTests.swift`

**Interfaces:**
- Consumes: nothing new
- Produces:
  - `struct StoredLayouts` with `var version: Int` and `var apps: [String: String?]`
  - `func layout(forBundleID: String) -> String?` — signature UNCHANGED; returns nil for both
    unset and absent
  - `func allEntries() -> [(bundleID: String, layoutID: String?)]` — element type CHANGED
  - `func setLayout(_ layoutID: String, forBundleID: String)` — unchanged signature
  - `func addAppWithNoLayout(bundleID: String)` — NEW; registers an app with no layout
  - `func isManaged(bundleID: String) -> Bool` — NEW; true when the key is present, whether or
    not a layout is set. This is the only way to distinguish unset from absent.
  - `func remove(bundleID: String)` — unchanged
  - `currentSchemaVersion` becomes `2`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/movaMemTests/LayoutStoreTests.swift`. The existing helper `makeTempFileURL()`
is already in that file — reuse it, do not redefine it.

```swift
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
    // Verifies unset entries appear with a nil layout, which is what the menu
    // relies on to render the "(not set)" row.
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

@Test func writesUseSchemaVersionTwo() throws {
    let url = makeTempFileURL()
    let store = LayoutStore(fileURL: url)
    store.setLayout("com.apple.keylayout.Canadian", forBundleID: "com.a.app")

    let data = try Data(contentsOf: url)
    let decoded = try JSONDecoder().decode(StoredLayouts.self, from: data)
    #expect(decoded.version == 2)
}

@Test func settingALayoutReplacesUnset() {
    let store = LayoutStore(fileURL: makeTempFileURL())
    store.addAppWithNoLayout(bundleID: "com.a.app")
    store.setLayout("com.apple.keylayout.French", forBundleID: "com.a.app")

    #expect(store.layout(forBundleID: "com.a.app") == "com.apple.keylayout.French")
    #expect(store.allEntries().count == 1)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rm -rf .build && make test`
Expected: FAIL — `addAppWithNoLayout` and `isManaged` do not exist, and the
`allEntries()` tests fail to compile because its element type is still non-optional.

- [ ] **Step 3: Change the model and the schema version**

In `Sources/movaMem/LayoutStore.swift`:

```swift
/// On-disk shape of the store. Kept as a separate type so the JSON format is
/// explicit and versioned.
struct StoredLayouts: Codable {
    var version: Int
    /// Bundle ID -> TIS input source ID.
    ///
    /// The value is optional: nil means "this app is managed, but has no layout
    /// to restore yet". That is how an app added via Add App... starts out. It
    /// encodes as an explicit JSON null rather than an omitted key, which is what
    /// keeps "unset" distinguishable from "never seen" across a reload.
    var apps: [String: String?]
}
```

And bump the version constant:

```swift
    private static let currentSchemaVersion = 2
```

- [ ] **Step 4: Fix every reader inside `LayoutStore`**

`apps[bundleID]` is now a DOUBLE optional (`String??`). Flatten with `?? nil` at every read.
Replace the reading and writing sections:

```swift
    // MARK: - Reading

    /// The layout to restore for this app, or nil if there is none.
    ///
    /// Returns nil for two different situations that the caller does not need to
    /// tell apart: the app is managed but has no layout set yet, or the app has
    /// never been seen. Both mean "do nothing on activation", which is exactly
    /// what SwitchCoordinator wants. Use isManaged(bundleID:) when the difference
    /// matters, as the menu does.
    func layout(forBundleID bundleID: String) -> String? {
        // `layouts.apps[bundleID]` is String?? here: the outer optional is "is the
        // key present", the inner is "is a layout set". Writing `if let` on it
        // would enter the branch for an unset app, which is the wrong answer, so
        // flatten both levels with `?? nil`.
        let layoutID: String? = layouts.apps[bundleID] ?? nil
        return layoutID
    }

    /// True when this app is in the store at all, whether or not a layout is set.
    /// This is the only way to distinguish an unset app from an unknown one.
    func isManaged(bundleID: String) -> Bool {
        return layouts.apps.index(forKey: bundleID) != nil
    }

    /// All entries, sorted by bundle ID so the menu order is stable between openings.
    ///
    /// An entry whose layoutID is nil is managed but unset; the menu shows it as
    /// "(not set)". Unset entries must NOT be dropped here.
    func allEntries() -> [(bundleID: String, layoutID: String?)] {
        var result: [(bundleID: String, layoutID: String?)] = []
        let sortedKeys = layouts.apps.keys.sorted()
        for bundleID in sortedKeys {
            // Flatten the double optional. The phase-1 version used `if let` here,
            // which would now skip every unset app.
            let layoutID: String? = layouts.apps[bundleID] ?? nil
            result.append((bundleID: bundleID, layoutID: layoutID))
        }
        return result
    }

    // MARK: - Writing

    func setLayout(_ layoutID: String, forBundleID bundleID: String) {
        layouts.apps[bundleID] = layoutID
        save()
    }

    /// Registers an app with no layout to restore. Used by Add App..., where the
    /// user has chosen which app to manage but not yet which layout.
    ///
    /// Does nothing if the app is already managed. Without that guard, re-adding
    /// an app would wipe a layout the user had already taught us. The Add App...
    /// flow does filter already-managed apps before calling this, but the store
    /// must not depend on its caller to avoid destroying data.
    func addAppWithNoLayout(bundleID: String) {
        if isManaged(bundleID: bundleID) {
            log.debug("Already managed, leaving alone: \(bundleID, privacy: .public)")
            return
        }
        // Assigning `.some(nil)` stores a present key with a nil value. Writing
        // `layouts.apps[bundleID] = nil` would REMOVE the key instead — that is
        // how dictionary subscript assignment works with optionals.
        layouts.apps[bundleID] = .some(nil)
        save()
    }

    func remove(bundleID: String) {
        layouts.apps.removeValue(forKey: bundleID)
        save()
    }
```

**The `.some(nil)` detail in `addAppWithNoLayout` is critical.** Assigning plain `nil` to a
dictionary subscript deletes the key. Only `.some(nil)` stores a present-but-nil value.

- [ ] **Step 5: Run tests to verify they pass**

Run: `rm -rf .build && make test`
Expected: PASS. Test count rises from 35 to 42. Zero build warnings.

If `SwitchCoordinator.swift` or `MenuController.swift` now fail to compile, fix only what the
compiler demands to restore the build — `layout(forBundleID:)` kept its signature, so the
likely break is `allEntries()`'s element type in `MenuController`. A minimal fix there is fine;
Task 3 rewrites that code properly.

- [ ] **Step 6: Verify the coordinator treats unset exactly as unknown**

Append to `Tests/movaMemTests/SwitchCoordinatorTests.swift`. The helpers `makeTempStore()`,
`canadian`, `ukrainian`, and `french` already exist in that file — reuse them.

```swift
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
```

Run: `rm -rf .build && make test`
Expected: PASS, 44 tests. These should pass with **no change to `SwitchCoordinator`** — if
either fails, stop and report, because it means unset is not behaving as unknown.

- [ ] **Step 7: Commit**

```bash
git add Sources/movaMem/LayoutStore.swift Tests/movaMemTests/LayoutStoreTests.swift Tests/movaMemTests/SwitchCoordinatorTests.swift
git commit -m "feat: allow an app to be managed with no layout (schema v2)

The store value becomes optional so Add App... can register an app before a
layout is chosen. nil encodes as an explicit JSON null, which keeps unset
distinguishable from absent across a reload.

apps[bundleID] is now a double optional, so every read flattens with ?? nil.
The phase-1 allEntries() used `if let`, which would have silently dropped
unset apps from the menu. addAppWithNoLayout assigns .some(nil), because
assigning plain nil to a dictionary subscript removes the key instead.

SwitchCoordinator needed no change: unset and unknown both return nil from
layout(forBundleID:), and doing nothing is correct for both."
```

---

### Task 2: `AppPicker` — the decision function

Pure logic with real tests. The `NSOpenPanel` shell comes in Task 4, so this task has no
AppKit UI and no untestable code.

**Files:**
- Create: `Sources/movaMem/AppPicker.swift`
- Create: `Tests/movaMemTests/AppPickerTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 (deliberately — the caller passes in the managed bundle IDs, so
  this file does not depend on `LayoutStore`)
- Produces:
  - `enum AppPickResult` with cases `.valid(bundleID: String)`,
    `.alreadyManaged(appName: String)`, `.noBundleIdentifier(appName: String)`
  - `struct AppPicker` with
    `static func evaluate(appBundleURL: URL, managedBundleIDs: Set<String>) -> AppPickResult`
  - `static func displayName(forBundleAt: URL) -> String`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import movaMem

/// Builds a real .app bundle in a temp directory. No mocking — the code under
/// test reads a real Info.plist through Bundle(url:).
private func makeTempAppBundle(name: String, bundleID: String?) -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("picker-" + UUID().uuidString)
    let appURL = root.appendingPathComponent("\(name).app")
    let contents = appURL.appendingPathComponent("Contents")
    try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

    var entries = "<key>CFBundleName</key><string>\(name)</string>"
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
        // Only the name is carried: it is what the alert shows. The bundle ID is
        // not needed by any caller, so the case does not carry it.
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rm -rf .build && make test`
Expected: FAIL — `cannot find 'AppPicker' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import os

/// What happened when the user picked an app in the Add App... panel.
///
/// Three outcomes, each needing a different response from the menu, which is why
/// this decision lives in a plain function that can be tested rather than inside
/// the AppKit panel code.
enum AppPickResult {
    /// Usable and not already in the store.
    case valid(bundleID: String)
    /// Already in the store. Nothing to do, but the user must be told, or the
    /// menu item will look broken.
    case alreadyManaged(appName: String)
    /// The bundle has no CFBundleIdentifier, so movaMem cannot identify it.
    case noBundleIdentifier(appName: String)
}

/// Decides whether a chosen application can be managed.
///
/// This type holds no state and touches no UI. The NSOpenPanel that produces the
/// URL lives in MenuController; everything worth testing is here.
struct AppPicker {
    private static let log = Logger(subsystem: "com.movamem.app", category: "AppPicker")

    /// Classifies a chosen app bundle.
    ///
    /// managedBundleIDs is passed in rather than read from LayoutStore, so this
    /// function stays pure and this file has no dependency on the store.
    static func evaluate(appBundleURL: URL, managedBundleIDs: Set<String>) -> AppPickResult {
        let appName = displayName(forBundleAt: appBundleURL)

        // Bundle(url:) returns nil for anything that is not a real bundle, and
        // bundleIdentifier is nil when Info.plist has no CFBundleIdentifier.
        // Neither case crashes; both mean the same thing to us.
        guard let bundle = Bundle(url: appBundleURL) else {
            log.error("Not a readable bundle: \(appName, privacy: .public)")
            return .noBundleIdentifier(appName: appName)
        }
        guard let bundleID = bundle.bundleIdentifier else {
            log.error("Bundle has no identifier: \(appName, privacy: .public)")
            return .noBundleIdentifier(appName: appName)
        }

        if managedBundleIDs.contains(bundleID) {
            return .alreadyManaged(appName: appName)
        }
        return .valid(bundleID: bundleID)
    }

    /// Human-readable name for an app bundle on disk.
    ///
    /// Prefers the names inside Info.plist and uses the filename only as a last
    /// resort. That matters because the filename can be something unhelpful — a
    /// downloaded app may sit at a path with a generated name, and putting that
    /// in an alert would be confusing.
    static func displayName(forBundleAt url: URL) -> String {
        let filenameFallback = url.deletingPathExtension().lastPathComponent

        guard let bundle = Bundle(url: url) else {
            return filenameFallback
        }
        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        if let name = displayName {
            return name
        }
        let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        if let name = bundleName {
            return name
        }
        return filenameFallback
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rm -rf .build && make test`
Expected: PASS, 54 tests, zero warnings. (Counts drifted upward during execution as fix rounds added tests; trust the actual run.)

- [ ] **Step 5: Commit**

```bash
git add Sources/movaMem/AppPicker.swift Tests/movaMemTests/AppPickerTests.swift
git commit -m "feat: add AppPicker decision function

Classifies a chosen app bundle as valid, already-managed, or having no bundle
identifier. Pure and stateless, so it is tested against real temp .app bundles
rather than mocks; the NSOpenPanel that produces the URL comes later and stays
in MenuController.

managedBundleIDs is passed in rather than read from LayoutStore, keeping this
file free of any store dependency. Display names prefer Info.plist over the
filename, since a generated filename in an alert would confuse."
```

---

### Task 3: Submenus, layout selection, and Forget This App

Turns each app row into a submenu. No `Add App…` yet — that is Task 4.

**Files:**
- Modify: `Sources/movaMem/MenuController.swift`

**Interfaces:**
- Consumes: `LayoutStore.allEntries() -> [(bundleID: String, layoutID: String?)]`,
  `LayoutStore.setLayout(_:forBundleID:)`, `LayoutStore.remove(bundleID:)`,
  `InputSourceProviding.availableLayouts() -> [KeyboardLayout]`,
  `InputSourceProviding.select(layoutID:) -> Bool`,
  `AppMonitoring.frontmostBundleID -> String?`
- Produces: a `MenuController` whose app rows are enabled and carry submenus

**A required constructor change.** `MenuController` currently receives `store`, `inputSource`,
and `coordinator`. To apply a layout immediately when the edited app is frontmost, it also
needs to know which app is frontmost. Add an `appMonitor: AppMonitoring` parameter and store
it. `main.swift` already constructs `AppMonitor` before `MenuController`, so wiring it is a
one-line change there — make that change in this task and keep the build green.

- [ ] **Step 1: Replace `addAppEntries(to:)`**

Each row gains a submenu. Menu items carry their target via `representedObject` — never parse
titles, because row titles contain an em dash and so do some layout names.

```swift
    /// Identifies which app and layout a submenu item refers to.
    ///
    /// Attached to NSMenuItem.representedObject rather than encoded in the title:
    /// titles contain an em dash as a separator, and a layout name could contain
    /// one too, so parsing them back would be fragile.
    private final class LayoutChoice: NSObject {
        let bundleID: String
        let layoutID: String
        init(bundleID: String, layoutID: String) {
            self.bundleID = bundleID
            self.layoutID = layoutID
            super.init()
        }
    }

    /// Identifies which app a Forget This App item refers to.
    private final class ForgetTarget: NSObject {
        let bundleID: String
        init(bundleID: String) {
            self.bundleID = bundleID
            super.init()
        }
    }

    private func addAppEntries(to menu: NSMenu) {
        let entries = store.allEntries()

        if entries.isEmpty {
            let empty = NSMenuItem(title: "No apps remembered yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        // Build a lookup of layout ID -> display name once, rather than searching
        // the layout list for every entry.
        let installedLayouts = inputSource.availableLayouts()
        var layoutNames: [String: String] = [:]
        for layout in installedLayouts {
            layoutNames[layout.id] = layout.name
        }

        for entry in entries {
            let appName = displayName(forBundleID: entry.bundleID)

            // Three row states: a layout that is set and installed, a layout that
            // is set but no longer installed, and no layout at all.
            var title: String
            var isUnavailable = false

            if let layoutID = entry.layoutID {
                let layoutName = layoutNames[layoutID] ?? layoutID
                // availableLayouts() asks the OS fresh every time the menu opens,
                // so a missing name means the layout really is not installed right
                // now — and it becomes present again if the user reinstalls it.
                let layoutIsNotInstalled = layoutNames[layoutID] == nil
                if layoutIsNotInstalled {
                    title = "\(appName) — \(layoutName) (unavailable)"
                    isUnavailable = true
                } else {
                    title = "\(appName) — \(layoutName)"
                }
            } else {
                // Managed via Add App... but no layout chosen yet.
                title = "\(appName) — (not set)"
            }

            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = makeSubmenu(
                forBundleID: entry.bundleID,
                currentLayoutID: entry.layoutID,
                installedLayouts: installedLayouts
            )
            if isUnavailable {
                item.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.foregroundColor: NSColor.disabledControlTextColor]
                )
            }
            menu.addItem(item)
        }
    }

    /// The per-app submenu: every installed layout, then Forget This App.
    private func makeSubmenu(
        forBundleID bundleID: String,
        currentLayoutID: String?,
        installedLayouts: [KeyboardLayout]
    ) -> NSMenu {
        let submenu = NSMenu()
        // Same reason as the main menu: AppKit would otherwise recompute enabled
        // state at display time and ignore what we set.
        submenu.autoenablesItems = false

        for layout in installedLayouts {
            let layoutItem = NSMenuItem(
                title: layout.name,
                action: #selector(chooseLayout(_:)),
                keyEquivalent: ""
            )
            layoutItem.target = self
            layoutItem.representedObject = LayoutChoice(bundleID: bundleID, layoutID: layout.id)
            if layout.id == currentLayoutID {
                layoutItem.state = .on
            } else {
                layoutItem.state = .off
            }
            submenu.addItem(layoutItem)
        }

        submenu.addItem(NSMenuItem.separator())

        let forgetItem = NSMenuItem(
            title: "Forget This App",
            action: #selector(forgetApp(_:)),
            keyEquivalent: ""
        )
        forgetItem.target = self
        forgetItem.representedObject = ForgetTarget(bundleID: bundleID)
        submenu.addItem(forgetItem)

        return submenu
    }
```

- [ ] **Step 2: Add the two actions**

```swift
    @objc private func chooseLayout(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? LayoutChoice else {
            log.error("Layout menu item had no LayoutChoice attached")
            return
        }

        store.setLayout(choice.layoutID, forBundleID: choice.bundleID)
        log.debug("Set \(choice.layoutID, privacy: .public) for \(choice.bundleID, privacy: .public)")

        // Apply at once when the app being edited is the one in front, because a
        // restore normally happens on activation and no activation will fire for
        // the app that is already frontmost. Without this the most common
        // interaction — setting the layout for the app you are using — would
        // appear to do nothing until you left and came back.
        //
        // This comparison is safe because movaMem is an .accessory / LSUIElement
        // app: it has no Dock icon, no window, and no app-switcher entry, so
        // opening this menu never makes it frontmost and NSWorkspace still
        // reports the user's app underneath. (Its bundle ID is also in
        // AppMonitor.ignoredBundleIDs, but that only filters the activation
        // notification — it does NOT affect this read. An earlier version of this
        // plan credited the ignore list for the guarantee, which was wrong.)
        if appMonitor.frontmostBundleID == choice.bundleID {
            let didSelect = inputSource.select(layoutID: choice.layoutID)
            if didSelect == false {
                log.error("Could not select \(choice.layoutID, privacy: .public) immediately")
            }
        }
    }

    @objc private func forgetApp(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ForgetTarget else {
            log.error("Forget menu item had no ForgetTarget attached")
            return
        }
        // Only the remembered preference goes away. The layout the user is
        // currently typing in is deliberately left alone — forgetting an app
        // means movaMem stops managing it, not that anything gets reverted.
        store.remove(bundleID: target.bundleID)
        log.debug("Forgot \(target.bundleID, privacy: .public)")
    }
```

- [ ] **Step 3: Wire `appMonitor` through the constructor**

In `MenuController`, add the stored property and parameter:

```swift
    private let appMonitor: AppMonitoring
```

and extend `init` to take `appMonitor: AppMonitoring`, assigning it before `super.init()`.

In `Sources/movaMem/main.swift`, pass it:

```swift
let menuController = MenuController(
    store: store,
    inputSource: inputSource,
    coordinator: coordinator,
    appMonitor: appMonitor
)
```

- [ ] **Step 4: Verify the build and the existing suite**

Run: `rm -rf .build && make test`
Expected: PASS, 54 tests (this task adds none — `MenuController` is untested by design),
zero warnings.

Run: `make build`
Expected: `Build complete!`, zero warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/movaMem/MenuController.swift Sources/movaMem/main.swift
git commit -m "feat: per-app layout submenus and Forget This App

Each app row becomes a submenu of installed layouts with a checkmark on the
current choice, plus Forget This App. Rows are now enabled, which is what
phase 1's autoenablesItems = false was added for.

Menu items carry their target through representedObject rather than encoded in
the title, because titles use an em dash as a separator and a layout name may
contain one too.

Setting a layout applies immediately only when the edited app is frontmost.
That case needs it because no activation fires for the app already in front;
any other app is left undisturbed. MenuController now takes AppMonitoring to
answer that question rather than assuming it."
```

---

### Task 4: `Add App…`

The `NSOpenPanel` shell plus the three outcome responses.

**Files:**
- Modify: `Sources/movaMem/MenuController.swift`

**Interfaces:**
- Consumes: `AppPicker.evaluate(appBundleURL:managedBundleIDs:) -> AppPickResult`,
  `AppPicker.displayName(forBundleAt:) -> String`,
  `LayoutStore.addAppWithNoLayout(bundleID:)`, `LayoutStore.allEntries()`
- Produces: an `Add App…` menu item above the settings separator

- [ ] **Step 1: Add the menu item**

In `menuNeedsUpdate`, immediately after `addAppEntries(to: menu)` and BEFORE the separator that
precedes `Launch at Login`:

```swift
        // Grouped with the app list rather than the settings below, because it is
        // a list operation. The trailing ellipsis is the macOS convention for an
        // item that opens a dialog.
        let addItem = NSMenuItem(title: "Add App…", action: #selector(addApp), keyEquivalent: "")
        addItem.target = self
        menu.addItem(addItem)
```

Note the ellipsis is a single `…` character, not three periods.

- [ ] **Step 2: Add the action**

```swift
    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Open where most apps live, but do not lock the user in: Mail and other
        // Apple apps are under /System/Applications, so restricting to a single
        // directory would make them unreachable.
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Add"
        panel.message = "Choose an application to manage."

        let response = panel.runModal()
        if response != .OK {
            return   // cancelled: do nothing, say nothing
        }
        guard let chosenURL = panel.url else {
            return
        }

        var managedBundleIDs: Set<String> = []
        for entry in store.allEntries() {
            managedBundleIDs.insert(entry.bundleID)
        }

        let result = AppPicker.evaluate(appBundleURL: chosenURL, managedBundleIDs: managedBundleIDs)
        switch result {
        case .valid(let bundleID):
            // Added with no layout. The row shows "(not set)" until the user picks
            // one from the submenu.
            store.addAppWithNoLayout(bundleID: bundleID)
            log.debug("Added \(bundleID, privacy: .public) with no layout")

        case .alreadyManaged(let appName):
            // A silent no-op would look broken, so say so plainly.
            showInfoAlert(
                title: "Already in the List",
                message: "\(appName) is already managed by movaMem. Its layout is set from its own submenu."
            )

        case .noBundleIdentifier(let appName):
            showInfoAlert(
                title: "Cannot Manage This App",
                message: "\(appName) has no bundle identifier, and movaMem identifies applications by bundle identifier."
            )
        }
    }

    /// A single-button informational alert. Used only for the two dead ends in
    /// Add App..., where doing nothing silently would read as a bug.
    private func showInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
```

**No new import is needed.** Verified by probe: `allowedContentTypes = [.application]` compiles
and works with only `import AppKit`, which `MenuController` already has. Do not add
`import UniformTypeIdentifiers` — it is redundant here.

- [ ] **Step 3: Verify the build and the existing suite**

Run: `rm -rf .build && make test`
Expected: PASS, 54 tests, zero warnings. (Counts drifted upward during execution as fix rounds added tests; trust the actual run.)

Run: `make build`
Expected: `Build complete!`, zero warnings.

- [ ] **Step 4: Commit**

```bash
git add Sources/movaMem/MenuController.swift
git commit -m "feat: add an app from the menu via a file picker

Add App... opens an NSOpenPanel restricted to app bundles, starting at
/Applications but not locked there, since Mail and friends live under
/System/Applications. A chosen app is added with no layout and shows as
'(not set)'.

The two dead ends get an alert rather than silence: an app already in the list,
and an app with no bundle identifier. Both would otherwise look like the menu
item did nothing."
```

---

### Task 5: Build the bundle and extend the manual checklist

Phase 2's UI is unavoidably manual, as in phase 1. This task produces the runnable app and the
checklist the owner will work through.

**Files:**
- Modify: `docs/superpowers/plans/2026-08-12-manual-test-checklist.md`

**Interfaces:**
- Consumes: everything from Tasks 1-4
- Produces: a `movaMem.app` bundle and a written phase-2 checklist section

- [ ] **Step 1: Build and verify the bundle**

```bash
rm -rf .build && make test && make bundle
codesign --verify --verbose movaMem.app
/usr/libexec/PlistBuddy -c "Print :LSUIElement" movaMem.app/Contents/Info.plist
```

Expected: 54 tests pass; `Built movaMem.app`; `valid on disk` and
`satisfies its Designated Requirement`; `true`.

- [ ] **Step 2: Confirm the app launches and writes schema v2**

```bash
./movaMem.app/Contents/MacOS/movaMem &
sleep 3
kill %1
cat ~/Library/Application\ Support/movaMem/layouts.json
```

Expected: the app runs without crashing. The store file is unchanged until something is
edited — merely launching does not rewrite it, so it may still read `"version" : 1` here. That
is correct: the version bumps on the first write.

- [ ] **Step 3: Append the phase-2 section to the checklist**

Add this to `docs/superpowers/plans/2026-08-12-manual-test-checklist.md`:

```markdown
---

## Phase 2 — Manual Layout Control (owner-required)

Install and launch:

```bash
make install && open /Applications/movaMem.app
```

- [ ] **P2-1: Submenus appear with a checkmark**

  Click the icon, then hover an app row. A submenu lists every installed layout, with a
  checkmark on the one currently set for that app.

- [ ] **P2-2: Setting a layout for the FRONTMOST app applies immediately**

  With VS Code frontmost, open the menu, hover the VS Code row, and pick French. The active
  layout should change to French right away — confirm against the system input menu. The row
  should read `Code — French` next time you open the menu.

- [ ] **P2-3: Setting a layout for a DIFFERENT app does not disturb the current one**

  With VS Code frontmost and on Canadian, open the menu, hover the Telegram row, and pick
  Ukrainian. Your active layout must STAY Canadian. Then switch to Telegram: it should become
  Ukrainian.

- [ ] **P2-4: Forget This App removes the row**

  Open a row's submenu and choose `Forget This App`. The row disappears. Your current layout
  must not change.

- [ ] **P2-5: A forgotten app can be re-learned**

  After forgetting Slack, go to Slack and switch layout by hand. Slack reappears in the menu
  with that layout.

- [ ] **P2-6: Add App… adds an app that is not running**

  Quit Telegram entirely. Click `Add App…`, choose Telegram from `/Applications`. It appears in
  the menu as `Telegram — (not set)`. Pick French from its submenu, then launch Telegram — it
  should become French.

- [ ] **P2-7: Add App… reaches /System/Applications**

  Click `Add App…` and navigate to `/System/Applications`. Choose Mail. It should be added,
  proving the panel is not locked to `/Applications`.

- [ ] **P2-8: Adding an already-managed app says so**

  Click `Add App…` and choose an app already in the list. An alert appears naming the app, and
  the list does not change or gain a duplicate.

- [ ] **P2-9: `(not set)` does nothing on activation**

  Add an app via `Add App…` without choosing a layout. Switch to that app. Your layout must
  NOT change — an unset app behaves exactly like an unmanaged one.

- [ ] **P2-10: The store is schema v2 with a null**

  ```bash
  cat ~/Library/Application\ Support/movaMem/layouts.json
  ```

  Expect `"version" : 2`, and an app added but not yet assigned showing as `null`.

- [ ] **P2-11: Cancelling the picker does nothing**

  Click `Add App…`, then Cancel. No alert, no change to the list.

- [ ] **P2-12: An unavailable layout can be replaced**

  Remove a layout in System Settings that some app is set to. Its row reads `(unavailable)` and
  dimmed. Open that row's submenu and pick an installed layout — the row returns to normal.
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/plans/2026-08-12-manual-test-checklist.md
git commit -m "docs: add phase 2 manual verification checklist

Twelve owner-required checks covering submenus and checkmarks, the
frontmost/non-frontmost distinction for immediate application, Forget This App
and re-learning, Add App... for a non-running app and for /System/Applications,
the already-managed alert, unset behaving as unmanaged, schema v2 on disk,
cancelling the picker, and replacing an unavailable layout."
```

---

## Self-Review

**Spec coverage** — every spec requirement maps to a task:

| Spec requirement | Task |
|---|---|
| Submenu of installed layouts per app row | 3 |
| Checkmark on the current choice | 3 |
| `Forget This App` | 3 |
| `Add App…` via `NSOpenPanel`, app bundles only | 4 |
| Panel opens at `/Applications`, navigation unrestricted | 4 |
| New app added with no layout, shown `(not set)` | 1 (store), 3 (label), 4 (action) |
| Already-managed app: tell the user, change nothing | 2 (decision), 4 (alert) |
| No-bundle-identifier app: tell the user | 2 (decision), 4 (alert) |
| `null` on disk, schema version 2 | 1 |
| v1 file loads with no migration code | 1 |
| `layout(forBundleID:)` conflates unset and absent | 1 |
| `allEntries()` distinguishes them | 1 |
| Coordinator treats unset as unknown | 1 (verified by test, no code change) |
| Immediate apply only when the edited app is frontmost | 3 |
| Rows enabled via phase-1's `autoenablesItems = false` | 3 |
| `representedObject`, never title parsing | 3 |
| Empty state keeps `Add App…` reachable | 4 (item added outside the empty-state early return) |
| Manual checklist extension | 5 |

**Placeholder scan:** none. Every code step contains complete, runnable code; every verify step
names the command and expected result.

**Type consistency:** verified across tasks — `allEntries()` returns
`[(bundleID: String, layoutID: String?)]` in Tasks 1, 3, and 4; `addAppWithNoLayout(bundleID:)`,
`isManaged(bundleID:)`, `AppPickResult`'s three cases, `AppPicker.evaluate(appBundleURL:managedBundleIDs:)`,
and `AppPicker.displayName(forBundleAt:)` are each used with the same names and signatures
everywhere they appear.

**Known gaps, stated deliberately:**

- `MenuController` and the `NSOpenPanel`/`NSAlert` code have no unit tests, consistent with
  phase 1 and for the same reason: their bodies are AppKit calls. Task 5's checklist covers
  them.
- Test count rises from 35 to 50. Coverage stays roughly where phase 1 left it (~60-70%
  overall, logic layer near 100%) — a recorded, accepted deviation from the org's 99.9%
  standard.
- `MenuController` will end this plan around 330 lines, under the 500 cap but growing. The
  spec notes that extracting a testable menu-model layer is the natural next step if it keeps
  growing; that is deliberately not done here, to avoid refactoring working code while also
  changing the storage format.
