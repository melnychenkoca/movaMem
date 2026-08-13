import Foundation
import os

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

    /// Bundle IDs the user explicitly chose to forget.
    ///
    /// Kept so that automatic learning cannot re-add an app the user rejected.
    /// Without it, forgetting an app you keep using was effectively a no-op with
    /// learning on: the next activation learned it straight back.
    ///
    /// A sorted array on disk rather than a set, because JSON has no set type and
    /// the owner reads this file by hand. Note that `.sortedKeys` only orders
    /// object keys, so the sort is applied explicitly when saving.
    var forgotten: [String]

    /// Decoded explicitly so `forgotten` can default to empty for the v1 and v2
    /// files that predate it. A synthesized initializer would fail to decode them
    /// outright, and load() would then quarantine every existing install's store
    /// as malformed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        apps = try container.decode([String: String?].self, forKey: .apps)
        forgotten = try container.decodeIfPresent([String].self, forKey: .forgotten) ?? []
    }

    /// Written out because declaring `init(from:)` above suppresses the
    /// synthesized memberwise initializer. `forgotten` defaults to empty since
    /// LayoutStore fills it from its own set when saving.
    init(version: Int, apps: [String: String?], forgotten: [String] = []) {
        self.version = version
        self.apps = apps
        self.forgotten = forgotten
    }
}

/// Remembers which keyboard layout belongs to which application.
///
/// Loads once at construction into memory. Reads are memory-only; writes update
/// memory and then persist to disk.
final class LayoutStore {
    private let fileURL: URL
    private let log = Logger(subsystem: "com.movamem.app", category: "LayoutStore")

    private var layouts: StoredLayouts

    /// The forgotten bundle IDs, held as a Set for O(1) membership checks — this
    /// is read on every app activation. `layouts.forgotten` is the on-disk array
    /// form; this is the authority in memory, and save() derives the array from
    /// it so the two cannot drift.
    private var forgotten: Set<String> = []

    /// False once a disk write has failed. The menu shows a degraded-state row
    /// when this is false. The app keeps working in memory either way.
    private(set) var isWritable = true

    /// True when the store file existed but could not be loaded — either it was
    /// unreadable (permissions, I/O error) or malformed. The menu shows a
    /// degraded-state row for this too, so the user knows their remembered
    /// layouts did not come back this launch.
    private(set) var didFailToLoad = false

    /// True when a quarantine move (moving a bad file aside before replacing it)
    /// has failed. When this is true, `save()` refuses to write at all. Without
    /// this guard, a failed quarantine would leave the original bad file in
    /// place, and the very next `setLayout` would overwrite it with `.atomic`,
    /// which is exactly the silent data loss this whole mechanism exists to
    /// prevent.
    private var quarantineFailed = false

