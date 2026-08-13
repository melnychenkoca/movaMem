# movaMem Phase 1 — Manual Verification Checklist

**Date:** 2026-08-12
**Build:** `movaMem.app`, ad-hoc signed, from branch `feat/phase-1`
**Automated suite:** 29 tests passing from a clean `.build`, zero build warnings

This checklist covers what unit tests cannot reach: real Carbon layout switching, real AppKit
menus, and the wiring in `main.swift`.

Steps are split into two groups. The **automated** group was driven programmatically against
the real `movaMem.app` bundle and the results are recorded below. The **owner-required** group
needs GUI interaction — clicking menu items, switching between real apps, rebooting — and is
left unchecked for the owner to run.

---

## Automated — verified against the real bundle

- [x] **Bundle is well-formed**

  `codesign --verify --verbose movaMem.app` → `valid on disk`,
  `satisfies its Designated Requirement`.
  `CFBundleIdentifier` = `com.movamem.app` (matches `AppMonitor.ignoredBundleIDs`, so the app
  ignores its own menu taking focus).
  `LSUIElement` = `true`, as an XML boolean rather than the string `"true"`.

- [x] **App launches and stays running**

  Launched from the bundle, survived 8 seconds, no crash.

- [x] **Resource usage is within target**

  `phys_footprint` **19 MB** (target: under ~30 MB). CPU **0.0%** while idle.

  Note: `ps`-reported RSS reads ~52 MB for this app and is the wrong metric — it counts
  shared AppKit framework pages that every Mac app maps and that are not attributable to
  movaMem. `phys_footprint` is what Activity Monitor reports as "Memory".

- [x] **First encounter records nothing** (Step 2 / empty-state precondition)

  Launched with no store present. No `~/Library/Application Support/movaMem/` directory was
  created. Confirms an app enters the store only after a deliberate layout choice, rather than
  on mere activation.

- [x] **Corrupt store file is quarantined, not deleted** (Step 8)

  Wrote `garbage not json` to `layouts.json`, relaunched. The app **did not crash**, and the
  bad file was renamed to `layouts.json.corrupt-1786559611`. Renamed, never deleted — a
  parsing bug must not destroy saved layouts.

- [x] **Layout changes are detected and persisted** (core of Steps 3-4 and 6)

  With movaMem running, an external process switched the active layout through every installed
  layout via `TISSelectInputSource`. movaMem detected each change and wrote the result:

  ```json
  {
    "apps" : {
      "com.apple.loginwindow" : "com.apple.keylayout.Canadian"
    },
    "version" : 1
  }
  ```

  This proves the whole pipeline end to end: the distributed notification fires, the
  coordinator attributes the change to the frontmost bundle ID, and `LayoutStore` persists it
  with schema version 1, pretty-printed for hand inspection. The bundle ID is
  `com.apple.loginwindow` because the driver ran from a shell with no frontmost GUI app —
  correct attribution, not a bug. The store was cleared afterward.

- [x] **Installed layouts on this machine**

  `com.apple.keylayout.Canadian` (displays as "Canadian" — this is the Latin/English-typing
  layout; there is no layout named "English" on this machine) and
  `com.apple.keylayout.Ukrainian-PC`.

  **The steps below use French as a third layout, which is not enabled yet.** Add it once in
  System Settings → Keyboard → Input Sources before working through them — the three-app
  scenarios need three distinct layouts to be meaningful. Any third layout works if you would
  rather pick another; substitute its name throughout.

---

## Owner-required — needs GUI interaction

Install first:

```bash
make install && open /Applications/movaMem.app
```

- [ ] **Step 1: No Dock icon**

  An `mM` glyph in a rounded border appears at the right of the menu bar. **No Dock icon
  appears.** If one does, `LSUIElement` is not being read.

