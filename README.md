# movaMem

Per-application keyboard layout memory for macOS.

macOS has one global keyboard layout, so working across apps in different languages means
switching it by hand every time focus changes. movaMem remembers the layout you deliberately
chose in each application and restores it when you come back.

Type English in VS Code, Ukrainian in Slack, French in Telegram. Switch between them and the
layout follows.

![movaMem's menu bar item, showing remembered apps and a layout submenu](docs/superpowers/pics/bar-menu.png)

## What it does

- **Learns by watching.** Switch layout while in an app and movaMem remembers it for that app.
  Nothing is recorded until you make a real choice, so the list only ever contains decisions you
  actually made.
- **Restores automatically** when you return to an app.
- **Set a layout by hand** from any app's submenu, with a checkmark on the current one.
- **Forget an app** to stop managing it.
- **Add an app you have never opened** via `Add App…`, including one that is not running. It
  starts as `(not set)` and does nothing until you pick a layout.
- **Learn new apps automatically**, off by default. With it on, the first time you switch to an
  app movaMem does not know, it saves whatever layout is active right then — useful when that
  layout is already the one you want there, since watching alone would never see a switch to
  learn from. It fills in `(not set)` entries too. Leave it off and the list stays limited to
  apps you chose deliberately.
- **Hide the menu bar icon** if you want it out of the way. The app keeps working; relaunching
  brings the icon back.
- **Launch at login**, off by default.
- **Shows its version** at the bottom of the menu. There is no Dock icon and no About window, so
  this is the only way to tell which build is running — worth having when a Homebrew tap is stale
  or an upgrade did not take.

### Requires no permissions

movaMem detects layout changes through a system notification rather than by watching your
keystrokes. It never appears in Accessibility or Input Monitoring, and macOS shows no permission
prompt. It catches every way of switching — the ⌘Space-style shortcut, Caps Lock, and the system
input menu.

### Stays out of the way

Around 20 MB of memory and no measurable CPU while idle. There is a deliberate ~300 ms delay
before it switches on app activation, which is what stops Spotlight, notification banners, and
permission dialogs from polluting your saved layouts.

## Install

Requires macOS 14 or later.

### With Homebrew

```bash
brew tap melnychenkoca/movamem
brew trust --cask melnychenkoca/movamem/movamem
brew install --cask movamem

xattr -dr com.apple.quarantine /Applications/movaMem.app
open /Applications/movaMem.app
```

Four steps, because movaMem is built without an Apple Developer ID. Each one clears a different
gate:

**`brew trust`** — Homebrew 5 refuses to load casks from third-party taps until you trust them
explicitly. Without it the install stops before downloading anything.

**`xattr -dr com.apple.quarantine`** — Homebrew marks downloads as quarantined, and macOS refuses
to launch a quarantined app that is not notarized, calling it *"damaged and can't be opened"*.
The app is not damaged; that is just the message macOS uses. Removing the attribute clears it.

Note this is what the old `brew install --no-quarantine` flag used to do. That flag was removed in
Homebrew 5, so any instructions that still mention it will fail with `invalid option`.

If you would rather not strip the attribute, skip that step and approve the app once instead: try
to open it, let macOS block it, then go to System Settings → Privacy & Security and click
**Open Anyway**. On macOS 15 and later this is the only manual route — Apple removed the old
Control-click → Open bypass.

### From source

Needs Swift 6. Full Xcode is **not** required — the Command Line Tools are enough.

```bash
git clone git@github.com:melnychenkoca/movaMem.git
cd movaMem
make install
open /Applications/movaMem.app
```

An `mM` glyph appears at the right of the menu bar. There is no Dock icon and no window — it
is a menu bar app only.

To start using it, go to an app, switch to the layout you want there, and repeat for a couple of
apps. Then switch between them.

## Upgrade

If you installed with Homebrew:

```bash
brew update
brew upgrade --cask movamem

xattr -dr com.apple.quarantine /Applications/movaMem.app
open /Applications/movaMem.app
```

`brew update` refreshes the tap first — without it Homebrew keeps offering the version it already
knows about and reports nothing to upgrade. The freshly downloaded build is quarantined like any
other, so the `xattr` step is needed again for the same reason as at install time.

Quit movaMem from its menu before upgrading if Homebrew complains that the app is running. After
relaunching, check the version row at the bottom of the menu to confirm the new build is the one
running — a stale tap or a failed replace is otherwise invisible.

Your remembered layouts live outside the app bundle and are untouched by an upgrade.

If you installed from source:

```bash
cd movaMem
git pull
make install
open /Applications/movaMem.app
```

Quit the running copy from its menu first, so `make install` replaces the bundle cleanly.

## Uninstall

If you installed with Homebrew:

```bash
brew uninstall --cask movamem          # keeps your remembered layouts
brew uninstall --zap --cask movamem    # removes them too
```

If you installed from source:

```bash
# Quit from the menu first, then:
rm -rf /Applications/movaMem.app
rm -rf ~/Library/Application\ Support/movaMem
```

## Commands

| Command | What it does |
|---|---|
| `make` | Build and assemble `movaMem.app` in the project directory |
| `make install` | Build, assemble, and copy to `/Applications` |
| `make test` | Run the test suite (79 tests) |
| `make build` | Compile only, no bundle |
| `make clean` | Remove build artifacts and the bundle |
| `make sign-setup` | Print one-time steps for a stable code signature (optional) |
| `make icon` | Draw `Resources/AppIcon.icns` |
| `make dist` | Build the universal release zip and print its SHA256 |

The app icon is generated by [`Tools/make-icon.swift`](Tools/make-icon.swift) rather than checked
in, so it can be reviewed as code. `make bundle` regenerates it when the script changes; the
`.icns` itself is a build product and is gitignored. Small sizes are supersampled from a larger
render — drawing directly at 32px leaves too few pixels for the badge, which turns to a smear.

`make dist` is what CI runs on a version tag. It cross-compiles both architectures and joins them
with `lipo`, because `swift build --arch arm64 --arch x86_64` routes through Xcode's build system
and fails under Command Line Tools alone.

The app is ad-hoc signed by default, which is fine for personal use. `make sign-setup` explains
how to create a self-signed certificate if you want a stable identity across rebuilds.

## Where your data lives

```bash
cat ~/Library/Application\ Support/movaMem/layouts.json
```

```json
{
  "apps" : {
    "com.microsoft.VSCode" : "com.apple.keylayout.Canadian",
    "com.tinyspeck.slackmacgap" : null,
    "ru.keepcoder.Telegram" : "com.apple.keylayout.Ukrainian-PC"
  },
  "version" : 2
}
```

Plain JSON, pretty-printed, safe to read or edit by hand. Apps are keyed by bundle identifier so
your preferences survive renaming or moving an app. A `null` means the app is managed but has no
layout chosen yet.

If the file is ever unreadable or malformed, movaMem renames it aside as
`layouts.json.corrupt-<timestamp>` and starts fresh rather than overwriting it — your data is
never silently destroyed.

## How it works

Two sources of OS events feed one decision-maker, which reads and writes the JSON store.

```
NSWorkspace ──"VS Code activated"──┐
                                   ├──► SwitchCoordinator ──► LayoutStore (layouts.json)
Carbon TIS ──"layout → Ukrainian"──┘           │
                                               └──────────► InputSourceService (select)
```

| File | Responsibility |
|---|---|
| `InputSourceService` | The only code that touches Carbon's Text Input Sources API |
| `AppMonitor` | The only code that touches `NSWorkspace`, including the 300 ms dwell filter |
| `LayoutStore` | The JSON store, with atomic writes and corrupt-file quarantine |
| `SwitchCoordinator` | All the policy — what to restore, what to record |
| `MenuController` | The menu bar item and its menus |
| `AppPicker` | Decides whether a chosen app can be managed |
| `AppVersion` | Formats the version row from the bundle's own Info.plist |
| `Preferences` | The settings that persist across launches |
| `ToggleRowView` | A menu row that shows a real switch instead of a checkmark |
| `StatusGlyph` | Draws the "mM" menu bar glyph as a template image |
| `Tools/make-icon.swift` | Draws the app icon; not part of the app target |
| `main.swift` | Wires the pieces together; no logic of its own |

The two OS wrappers sit behind protocols, so the policy layer is tested against fakes with no OS
involvement. That is why the interesting rules — record only deliberate changes, ignore transient
focus, never learn from our own switching — are covered by fast unit tests rather than by clicking
around.

### Design notes

Three decisions worth knowing about, the first two driven by measured behavior rather than
assumption:

**Suppression stores a layout ID, not a flag.** movaMem must ignore the layout-change notification
caused by its own switching. The obvious approach is a boolean, and it is wrong: selecting an
already-active layout fires zero notifications, while one selection sometimes delivers two. A flag
breaks on both, intermittently. Storing *which* layout we selected is immune to both.

**Availability comes from the OS, every time the menu opens.** A layout you uninstall shows as
`(unavailable)` and dimmed, and returns to normal when you reinstall it — with no stale cached
state in between.

**The two settings use switches, not checkmarks.** `NSMenuItem.state` can only draw a checkmark,
so a switch means replacing the row with a custom view — and taking over the label, the pointer
highlight, and the click that AppKit would otherwise handle. Both toggles go through the same
row type so they cannot drift apart, and the fonts, colors, and metrics come from AppKit
(`menuFont`, `selectedContentBackgroundColor`, `fittingSize`) rather than hardcoded values that
would only look right on one macOS version. Clicking anywhere on the row toggles it, matching how
a standard menu item behaves across its full width.

**Learning on activation records without selecting.** "Learn new apps automatically" saves the
layout that is *already* active, so there is nothing to switch to. It must therefore leave the
suppression state above untouched: no notification is coming, so a value armed here would never
be cleared and would swallow your next genuine switch to that same layout. It also skips apps
that already have a saved layout, because a stored entry is a deliberate choice and outranks
whatever happens to be active now.

## Development

Docs live under [docs/superpowers/](docs/superpowers/): design specs, implementation plans, and a
manual verification checklist for the parts that need a human (menu appearance, real app switching,
launch at login across a reboot).

Code style is deliberately plain rather than idiomatic: explicit loops over chained
`map`/`filter`, named intermediate values, no force-unwraps, and comments that explain *why*. The
project is reviewed by someone who does not write Swift, so readability beats brevity.
