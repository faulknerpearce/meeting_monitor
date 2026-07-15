import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let dockHideGracePeriod: TimeInterval = 0.25

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    static func revealWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    static func hideDockIfNoWindows() {
        DispatchQueue.main.asyncAfter(deadline: .now() + dockHideGracePeriod) {
            let visible = NSApp.windows.contains {
                $0.isVisible && $0.styleMask.contains(.titled) && $0.canBecomeKey
            }
            if !visible {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
