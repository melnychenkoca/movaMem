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

    /// Internal bookkeeping only: layouts whose selection failed this session,
    /// used by this class to decide switching behavior (for example, not
    /// retrying a select that just failed). The menu deliberately does not
    /// consult this set for its "(unavailable)" label — it asks the OS fresh
    /// via availableLayouts() instead, which is authoritative at menu-open
    /// time and correctly stops flagging a layout the user has since
    /// reinstalled, which this sticky set would not.
    private(set) var unavailableLayoutIDs: Set<String> = []

    /// Whether an app movaMem is not yet managing may be added automatically.
    /// Backs the "Learn new apps automatically" menu toggle.
    ///
    /// Governs both ways an unmanaged app can enter the store: recording the
    /// active layout when the app is activated, and recording a hand-switch
    /// made while it is frontmost. Both are gated on this one preference so
    /// that "off" means what it says — nothing enters the store without the
    /// user adding it — and so Forget This App stays forgotten.
    ///
    /// This is a closure rather than a stored Bool so it is read fresh on every
    /// activation: the user can flip the menu item at any time and the next
    /// activation must honor it, with nothing to keep in sync. It is also what
    /// keeps UserDefaults out of this class — the preference is read in the
    /// closure the app wires up in main.swift, so tests pass a plain Bool and
    /// never touch global defaults state.
    private let shouldLearnOnActivation: () -> Bool

    init(
        inputSource: InputSourceProviding,
        appMonitor: AppMonitoring,
        store: LayoutStore,
        // Defaults to off, which is both the shipped default and what every
        // pre-existing call site and test expects.
        shouldLearnOnActivation: @escaping () -> Bool = { false }
    ) {
        self.inputSource = inputSource
        self.appMonitor = appMonitor
        self.store = store
        self.shouldLearnOnActivation = shouldLearnOnActivation
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

    /// Lets another component declare that it is about to call select() itself,
    /// so the resulting notification is attributed to the right app.
    ///
    /// This exists because `SwitchCoordinator.start()` is not the only place
    /// that calls `inputSource.select(layoutID:)` — `MenuController.chooseLayout`
    /// also calls it directly, to apply a layout immediately when the user picks
    /// it for the app that is currently frontmost. That select() can fire the
    /// same layout-changed notification our own selects fire (see the comment
    /// on `layoutWeSelected` above), and `handleLayoutChanged` has no way to
    /// know which app a notification is "about" — it just reads
    /// `appMonitor.frontmostBundleID` fresh, at the moment the notification is
    /// actually delivered.
    ///
    /// That distinction matters because delivery is not synchronous with the
    /// select() call: the notification travels through
    /// DistributedNotificationCenter, which is cross-process, so there is a
    /// real window between "the menu called select() for app A" and "the
    /// notification arrives". If the user switches to app B inside that
    /// window (for example, by Cmd-Tabbing away right after picking a layout
    /// in the menu), `handleLayoutChanged` would otherwise see app B as
    /// frontmost and wrongly record the menu's choice against app B instead
    /// of app A — silently overwriting whatever layout B had saved, or
    /// inventing one for a B that had none. This was a reproduced,
    /// data-losing bug in phase 2, not a theoretical one.
    ///
    /// Calling this method before select() tells `handleLayoutChanged` "this
    /// specific layout ID, whatever app it turns out to be recorded against,
    /// was caused by us" — the same suppression `handleAppActivated` already
    /// relies on. The caller is responsible for calling this immediately
    /// before its own select(), for the same ordering reason documented on
    /// `handleAppActivated`: the notification can arrive synchronously.
    func noteLayoutWeAreAboutToSelect(_ layoutID: String) {
        layoutWeSelected = layoutID
    }

    /// Cancels a note made by `noteLayoutWeAreAboutToSelect` when the select it
    /// was announcing did not actually happen.
    ///
    /// A failed select fires no notification, so nothing would otherwise clear
    /// the noted value. It would stay armed and swallow the user's next genuine
    /// switch to that same layout, losing a preference they really did express.
    /// `handleAppActivated` clears the value on its own failed select for exactly
    /// this reason; any other caller of select() must do the same.
    ///
    /// Reproduced before this method existed: the menu tried to select an
    /// uninstalled layout, the select failed, and the user's later hand-switch to
    /// that layout in a different app recorded nothing at all.
    func cancelNotedLayout() {
        layoutWeSelected = nil
    }

    // MARK: - App activated

    private func handleAppActivated(bundleID: String) {
        guard let wantedLayout = store.layout(forBundleID: bundleID) else {
            // Nothing to restore. Two situations reach here and neither needs
            // telling apart: the app has never been seen, or it is managed via
            // Add App... but still unset.
            //
            // Without learning enabled this does nothing at all, because an entry
            // should only ever reflect a deliberate choice by the user.
            learnLayoutIfEnabled(forBundleID: bundleID)
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

    /// Records the layout that is already active as this app's preference.
    ///
    /// Called only from the "nothing to restore" path above, so it can never
    /// overwrite a layout the user deliberately chose.
    ///
    /// Deliberately performs no select(): the layout being recorded is the one
    /// already active, so there is nothing to switch to. That is also why this
    /// must NOT touch `layoutWeSelected` — no notification is coming, so an
    /// armed value would never be cleared and would swallow the user's next
    /// genuine switch to this same layout, which is the failure
    /// `cancelNotedLayout()` exists to undo elsewhere.
    private func learnLayoutIfEnabled(forBundleID bundleID: String) {
        // An explicit forget outranks the learning preference. Forgetting names
        // one specific app; learning is a blanket default, so the specific choice
        // wins. Without this the reported bug appeared: forgetting an app you keep
        // using did nothing at all, because reopening it learned it right back.
        if store.isForgotten(bundleID: bundleID) {
            log.debug("Not learning \(bundleID, privacy: .public): the user forgot it")
            return
        }

        if shouldLearnOnActivation() == false {
            log.debug("No remembered layout for \(bundleID, privacy: .public)")
            return
        }

        guard let activeLayout = inputSource.currentLayoutID else {
            // currentLayoutID is documented as nil-able. There is no layout to
            // record, and creating an entry with nothing in it would only add a
            // "(not set)" row the user never asked for.
            log.error("Cannot learn layout for \(bundleID, privacy: .public): current layout is unknown")
            return
        }

        log.debug("Learning \(activeLayout, privacy: .public) for \(bundleID, privacy: .public)")
        store.setLayout(activeLayout, forBundleID: bundleID)
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

        // An app movaMem is not managing only becomes managed by a deliberate
        // act: Add App..., or switching learning on. Recording here regardless
        // was how a forgotten app silently came back — the user chose Forget
        // This App, then changed layout in it once, and it reappeared in the
        // menu as if the forget had never happened.
        //
        // Note this reads isManaged, not layout(forBundleID:): an Add App...
        // entry is managed but still unset, and a hand-switch is exactly how
        // the user fills it in. Testing the layout instead would treat that
        // entry as unmanaged and refuse to record, which is the bug this guard
        // is meant to prevent, pointed the other way.
        if store.isManaged(bundleID: bundleID) == false && shouldLearnOnActivation() == false {
            log.debug("Not recording \(newLayout, privacy: .public): \(bundleID, privacy: .public) is not managed")
            return
        }

        // A forgotten app is not re-added by a hand-switch either, even with
        // learning on. Switching layout while an app happens to be frontmost is
        // about the typing at hand, not a decision to manage that app again —
        // treating it as one would undo the forget as a side effect of ordinary
        // typing. Re-adding is done through the app's submenu or Add App..., both
        // of which name the app and clear the mark via the store.
        if store.isForgotten(bundleID: bundleID) {
            log.debug("Not recording \(newLayout, privacy: .public): \(bundleID, privacy: .public) was forgotten")
            return
        }

        log.debug("Recording \(newLayout, privacy: .public) for \(bundleID, privacy: .public)")
        store.setLayout(newLayout, forBundleID: bundleID)
        unavailableLayoutIDs.remove(newLayout)
    }
}
