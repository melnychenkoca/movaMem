import AppKit
import Foundation
import ServiceManagement
import os

/// The status bar icon and its menu.
///
/// This class only ever touches AppKit, which is a main-thread-only framework.
/// Marking it @MainActor tells the compiler to check that for us: every call
/// into this class must come from the main thread, or the code will not build.
/// No test in this project constructs a MenuController, so there is no
/// synchronous test call that @MainActor would need to turn into an async one.
/// This is the opposite situation from AppMonitor, whose synchronous test calls
/// forced it to use @unchecked Sendable instead — a promise to the compiler
/// that is not actually checked, only documented in a comment.
@MainActor
final class MenuController: NSObject {
    private let log = Logger(subsystem: "com.movamem.app", category: "MenuController")
    private let store: LayoutStore
    private let inputSource: InputSourceProviding
    private let coordinator: SwitchCoordinator
    private let appMonitor: AppMonitoring

    private var statusItem: NSStatusItem?

    init(
        store: LayoutStore,
        inputSource: InputSourceProviding,
        coordinator: SwitchCoordinator,
        appMonitor: AppMonitoring
    ) {
        self.store = store
        self.inputSource = inputSource
        self.coordinator = coordinator
        self.appMonitor = appMonitor
        super.init()
    }

    /// Shows the icon. Hiding it (see hideIcon()) only lasts for the current
    /// session, so every launch — including the very first one — always shows it.
    func install() {
        showIcon()
    }

    private func showIcon() {
        // variableLength, not squareLength: "mM" is wider than it is tall, and a
        // square status item would clip the second letter.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // A static glyph, deliberately: a live layout code would be confused with
        // the system's own input menu.
        if let button = item.button {
            button.image = StatusGlyph.image()
            // The image carries no text of its own as far as VoiceOver is
            // concerned, so the description is what names the app aloud.
            button.image?.accessibilityDescription = "movaMem"
        }

        let menu = NSMenu()
        // Rebuild the app list each time the menu opens, so there is zero cost
        // while it is closed.
        menu.delegate = self
        // AppKit's default behavior recomputes each item's enabled state at
        // display time and ignores whatever we set manually. Turning that off
        // makes our own "isEnabled = false" lines below actually load-bearing,
        // which matters once phase 2 gives these rows real actions.
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
    }

    // MARK: - Menu actions

    // Hiding is session-only and intentionally not persisted: relaunching the
    // app always shows the icon again (see install()). Do not re-add a
    // UserDefaults flag here thinking persistence is missing — it was removed
    // because install() unconditionally shows the icon regardless of any
    // stored value, which made the flag write-only and did nothing.
    @objc private func hideIcon() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        // The app keeps remembering and switching layouts while hidden.
        log.debug("Icon hidden; relaunch the app to bring it back")
    }

    /// Flips launch-at-login from the service's own status. Not an @objc action:
    /// the switch row calls it directly rather than through a selector.
    private func setLaunchAtLogin() {
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
}

// MARK: - Menu building

