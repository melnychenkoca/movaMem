# movaMem — Per-Application Keyboard Layout Memory

**Date:** 2026-08-12
**Status:** Approved design

## Problem

macOS has one global keyboard layout. Working across apps in different languages means
switching the layout by hand every time focus changes — English in VS Code, Ukrainian in
Slack, French in Telegram, over and over.

movaMem remembers the last layout you deliberately chose in each application and restores
it automatically when you return to that application.

## Scope

**Phase 1 (this spec):**

- Remember the last deliberately-chosen keyboard layout per application
- Restore it automatically on app activation
- Status bar menu listing remembered apps and their layouts (read-only)
- Hide/show the status bar icon, persistent across launches
- Launch at login

**Phase 2 — now designed in `2026-08-12-movamem-phase-2-design.md`:**

- Manually set the layout for an app from the menu
- Delete entries from the menu
- Add an app that has never been visited (`Add App…`), and an "unset" state for it, which
  bumps the store schema to version 2

**Explicitly out of scope:** iCloud sync, preferences window, per-window or per-URL
layouts, hotkey-driven switching, onboarding, distribution/notarization.

## Platform and Toolchain

- **Language:** Swift 6.3, targeting macOS 26
- **Build:** Swift Package Manager plus a `Makefile` that assembles the `.app` bundle.
  Full Xcode is not installed and is not required.
- **Dependencies:** none. AppKit, Foundation, Carbon/HIToolbox, ServiceManagement, os_log.

### Language choice

The app needs three OS capabilities, all of which are Objective-C/C APIs in Apple
frameworks with no cross-platform abstraction:

1. Frontmost-app detection — `NSWorkspace.didActivateApplicationNotification`
2. Read/set input source — `TISCopyCurrentKeyboardInputSource` / `TISSelectInputSource`
3. Status bar item — `NSStatusItem`

Swift accesses all three directly with no bridge. Alternatives were considered and
rejected: Python/PyObjC (40–80 MB bundle, 60–120 MB RAM, 0.5–2 s cold start — wrong shape
for a daemon reacting to every app switch), Electron (~150 MB, 200–400 MB RAM, and no
Carbon TIS access without a native addon anyway), Go (cgo shims for every menu callback),
Rust (viable and equally fast, but `unsafe` Obj-C messaging throughout for no gain).
Swift: ~1–2 MB binary, ~15–25 MB RAM, instant start.

### Carbon dependency

`TISSelectInputSource` and `kTISNotifySelectedKeyboardInputSourceChanged` are Carbon-era C
APIs. They are not deprecated and are what every app in this category uses, but Apple has
never shipped a modern replacement. This dependency is unavoidable — any approach that
sets the input source needs it.

## Code Style Constraint

The owner does not write Swift but reviews every change personally. Code must therefore be
legible to someone who does not know the language's idioms. This is a hard constraint on
implementation, not a preference:

- Explicit `if` and `for` loops over chained `map`/`filter`/`reduce` pipelines
- Named intermediate variables over nested one-liners
- No force-unwraps, no deep optional chaining, minimal `guard let` chaining
- No generics, result builders, protocol extensions with default implementations, or Combine
- Comments explain *why*, in plain English — especially where Carbon or AppKit behavior is
  non-obvious
- Where a Swift-specific construction is unavoidable, a short comment explains what the
  syntax does, not just why it is there

Consequence: this may produce slightly longer code than idiomatic Swift would. That is the
intended trade — reviewability is worth more here than concision, since unreviewable code
would cost the owner the ability to verify what the app does.

The protocol boundaries in the architecture are the one deliberate exception. They exist so
the logic layer is testable, and they are simple protocols (a few method signatures), not
generic or extension-heavy ones.

## Behavioral Decisions

Each of these was decided explicitly during design.

