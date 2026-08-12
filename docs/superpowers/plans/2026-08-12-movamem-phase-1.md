# movaMem Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu-bar app that remembers the last deliberately-chosen keyboard layout per application and restores it automatically on app activation.

**Architecture:** Two OS event sources (`NSWorkspace` activation, Carbon TIS layout change) feed one policy object (`SwitchCoordinator`) that reads and writes a JSON store. The two OS wrappers sit behind protocols so the policy layer is unit-testable against fakes with no OS involvement.

**Tech Stack:** Swift 6.3, SwiftPM (no Xcode), AppKit, Carbon/HIToolbox, ServiceManagement, os_log, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-12-movamem-design.md`

## Global Constraints

These apply to every task. A task's requirements implicitly include this section.

- **Readability over idiom — hard constraint.** The owner does not write Swift but reviews
  every change. Explicit `if`/`for` over `map`/`filter`/`reduce` chains. Named intermediate
  variables over nested one-liners. No force-unwraps, no deep optional chaining, no generics,
  no result builders, no Combine. Comments explain *why* in plain English. Where a
  Swift-specific construction is unavoidable, a comment explains what the syntax does. This
  may produce longer code than idiomatic Swift; that is the intended trade.
- **File size:** under 500 lines each. Functions under 50 lines.
- **Logging:** `os_log` only. No `print` in shipped code.
- **Platform floor:** `platforms: [.macOS(.v14)]` in `Package.swift`. Required — without it the
  `@Test` macro fails to expand.
- **Dependencies:** none. Only Apple frameworks.
- **Test command:** always `make test`, never bare `swift test` (see Task 1 for why).
- **Layout IDs on this machine** (verified by probe): `com.apple.keylayout.Canadian`,
  `com.apple.keylayout.Ukrainian-PC`, `com.apple.keylayout.French`. There is no layout named
  "English" — the Latin layout displays as "Canadian".
- **Commit after every task**, using the message given in the task's final step.
- **Coverage:** logic layer (`SwitchCoordinator`, `LayoutStore`) at ~100%. OS wrappers and
  menu are covered by the manual checklist in Task 9, not unit tests. Overall ~60–70% is the
  accepted target — this is a recorded deviation from the org's 99.9% standard, because
  testing the wrapper bodies would only assert that Apple's functions were called.

---

### Task 1: Package skeleton and working test command

Establishes the package and — more importantly — the `Makefile` that makes `swift test` work
at all. Command Line Tools ships Swift Testing but not on any default search path, so plain
`swift test` fails with `no such module 'Testing'`, and fixing only that fails again at load
time with `Library not loaded: @rpath/lib_TestingInterop.dylib`. Both paths were found by
probing; this task encodes them so no later task hits a cryptic linker error.

**Files:**
- Create: `Package.swift`
- Create: `Makefile`
- Create: `Sources/movaMem/main.swift` (stub — the filename is load-bearing, see Step 3)
- Create: `Tests/movaMemTests/SanityTests.swift`

**Interfaces:**
- Consumes: nothing (first task)
- Produces: a package named `movaMem` with an executable target `movaMem` and a test target
  `movaMemTests`; `make test` runs the suite; `make build` compiles release.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

// The macOS platform floor is REQUIRED, not optional. Without it, Swift Testing's
// @Test macro expands to code that fails with "'isolation()' is only available in
// macOS 10.15 or newer".
let package = Package(
    name: "movaMem",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "movaMem",
            path: "Sources/movaMem"
        ),
        .testTarget(
            name: "movaMemTests",
            dependencies: ["movaMem"],
            path: "Tests/movaMemTests"
        ),
    ]
)
```

- [ ] **Step 2: Write the `Makefile`**

The two `-rpath` flags and the `-F` flag are all mandatory. Verified working on macOS 26.5
with Command Line Tools 6.3 and no Xcode installed.

```makefile
# Swift Testing ships inside Command Line Tools but is not on any default search
# path. -F finds the framework at compile time; the two -rpath flags let dyld find
# the framework and its interop dylib at run time. Without all three, `swift test`
# fails either with "no such module 'Testing'" or a dyld load error.
TESTING_FW  = /Library/Developer/CommandLineTools/Library/Developer/Frameworks
TESTING_LIB = /Library/Developer/CommandLineTools/Library/Developer/usr/lib

TEST_FLAGS = -Xswiftc -F -Xswiftc $(TESTING_FW) \
             -Xlinker -rpath -Xlinker $(TESTING_FW) \
             -Xlinker -rpath -Xlinker $(TESTING_LIB)

.PHONY: test build clean

test:
	swift test $(TEST_FLAGS)

build:
	swift build -c release

clean:
	rm -rf .build movaMem.app
```

Note: `Makefile` requires real tab characters for indentation, not spaces.

- [ ] **Step 3: Create a stub entry point**

**The filename must be exactly `Sources/movaMem/main.swift`.** Swift permits top-level code
only in a file with that name. A differently-named placeholder links only while it is the
target's single source file — the moment Task 2 adds a second file, the executable product
fails to link with an undefined `_MovaMem_main` symbol, and `make test` fails for every
later task. (This was found the hard way during execution; the original plan said
`Placeholder.swift` and had to be corrected mid-flight.)

Comments only, no code — the file just has to exist under the right name:

```swift
// Temporary entry point so the executable product links while the app is being
// built up task by task. Task 7 replaces this with the real one.
//
// The FILENAME matters: Swift allows top-level code only in a file named
// exactly "main.swift". A differently-named placeholder works only while it is
// the target's single source file, so adding a second file breaks the link with
// "Undefined symbols: _MovaMem_main".
```

- [ ] **Step 4: Write the sanity test**

```swift
import Testing

@Test func packageBuildsAndTestsRun() {
    // Proves the Makefile's flags work. If this fails to *compile*, the
    // framework search path is wrong; if it fails to *load*, an rpath is wrong.
    #expect(1 + 1 == 2)
}
```

- [ ] **Step 5: Run the test**

Run: `make test`
Expected: PASS, with output containing `Test run with 1 test in 0 suites passed`.

If it fails with `no such module 'Testing'`, the `-F` path is wrong. If it fails with
`Library not loaded: @rpath/lib_TestingInterop.dylib`, the second `-rpath` is wrong.

**Every task from here on must verify with `rm -rf .build && make test`, not bare
`make test`.** A warm `.build` can mask a link failure in the executable product: during
execution, Tasks 2-4 all reported green while the product had been unlinkable since Task 2,
and the breakage only surfaced in Task 5. Incremental runs are fine while iterating, but the
run you report and commit against must start from a clean `.build`.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Makefile Sources/movaMem/main.swift Tests/movaMemTests/SanityTests.swift
git commit -m "build: package skeleton with working Swift Testing setup