extension MenuController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addStorageWarning(to: menu)
        addAppEntries(to: menu)

        // Grouped with the app list rather than the settings below, because it is
        // a list operation. The trailing ellipsis is the macOS convention for an
        // item that opens a dialog.
        let addItem = NSMenuItem(title: "Add App…", action: #selector(addApp), keyEquivalent: "")
        addItem.target = self
        menu.addItem(addItem)

        menu.addItem(NSMenuItem.separator())
        addFooterItems(to: menu)
    }

    /// Builds a menu row carrying a ToggleRowView.
    ///
    /// The item has no action or target: the view owns the click, because AppKit
    /// does not route clicks on a custom view through the item's action. Every
    /// toggle goes through here so they cannot drift apart.
    ///
    /// Every toggle row gets the same width, so the switches all land on the same
    /// right edge instead of tracking their own label lengths. The max() guards the
    /// case where a label is longer than that width allows, which would otherwise
    /// clip the switch — a real frame is required either way, since a zero-height
    /// view renders as a sliver.
    private func makeToggleItem(
        title: String,
        isOn: Bool,
        onToggle: @escaping (Bool) -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem()
        let row = ToggleRowView(title: title, isOn: isOn, onToggle: onToggle)
        let fitting = row.fittingSize
        row.frame = NSRect(
            x: 0,
            y: 0,
            width: max(fitting.width, ToggleRowView.preferredWidth),
            height: fitting.height
        )
        item.view = row
        return item
    }

    /// A load failure is the more serious problem — it means the layouts the
    /// user already had are gone from memory this launch, not just that new
    /// ones cannot be saved — so if both are true, show only that one rather
    /// than stacking two nearly identical warning rows.
    private func addStorageWarning(to menu: NSMenu) {
        if store.didFailToLoad {
            let warning = NSMenuItem(
                title: "Could not read saved layouts — check Console for details",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            menu.addItem(warning)
            menu.addItem(NSMenuItem.separator())
        } else if store.isWritable == false {
            let warning = NSMenuItem(
                title: "Not saving — check Console for details",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            menu.addItem(warning)
            menu.addItem(NSMenuItem.separator())
        }
    }

    /// The fixed items at the bottom of the menu: the two learning toggles,
    /// Launch at Login, Hide Icon, and Quit (which also shows the version).
    private func addFooterItems(to menu: NSMenu) {
        // Grouped with the other switches rather than beside the app list, so
        // every setting sits in one block instead of being split across the menu.
        //
        // The coordinator reads this preference on every activation, so there is
        // deliberately nothing to notify here.
        menu.addItem(makeToggleItem(
            title: "Learn new apps automatically",
            isOn: Preferences.learnNewAppsAutomatically,
            onToggle: { [weak self] newValue in
                Preferences.learnNewAppsAutomatically = newValue
                self?.log.debug("Learn new apps automatically: \(newValue, privacy: .public)")
            }
        ))

        // Directly below the toggle it qualifies: this narrows what that one
        // learns, so it reads as a sub-condition of it in that position. It is
        // shown whatever that toggle's state is, rather than hidden when
        // learning is off — a control that vanishes is harder to find again than
        // one that is simply inert, and its own state is still worth seeing.
        menu.addItem(makeToggleItem(
            title: "Learn system apps",
            isOn: Preferences.trackSystemApps,
            onToggle: { [weak self] newValue in
                Preferences.trackSystemApps = newValue
                self?.log.debug("Learn system apps: \(newValue, privacy: .public)")
            }
        ))

        // The new value is ignored: SMAppService is the source of truth, so
        // setLaunchAtLogin reads its status and flips that. A failed registration
        // then leaves the real state alone and the next menu open shows the truth
        // rather than an optimistic switch position.
        menu.addItem(makeToggleItem(
            title: "Launch at Login",
            isOn: SMAppService.mainApp.status == .enabled,
            onToggle: { [weak self] _ in self?.setLaunchAtLogin() }
        ))

        let hideItem = NSMenuItem(title: "Hide Icon", action: #selector(hideIcon), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        menu.addItem(NSMenuItem.separator())

        // The version shares this row rather than taking one of its own above it:
        // see AppVersion.quitTitle. ⌘Q still draws at the right edge, so the row
        // reads "Quit movaMem 1.2.0        ⌘Q".
        let parts = AppVersion.currentQuitTitleParts()

        // The plain title is set too, not just the attributed one: VoiceOver and
        // any AppKit path that ignores attributedTitle read this, and it is what
        // the row falls back to rather than an empty label.
        let quitItem = NSMenuItem(
            title: parts.command + parts.version,
            action: #selector(quit),
            keyEquivalent: "q"
        )

        quitItem.attributedTitle = Self.styledQuitTitle(parts: parts)

        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// How far from the row's left edge the version starts, in points.
    ///
    /// A fixed stop rather than a centred one. Centring would need the menu's
    /// width, which AppKit derives from the widest row — here, the app list. The
    /// version would then sit in a different place after every app learned or
    /// forgotten, and a stop past the natural width stretches the whole menu to
    /// reach it. A constant lands the version in the same spot on every open.
    ///
    /// Sized in em widths of the menu font rather than raw points so it tracks a
    /// font or accessibility size change instead of crowding the command.
    private static let versionTabStopEms: CGFloat = 5.5

    /// The Quit row drawn as two runs: the command, then the dimmed version at a
    /// fixed tab stop.
    ///
    /// Static and parameterised so a test can measure the result without a
    /// controller or a live menu.
    static func styledQuitTitle(parts: (command: String, version: String)) -> NSAttributedString {
        // Explicit: setting attributedTitle drops the font AppKit would have
        // supplied, which would otherwise leave this row in the system font at
        // the wrong size next to the toggles above it.
        let font = NSFont.menuFont(ofSize: 0)

        // A tab is what actually moves the version; .center alignment does
        // nothing, since AppKit lays a menu title out left-aligned inside its own
        // cell and ignores the paragraph alignment entirely.
        let style = NSMutableParagraphStyle()
        let stop = font.pointSize * versionTabStopEms
        style.tabStops = [NSTextTab(textAlignment: .left, location: stop, options: [:])]

        // Trailing whitespace on the command becomes the tab: the space would
        // otherwise be drawn before the tab advanced, nudging the stop rightward.
        let command = parts.command.trimmingCharacters(in: .whitespaces) + "\t"

        let styled = NSMutableAttributedString(
            string: command,
            attributes: [.font: font, .paragraphStyle: style]
        )
        // Only the name and version are dimmed, so the row still reads as the
        // Quit command first. disabledControlTextColor is the same grey the
        // unavailable-layout rows use below, and what AppKit draws ⌘Q in — the
        // version then matches the key equivalent it sits beside instead of
        // introducing a third level of contrast.
        styled.append(NSAttributedString(
            string: parts.version,
            attributes: [
                .font: font,
                .paragraphStyle: style,
                .foregroundColor: NSColor.disabledControlTextColor,
            ]
        ))
        return styled
    }

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
            let row = rowTitle(forEntry: entry, layoutNames: layoutNames)

            let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
            item.submenu = makeSubmenu(
                forBundleID: entry.bundleID,
                currentLayoutID: entry.layoutID,
                installedLayouts: installedLayouts
            )
            if row.isUnavailable {
                item.attributedTitle = NSAttributedString(
                    string: row.title,
                    attributes: [.foregroundColor: NSColor.disabledControlTextColor]
                )
            }
            menu.addItem(item)
        }
    }

    /// Builds the title for one app row and whether it should render dimmed.
    ///
    /// Three row states: a layout that is set and installed, a layout that is
    /// set but no longer installed, and no layout at all.
    private func rowTitle(
        forEntry entry: (bundleID: String, layoutID: String?),
        layoutNames: [String: String]
    ) -> (title: String, isUnavailable: Bool) {
        let appName = displayName(forBundleID: entry.bundleID)

        guard let layoutID = entry.layoutID else {
            // Managed via Add App... but no layout chosen yet.
            return (title: "\(appName) — (not set)", isUnavailable: false)
        }

        let layoutName = layoutNames[layoutID] ?? layoutID
        // availableLayouts() asks the OS fresh every time the menu opens, so
        // layoutNames reflects live truth in both directions: a layout that was
        // uninstalled shows up missing, and one that was reinstalled since shows
        // up present again. That makes it authoritative for what the menu
        // displays, so we deliberately do not also consult
        // coordinator.unavailableLayoutIDs here — that set is sticky (it is only
        // cleared by a successful select or a user switch to that layout) and
        // would keep marking a row unavailable after the user reinstalled the
        // layout in System Settings but had not yet revisited the app that uses
        // it. unavailableLayoutIDs still exists on the coordinator and still
        // matters internally for switching decisions; it is just not the right
        // source for this label.
        let layoutIsNotInstalled = layoutNames[layoutID] == nil
        if layoutIsNotInstalled {
            return (title: "\(appName) — \(layoutName) (unavailable)", isUnavailable: true)
        }
        return (title: "\(appName) — \(layoutName)", isUnavailable: false)
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
        // notification — it does not affect this read.)
        if appMonitor.frontmostBundleID == choice.bundleID {
            // Tell the coordinator what we are about to do BEFORE doing it, for
            // the same reason SwitchCoordinator.handleAppActivated does: the
            // layout-changed notification this select() triggers can arrive
            // before this call even returns, and if it arrives after the user
            // has switched apps, the coordinator would otherwise attribute it
            // to whatever app is frontmost by then instead of this one.
            coordinator.noteLayoutWeAreAboutToSelect(choice.layoutID)
            let didSelect = inputSource.select(layoutID: choice.layoutID)
            if didSelect == false {
                log.error("Could not select \(choice.layoutID, privacy: .public) immediately")
                // The select never happened, so no notification will arrive to
                // clear the note above. Leaving it armed would swallow the user's
                // next genuine switch to this same layout — the same reason
                // handleAppActivated clears its own note on failure.
                coordinator.cancelNotedLayout()
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