| Decision | Choice | Reasoning |
|---|---|---|
| When to record | Only user-initiated layout changes | Recording on every switch-away lets transient-focus apps pollute the store |
| App identity | Bundle identifier | Stable across app renames, moves, and updates; path and name are not |
| First encounter with an app | Do nothing | Keeps the store meaningful — every entry is a real choice, which matters for phase 2's manual list |
| Storage | JSON file, human-readable | Inspectable and hand-editable; the owner does not write Swift, so a readable file is the debugging path |
| History depth | Last layout only | No consumer for history; phase 2's override replaces the value outright |
| Change detection | Distributed notification | No permissions at all, catches every switch method, adds no input-path latency |
| Status bar icon | Static glyph | A dynamic layout code would be confused with the system input menu |
| Hiding the icon | Persists; relaunch restores | Standard macOS pattern, and the recovery path is the most obvious available action |

### Why notification-based detection, not an event tap

A `CGEventTap` alternative was rejected: it requires Accessibility permission (giving the
app a keylogger's permission profile for no reason), must hardcode which shortcuts mean
"switch layout" — missing the system input menu, Caps Lock switching, and custom bindings —
and adds a callback on the input path.

The distributed notification requires **no permissions**, catches strictly more cases, and
costs nothing when idle. Its one subtlety is that it carries no "who caused this"
information, which the suppression flag below resolves.

### The 300ms dwell threshold

Apps that briefly steal focus (Spotlight, notification banners, permission dialogs) must
not be treated as real activations, or saved layouts slowly rot. An activation is only
reported if the app is still frontmost 300ms later.

300ms is long enough to filter transients and short enough to be imperceptible: it delays
only the *switch*, and no meaningful typing happens in the first 300ms after activating an
app. It will be a named constant.

An ignore-list provides a second guard for known offenders (Spotlight, Notification
Center, movaMem's own menu).

## Architecture

Two event sources, one decision-maker, one store.

```
NSWorkspace ──"VS Code activated"──┐
                                   ├──► SwitchCoordinator ──► LayoutStore (layouts.json)
Carbon TIS ──"layout → Ukrainian"──┘           │
                                               └──────────► InputSourceService (select)
```

**On app activation:** `AppMonitor` detects the frontmost-app change and starts a 300ms
timer. If the app is still frontmost when it fires and is not ignore-listed, the activation
is reported. `SwitchCoordinator` looks up the bundle ID; if a saved layout exists and
differs from the current one, it records that layout ID as "ours" and calls
`InputSourceService.select`. Unknown app, or saved layout already active: nothing happens.

**On layout change:** Carbon fires the notification. `SwitchCoordinator` reads the current
layout; if it matches the layout it just selected itself, the change is ignored. Otherwise
it was user-initiated, so it records `(frontmost bundle ID → new layout)` and persists.

### Suppression by layout identity (not a boolean flag)

**This section was revised after probing the real Carbon API.** An earlier version of this
design used a boolean flag raised before our `select` call and lowered when the resulting
notification arrived. Probing showed that design is broken.

Measured behavior of `TISSelectInputSource` on macOS 26.5:

1. Our own `select` **does** fire the notification — so suppression is genuinely required.
2. `TISCopyCurrentKeyboardInputSource` is updated **synchronously**, before the notification.
3. Selecting the already-active layout fires **zero** notifications (macOS coalesces it).
4. A single `select` sometimes delivers **two** notifications, both reporting the same
   final layout.

Findings 3 and 4 each break a boolean flag. Coalescing leaves it stuck up forever, so the
app silently stops learning. Duplicate delivery lowers it on the first notification, then
the second arrives with the flag down and is recorded as a *user* change — the app learns
from its own switch, which is the exact failure this design exists to prevent. Both are
intermittent and timing-dependent, so a flag would work most of the time and corrupt saved
layouts occasionally.

**The design used instead:** store the layout ID we ourselves selected, rather than a
boolean.

- Before calling `select`, set `layoutWeSelected = <target id>`.
- On notification, read the current layout. If it equals `layoutWeSelected`, ignore it —
  that change was ours, however many notifications arrive.
- Otherwise clear `layoutWeSelected` and record the change as user-initiated.

This is naturally immune to both failure modes: duplicates all match the stored ID and are
all ignored, and a coalesced notification that never arrives leaves a stale ID that the next
genuine change simply overwrites. **No timer and no safety timeout are needed**, which
removes the timing-dependent component of the original design.

Verified end-to-end against the real API: restore ignored, redundant select harmless,
genuine user change recorded exactly once.

### Threading

Everything on the main thread. Both notifications arrive there, the store is a few KB, and
JSON writes are sub-millisecond. No queues, no locks. The atomic file write is synchronous
and fast enough not to matter at this size.

## Components

Six files. The first two wrap the OS behind protocols so the coordinator is testable
against fakes.

### `InputSourceService`

The only code that touches Carbon.

- Lists selectable keyboard layouts (id + display name), reads the current one, selects one
  by id, publishes layout-change events.
- Filters TIS's raw list to selectable keyboard layouts only — the raw list includes
  non-selectable and non-keyboard entries that would clutter phase 2's picker.
- Behind a protocol. Depends on: Carbon/HIToolbox.

### `AppMonitor`

The only code that touches `NSWorkspace`.

- Publishes "app with bundle ID X became frontmost," already filtered by the 300ms dwell
  check and the ignore-list, so nothing downstream sees transient focus.
- Exposes "who is frontmost now," needed when a layout change arrives.
- Injected clock so dwell logic is testable without sleeping.
- Behind a protocol. Depends on: `NSWorkspace`.

### `LayoutStore`

Owns `~/Library/Application Support/movaMem/layouts.json`.

- `layout(for:)`, `setLayout(_:for:)`, `remove(for:)`, and all-entries for the menu.
- Loads once at launch into an in-memory dictionary. Reads hit memory; writes update memory
  and persist.
- **Atomic writes** — write new file, then rename — so a crash mid-write cannot truncate the
  store.
- Malformed or unreadable file → start empty, and **rename the bad file aside** to
  `layouts.json.corrupt-<timestamp>` rather than deleting it, so a bug cannot silently
  destroy data.
- Stores a **schema version** from day one. One line now; without it any future format
  change has to guess what it is reading.
- Depends on: Foundation. Fully testable against a temp directory.

### `SwitchCoordinator`

The policy layer — the only place the rules live.

- Consumes both event streams, owns the `layoutWeSelected` suppression state, decides what
  to restore and what to record.
- Every behavioral decision in this spec is a branch here, which is why it is isolated and
  injected with fakes.
- Depends on: the two protocols plus `LayoutStore`. No OS calls, no AppKit import.

### `MenuController`

The status bar item and its menu.

- Builds `NSStatusItem` and `NSMenu`; owns and persists the hidden flag; owns the
  launch-at-login toggle.
- Rebuilds the app list when the menu opens rather than keeping it live — zero cost while
  closed.
- Depends on: AppKit, `LayoutStore`, `InputSourceService`, `SMAppService`.

### `main.swift`

Constructs the five components, wires them, starts the run loop. No logic. Deliberately
untested — covered by the manual smoke test, since a composition-only file cannot be
meaningfully unit tested.

### Menu contents (phase 1)

- Remembered apps with their layouts (app name, layout name) — **read-only**
- Separator
- Launch at Login (toggle)
- Hide Icon
- Quit

App names are resolved from bundle IDs for display. If an app has been uninstalled and the
name cannot be resolved, the entry shows the bundle ID so it remains identifiable and
removable in phase 2, rather than rendering as a blank row.

Entry text is fixed to avoid guesswork during implementation:

- Normal: `VS Code — English`
- Layout no longer installed: `Slack — Ukrainian (unavailable)`, shown dimmed
- App name unresolvable: `com.tinyspeck.slackmacgap — Ukrainian`
- Empty store: a single dimmed, non-clickable `No apps remembered yet`
- Storage unwritable: a dimmed `Not saving — check Console for details` above the separator

Phase 2 turns each app entry into a submenu of available layouts. That machinery is not
built now, but `LayoutStore` and `InputSourceService` already expose what it needs, so the
change is additive.

## Failure Modes

Guiding rule: **the app must never fight the user.** A switcher that switches wrongly is
worse than one that does nothing, so every uncertain case does nothing.

| Failure | Behavior |
|---|---|
| Saved layout uninstalled | `select` fails; leave layout alone, keep the entry, mark it unavailable in the menu. Auto-removal would silently erase a preference that becomes valid again on reinstall. |
| App uninstalled | Keep the entry — costs bytes, correct again on reinstall. Phase 2 allows manual deletion. No automatic pruning. |
| `layouts.json` corrupt | Start empty, quarantine the file with a timestamped rename, relearn as the user works. |
| Directory not writable | Run in-memory for the session; menu indicates the degraded state. Switching still works, which is the part the user notices. |
| Write fails (disk full) | Memory keeps the value so the session behaves normally; not persisted. Logged, no dialog — the app cannot fix it and interrupting accomplishes nothing. |
| Coalesced notification (redundant select fires none) | Stale `layoutWeSelected` is simply overwritten by the next genuine change. No timer needed. |
| Duplicate notifications for one select | All duplicates match `layoutWeSelected` and are all ignored. |
| Two apps activate within 300ms | Pending timer cancelled and replaced; only the settled app is restored. No flicker. |

**Deliberately not error-handled:** unknown apps and already-correct layouts. Both are the
normal path, not errors — they do nothing and log nothing, or the log becomes noise.

### Logging

`os_log` — free when nobody is reading, inspectable in Console.app when something is wrong.
No log files to grow, no `print`. Decisions at debug level, problems at error level. This
is the primary "why did it do that" window for an owner who does not read Swift.

## Testing

### `SwitchCoordinator` — target ~100% coverage

Tested against fake `InputSourceService` and fake `AppMonitor`: pure function calls, no OS
involvement, no waiting.

- Known app, saved layout differs → selects saved layout
- Known app, layout already matches → **no** select call (a redundant select would cause a
  notification storm)
- Unknown app → nothing restored, nothing recorded
- Layout change matching `layoutWeSelected` → not recorded
- Layout change differing from `layoutWeSelected` → recorded against frontmost app
- **Two notifications for one select** → ignored both times, nothing recorded (the duplicate
  delivery observed in probing)
- **Coalesced select leaves stale `layoutWeSelected`** → next genuine user change is still
  recorded correctly
- Two rapid activations → only the settled app is restored

The two probe-derived tests are the most valuable in the suite: both failures are
intermittent and timing-dependent, so they would otherwise ship and corrupt saved layouts
occasionally rather than failing visibly.

### `LayoutStore` — target ~100% coverage

Against a temp directory: round-trip, missing file, malformed JSON, corrupt-file
quarantine, atomic write survives simulated mid-write failure, schema version preserved.

### `AppMonitor` — dwell logic tested

Injected clock, so the transient-focus rule is verified in milliseconds rather than by
hand.

### OS wrappers and menu — manual checklist

`InputSourceService`'s Carbon calls and `MenuController`'s AppKit construction are verified
manually:

- List layouts; select each installed layout
- Notification fires on every switch method: ⌘Space, Caps Lock, system input menu
- Ignore-list filters Spotlight and notification banners
- Hide icon, relaunch, icon returns
- Launch at login registers and survives reboot

### Smoke test

After each build: launch, switch between three apps with different layouts, confirm correct
restoration, quit. Unit tests cannot catch a wiring mistake in `main.swift`.

### Framework

Swift Testing, not XCTest. The org standard names Vitest/Jest, which are JavaScript; Swift
Testing is this platform's equivalent.

**Verified working without Xcode, but it needs two non-default flags.** Command Line Tools
ships `Testing.framework` and `lib_TestingInterop.dylib`, but neither is on a default search
path, and `XCTest.framework` is absent entirely (so XCTest is not an option here). Plain
`swift test` fails with `no such module 'Testing'`; adding only the framework path then fails
at load with `Library not loaded: @rpath/lib_TestingInterop.dylib`.

The working invocation, wrapped as `make test` so it is never typed by hand:

```
FW  = /Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB = /Library/Developer/CommandLineTools/Library/Developer/usr/lib

swift test -Xswiftc -F -Xswiftc $(FW) \
           -Xlinker -rpath -Xlinker $(FW) \
           -Xlinker -rpath -Xlinker $(LIB)
```

`Package.swift` must also declare `platforms: [.macOS(.v14)]` or newer. Without a platform
floor, the `@Test` macro expansion fails with `'isolation()' is only available in macOS 10.15
or newer`.

### Coverage exception — deliberate deviation from org standard

The org standard is ≥99.9% unit coverage. **This project will reach roughly 60–70% overall
line coverage**, with the logic layer (`SwitchCoordinator`, `LayoutStore`) near 100%.

`InputSourceService` and `AppMonitor` are thin wrappers over Carbon and `NSWorkspace`;
`MenuController` constructs AppKit objects. Unit-testing their bodies would assert that
Apple's functions were called, which verifies nothing real. Those layers are covered by the
manual checklist instead.

This is recorded as an accepted exception, not an oversight. The part of the codebase
holding every decision in this spec is at ~100%.

## Build and Packaging

SwiftPM package: one executable target (`movaMem`), one test target, no third-party
dependencies.

`swift build` produces a bare Unix executable, but a menu-bar app needs a `.app` bundle —
without one macOS gives it a Dock icon, no proper identity, and no reliable launch-at-login.
A `Makefile` assembles it:

1. `swift build -c release`
2. Create the `movaMem.app` structure
3. Copy the binary in
4. Write `Info.plist`, including **`LSUIElement = true`** — this is what makes it menu-bar
   only, with no Dock icon and no window
5. Sign with the local certificate
6. Copy to `/Applications`

Targets: `make` (build + bundle), `make install`, `make test`.

### Signing

One-time setup creates a self-signed certificate in the login keychain; every build signs
with the same identity, keeping the identity stable across rebuilds and Gatekeeper quiet.
This matters less than it would under the event-tap approach — notification-based detection
needs no permissions, so there is no grant to lose — but a consistent identity is still
worth the one-time cost. The setup command will be documented.

### Launch at login

`SMAppService` — the app registers itself; the toggle lives in the menu. Included in phase 1
because a layout-memory app that is not running silently does nothing, which is the worst
failure mode.

### Distribution

None. Built and installed locally. No notarization, no DMG, no updater. Sharing it later
would require a paid Apple Developer account for notarization — out of scope.

## Success Criteria

1. Type in VS Code, Slack, and Telegram with three different layouts; switching between them
   restores the right layout each time, with no manual switching after the first choice in
   each app.

   The owner's installed layouts, confirmed by probing: `com.apple.keylayout.Canadian`
   (displays as "Canadian", the Latin/English-typing layout) and
   `com.apple.keylayout.Ukrainian-PC`. Note there is no layout named "English" on this
   machine — the menu will correctly show "Canadian".

   Examples elsewhere in these documents use French as a third layout. It is a standard macOS
   layout but is not enabled on this machine yet; add it in System Settings → Keyboard → Input
   Sources to run the three-app scenarios, or substitute any third layout you prefer.
2. Spotlight, notification banners, and permission dialogs never alter a saved layout.
3. The app never switches the layout while the user is typing.
4. Status bar menu lists remembered apps with their current layouts.
5. Hiding the icon persists across launches; relaunching restores it.
6. Idle memory under ~30 MB, measured as `phys_footprint` (what Activity Monitor reports as
   "Memory"); no measurable CPU while idle.

   Measured after Task 8: **`phys_footprint` 19 MB, CPU 0.0% idle**. Note that `ps`-reported
   RSS reads ~52 MB for this app and is the wrong metric — it counts shared AppKit framework
   pages that every Mac app maps and that are not attributable to movaMem.
7. Survives reboot and starts automatically.