- [ ] **Step 2: Empty state**

  Click the icon. Expect a dimmed, unclickable `No apps remembered yet`, then a separator,
  then `Launch at Login`, `Hide Icon`, a separator, a dimmed `movaMem <version>`, and `Quit`.

  The version must match `CFBundleShortVersionString` in the bundle's `Info.plist`. It is read
  at runtime, so a mismatch means the wrong bundle is running — worth checking after an upgrade.

- [ ] **Step 3: Teach it three apps**

  1. Open VS Code, switch to Canadian
  2. Open Slack, switch to Ukrainian
  3. Open Telegram, switch to French

  Click the icon. Expect three rows — `Code — Canadian`, `Slack — Ukrainian`,
  `Telegram — French` — sorted by bundle ID.

- [ ] **Step 4: Automatic restoration — the app's whole purpose**

  Switch VS Code → Slack → Telegram → VS Code, pausing about a second in each.

  Expect the layout to change on its own to match each app. Confirm against the system input
  menu. **If this fails, stop and report it** — everything else is secondary.

- [ ] **Step 5: Transient focus is ignored**

  With Slack frontmost (Ukrainian), press ⌘Space to open Spotlight, type a letter, press
  Escape. Expect the layout to still be Ukrainian, and no new menu entry for Spotlight.

- [ ] **Step 6: Every switching method is detected**

  In VS Code, change the layout three ways: your ⌘Space-style shortcut, Caps Lock if
  configured, and the system input menu. Each should be recorded — verify by switching away
  and back, and confirming the last layout chosen is restored. This is what an event-tap
  implementation would have missed.

- [ ] **Step 7: Inspect the store**

  ```bash
  cat ~/Library/Application\ Support/movaMem/layouts.json
  ```

  Expect pretty-printed JSON, `"version": 1`, and three bundle IDs mapped to layout IDs.

- [ ] **Step 9: Hide and restore**

  Click the icon → `Hide Icon`. The icon disappears.
  Then switch between two known apps: **layouts should still switch** — the app works while
  hidden.
  Then `open /Applications/movaMem.app`. The icon returns.

- [ ] **Step 10: Launch at login**

  Click the icon, enable `Launch at Login`. Confirm it appears in System Settings → General →
  Login Items. Reboot. Expect the icon present after login without launching anything by hand.

- [ ] **Step 12: Uninstalled layout handling — two parts**

  **12a, with activation:** Remove the French layout in System Settings → Keyboard → Input
  Sources, then activate Telegram. Expect the layout not to change, no crash, and the menu row
  to read `Telegram — com.apple.keylayout.French (unavailable)`, dimmed. Re-add the layout and
  confirm the row returns to normal.

  **12b, WITHOUT activation — this is the case that caught a real bug.** Remove the layout,
  quit movaMem, relaunch it, and open the menu **before touching Telegram at all**. The row
  must still read `(unavailable)` and be dimmed.

  An earlier implementation keyed dimming solely off in-memory state populated during
  activation, so after a relaunch the row looked completely normal. Step 12a passed anyway
  because it activates the app first, which is exactly why 12b exists.

---

## Phase 2 — Manual Layout Control

Phase 2 turns the read-only list into a full editor: pick a layout per app, forget an app, and
add an app you have never visited.

### Automated — verified against the real bundle

- [x] **Bundle still well-formed after phase 2**

  `codesign --verify` → `valid on disk`, `satisfies its Designated Requirement`.
  `LSUIElement` = `true`. `CFBundleIdentifier` = `com.movamem.app`.

- [x] **App launches and idles cheaply**

  Runs from the bundle, `phys_footprint` 20 MB, 0% CPU idle. (Phase 1 measured 19 MB, so the
  new menu code added roughly 1 MB.)

- [x] **An unset entry does not crash the app and is not rewritten**

  Seeded the store with `{"com.apple.loginwindow": null, "version": 2}`, launched, and confirmed
  the app survived and left the file byte-identical. An unset app is treated exactly like an
  unknown one.