Command Line Tools ships Testing.framework and lib_TestingInterop.dylib but
neither is on a default search path, so bare 'swift test' cannot work. The
Makefile encodes the framework path and both rpaths. Use 'make test' always."
```

---

### Task 2: `LayoutStore` — persistence

The JSON store. Pure Foundation, no OS event handling, fully testable against a temp
directory.

**Files:**
- Create: `Sources/movaMem/LayoutStore.swift`
- Create: `Tests/movaMemTests/LayoutStoreTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `struct StoredLayouts: Codable` with `var version: Int` and `var apps: [String: String]`
  - `final class LayoutStore` with:
    - `init(fileURL: URL)`
    - `func layout(forBundleID: String) -> String?`
    - `func setLayout(_ layoutID: String, forBundleID: String)`
    - `func remove(bundleID: String)`
    - `func allEntries() -> [(bundleID: String, layoutID: String)]` — sorted by bundleID
    - `var isWritable: Bool` — false once a write has failed; drives the menu's degraded row
  - Keys are bundle IDs, values are TIS input source IDs. Current schema version is `1`.

- [ ] **Step 1: Write the failing tests**

```swift
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
    #expect(decoded.version == 1)
    #expect(decoded.apps["com.microsoft.VSCode"] == "com.apple.keylayout.Canadian")
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: FAIL — `cannot find 'LayoutStore' in scope` and `cannot find 'StoredLayouts' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import os

/// On-disk shape of the store. Kept as a separate type so the JSON format is
/// explicit and versioned.
struct StoredLayouts: Codable {
    var version: Int
    /// Bundle ID -> TIS input source ID.
    var apps: [String: String]
}

/// Remembers which keyboard layout belongs to which application.
///
/// Loads once at construction into memory. Reads are memory-only; writes update
/// memory and then persist to disk.
final class LayoutStore {
    private let fileURL: URL
    private let log = Logger(subsystem: "com.movamem.app", category: "LayoutStore")

    private var layouts: StoredLayouts

    /// False once a disk write has failed. The menu shows a degraded-state row
    /// when this is false. The app keeps working in memory either way.
    private(set) var isWritable = true

