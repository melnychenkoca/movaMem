# movaMem Phase 2 — Manual Layout Control

**Date:** 2026-08-12
**Status:** Approved design
**Builds on:** `2026-08-12-movamem-design.md` (phase 1, shipped on `feat/phase-1`)

## Problem

Phase 1 learns layouts by observation only. An app enters the store when the user
deliberately switches layout while in it, and the menu is a read-only view of what was
learned. That leaves three things impossible:

1. Setting an app's layout without visiting the app and switching by hand
2. Removing an app from the list
3. Configuring an app at all before its first visit

Phase 2 makes the menu a complete editor: add, change, forget.

## Scope

**In scope:**

- Each app row becomes a submenu of installed layouts, with a checkmark on the current choice
- `Forget This App` removes an entry
- `Add App…` opens a file picker to add any installed app, with no layout initially
- A new "unset" state: the app is managed but has no layout to restore
- Storage schema bumps to version 2 to represent unset

**Out of scope, deliberately:**

- A persistent "don't manage this app" opt-out. It solves a problem not yet encountered
  (an app fighting movaMem) and needs a new store concept, new UI state, and new
  coordinator logic. Add it when a real case appears, informed by that case.
- Confirmation prompt on `Forget This App`. The action is recoverable — re-add via
  `Add App…`, or simply switch layouts in that app again — so a dialog is friction.
- Everything phase 1 excluded: iCloud sync, preferences window, per-window layouts,
  hotkeys, notarization.

## Behavioral Decisions

Each was decided explicitly during design.

| Decision | Choice | Reasoning |
|---|---|---|
| When a manual choice takes effect | Saved immediately; applied on next activation | Setting app X's layout must never change what the user is typing in app Y |
| Exception: the edited app is frontmost | Apply immediately | Activation is what normally triggers a restore, and no activation fires for the app already in front. Without this, the most common interaction appears to do nothing. |
| Removing an entry | `Forget This App` | Cleanup only. Recovery is re-adding, or switching layouts in that app. |
| Adding an app | File picker (`NSOpenPanel`) | The only option that reaches apps which are not running, and the honest answer to "how do I add an app back after forgetting it" |
| Layout for a newly added app | None — shown as `(not set)` | More honest than guessing the user's current layout, at the cost of a new state |
| Picking an app already in the list | Tell the user, change nothing | A silent no-op would look broken |
| Storing "unset" | JSON `null`, schema version 2 | The type system then forces every reader to handle it; an empty-string sentinel fails silently |
| Picker restrictions | App bundles only, opens at `/Applications`, navigation unrestricted | Safari and Mail live in `/System/Applications`, so locking to one directory would exclude them |

### Why `null` rather than an empty-string sentinel

Three representations were considered for "unset":

- A separate `unsetApps` list — two collections to keep in sync, every reader consults both
- `""` as a sentinel — no schema change, but a reader that forgets to check it would try to
  select a layout with an empty ID, and the failure would be a silently failed switch
- `[String: String?]` encoding as JSON `null` — the compiler will not let a reader ignore
  the unset case

The third was chosen. Phase 1 already shipped the machinery this needs: the schema version
field and the newer-version rejection in `LayoutStore.load()`. This is their first real use.

## Storage

`StoredLayouts` changes:

```swift
struct StoredLayouts: Codable {
    var version: Int          // now 2
    var apps: [String: String?]   // nil means "managed, but no layout to restore"
}
```

Written form:

```json
{
  "apps" : {
    "com.microsoft.VSCode" : "com.apple.keylayout.Canadian",
    "com.tinyspeck.slackmacgap" : null
  },
  "version" : 2
}
```

**Reading v1 files needs no migration code.** A v1 file has all-string values, which decode
into `[String: String?]` as non-nil optionals. The first write afterwards bumps the file to
version 2.

**The downgrade direction is already handled.** A phase-1 build meeting a v2 file hits the
newer-version rejection added at the end of phase 1: it quarantines the file
non-destructively and starts empty, rather than misreading it.