- [x] **A version-1 store upgrades to version 2 on the next write, preserving its data**

  Run against a copy of the owner's real v1 file. Both existing layouts survived, the newly
  added app was written as `null`, and the file's version became 2.

  **This check found a real bug.** Before the fix, `load()` adopted the file's own version and
  `save()` wrote it straight back, so the file kept claiming version 1 forever while holding
  version 2 content — nulls included. A version-1-only reader would have misinterpreted it
  rather than quarantining it. Fixed in `5c1b64f`, with a mutation-verified test.

- [x] **Full suite green**

  55 tests from a clean `.build`, zero build warnings.

### Owner-required — needs GUI interaction

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

  With VS Code frontmost on Canadian, open the menu, hover the Telegram row, and pick
  Ukrainian. Your active layout must STAY Canadian. Then switch to Telegram: it should become
  Ukrainian.

- [ ] **P2-4: Forget This App removes the row**

  Open a row's submenu and choose `Forget This App`. The row disappears, and your current
  layout must not change — forgetting stops management, it does not revert anything.

- [ ] **P2-5: A forgotten app stays forgotten**

  With `Learn new apps automatically` OFF, forget Slack, then go to Slack and switch layout by
  hand. Slack must NOT reappear in the menu — an app only enters the list when you add it.

- [ ] **P2-5b: A forgotten app can still be re-learned deliberately**

  Turn `Learn new apps automatically` ON, then go to Slack and switch layout by hand. Slack
  reappears with that layout. Turning learning on is the deliberate act that re-enables this;
  `Add App…` is the other.

- [ ] **P2-6: Add App… adds an app that is not running**

  Quit Telegram entirely. Click `Add App…`, choose Telegram from `/Applications`. It appears as
  `Telegram — (not set)`. Pick French from its submenu, then launch Telegram — it should become
  French.

- [ ] **P2-7: Add App… reaches /System/Applications**

  Click `Add App…` and navigate to `/System/Applications`. Choose Mail. It should be added,
  proving the panel is not locked to `/Applications`.

- [ ] **P2-8: Adding an already-managed app says so**

  Click `Add App…` and choose an app already in the list. An alert appears naming the app, and
  the list does not change or gain a duplicate.

  **Also confirm the alert appears in front.** movaMem is an `.accessory` app that never
  activates itself, so a reviewer flagged that its alerts could in principle appear behind
  another window. Nobody could construct a case where that actually happens, but this is the
  step that would catch it on real hardware.

- [ ] **P2-9: `(not set)` does nothing on activation**

  Add an app via `Add App…` without choosing a layout, then switch to that app. Your layout must
  NOT change — an unset app behaves exactly like an unmanaged one.

- [ ] **P2-10: The store is version 2 with a null**

  ```bash
  cat ~/Library/Application\ Support/movaMem/layouts.json
  ```

  Expect `"version" : 2`, and any app added but not yet assigned showing as `null`.

  Note your current file is still `"version" : 1` until phase 2 writes to it for the first
  time — that is correct, and the first edit upgrades it in place while keeping your layouts.

- [ ] **P2-11: Cancelling the picker does nothing**

  Click `Add App…`, then Cancel. No alert, no change to the list.

- [ ] **P2-12: An unavailable layout can be replaced**

  Remove a layout in System Settings that some app is set to. Its row reads `(unavailable)` and
  dimmed. Open that row's submenu and pick an installed layout — the row returns to normal.

---

## Notes

- Steps 11 and 8 from the plan appear in the automated group above; Step 13 is this document.
- The app keeps remembering and switching layouts while its icon is hidden. Only the icon is
  gone, and relaunching restores it.
- No permissions are required. movaMem uses a distributed notification rather than an event
  tap, so it never appears in Accessibility or Input Monitoring, and no TCC prompt appears.
- Phase 2 adds no permission requirements either. `Add App…` uses a standard open panel, which
  grants access to the chosen app bundle only.
