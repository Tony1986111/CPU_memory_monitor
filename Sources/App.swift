import AppKit
import ServiceManagement

/// App entry point: runs as a background accessory app with no Dock icon.
@main
enum CPUMemoryMonitorApp {
    private static let delegate = AppDelegate()

    /// Starts the AppKit run loop.
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Wires up sampling, the notch island and a small status-bar menu (launch at login, quit).
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = SystemMonitor()
    private var island: IslandController?
    private var statusItem: NSStatusItem?
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private var screensAsleep = false
    private var sessionInactive = false

    /// Starts sampling and shows the island once AppKit is ready.
    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.start()
        island = IslandController(monitor: monitor)
        setUpStatusItem()
        pauseSamplingWhileUnseen()
    }

    /// Stops sampling while the displays sleep or another user session is active, when nobody can see the numbers.
    private func pauseSamplingWhileUnseen() {
        let center = NSWorkspace.shared.notificationCenter
        let observe = { (name: Notification.Name, update: @escaping (AppDelegate) -> Void) in
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                update(self)
                if self.screensAsleep || self.sessionInactive { self.monitor.stop() } else { self.monitor.start() }
            }
        }
        observe(NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        observe(NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "CPU and Memory Monitor")

        let menu = NSMenu()
        menu.delegate = self
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    /// Refreshes the login-item checkmark each time the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the Launch at Login setting"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
