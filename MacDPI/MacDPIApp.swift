import AppKit

/// AppKit owns window/termination lifetime; SwiftUI renders the complete interface.
@main
enum MacDPIApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
