/// Everything the app needs from the window system.
///
/// This protocol exists so SwitchCoordinator can be tested without AppKit. The
/// real implementation is AppMonitor (Task 6).
protocol AppMonitoring: AnyObject {
    /// Bundle ID of the frontmost app right now, or nil if unknown.
    var frontmostBundleID: String? { get }

    /// Called when an app has become frontmost AND stayed frontmost long enough
    /// to count as a real switch. Transient focus (Spotlight, notification
    /// banners) is filtered out before this fires. The value is a bundle ID.
    var onAppActivated: ((String) -> Void)? { get set }
}
