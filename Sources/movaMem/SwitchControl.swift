import AppKit

/// A small switch drawn by hand, used instead of NSSwitch.
///
/// NSSwitch would be the obvious choice and was the first attempt. It is wrong
/// here for one measured reason: its "on" fill is the system accent color, and
/// macOS desaturates accent colors in windows that are not key. A menu is never
/// key, so an NSSwitch in a menu renders its on state as grey — the same grey as
/// its off state, distinguished only by knob position. That was reported as
/// unreadable, and it is: two greys differing by a few points of knob offset is
/// not a state indicator.
///
/// Drawing the track ourselves sidesteps the desaturation entirely, because the
/// color is ours rather than something AppKit dims on our behalf. It also lets
/// the control be sized to suit a menu row, which NSSwitch does not allow — its
/// size is fixed by the system.
///
/// Note this is deliberately NOT a general-purpose control. It does what these
/// two menu rows need and nothing more.
@MainActor
final class SwitchControl: NSView {
    /// Called when a click toggles the switch. The argument is the new value.
    var onToggle: ((Bool) -> Void)?

    private(set) var isOn: Bool

    /// Sized down from NSSwitch's fixed footprint so the row reads as a menu row
    /// rather than a settings pane. The proportions still follow the platform
    /// shape: a track twice as wide as it is tall, with a round knob just inside.
    static let controlWidth: CGFloat = 30
    static let controlHeight: CGFloat = 16
    private static let knobInset: CGFloat = 2

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: SwitchControl.controlWidth, height: SwitchControl.controlHeight))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SwitchControl is not loaded from a nib")
    }

    override var intrinsicContentSize: NSSize {
        return NSSize(width: SwitchControl.controlWidth, height: SwitchControl.controlHeight)
    }

    /// Updates the visible state without notifying the caller. Used when the value
    /// changes from somewhere other than a click on this control.
    func setOn(_ newValue: Bool) {
        isOn = newValue
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds
        let radius = track.height / 2

        // The on color is taken from controlAccentColor but forced to full
        // saturation by resolving it in a context AppKit does not dim: reading its
        // sRGB components and rebuilding the color. Using controlAccentColor
        // directly here would reintroduce the exact desaturation this class exists
        // to avoid.
        let trackColor: NSColor
        if isOn {
            trackColor = SwitchControl.fullSaturationAccent()
        } else {
            // A visibly darker/lighter track than the knob in both appearances, so
            // off reads as off without relying on color vision.
            trackColor = NSColor.tertiaryLabelColor
        }
        trackColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        // The knob is always the same near-white in both appearances, matching how
        // the platform draws it, so the moving part stays the high-contrast element.
        let knobDiameter = track.height - SwitchControl.knobInset * 2
        let knobX: CGFloat
        if isOn {
            knobX = track.maxX - knobDiameter - SwitchControl.knobInset
        } else {
            knobX = track.minX + SwitchControl.knobInset
        }
        let knobRect = NSRect(
            x: knobX,
            y: track.minY + SwitchControl.knobInset,
            width: knobDiameter,
            height: knobDiameter
        )
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
    }

    /// controlAccentColor with the window-inactive dimming removed.
    ///
    /// AppKit decides whether to desaturate based on the drawing context's window
    /// state, which a menu always reports as inactive. Converting to sRGB pins the
    /// components at their undimmed values, so the blue survives into the menu.
    private static func fullSaturationAccent() -> NSColor {
        guard let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else {
            // systemBlue is the default accent, so this fallback keeps the on state
            // blue rather than dropping to something meaningless.
            return .systemBlue
        }
        return NSColor(
            srgbRed: accent.redComponent,
            green: accent.greenComponent,
            blue: accent.blueComponent,
            alpha: 1
        )
    }

    override func mouseDown(with event: NSEvent) {
        // Handled here rather than on the row so a click on the control itself
        // toggles exactly once; the row's own handler checks for this.
        toggle()
    }

    func toggle() {
        isOn = isOn == false
        needsDisplay = true
        onToggle?(isOn)
    }
}