### API changes to `LayoutStore`

- `layout(forBundleID:) -> String?` — unchanged signature. It already returns `nil` for
  "no layout", so unset and unknown collapse to the same value, which is exactly what the
  coordinator wants.
- `allEntries()` element type becomes `(bundleID: String, layoutID: String?)`. The menu must
  distinguish unset from absent; the coordinator must not.
- New method `addAppWithNoLayout(bundleID:)` to register an app with no layout to restore.

**A conflation worth recording:** because `layout(forBundleID:)` returns `nil` for both
"unset" and "never seen", the store cannot distinguish those two through that method.
Nothing needs to today, and the coordinator actively benefits from the conflation. Anything
that later needs to tell them apart must use `allEntries()`. This is a deliberate trade, not
an oversight.

### Coordinator impact

**None.** An unset app is treated exactly as an unknown app: `layout(forBundleID:)` returns
`nil`, and the existing activation path already does nothing in that case. Unset needs no new
switching logic — only a different menu label.

## Components

### New: `AppPicker` (`Sources/movaMem/AppPicker.swift`)

Split deliberately into a testable decision and an untestable shell, for the same reason
phase 1 put the OS behind protocols: the logic worth testing must not be trapped inside an
AppKit-bound file.

**The decision (pure, tested).** Given a chosen app bundle URL and the bundle IDs already in
the store, return one of three outcomes:

```swift
enum AppPickResult {
    case valid(bundleID: String)
    case alreadyManaged(bundleID: String, appName: String)
    case noBundleIdentifier(appName: String)
}
```

Three outcomes with three different UI responses. Tests build real `.app` directories in a
temp location with hand-written `Info.plist` files — with and without `CFBundleIdentifier` —
so no mocking is involved.

**The shell (untested).** Configures `NSOpenPanel` for app bundles only, opens at
`/Applications` with navigation unrestricted, hands the chosen URL to the decision function.
Around ten lines, no branching worth testing.

Depends on Foundation and AppKit, **not** on `LayoutStore` — the caller passes in the
existing bundle IDs, keeping the decision function pure.

### Modified: `MenuController`

Gains submenu construction and three actions. Rows become enabled — which is what phase 1's
`menu.autoenablesItems = false` was added for, so that `isEnabled` is honored rather than
silently recomputed by AppKit when rows have real actions.

Menu items carry their target app and layout via `representedObject`, the standard AppKit
mechanism. **Titles must never be parsed to recover this** — a layout name containing an em
dash would break it, and row titles already use an em dash as a separator.

### Modified: `LayoutStore`

As described under Storage.

## Menu Layout

```
VS Code — Canadian          ▸    ✓ Canadian
Slack — (not set)           ▸      Ukrainian
Telegram — French          ▸      French
                                 ─────────────
Add App…                           Forget This App
Launch at Login
Hide Icon
Quit movaMem
```

**Row states:**

| State | Row text | Submenu checkmark |
|---|---|---|
| Layout set and installed | `VS Code — Canadian` | on that layout |
| Unset | `Slack — (not set)` | none |
| Layout set but uninstalled | `Telegram — French (unavailable)`, dimmed | none — that layout is absent from the picker |

Choosing any installed layout replaces an unavailable one.

**Submenu contents:** every installed layout, checkmark on the current choice, a separator,
then `Forget This App`.

**`Add App…` placement:** above the separator that precedes `Launch at Login`, grouped with
the app list, because it is a list operation rather than an app preference. The trailing
ellipsis follows the macOS convention for an item that opens a dialog.

**Empty state:** `No apps remembered yet` remains, and `Add App…` is still available, so the
menu is never a dead end.

**Rebuild cost:** the menu already rebuilds on open via `menuNeedsUpdate`. Submenus add one
`NSMenu` per app — trivial for a few dozen apps, and still zero cost while closed.

## Failure Modes

Phase 1's rule still governs: **never fight the user.** Every uncertain case does nothing.

