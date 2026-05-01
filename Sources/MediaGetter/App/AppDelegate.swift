import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if ProcessInfo.processInfo.arguments.contains("-uitest-compact-window") {
            DispatchQueue.main.async {
                NSApp.windows.first?.setContentSize(
                    NSSize(
                        width: LayoutMetrics.minimumWindowWidth,
                        height: LayoutMetrics.minimumWindowHeight
                    )
                )
            }
        }
    }
}