    private static let currentSchemaVersion = 1

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.layouts = StoredLayouts(version: LayoutStore.currentSchemaVersion, apps: [:])
        load()
    }

    // MARK: - Reading

    func layout(forBundleID bundleID: String) -> String? {
        return layouts.apps[bundleID]
    }

    /// All entries, sorted by bundle ID so the menu order is stable between openings.
    func allEntries() -> [(bundleID: String, layoutID: String)] {
        var result: [(bundleID: String, layoutID: String)] = []
        let sortedKeys = layouts.apps.keys.sorted()
        for bundleID in sortedKeys {
            if let layoutID = layouts.apps[bundleID] {
                result.append((bundleID: bundleID, layoutID: layoutID))
            }
        }
        return result
    }

    // MARK: - Writing

    func setLayout(_ layoutID: String, forBundleID bundleID: String) {
        layouts.apps[bundleID] = layoutID
        save()
    }

    func remove(bundleID: String) {
        layouts.apps.removeValue(forKey: bundleID)
        save()
    }

    // MARK: - Disk

    private func load() {
        // A missing file is the normal first-run case, not an error.
        if FileManager.default.fileExists(atPath: fileURL.path) == false {
            log.debug("No store file yet; starting empty")
            return
        }

        var data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            log.error("Could not read store file: \(error.localizedDescription, privacy: .public)")
            return
        }

        do {
            let decoded = try JSONDecoder().decode(StoredLayouts.self, from: data)
            layouts = decoded
            log.debug("Loaded \(decoded.apps.count) remembered apps")
        } catch {
            // The file exists but is not valid. Move it aside rather than deleting
            // it, so a bug in this code can never destroy the user's data.
            log.error("Store file is malformed; quarantining it")
            quarantineCorruptFile()
        }
    }

    private func quarantineCorruptFile() {
        // Timestamp comes from the file system clock, formatted as a plain integer
        // so the name is filesystem-safe.
        let stamp = Int(Date().timeIntervalSince1970)
        let quarantineURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("layouts.json.corrupt-\(stamp)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: quarantineURL)
            log.error("Moved bad store to \(quarantineURL.lastPathComponent, privacy: .public)")
        } catch {
            log.error("Could not quarantine bad store: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log.error("Could not create store directory: \(error.localizedDescription, privacy: .public)")
            isWritable = false
            return
        }

        var data: Data
        do {
            let encoder = JSONEncoder()
            // Pretty-printed and key-sorted because the owner reads this file by hand.
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(layouts)
        } catch {
            log.error("Could not encode store: \(error.localizedDescription, privacy: .public)")
            isWritable = false
            return
        }

        do {
            // .atomic writes to a temp file and renames, so a crash mid-write
            // cannot leave a truncated store behind.
            try data.write(to: fileURL, options: .atomic)
            isWritable = true
        } catch {
            // Memory keeps the value, so this session still behaves correctly.
            // Nothing is surfaced to the user: the app cannot fix a full disk and
            // interrupting the user accomplishes nothing.
            log.error("Could not write store: \(error.localizedDescription, privacy: .public)")
            isWritable = false
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS, 10 tests (1 sanity + 9 store).

- [ ] **Step 5: Commit**

```bash
git add Sources/movaMem/LayoutStore.swift Tests/movaMemTests/LayoutStoreTests.swift
git commit -m "feat: add LayoutStore with atomic writes and corrupt-file quarantine

Bundle ID -> layout ID, versioned JSON, pretty-printed for hand inspection.
Malformed files are renamed aside rather than deleted. Write failures degrade
to memory-only and set isWritable = false for the menu to show."
```

---

### Task 3: Protocols and fakes

Defines the two OS boundaries and their test doubles. No real OS code yet — that is Tasks 5
and 6. Doing this first lets Task 4 (the policy layer, where all the risk lives) be written
and fully tested without touching Carbon or AppKit.

**Files:**
- Create: `Sources/movaMem/InputSourceProviding.swift`
- Create: `Sources/movaMem/AppMonitoring.swift`
- Create: `Tests/movaMemTests/Fakes.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `struct KeyboardLayout` with `let id: String` and `let name: String`
  - `protocol InputSourceProviding`:
    - `var currentLayoutID: String? { get }`
    - `func availableLayouts() -> [KeyboardLayout]`
    - `func select(layoutID: String) -> Bool` — returns false if selection failed
    - `var onLayoutChanged: (() -> Void)? { get set }`
  - `protocol AppMonitoring`:
    - `var frontmostBundleID: String? { get }`
    - `var onAppActivated: ((String) -> Void)? { get set }`
  - `FakeInputSource` and `FakeAppMonitor` in the test target, each able to simulate events.

- [ ] **Step 1: Write `InputSourceProviding.swift`**

```swift
/// One selectable keyboard layout.
struct KeyboardLayout {
    /// TIS input source ID, e.g. "com.apple.keylayout.Ukrainian-PC".
    let id: String
    /// Localized display name, e.g. "Ukrainian".
    let name: String
}

/// Everything the app needs from the keyboard-layout system.
///
/// This protocol exists so SwitchCoordinator can be tested without Carbon. The
/// real implementation is InputSourceService (Task 5).
protocol InputSourceProviding: AnyObject {
    /// The layout active right now, or nil if it cannot be determined.
    var currentLayoutID: String? { get }

    /// Layouts the user can actually switch to.
    func availableLayouts() -> [KeyboardLayout]

    /// Switches to the given layout. Returns false if it failed, which happens
    /// when a remembered layout has since been uninstalled.
    func select(layoutID: String) -> Bool

    /// Called after the active layout changes, for any reason — including changes
    /// this app caused itself.
    var onLayoutChanged: (() -> Void)? { get set }
}
```

- [ ] **Step 2: Write `AppMonitoring.swift`**

```swift
/// Everything the app needs from the window system.
///
/// This protocol exists so SwitchCoordinator can be tested without AppKit. The
/// real implementation is AppMonitor (Task 6).
protocol AppMonitoring: AnyObject {
    /// Bundle ID of the frontmost app right now, or nil if unknown.
    var frontmostBundleID: String? { get }

    /// Called when an app has become frontmost AND stayed frontmost long enough
    /// to count as a real switch. Transient focus (Spotlight, notification
    /// banners) is filtered out before this fires. The value is a bundle ID.
    var onAppActivated: ((String) -> Void)? { get set }
}
```

- [ ] **Step 3: Write the fakes**

```swift
import Foundation
@testable import movaMem

/// Test double for the keyboard-layout system.
final class FakeInputSource: InputSourceProviding {
    var currentLayoutID: String?
    var onLayoutChanged: (() -> Void)?

    /// Layout IDs that select() will accept. Anything else fails, which is how
    /// an uninstalled layout is simulated.
    var installedLayoutIDs: [String] = []

    /// Every layout ID passed to select(), in order. Tests assert on this to
    /// prove a switch did or did not happen.
    var selectCalls: [String] = []

    init(current: String? = nil, installed: [String] = []) {
        self.currentLayoutID = current
        self.installedLayoutIDs = installed
    }

    func availableLayouts() -> [KeyboardLayout] {
        var result: [KeyboardLayout] = []
        for id in installedLayoutIDs {
            result.append(KeyboardLayout(id: id, name: id))
        }
        return result
    }

    func select(layoutID: String) -> Bool {
        selectCalls.append(layoutID)
        if installedLayoutIDs.contains(layoutID) == false {
            return false   // simulates a layout the user has uninstalled
        }
        currentLayoutID = layoutID
        return true
    }

    // MARK: - Simulation helpers

    /// Simulates the OS notification firing. Does NOT change currentLayoutID —
    /// callers set that first, mirroring the real API where the current layout is
    /// already updated by the time the notification arrives.
    func fireLayoutChangedNotification() {
        onLayoutChanged?()
    }

    /// Simulates the user switching layout by hand: sets the new value and fires.
    func simulateUserSwitch(to layoutID: String) {
        currentLayoutID = layoutID
        onLayoutChanged?()
    }
}

/// Test double for the window system.
final class FakeAppMonitor: AppMonitoring {
    var frontmostBundleID: String?
    var onAppActivated: ((String) -> Void)?

    init(frontmost: String? = nil) {
        self.frontmostBundleID = frontmost
    }

    /// Simulates an app activation that already passed the dwell filter.
    func simulateActivation(of bundleID: String) {
        frontmostBundleID = bundleID
        onAppActivated?(bundleID)
    }
}
```

- [ ] **Step 4: Verify it compiles**

Run: `make test`
Expected: PASS, still 10 tests. The fakes are unused so far; this step only proves the
protocols and fakes compile and conform.

- [ ] **Step 5: Commit**

```bash
git add Sources/movaMem/InputSourceProviding.swift Sources/movaMem/AppMonitoring.swift Tests/movaMemTests/Fakes.swift
git commit -m "feat: add OS boundary protocols and test fakes

InputSourceProviding and AppMonitoring wrap Carbon and NSWorkspace so the
policy layer can be tested without either. Fakes can simulate app activation,
user layout switches, duplicate notifications, and uninstalled layouts."
```

---

### Task 4: `SwitchCoordinator` — the policy layer

The heart of the app, and the only place the behavioral rules live. Every decision from the
spec is a branch here.

**The suppression mechanism is the critical part.** It stores *which layout this app itself
selected* rather than a boolean flag. Probing the real Carbon API showed a boolean is unsafe:
selecting the already-active layout fires **zero** notifications (a flag would stick up
forever and the app would silently stop learning), and one `select` sometimes delivers **two**
notifications (a flag would drop on the first, and the second would be recorded as a user
change — the app learning from its own switch). Both failures are intermittent, so a flag
would work most of the time and corrupt saved layouts occasionally.

**Files:**
- Create: `Sources/movaMem/SwitchCoordinator.swift`
- Create: `Tests/movaMemTests/SwitchCoordinatorTests.swift`

**Interfaces:**
- Consumes: `InputSourceProviding`, `AppMonitoring` (Task 3), `LayoutStore` (Task 2)
- Produces: `final class SwitchCoordinator` with
  - `init(inputSource: InputSourceProviding, appMonitor: AppMonitoring, store: LayoutStore)`
  - `func start()` — installs the two callbacks
  - `var unavailableLayoutIDs: Set<String>` — layouts whose `select` failed; the menu marks
    these as unavailable

- [ ] **Step 1: Write the failing tests**

```swift
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

@Test func layoutChangeWithNoFrontmostAppIsIgnored() {
    let input = FakeInputSource(current: canadian, installed: [canadian, french])
    let monitor = FakeAppMonitor(frontmost: nil)
    let store = makeTempStore()

    let coordinator = SwitchCoordinator(inputSource: input, appMonitor: monitor, store: store)
    coordinator.start()

    input.simulateUserSwitch(to: french)
    #expect(store.allEntries().isEmpty)
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: FAIL — `cannot find 'SwitchCoordinator' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import os

/// Decides when to restore a remembered layout and when to record a new one.
///
/// This is the only place the app's behavioral rules live. It performs no OS calls
/// of its own — everything arrives through the two protocols — which is what makes
/// it fully testable.
final class SwitchCoordinator {
    private let inputSource: InputSourceProviding
    private let appMonitor: AppMonitoring
    private let store: LayoutStore
    private let log = Logger(subsystem: "com.movamem.app", category: "SwitchCoordinator")

    /// The layout ID this app most recently asked the OS to select, or nil.
    ///
    /// This is the suppression mechanism, and it is deliberately NOT a boolean.
    /// Measured Carbon behavior on macOS 26.5:
    ///   - selecting the already-active layout fires ZERO notifications, so a
    ///     boolean flag would stay raised forever and the app would stop learning;
    ///   - one select sometimes delivers TWO notifications, so a boolean would
    ///     clear on the first and record the second as a user change — the app
    ///     learning from its own switch.
    /// Comparing against the layout ID is immune to both: every duplicate matches
    /// and is ignored, and a stale value is simply overwritten by the next real
    /// change. No timer is needed.
    private var layoutWeSelected: String?

    /// Remembered layouts that are no longer installed. The menu dims these.
    private(set) var unavailableLayoutIDs: Set<String> = []

    init(inputSource: InputSourceProviding, appMonitor: AppMonitoring, store: LayoutStore) {
        self.inputSource = inputSource
        self.appMonitor = appMonitor
        self.store = store
    }

    /// Installs the event callbacks. Nothing happens until this is called.
    func start() {
        // [weak self] prevents a retain cycle: these closures are stored on the
        // objects this class holds, so a strong reference would keep both alive
        // forever.
        appMonitor.onAppActivated = { [weak self] bundleID in
            self?.handleAppActivated(bundleID: bundleID)
        }
        inputSource.onLayoutChanged = { [weak self] in
            self?.handleLayoutChanged()
        }
        log.debug("Coordinator started")
    }

    // MARK: - App activated

    private func handleAppActivated(bundleID: String) {
        guard let wantedLayout = store.layout(forBundleID: bundleID) else {
            // First time seeing this app. Do nothing: entries should only ever
            // reflect a deliberate choice by the user.
            log.debug("No remembered layout for \(bundleID, privacy: .public)")
            return
        }

        if wantedLayout == inputSource.currentLayoutID {
            // Already correct. Selecting anyway would fire no notification and
            // leave stale suppression state behind.
            log.debug("Layout already correct for \(bundleID, privacy: .public)")
            return
        }

        log.debug("Restoring \(wantedLayout, privacy: .public) for \(bundleID, privacy: .public)")

        // Record what we are about to do BEFORE doing it: the notification can
        // arrive synchronously inside select().
        layoutWeSelected = wantedLayout

        let didSelect = inputSource.select(layoutID: wantedLayout)
        if didSelect {
            unavailableLayoutIDs.remove(wantedLayout)
        } else {
            // The layout was uninstalled. Keep the entry — it becomes valid again
            // on reinstall — but mark it so the menu can explain itself.
            log.error("Could not select \(wantedLayout, privacy: .public); marking unavailable")
            unavailableLayoutIDs.insert(wantedLayout)
            layoutWeSelected = nil
        }
    }

    // MARK: - Layout changed

    private func handleLayoutChanged() {
        guard let newLayout = inputSource.currentLayoutID else {
            log.error("Layout changed but current layout is unknown")
            return
        }

        if newLayout == layoutWeSelected {
            // This app caused this change. Ignore it, and keep the stored value
            // so any duplicate notification is ignored too.
            log.debug("Ignoring our own switch to \(newLayout, privacy: .public)")
            return
        }

        // A real user change supersedes any stale suppression state.
        layoutWeSelected = nil

        guard let bundleID = appMonitor.frontmostBundleID else {
            log.debug("Layout changed with no frontmost app; not recording")
            return
        }

        log.debug("Recording \(newLayout, privacy: .public) for \(bundleID, privacy: .public)")
        store.setLayout(newLayout, forBundleID: bundleID)
        unavailableLayoutIDs.remove(newLayout)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS, 20 tests (1 sanity + 9 store + 10 coordinator).

- [ ] **Step 5: Commit**

```bash
git add Sources/movaMem/SwitchCoordinator.swift Tests/movaMemTests/SwitchCoordinatorTests.swift
git commit -m "feat: add SwitchCoordinator with layout-identity suppression

Restores remembered layouts on activation, records only user-initiated changes.
Suppression stores the layout ID we selected rather than a boolean, which is
immune to the two Carbon behaviors measured by probe: coalesced notifications
on redundant select, and duplicate notifications for one select. Includes a
regression test for each."
```

---

### Task 5: `InputSourceService` — real Carbon implementation

The only file that touches Carbon. The API shapes here are all verified by probe, including
the `Unmanaged` pointer handling, which is the fiddliest part of the whole project.

**Files:**
- Create: `Sources/movaMem/InputSourceService.swift`

**Interfaces:**
- Consumes: `InputSourceProviding`, `KeyboardLayout` (Task 3)
- Produces: `final class InputSourceService: InputSourceProviding` with `init()` and `deinit`
  that removes the notification observer.

- [ ] **Step 1: Write the implementation**

No unit tests for this file — its body is Carbon calls, and asserting that Apple's functions
were called would verify nothing. It is covered by the manual checklist in Task 9.

```swift
import Carbon
import Foundation
import os

/// The only code in the app that talks to Carbon's Text Input Sources API.
///
/// Carbon is old but not deprecated, and Apple has never shipped a replacement
/// for keyboard-layout switching. Reading and setting the layout needs no
/// permissions of any kind — verified on macOS 26.5.
final class InputSourceService: InputSourceProviding {
    private let log = Logger(subsystem: "com.movamem.app", category: "InputSourceService")
    var onLayoutChanged: (() -> Void)?

    init() {
        // The OS broadcasts this whenever the layout changes, for any reason —
        // Cmd+Space, Caps Lock, the system input menu, or our own select() call.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(layoutDidChange),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )
        log.debug("Listening for input source changes")
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// @objc is required because this is called by the notification system, which
    /// is Objective-C and needs a runtime-visible selector.
    @objc private func layoutDidChange() {
        onLayoutChanged?()
    }

    // MARK: - Reading

    var currentLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            log.error("Could not read current input source")
            return nil
        }
        return InputSourceService.readStringProperty(source, kTISPropertyInputSourceID)
    }

    func availableLayouts() -> [KeyboardLayout] {
        // Ask only for keyboard layouts; the unfiltered list also contains input
        // modes and palettes the user cannot select.
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String
        ] as CFDictionary

        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue()
            as? [TISInputSource] else {
            log.error("Could not list input sources")
            return []
        }

        var layouts: [KeyboardLayout] = []
        for source in list {
            // Skip anything the user cannot actually switch to. On some setups
            // this filters nothing; on others it removes several entries.
            if InputSourceService.readBoolProperty(source, kTISPropertyInputSourceIsSelectCapable) == false {
                continue
            }
            guard let id = InputSourceService.readStringProperty(source, kTISPropertyInputSourceID) else {
                continue
            }
            let name = InputSourceService.readStringProperty(source, kTISPropertyLocalizedName) ?? id
            layouts.append(KeyboardLayout(id: id, name: name))
        }
        return layouts
    }

    // MARK: - Writing

    func select(layoutID: String) -> Bool {
        var wanted: TISInputSource?
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String
        ] as CFDictionary

        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue()
            as? [TISInputSource] else {
            return false
        }
        for source in list {
            if InputSourceService.readStringProperty(source, kTISPropertyInputSourceID) == layoutID {
                wanted = source
                break
            }
        }

        guard let target = wanted else {
            // Normal when a remembered layout has been uninstalled.
            log.error("Layout \(layoutID, privacy: .public) is not installed")
            return false
        }

        let status = TISSelectInputSource(target)
        if status != noErr {
            log.error("TISSelectInputSource failed with status \(status)")
            return false
        }
        return true
    }

    // MARK: - Carbon property helpers
    //
    // Carbon returns properties as raw pointers. Unmanaged<>.fromOpaque() wraps a
    // raw pointer, and takeUnretainedValue() reads it WITHOUT taking ownership —
    // correct here because TISGetInputSourceProperty does not transfer ownership.
    // (By contrast the TISCopy*/TISCreate* calls above return owned objects, hence
    // takeRetainedValue there.) Getting this wrong causes crashes or leaks.

    private static func readStringProperty(
        _ source: TISInputSource,
        _ key: CFString
    ) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func readBoolProperty(
        _ source: TISInputSource,
        _ key: CFString
    ) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `make test`
Expected: PASS, still 20 tests. This proves the Carbon API usage compiles; behavior is
verified in Task 9.

- [ ] **Step 3: Commit**

```bash
git add Sources/movaMem/InputSourceService.swift
git commit -m "feat: add InputSourceService wrapping Carbon TIS

Lists selectable keyboard layouts, reads and sets the current one, and publishes
change notifications. Requires no permissions. Unmanaged pointer handling follows
Carbon's ownership rules: takeRetainedValue for Copy/Create, takeUnretainedValue
for Get."
```

---

### Task 6: `AppMonitor` — real NSWorkspace implementation with dwell filter

The only file that touches `NSWorkspace`. Unlike Task 5 this one has real logic — the 300ms
dwell filter — so that part is unit-tested with an injected clock rather than by sleeping.

**Files:**
- Create: `Sources/movaMem/AppMonitor.swift`
- Create: `Tests/movaMemTests/AppMonitorTests.swift`

**Interfaces:**
- Consumes: `AppMonitoring` (Task 3)
- Produces: `final class AppMonitor: AppMonitoring` with
  - `init(dwellSeconds: Double = 0.3, scheduler: @escaping (Double, @escaping @Sendable () -> Void) -> Void = AppMonitor.defaultScheduler)`
  - `static let defaultScheduler` — schedules on the main queue
  - `static let ignoredBundleIDs: Set<String>`
  - `func handleActivation(bundleID: String)` — internal entry point, called by the real
    notification and directly by tests

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import movaMem

/// A scheduler that runs nothing until the test says so, letting dwell behavior
/// be tested without any real waiting.
private final class ManualScheduler {
    private var pending: [(delay: Double, work: () -> Void)] = []

    func schedule(after delay: Double, work: @escaping () -> Void) {
        pending.append((delay: delay, work: work))
    }

    /// Runs every scheduled block, simulating enough time passing.
    func fireAll() {
        let toRun = pending
        pending = []
        for item in toRun {
            item.work()
        }
    }

    var pendingCount: Int { return pending.count }
}

@Test func activationIsReportedAfterDwellPeriod() {
    let scheduler = ManualScheduler()
    let monitor = AppMonitor(dwellSeconds: 0.3) { delay, work in
        scheduler.schedule(after: delay, work: work)
    }

    var reported: [String] = []
    monitor.onAppActivated = { bundleID in reported.append(bundleID) }

    monitor.handleActivation(bundleID: "com.microsoft.VSCode")
    #expect(reported.isEmpty)   // nothing yet — still inside the dwell window

    scheduler.fireAll()
    #expect(reported == ["com.microsoft.VSCode"])
}

@Test func transientFocusIsNotReported() {
    let scheduler = ManualScheduler()
    let monitor = AppMonitor(dwellSeconds: 0.3) { delay, work in
        scheduler.schedule(after: delay, work: work)
    }

    var reported: [String] = []
    monitor.onAppActivated = { bundleID in reported.append(bundleID) }

    // Spotlight steals focus, then the user lands on VS Code before the dwell
    // period elapses. Only VS Code should be reported.
    monitor.handleActivation(bundleID: "com.apple.Spotlight")
    monitor.handleActivation(bundleID: "com.microsoft.VSCode")
    scheduler.fireAll()

    #expect(reported == ["com.microsoft.VSCode"])
}

@Test func ignoredBundleIDsAreNeverReported() {
    let scheduler = ManualScheduler()
    let monitor = AppMonitor(dwellSeconds: 0.3) { delay, work in
        scheduler.schedule(after: delay, work: work)
    }

    var reported: [String] = []
    monitor.onAppActivated = { bundleID in reported.append(bundleID) }

    monitor.handleActivation(bundleID: "com.apple.Spotlight")
    scheduler.fireAll()

    #expect(reported.isEmpty)
    // Ignored apps should not even be scheduled.
    #expect(scheduler.pendingCount == 0)
}

@Test func rapidSwitchingReportsOnlyTheSettledApp() {
    let scheduler = ManualScheduler()
    let monitor = AppMonitor(dwellSeconds: 0.3) { delay, work in
        scheduler.schedule(after: delay, work: work)
    }

    var reported: [String] = []
    monitor.onAppActivated = { bundleID in reported.append(bundleID) }

    monitor.handleActivation(bundleID: "com.tinyspeck.slackmacgap")
    monitor.handleActivation(bundleID: "ru.keepcoder.Telegram")
    monitor.handleActivation(bundleID: "com.microsoft.VSCode")
    scheduler.fireAll()

    #expect(reported == ["com.microsoft.VSCode"])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: FAIL — `cannot find 'AppMonitor' in scope`.

- [ ] **Step 3: Write the implementation**

**Concurrency annotations are required and were found the hard way during execution.** Under
Swift 6.3 with tools-version 6.0, strict concurrency checking is on by default and the
obvious version of this code does not compile. Verified in an isolated package:

- Closure types without `@Sendable` → hard error: `static property 'defaultScheduler' is not
  concurrency-safe because non-'Sendable' type ... may have shared mutable state`.
- `@Sendable` closures but a plain class → hard error: `capture of 'self' with non-Sendable
  type 'AppMonitor?' in a '@Sendable' closure`.
- `MainActor.assumeIsolated` to dodge the capture → same error, and it adds a call that
  *crashes* if ever reached off the main thread. Strictly worse.
- `@MainActor` on the class (the compiler's own suggestion) → forces the synchronous test
  calls to become async, which would require rewriting the tests in Step 1.

So both `@Sendable` on the closure types and `@unchecked Sendable` on the class are forced.
`@unchecked Sendable` silences the checker rather than satisfying it, so the class comment
must say plainly that safety rests on a main-thread-only convention the compiler will not
enforce. The real guarantee: one piece of mutable state (`pendingBundleID`),
`defaultScheduler` dispatches to `DispatchQueue.main`, and
`NSWorkspace.didActivateApplicationNotification` is delivered on the main thread.

**This conclusion is specific to `AppMonitor`, not a project-wide rule.** `@unchecked
Sendable` is the fallback only where `@MainActor` is genuinely unavailable — here, because
`AppMonitor` has synchronous test calls that `@MainActor` would force to become async.
**Prefer `@MainActor` wherever no test constrains the type** (see Task 7's `MenuController`,
where it is the correct choice): the compiler then verifies main-thread safety instead of
being told to trust an unenforced convention. During execution the controller initially
over-generalized this into "never use `@MainActor`", which left three avoidable warnings in
`MenuController` until it was corrected.

```swift
import AppKit
import Foundation
import os

/// Watches which application is frontmost, filtering out focus that does not
/// represent a real user switch.
///
/// Marked @unchecked Sendable because this type is used only from the main
/// thread, and that is enforced by convention rather than by the type system.
/// @MainActor would be the checked alternative but forces the synchronous test
/// calls to become async.
final class AppMonitor: AppMonitoring, @unchecked Sendable {
    private let log = Logger(subsystem: "com.movamem.app", category: "AppMonitor")
    var onAppActivated: ((String) -> Void)?

    /// How long an app must stay frontmost to count as a real switch.
    ///
    /// 300ms is long enough to filter Spotlight, notification banners, and
    /// permission dialogs, and short enough to be imperceptible: it delays only
    /// the layout switch, and no meaningful typing happens in the first 300ms
    /// after activating an app.
    private let dwellSeconds: Double

    /// Injected so tests can control time instead of sleeping.
    private let scheduler: (Double, @escaping @Sendable () -> Void) -> Void

    /// Apps that take focus without representing a user switch.
    static let ignoredBundleIDs: Set<String> = [
        "com.apple.Spotlight",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "com.movamem.app",
    ]

    /// The app we are currently waiting on. If another activation arrives first,
    /// this changes and the earlier pending check does nothing.
    ///
    /// Dedup is by bundle-ID identity, not by pending-check generation: if the
    /// user leaves an app and returns to it inside one dwell window (A -> B -> A),
    /// both A checks match and the activation is reported twice. Harmless,
    /// because SwitchCoordinator ignores an activation whose layout is already
    /// current — but it is real behavior, so a test pins it.
    private var pendingBundleID: String?

    static let defaultScheduler: @Sendable (Double, @escaping @Sendable () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    init(
        dwellSeconds: Double = 0.3,
        scheduler: @escaping (Double, @escaping @Sendable () -> Void) -> Void = AppMonitor.defaultScheduler
    ) {
        self.dwellSeconds = dwellSeconds
        self.scheduler = scheduler
    }

    /// Begins watching. Nothing is reported until this is called.
    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        log.debug("Watching for app activations")
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    var frontmostBundleID: String? {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// @objc is required: the notification system is Objective-C and needs a
    /// runtime-visible selector.
    @objc private func appDidActivate(_ notification: Notification) {
        let userInfo = notification.userInfo
        guard let app = userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        guard let bundleID = app.bundleIdentifier else {
            // Some processes have no bundle ID. Nothing to remember them by.
            return
        }
        handleActivation(bundleID: bundleID)
    }

    /// Applies the ignore list and the dwell filter. Called by the notification
    /// above, and directly by tests.
    func handleActivation(bundleID: String) {
        if AppMonitor.ignoredBundleIDs.contains(bundleID) {
            log.debug("Ignoring \(bundleID, privacy: .public)")
            return
        }

        pendingBundleID = bundleID

        scheduler(dwellSeconds) { [weak self] in
            guard let self = self else { return }
            // If another app activated in the meantime, this check is stale and
            // must do nothing. This is what prevents flicker during fast switching.
            if self.pendingBundleID != bundleID {
                return
            }
            self.log.debug("Activated: \(bundleID, privacy: .public)")
            self.onAppActivated?(bundleID)
        }
    }
}
```

Note: the real dwell check should also confirm the app is *still* frontmost, but comparing
`pendingBundleID` is sufficient and keeps the logic testable without mocking `NSWorkspace`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS, 29 tests (1 sanity + 9 store + 14 coordinator + 5 monitor). Counts here assume Task 4 and Task 6 each gained tests during their fix rounds; trust the actual output over this number.

- [ ] **Step 5: Commit**

```bash
git add Sources/movaMem/AppMonitor.swift Tests/movaMemTests/AppMonitorTests.swift
git commit -m "feat: add AppMonitor with 300ms dwell filter and ignore list

Filters transient focus (Spotlight, notification banners) so saved layouts are
never polluted by apps that briefly steal focus. The scheduler is injected so
dwell behavior is tested in milliseconds rather than by sleeping."
```

---

### Task 7: Menu bar UI and app entry point

Builds the status item, the menu, the hide/show behavior, and launch-at-login. Also replaces
the placeholder file with the real `main.swift`.

**Files:**
- Create: `Sources/movaMem/MenuController.swift`
- Create: `Sources/movaMem/main.swift`
- Overwrite: `Sources/movaMem/main.swift` (replaces the Task 1 stub — do NOT delete the file,
  the executable product needs a file with this exact name to link)

**Interfaces:**
- Consumes: `LayoutStore` (Task 2), `InputSourceProviding` (Task 3), `SwitchCoordinator`
  (Task 4), `InputSourceService` (Task 5), `AppMonitor` (Task 6)
- Produces: `final class MenuController: NSObject` with
  `init(store:inputSource:coordinator:)` and `func install()`

- [ ] **Step 1: Write `MenuController.swift`**

No unit tests — this builds AppKit objects, and asserting they were constructed verifies
nothing. Covered by the manual checklist in Task 9.

```swift
import AppKit
import Foundation
import ServiceManagement
import os

/// The status bar icon and its menu.
/// @MainActor because everything here touches AppKit, which is main-thread-only.
/// Unlike AppMonitor — which must use @unchecked Sendable because @MainActor would
/// force its synchronous test calls to become async — MenuController is referenced
/// by no test, so the checked annotation is available and is the better choice: the
/// compiler verifies main-thread safety instead of being asked to trust a convention.
/// Without this, Swift 6 emits warnings on button.image, NSApplication.shared, and
/// terminate().
@MainActor
final class MenuController: NSObject {
    private let log = Logger(subsystem: "com.movamem.app", category: "MenuController")
    private let store: LayoutStore
    private let inputSource: InputSourceProviding
    private let coordinator: SwitchCoordinator

    private var statusItem: NSStatusItem?

    /// Persisted in UserDefaults rather than layouts.json: this is a UI preference,
    /// not app-layout data, and mixing them would clutter a file the owner reads.
    private static let hiddenKey = "statusIconHidden"

    init(store: LayoutStore, inputSource: InputSourceProviding, coordinator: SwitchCoordinator) {
        self.store = store
        self.inputSource = inputSource
        self.coordinator = coordinator
        super.init()
    }

    /// Shows the icon unless the user hid it. Launching the app always clears the
    /// hidden flag, which is the documented way to get the icon back.
    func install() {
        let wasHidden = UserDefaults.standard.bool(forKey: MenuController.hiddenKey)
        if wasHidden {
            log.debug("Icon was hidden; showing it again because the app was launched")
            UserDefaults.standard.set(false, forKey: MenuController.hiddenKey)
        }
        showIcon()
    }

    private func showIcon() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // A static glyph, deliberately: a live layout code would be confused with
        // the system's own input menu.
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "keyboard",
                accessibilityDescription: "movaMem"
            )
        }

        let menu = NSMenu()
        // AppKit's autoenablesItems defaults to true, which recomputes enabled
        // state at display time and IGNORES any isEnabled we set by hand. Turning
        // it off is what makes the explicit `isEnabled = false` calls below
        // actually load-bearing. Without this the read-only rows look correct only
        // because they have no action — and they would silently become clickable
        // in phase 2, when those rows gain real submenus.
        menu.autoenablesItems = false
        // Rebuild the app list each time the menu opens, so there is zero cost
        // while it is closed.
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    // MARK: - Menu actions

    @objc private func hideIcon() {
        UserDefaults.standard.set(true, forKey: MenuController.hiddenKey)
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        // The app keeps remembering and switching layouts while hidden.
        log.debug("Icon hidden; relaunch the app to bring it back")
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            log.error("Could not change launch-at-login: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Menu building

extension MenuController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if store.isWritable == false {
            let warning = NSMenuItem(
                title: "Not saving — check Console for details",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            menu.addItem(warning)
            menu.addItem(NSMenuItem.separator())
        }

        addAppEntries(to: menu)

        menu.addItem(NSMenuItem.separator())

        let loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.target = self
        if SMAppService.mainApp.status == .enabled {
            loginItem.state = .on
        } else {
            loginItem.state = .off
        }
        menu.addItem(loginItem)

        let hideItem = NSMenuItem(title: "Hide Icon", action: #selector(hideIcon), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        let quitItem = NSMenuItem(title: "Quit movaMem", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
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
        var layoutNames: [String: String] = [:]
        for layout in inputSource.availableLayouts() {
            layoutNames[layout.id] = layout.name
        }

        for entry in entries {
            let appName = displayName(forBundleID: entry.bundleID)
            let layoutName = layoutNames[entry.layoutID] ?? entry.layoutID

            // A layout counts as unavailable for either of two reasons, and both
            // checks are needed.
            //
            // The first is the launch-independent one: if the layout is missing
            // from layoutNames, it is not installed on this Mac right now, which
            // we know every time the menu opens. Relying only on the coordinator's
            // set would leave a removed layout looking normal after a relaunch
            // until the user happened to visit that app again, because that set
            // lives in memory and starts empty.
            //
            // The second still carries information the first does not: a layout
            // that IS installed but whose selection actually failed this session.
            let layoutIsNotInstalled = (layoutNames[entry.layoutID] == nil)
            let selectFailedThisSession = coordinator.unavailableLayoutIDs.contains(entry.layoutID)
            let isUnavailable = layoutIsNotInstalled || selectFailedThisSession

            var title = "\(appName) — \(layoutName)"
            if isUnavailable {
                title = "\(appName) — \(layoutName) (unavailable)"
            }

            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            // Read-only in phase 1. Phase 2 turns each of these into a submenu of
            // available layouts.
            item.isEnabled = false
            if isUnavailable {
                item.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.foregroundColor: NSColor.disabledControlTextColor]
                )
            }
            menu.addItem(item)
        }
    }

    /// Human-readable app name, falling back to the bundle ID when the app is no
    /// longer installed — so the row stays identifiable rather than going blank.
    private func displayName(forBundleID bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        let bundle = Bundle(url: url)
        let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        if let name = displayName {
            return name
        }
        let bundleName = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        if let name = bundleName {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
```

- [ ] **Step 2: Write `main.swift`**

```swift
import AppKit
import Foundation

/// Wires the pieces together and starts the app. Deliberately contains no logic:
/// everything testable lives in the components this file constructs.
///
/// This file has no unit tests. A wiring mistake here is caught by the manual
/// smoke test in Task 9, because a composition-only file cannot be meaningfully
/// unit tested.

private func storeFileURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
    let supportDirectory = base.first ?? URL(fileURLWithPath: NSHomeDirectory())
    return supportDirectory
        .appendingPathComponent("movaMem")
        .appendingPathComponent("layouts.json")
}

let store = LayoutStore(fileURL: storeFileURL())
let inputSource = InputSourceService()
let appMonitor = AppMonitor()

let coordinator = SwitchCoordinator(
    inputSource: inputSource,
    appMonitor: appMonitor,
    store: store
)
coordinator.start()
appMonitor.start()

let application = NSApplication.shared
// .accessory means no Dock icon and no windows — a menu-bar-only app. This
// pairs with LSUIElement in Info.plist (Task 8).
application.setActivationPolicy(.accessory)

let menuController = MenuController(
    store: store,
    inputSource: inputSource,
    coordinator: coordinator
)
menuController.install()

application.run()
```

- [ ] **Step 3: Confirm the stub is fully replaced**

Step 2 overwrites `Sources/movaMem/main.swift` in place. There is nothing to delete — the
file must keep this exact name or the executable product stops linking. Just confirm no stub
comments survive:

```bash
grep -c "Temporary entry point" Sources/movaMem/main.swift   # expect 0
```

- [ ] **Step 4: Verify it builds and tests still pass**

Run: `make test && make build`
Expected: PASS, 29 tests, then `Build complete!` with zero warnings.

- [ ] **Step 5: Commit**

```bash
git add -A Sources/movaMem
git commit -m "feat: add status bar menu and app entry point

Static keyboard glyph, read-only app list rebuilt on menu open, launch-at-login
toggle, and hide-icon that persists until the next launch. main.swift is pure
composition with no logic."
```

---

### Task 8: App bundle and installation

Turns the bare executable into a `.app`. Without a bundle macOS gives the process a Dock
icon, no stable identity, and no reliable launch-at-login.

**Files:**
- Modify: `Makefile` (add `bundle`, `install`, `sign-setup` targets)
- Create: `Resources/Info.plist`

**Interfaces:**
- Consumes: the `movaMem` executable from `make build`
- Produces: `movaMem.app` in the project root; `make install` copies it to `/Applications`.

- [ ] **Step 1: Write `Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>movaMem</string>
    <key>CFBundleDisplayName</key>
    <string>movaMem</string>
    <key>CFBundleIdentifier</key>
    <string>com.movamem.app</string>
    <key>CFBundleExecutable</key>
    <string>movaMem</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- LSUIElement is what makes this a menu-bar-only app: no Dock icon, no
         window, no app switcher entry. Without it the app appears in the Dock. -->
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 2: Add bundling targets to the `Makefile`**

Append to the existing `Makefile`. Remember: real tabs, not spaces.

```makefile
APP_NAME   = movaMem
APP_BUNDLE = $(APP_NAME).app
BINARY     = .build/release/$(APP_NAME)

.PHONY: bundle install sign-setup

# Assembles the .app directory structure by hand, which is what Xcode would
# otherwise do for us.
bundle: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BINARY) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@# Sign with the local certificate if it exists, otherwise ad-hoc sign.
	@# Ad-hoc works fine but its identity changes every build.
	@if security find-certificate -c "movaMem Local" >/dev/null 2>&1; then \
		echo "Signing with movaMem Local certificate"; \
		codesign --force --sign "movaMem Local" $(APP_BUNDLE); \
	else \
		echo "No local certificate found; ad-hoc signing"; \
		codesign --force --sign - $(APP_BUNDLE); \
	fi
	@echo "Built $(APP_BUNDLE)"

install: bundle
	rm -rf /Applications/$(APP_BUNDLE)
	cp -R $(APP_BUNDLE) /Applications/
	@echo "Installed to /Applications/$(APP_BUNDLE)"

# One-time setup for a stable code signature. Not required — ad-hoc signing works
# — but a stable identity keeps Gatekeeper quiet across rebuilds.
sign-setup:
	@echo "Create a self-signed certificate named exactly: movaMem Local"
	@echo ""
	@echo "  1. Open Keychain Access"
	@echo "  2. Menu: Keychain Access > Certificate Assistant > Create a Certificate..."
	@echo "  3. Name: movaMem Local"
	@echo "  4. Identity Type: Self Signed Root"
	@echo "  5. Certificate Type: Code Signing"
	@echo "  6. Create, then re-run 'make bundle'"
```

- [ ] **Step 3: Build the bundle**

Run: `make bundle`
Expected: `Built movaMem.app`, with a line about ad-hoc signing (the certificate does not
exist yet, which is fine).

- [ ] **Step 4: Verify the bundle is well-formed**

Run:
```bash
codesign --verify --verbose movaMem.app && \
  /usr/libexec/PlistBuddy -c "Print :LSUIElement" movaMem.app/Contents/Info.plist
```
Expected: `valid on disk`, `satisfies its Designated Requirement`, then `true`.

- [ ] **Step 5: Commit**

```bash
git add Makefile Resources/Info.plist
git commit -m "build: assemble and sign the .app bundle

LSUIElement makes it menu-bar-only with no Dock icon. Signs with a 'movaMem
Local' certificate when present, ad-hoc otherwise; 'make sign-setup' prints the
one-time steps for a stable identity."
```

---

### Task 9: Manual verification

The parts unit tests cannot reach: real Carbon behavior, real AppKit menus, and the wiring in
`main.swift`. Every item is a real action with an expected observable result.

**Files:**
- Create: `docs/superpowers/plans/2026-08-12-manual-test-checklist.md`

**Interfaces:**
- Consumes: `/Applications/movaMem.app` from Task 8
- Produces: a completed checklist; any failure becomes a bug to fix before phase 1 is done.

- [ ] **Step 1: Install and launch**

```bash
make install && open /Applications/movaMem.app
```
Expected: a keyboard glyph appears at the right of the menu bar. **No Dock icon appears** —
if one does, `LSUIElement` is not being read.

- [ ] **Step 2: Verify the empty state**

Click the icon.
Expected: a dimmed, unclickable `No apps remembered yet`, then a separator, then
`Launch at Login`, `Hide Icon`, `Quit movaMem`.

- [ ] **Step 3: Teach it three apps**

The core scenario. Layout names on this machine are Canadian, Ukrainian, French.

1. Open VS Code, switch to Canadian
2. Open Slack, switch to Ukrainian
3. Open Telegram, switch to French

Click the icon.
Expected: three rows — `Code — Canadian`, `Slack — Ukrainian`, `Telegram — French`, sorted
by bundle ID.

- [ ] **Step 4: Verify automatic restoration**

Switch: VS Code → Slack → Telegram → VS Code, pausing about a second in each.

Expected: the layout changes on its own to match each app. Confirm against the system input
menu in the menu bar. **This is the app's whole purpose** — if it fails, stop and debug before
continuing.

- [ ] **Step 5: Verify transient focus is ignored**

With Slack frontmost (Ukrainian), press ⌘Space to open Spotlight, type a letter, press Escape.

Expected: the layout is still Ukrainian, and the menu shows no new entry for Spotlight.

- [ ] **Step 6: Verify every switching method is detected**

In VS Code, change the layout three different ways: ⌘Space (or your configured shortcut),
Caps Lock if configured, and the system input menu.

Expected: each is recorded. Verify by switching away and back — the last layout chosen should
be restored. This confirms the notification approach catches what an event tap would miss.

- [ ] **Step 7: Inspect the store on disk**

```bash
cat ~/Library/Application\ Support/movaMem/layouts.json
```
Expected: pretty-printed JSON, `"version": 1`, and an `apps` object with three bundle IDs
mapped to layout IDs.

- [ ] **Step 8: Verify corrupt-file recovery**

```bash
echo "garbage" > ~/Library/Application\ Support/movaMem/layouts.json
killall movaMem; open /Applications/movaMem.app; sleep 2
ls ~/Library/Application\ Support/movaMem/
```
Expected: the app launches normally, the menu shows `No apps remembered yet`, and a
`layouts.json.corrupt-<timestamp>` file exists. The bad file must be **renamed, not deleted**.

- [ ] **Step 9: Verify hide and restore**

Click the icon, choose `Hide Icon`.
Expected: the icon disappears.

Then switch between two known apps.
Expected: layouts still switch — the app works while hidden.

Then `open /Applications/movaMem.app`.
Expected: the icon returns.

- [ ] **Step 10: Verify launch at login**

Click the icon, enable `Launch at Login`. Confirm it appears in System Settings > General >
Login Items. Reboot.
Expected: the icon is present after login without launching anything by hand.

- [ ] **Step 11: Check resource usage**

Measure `phys_footprint`, not RSS. RSS counts shared AppKit framework pages that every Mac
app maps and which are not attributable to movaMem — it reads ~52 MB and is misleading.
`phys_footprint` is what Activity Monitor reports as "Memory" and measured 19 MB during
execution.

```bash
PID="$(pgrep -x movaMem)"
footprint -p "$PID" | tail -5          # phys_footprint: expect under ~30 MB
ps -o pcpu= -p "$PID"                  # expect at or near 0.0 while idle
```
Expected: `phys_footprint` under ~30 MB, and CPU at or near 0.0 while idle.

- [ ] **Step 12: Verify uninstalled-layout handling**

Remove one layout (say French) in System Settings > Keyboard > Input Sources, then activate
the app that remembered it.

Expected: the layout does not change, the app does not crash, and the menu row reads
`Telegram — com.apple.keylayout.French (unavailable)`, dimmed. Re-add the layout and confirm
the row returns to normal.

**Then repeat WITHOUT activating the app first**, because that is the case this step
originally missed. Remove the layout, quit movaMem, relaunch it, and open the menu before
touching Telegram at all. The row must still read `(unavailable)` and be dimmed. An earlier
implementation keyed dimming solely off in-memory state populated during activation, so the
row appeared completely normal after a relaunch — and this step passed anyway because it
activated the app first.

- [ ] **Step 13: Record results and commit**

Write the checklist file with each item and its result. Note any failures as follow-up bugs.

```bash
git add docs/superpowers/plans/2026-08-12-manual-test-checklist.md
git commit -m "docs: add manual verification checklist with results

Covers the paths unit tests cannot reach: real Carbon switching, every layout
change method, AppKit menu behavior, hide/restore, launch at login, resource
usage, and main.swift wiring."
```

---

## Self-Review

**Spec coverage** — every spec section maps to a task:

| Spec section | Task |
|---|---|
| Swift + SwiftPM, no Xcode | 1 |
| Swift Testing flags, platform floor | 1 |
| JSON store, atomic writes, quarantine, schema version | 2 |
| `isWritable` degraded state | 2, surfaced in 7 |
| Protocol boundaries for testability | 3 |
| Bundle-ID identity | 2, 4 |
| First encounter does nothing | 4 |
| Record only user-initiated changes | 4 |
| Layout-identity suppression + both probe findings | 4 |
| Uninstalled layout keeps entry, marked unavailable | 4, displayed in 7 |
| Carbon TIS wrapper, selectable-only filter | 5 |
| 300ms dwell filter, ignore list | 6 |
| Static icon | 7 |
| Read-only app list, exact row text | 7 |
| Hide persists, relaunch restores | 7, verified in 9 |
| Launch at login | 7, verified in 9 |
| `LSUIElement`, bundle, signing | 8 |
| Manual checklist | 9 |
| Resource targets | 9 |

**Placeholder scan:** no TBDs. Every code step contains complete, runnable code. Every test
step names the command and the expected result.

**Type consistency:** verified across tasks — `layout(forBundleID:)`, `setLayout(_:forBundleID:)`,
`allEntries()`, `isWritable`, `currentLayoutID`, `availableLayouts()`, `select(layoutID:)`,
`onLayoutChanged`, `frontmostBundleID`, `onAppActivated`, `unavailableLayoutIDs`,
`handleActivation(bundleID:)` are each used with the same name and signature everywhere they
appear.

**Known gaps, stated deliberately:**

- `InputSourceService`, `MenuController`, and `main.swift` have no unit tests, for the reason
  in the Global Constraints. Task 9 covers them.
- Overall coverage lands at ~60–70%, not the org's 99.9%. Recorded as an accepted deviation.
- Task 6's dwell check compares `pendingBundleID` rather than re-querying `NSWorkspace`. This
  keeps the logic testable; the difference is not observable in practice.
