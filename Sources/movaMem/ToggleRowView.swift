import AppKit

/// A menu row that shows a switch instead of a checkmark.
///
/// A standard NSMenuItem can only render its on/off state as a checkmark — that
/// is what `NSMenuItem.state` draws, and there is no switch style to ask for. The
/// only way to get a switch is to replace the row's content with a custom view,
/// which is what this is.
///
/// The switch is SwitchControl rather than NSSwitch; see that type for why.
///
/// Taking over the row means taking over everything AppKit would otherwise do for
/// it: the label, the highlight when the pointer is over the row, and the click.
/// Each of those is handled below, and each is a place where a custom view can
/// drift from system styling — so the values come from AppKit itself (menu fonts,
/// selection colors, layout metrics) rather than being hardcoded to numbers that
/// happen to look right on one macOS version.
///
/// @MainActor for the same reason as MenuController: this is AppKit-only code and
/// the compiler should enforce that it stays on the main thread.
@MainActor
final class ToggleRowView: NSView {
    /// Called when the user flips the switch or clicks the row. The argument is
    /// the new value.
    private let onToggle: (Bool) -> Void

    private let label: NSTextField
    private let toggle: SwitchControl

    /// Tracks whether the pointer is inside the row, so the row can paint the
    /// same highlight a standard menu item would.
    private var isHighlighted = false

    /// Menu rows align their text to leave room for the checkmark column, even
    /// when nothing in the menu is checked. Matching that inset is what keeps
    /// this row's label lined up with "Add App…" and the app rows above it.
    private static let horizontalInset: CGFloat = 14
    private static let verticalPadding: CGFloat = 4
    /// Minimum gap between the label and the switch, so a long label never runs
    /// into it.
    private static let labelToSwitchGap: CGFloat = 16

    /// The width every toggle row asks for.
    ///
    /// Fixed rather than derived from the label, so both switches land on the same
    /// right edge. Sizing each row to its own text would put the two switches at
    /// different x positions — "Launch at Login" is much shorter than "Learn new
    /// apps automatically" — and two controls of the same kind failing to line up
    /// is exactly the kind of detail that reads as sloppy.
    ///
    /// The value covers the longer of the two labels at the menu font plus the gap,
    /// the switch, and both insets. MenuController checks the real fitting width
    /// against it, so a label that outgrows it cannot silently clip.
    static let preferredWidth: CGFloat = 260

    init(title: String, isOn: Bool, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle

        // The menu font, not the system font: menus use a slightly different size
        // that changes with the user's menu bar settings, and hardcoding
        // systemFont(ofSize:) would look subtly wrong next to the other rows.
        let menuFont = NSFont.menuFont(ofSize: 0)

        label = NSTextField(labelWithString: title)
        label.font = menuFont
        label.translatesAutoresizingMaskIntoConstraints = false

        toggle = SwitchControl(isOn: isOn)
        toggle.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)

        addSubview(label)
        addSubview(toggle)

        toggle.onToggle = { [weak self] newValue in
            self?.reportNewValue(newValue)
        }

        let inset = ToggleRowView.horizontalInset
        let padding = ToggleRowView.verticalPadding
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            toggle.leadingAnchor.constraint(
                greaterThanOrEqualTo: label.trailingAnchor,
                constant: ToggleRowView.labelToSwitchGap
            ),
            // Pinned to the trailing edge, which is what puts the switch on the
            // right of the menu rather than beside its label.
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.widthAnchor.constraint(equalToConstant: SwitchControl.controlWidth),
            toggle.heightAnchor.constraint(equalToConstant: SwitchControl.controlHeight),

            // The label is the taller element now that the switch is small, so the
            // row height follows it.
            heightAnchor.constraint(greaterThanOrEqualTo: label.heightAnchor, constant: padding * 2),
        ])

        applyLabelColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // This view is only ever created in code. Implementing this properly would
        // mean maintaining a second construction path that nothing exercises.
        fatalError("ToggleRowView is not loaded from a nib")
    }

    /// Keeps the switch in step when the value changes elsewhere. The menu is
    /// rebuilt on every open, so this matters only while the menu is already
    /// showing — but a row that displayed a stale value would be actively
    /// misleading, so it is worth the two lines.
    func setOn(_ isOn: Bool) {
        toggle.setOn(isOn)
    }

    // MARK: - Highlight
    //
    // A custom view gets no highlight from AppKit, so without this the row would
    // stay flat while every other row lights up under the pointer — which reads
    // as the row being disabled.

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
        // selectedContentBackgroundColor is the color AppKit uses for a
        // highlighted menu row, so this tracks the system accent color and both
        // light and dark appearance without any color of our own.
        NSColor.selectedContentBackgroundColor.setFill()
        // Inset horizontally to match the rounded highlight macOS draws inside
        // the menu's own padding, rather than bleeding to the full width.
        let highlightRect = bounds.insetBy(dx: 5, dy: 0)
        let path = NSBezierPath(roundedRect: highlightRect, xRadius: 4, yRadius: 4)
        path.fill()
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

    /// Clicking anywhere on the row toggles it, not just the switch itself. A
    /// standard menu item responds across its whole width, and a row that only
    /// responded on a small control at the far right would feel broken.
    ///
    /// A click that lands on the switch does not reach here: SwitchControl handles
    /// its own mouseDown and AppKit routes the event to it, so the value is
    /// reported exactly once either way.
    override func mouseDown(with event: NSEvent) {
        toggle.toggle()
    }

    /// Reports the new value and deliberately leaves the menu open.
    ///
    /// An earlier version called cancelTracking() here to mimic a standard menu
    /// item, which dismisses on click. That is wrong for a switch: a switch is a
    /// setting you may want to flip and then look at, or set alongside the other
    /// toggle, and closing the menu out from under the click made the change feel
    /// like it had been cancelled rather than applied. Staying open also means the
    /// switch's new position is visible immediately, which is the whole point of
    /// showing a switch instead of a checkmark.
    private func reportNewValue(_ newValue: Bool) {
        onToggle(newValue)
    }
}