    private static let currentSchemaVersion = 3

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.layouts = StoredLayouts(version: LayoutStore.currentSchemaVersion, apps: [:])
        load()
    }

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
        // key present", the inner is "is a layout set". `?? nil` flattens both
        // levels into the single optional this function returns. Note that for
        // an absent key, `if let layoutID = layouts.apps[bundleID]` would also
        // fall through to nil here, so the two idioms happen to agree at this
        // particular call site — `?? nil` is used for clarity, not because the
        // other form is wrong here.
        let layoutID: String? = layouts.apps[bundleID] ?? nil
        return layoutID
    }

    /// True when this app is in the store at all, whether or not a layout is set.
    /// This is the only way to distinguish an unset app from an unknown one.
    func isManaged(bundleID: String) -> Bool {
        return layouts.apps.index(forKey: bundleID) != nil
    }

    /// True when the user explicitly forgot this app and has not re-added it.
    ///
    /// SwitchCoordinator consults this before learning an app automatically, so a
    /// forgotten app stays out of the store no matter how often it is activated.
    /// This outranks the learning preference deliberately: forgetting names one
    /// specific app, while learning is a blanket default, and the specific choice
    /// should win.
    func isForgotten(bundleID: String) -> Bool {
        return forgotten.contains(bundleID)
    }

    /// Every app the user explicitly forgot, sorted by bundle ID.
    ///
    /// Sorted for the same reason allEntries() is: the Forgotten Apps menu builds
    /// its rows straight from this, and Set iteration order is not stable between
    /// runs, so returning the set's own order would reshuffle the list every time
    /// the menu opened.
    func forgottenBundleIDs() -> [String] {
        return forgotten.sorted()
    }

    /// All entries, sorted by bundle ID so the menu order is stable between openings.
    ///
    /// An entry whose layoutID is nil is managed but unset; the menu shows it as
    /// "(not set)". Unset entries must NOT be dropped here.
    func allEntries() -> [(bundleID: String, layoutID: String?)] {
        var result: [(bundleID: String, layoutID: String?)] = []
        let sortedKeys = layouts.apps.keys.sorted()
        for bundleID in sortedKeys {
            // Flatten the double optional with `?? nil`. Because bundleID comes
            // from layouts.apps.keys, the key is always present here, so
            // `if let layoutID = layouts.apps[bundleID]` would in fact be
            // equivalent — the two idioms only diverge for an absent key, which
            // cannot happen in this loop. `?? nil` is used to be explicit about
            // "flatten, don't bind the inner optional", not to fix a live bug.
            let layoutID: String? = layouts.apps[bundleID] ?? nil
            result.append((bundleID: bundleID, layoutID: layoutID))
        }
        return result
    }

    // MARK: - Writing

    func setLayout(_ layoutID: String, forBundleID bundleID: String) {
        layouts.apps[bundleID] = layoutID
        // Choosing a layout is a deliberate act, so it un-forgets the app. This
        // lives here rather than in the callers so no future call site can set a
        // layout while leaving the app marked forgotten — which would store a
        // layout that automatic learning then refuses to touch, a state with no
        // way for the user to make sense of it.
        forgotten.remove(bundleID)
        save()
    }

    /// Registers an app with no layout to restore. Used by Add App..., where the
    /// user has chosen which app to manage but not yet which layout.
    func addAppWithNoLayout(bundleID: String) {
        // If this app is already managed, do nothing rather than overwrite it.
        // Add App... can be invoked again for an app movaMem already learned a
        // layout for (for example the caller's own "already managed" check gets
        // bypassed or changes in a future edit), and unconditionally assigning
        // .some(nil) here would silently wipe that remembered layout with no
        // warning. The store must not depend on a caller in another file to
        // prevent that; the guard belongs here, where it cannot be bypassed.
        if isManaged(bundleID: bundleID) {
            log.debug("addAppWithNoLayout ignored: \(bundleID, privacy: .public) is already managed")
            return
        }

        // Assigning `.some(nil)` stores a present key with a nil value. Writing
        // `layouts.apps[bundleID] = nil` would REMOVE the key instead — that is
        // how dictionary subscript assignment works with optionals.
        layouts.apps[bundleID] = .some(nil)
        // Add App... is the other deliberate act, and the escape hatch for an app
        // forgotten by mistake. See the note in setLayout.
        forgotten.remove(bundleID)
        save()
    }

    /// Forgets an app: drops its entry and records that the user rejected it.
    ///
    /// The mark is what makes Forget This App stick. Deleting the entry alone left
    /// the app eligible for automatic learning, so with "Learn new apps
    /// automatically" on, the very next activation put it straight back and the
    /// forget looked broken.
    func remove(bundleID: String) {
        layouts.apps.removeValue(forKey: bundleID)
        // Marked even when there was no entry to delete: a stale menu item or a
        // repeated forget expresses the same rejection, and recording it is both
        // harmless and more faithful to what the user asked for.
        forgotten.insert(bundleID)
        save()
    }

    /// Registers an app, capturing the layout that is active right now.
    ///
    /// Used by Add App..., so a newly added app is immediately useful rather than
    /// sitting at "(not set)" until the user happens to switch layouts inside it.
    /// A nil layoutID means the active layout could not be determined; the app is
    /// still added, just unset, because refusing to add it would be a worse
    /// outcome than an unset entry the user can fill in from the submenu.
    ///
    /// Like addAppWithNoLayout, this refuses to touch an app that is already
    /// managed — the layout it already carries was chosen deliberately, and the
    /// layout that happens to be active now is not a reason to overwrite it.
    func addApp(bundleID: String, layoutID: String?) {
        if isManaged(bundleID: bundleID) {
            log.debug("addApp ignored: \(bundleID, privacy: .public) is already managed")
            return
        }

        guard let layoutID else {
            addAppWithNoLayout(bundleID: bundleID)
            return
        }
        // setLayout already clears the forgotten mark and saves.
        setLayout(layoutID, forBundleID: bundleID)
    }

    /// Reverses a forget, capturing the layout that is active right now.
    ///
    /// Same reasoning as addApp: the app comes back ready to use. This deliberately
    /// DOES overwrite a layout left over from before the app was forgotten — that
    /// entry is stale by definition, and silently restoring it would apply a layout
    /// the user had moved on from with nothing on screen explaining where it came
    /// from. The layout active at the moment of the click is the more recent, more
    /// deliberate signal.
    func unforget(bundleID: String, layoutID: String?) {
        guard let layoutID else {
            unforget(bundleID: bundleID)
            return
        }
        // setLayout clears the forgotten mark and saves, so this needs nothing else.
        setLayout(layoutID, forBundleID: bundleID)
    }

    /// Reverses a forget: clears the mark and puts the app back in the list unset.
    ///
    /// This is the Forgotten Apps menu's only action. It lands the app in exactly
    /// the state Add App... produces — managed, no layout, showing "(not set)" —
    /// so one click makes the app visibly present again with a layout to pick.
    ///
    /// The order matters. `addAppWithNoLayout` returns early for an app that is
    /// already managed, in order to protect a remembered layout from being wiped.
    /// Clearing the mark first, and unconditionally, means that guard cannot also
    /// swallow the un-forget and leave the app marked forgotten with an entry
    /// present — a state where the menu shows a layout that learning refuses to
    /// touch. Both paths still save: the early return does not, but the explicit
    /// save below covers it.
    func unforget(bundleID: String) {
        forgotten.remove(bundleID)
        // Registers the app unset, or leaves an existing entry untouched.
        addAppWithNoLayout(bundleID: bundleID)
        // Unconditional because addAppWithNoLayout may have returned early
        // without saving, and the mark cleared above must still reach disk.
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
            // The file exists but we could not read it (permissions, I/O error,
            // and so on). This must be treated exactly like a malformed file:
            // move it aside and start empty. If we did not quarantine here, the
            // in-memory state would stay empty but the file on disk would stay
            // untouched, and the very next setLayout would overwrite it with
            // .atomic, destroying whatever was in it with no backup.
            log.error("Could not read store file: \(error.localizedDescription, privacy: .public)")
            didFailToLoad = true
            quarantineCorruptFile()
            return
        }

        do {
            let decoded = try JSONDecoder().decode(StoredLayouts.self, from: data)

            if decoded.version > LayoutStore.currentSchemaVersion {
                // This file was written by a newer version of movaMem. Adopting
                // it would decode fine today (Codable silently ignores unknown
                // keys) but the next save would write it back downgraded to
                // this app's fields only, permanently dropping whatever the
                // newer version added. Treat it the same as a corrupt file
                // rather than risk that silent downgrade.
                log.error("""
                Store file version \(decoded.version, privacy: .public) is newer than \
                this app's version \(LayoutStore.currentSchemaVersion, privacy: .public); \
                quarantining it rather than risk dropping its data
                """)
                didFailToLoad = true
                quarantineCorruptFile()
                return
            }

            // Take the app data, but stamp the CURRENT schema version rather than
            // keeping the file's own. Without this, an older file keeps claiming
            // its old version forever: load() would adopt it and the next save()
            // would write it straight back. That was harmless while every version
            // held the same shape, but it stopped being harmless once version 2
            // introduced null values for unset apps — a file would then contain
            // v2 content while advertising v1, and a v1-only reader would
            // misinterpret it instead of quarantining it.
            //
            // Upgrading in this direction is always safe: the check above already
            // rejected anything NEWER than we understand, so whatever reaches here
            // is a shape this version can represent completely.
            layouts = StoredLayouts(
                version: LayoutStore.currentSchemaVersion,
                apps: decoded.apps
            )
            // The set is the authority from here on; save() writes
            // layouts.forgotten from it, so it is deliberately not seeded above.
            forgotten = Set(decoded.forgotten)
            if decoded.version != LayoutStore.currentSchemaVersion {
                log.debug("""
                Upgrading store from version \(decoded.version, privacy: .public) \
                to \(LayoutStore.currentSchemaVersion, privacy: .public)
                """)
            }
            log.debug("Loaded \(decoded.apps.count) remembered apps")
        } catch {
            // The file exists but is not valid. Move it aside rather than deleting
            // it, so a bug in this code can never destroy the user's data.
            log.error("Store file is malformed; quarantining it")
            didFailToLoad = true
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
            // We could not even move the bad file out of the way. If save() went
            // on to write here anyway, .atomic would replace the original file
            // and destroy it with no backup — the exact failure this whole
            // mechanism exists to prevent. Refuse all future writes instead.
            log.error("Could not quarantine bad store: \(error.localizedDescription, privacy: .public)")
            quarantineFailed = true
        }
    }

    private func save() {
        if quarantineFailed {
            // A bad file is still sitting at fileURL and we could not move it
            // aside. Writing now would silently destroy it with .atomic, so we
            // refuse rather than risk that. The session still works in memory.
            log.error("Refusing to write: an earlier quarantine attempt failed")
            isWritable = false
            return
        }

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
            // Derive the on-disk array from the in-memory set at the moment of
            // writing, so the two can never disagree. Sorted explicitly because
            // .sortedKeys orders object keys only, leaving array order to us, and
            // Set iteration order is not stable between runs — without this the
            // file would reshuffle on every save and be unreadable in a diff.
            layouts.forgotten = forgotten.sorted()
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