| Failure | Behavior |
|---|---|
| Picked app has no bundle identifier | `NSAlert` naming the app; nothing added |
| Picked app already in the list | `NSAlert` naming the app; existing entry untouched |
| Chosen layout uninstalled between menu open and click | `select` fails, layout marked unavailable, entry keeps the layout ID for reinstall — same as phase 1 |
| Store unwritable when adding or forgetting | Change applies in memory so the session behaves normally; the existing `Not saving` row already warns. No dialog. |
| v2 file read by a phase-1 build | Quarantined, not misread — phase 1's version rejection |
| `NSOpenPanel` cancelled | Nothing happens, no alert |
| Forgetting the frontmost app | Entry removed; the current layout is left alone. movaMem stops managing it; nothing reverts. |

**On the two alerts:** this app has had zero modal dialogs until now, which slightly cuts
against "lightweight". Both are justified: they are genuine dead ends where silence would
read as a bug, and both are rare.

### The frontmost-app subtlety

Setting a layout for the frontmost app applies it immediately (per the decisions table). This
works because `AppMonitor.ignoredBundleIDs` already contains `com.movamem.app`, so while
movaMem's own menu holds focus, the frontmost app as the coordinator sees it is still the
user's app. That phase-1 guard is what makes immediate application correct here.

## Testing

**Tested:**

- `LayoutStore`: v1 file decodes without migration code; `null` round-trips; unset is
  distinguishable from absent via `allEntries()` but not via `layout(forBundleID:)`; a v2
  file is written after any change; existing quarantine and write-refusal behavior still
  holds
- `AppPicker` decision function: all three outcomes, against real temp `.app` bundles with
  and without `CFBundleIdentifier`
- `SwitchCoordinator`: an unset entry behaves exactly as an unknown app — nothing restored,
  nothing recorded

**Manually verified**, as in phase 1: the `NSOpenPanel` shell, submenu rendering, checkmark
placement, alert wording, and the immediate-apply-when-frontmost behavior. The phase-1 manual
checklist gains a phase-2 section.

**Coverage** stays roughly where phase 1 left it (~60-70% overall, logic layer near 100%).
The new logic is in the tested half; the new untestable code is about ten lines of panel
configuration. The org's 99.9% standard remains a recorded, accepted deviation for the same
reason as phase 1: testing AppKit wrappers would only assert that Apple's functions were
called.

## Risk

**The storage change is the riskiest part of phase 2, not the UI.** Changing the value type
from `String` to `String?` touches every reader of the store. The compiler will find the call
sites — there are few (coordinator, menu, tests) — and the downgrade direction is already
covered by phase 1's version rejection. But this is where a review should look hardest.

## Code Style

Phase 1's hard constraint carries over unchanged: the owner does not write Swift and reviews
every line personally. Explicit `if`/`for` over `map`/`filter`/`reduce`; named intermediate
variables; no force-unwraps or implicitly-unwrapped optionals; comments explain *why* in
plain English; `os_log` only; no third-party dependencies; files under 500 lines and
functions under 50.

Note that `MenuController` is currently 226 lines and will grow. If it approaches the cap,
extracting a testable menu-model layer (considered and deferred during this design) becomes
the natural next step rather than splitting arbitrarily.

## Success Criteria

1. Clicking an app row opens a submenu of installed layouts with a checkmark on the current
   choice; picking a different layout updates the store and the row.
2. Setting a layout for the frontmost app changes the active layout immediately.
3. Setting a layout for a non-frontmost app does not disturb the current layout, and applies
   on next visit to that app.
4. `Forget This App` removes the row; the app can be re-added via `Add App…` or by switching
   layouts in it.
5. `Add App…` adds any installed app, including one that is not running, as `(not set)`.
6. Adding an already-managed app shows a message and changes nothing.
7. `layouts.json` reads `"version": 2` and uses `null` for unset entries.
8. A phase-1 build meeting a v2 file quarantines it rather than misreading it.
9. Idle memory and CPU stay where phase 1 left them (`phys_footprint` under ~30 MB, 0% idle).
