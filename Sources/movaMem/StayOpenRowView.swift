import AppKit

/// A clickable menu row that does not dismiss the menu.
///
/// A standard NSMenuItem tears the whole menu down the moment its action fires and
/// cannot be talked out of it. That is wrong for rows that edit a list you are
/// looking at — un-forgetting an app, or forgetting one — where the menu closing
/// costs you the context you were working in and forces a reopen to make the next
/// change. Owning the click is the only way to keep the menu up, which is the same
/// reason ToggleRowView exists.
///
/// The row reports the click and nothing more. What to change, and which parts of
/// the menu to rebuild afterwards, is the caller's business — MenuController holds
/// that knowledge, and a view that reached into the menu hierarchy itself would be
/// impossible to test.
///
/// Taking over the row means taking over what AppKit would otherwise do for it —
/// the label, the pointer highlight, and the click. The layout values come from
/// MenuRowMetrics so these rows line up with the toggle rows in the same menu.
///
/// @MainActor for the same reason as MenuController: this is AppKit-only code and
/// the compiler should enforce that it stays on the main thread.
@MainActor
final class StayOpenRowView: NSView {
    /// Called when the row is clicked. The caller un-forgets the app and removes
    /// this row from the menu; the row itself knows nothing about either.
    private let onClick: () -> Void

    private let label: NSTextField

    /// Tracks whether the pointer is inside the row, so it can paint the same
    /// highlight a standard menu item would.
    private var isHighlighted = false

    init(title: String, onClick: @escaping () -> Void) {
        self.onClick = onClick

        // The menu font, not the system font: menus use a slightly different size
        // that changes with the user's menu bar settings, and hardcoding
        // systemFont(ofSize:) would look subtly wrong next to the other rows.
        label = NSTextField(labelWithString: title)
        label.font = NSFont.menuFont(ofSize: 0)
        label.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)

        addSubview(label)

        let padding = MenuRowMetrics.verticalPadding
        NSLayoutConstraint.activate([
            // The bezel is subtracted so the glyphs — not the text field's frame —
            // land where AppKit puts a standard title. See MenuRowMetrics.
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: MenuRowMetrics.titleInset - MenuRowMetrics.labelTextBezel
            ),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Pinned trailing as well as leading, so fittingSize accounts for the
            // full title. Without this the row could ask for a width that clips a
            // long bundle ID, which is the realistic case for an uninstalled app.
            label.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -MenuRowMetrics.trailingInset
            ),
            heightAnchor.constraint(greaterThanOrEqualTo: label.heightAnchor, constant: padding * 2),
        ])

        applyLabelColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // This view is only ever created in code. Implementing this properly would
        // mean maintaining a second construction path that nothing exercises.
        fatalError("StayOpenRowView is not loaded from a nib")
    }

    // MARK: - Test seams
    //
    // Read-only views onto private state. The alternative is either making the
    // state internal — inviting callers to mutate it — or leaving the click and
    // highlight paths untested, which is where this kind of view actually breaks.

    var displayedTitle: String {
        return label.stringValue
    }

    var isShowingHighlight: Bool {
        return isHighlighted
    }

    var labelLeadingInset: CGFloat {
        return MenuRowMetrics.titleInset - MenuRowMetrics.labelTextBezel
    }

    /// Drives the same path a real click takes, without synthesizing an event.
    func simulateClick() {
        reportClick()
    }

    // MARK: - Highlight

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        // .activeAlways because a menu runs in its own event tracking mode, where
        // the more common .activeInKeyWindow never fires.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        applyLabelColor()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        applyLabelColor()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHighlighted else {
            return
        }
        MenuRowMetrics.drawHighlight(in: bounds)
    }

    /// Applies the label color for the current highlight state.
    ///
    /// Called from init and from both mouse handlers rather than from layout(),
    /// because layout() is not guaranteed to run before the first draw of a
    /// manually-framed view — leaving the label on NSTextField's default color for
    /// that first frame.
    private func applyLabelColor() {
        if isHighlighted {
            label.textColor = .selectedMenuItemTextColor
        } else {
            label.textColor = .labelColor
        }
    }

    /// Reapplies the label color when the system switches between light and dark
    /// while the app is running. The colors used are dynamic, so AppKit resolves
    /// them per appearance — but the assignment still has to happen again for the
    /// text field to pick up the new resolution.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLabelColor()
    }

    // MARK: - Clicks

    override func mouseDown(with event: NSEvent) {
        reportClick()
    }

    /// Reports the click and deliberately leaves the menu open — no
    /// cancelTracking() here, which is the whole reason this view exists.
    ///
    /// The pointer is still over this row's old position after the caller removes
    /// it, but the highlight does not need clearing: the view is out of the menu
    /// and will not be drawn again. AppKit sends mouseEntered to whichever row
    /// takes its place.
    private func reportClick() {
        onClick()
    }
}
