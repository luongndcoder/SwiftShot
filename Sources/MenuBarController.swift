import AppKit
import SwiftUI

/// Builds the NSStatusItem menu-bar icon + dropdown.
@MainActor
final class MenuBarController {
    private var statusItem: NSStatusItem?
    private var appState: AppState?
    private var settingsWindow: NSWindow?

    private var permissionIndicator: NSMenuItem?

    func configure(with state: AppState) {
        self.appState = state
    }

    func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let imageURL = Bundle.main.url(forResource: "MenuIcon", withExtension: "png"),
           let img = NSImage(contentsOf: imageURL) {
            img.isTemplate = true
            statusItem?.button?.image = img
        } else {
            statusItem?.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SwiftShot")
        }
        rebuildMenu()
    }

    func updatePermissionStatus(_ granted: Bool) {
        permissionIndicator?.title = granted ? "Screen Recording: Granted ✓" : "Screen Recording: Needs Permission"
    }

    func showError(_ message: String) {
        showTransient(message, isError: true)
    }

    func showTransient(_ message: String, isError: Bool = false) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = NSColor.clear
        panel.isOpaque = false
        panel.hasShadow = true

        let label = NSTextField(labelWithString: message)
        label.frame = panel.contentView!.bounds.insetBy(dx: 12, dy: 8)
        label.alignment = .center
        label.textColor = isError ? .systemRed : .labelColor
        label.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(label)

        // Position near the status item, above the menu bar.
        if let button = statusItem?.button, let window = button.window {
            let screen = window.screen ?? NSScreen.main!
            let frame = NSRect(x: window.frame.midX - 130, y: screen.frame.maxY - 70, width: 260, height: 44)
            panel.setFrame(frame, display: true)
        }
        panel.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            panel.orderOut(nil)
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()

        let captureItem = NSMenuItem(title: "Capture Region", action: #selector(captureAction), keyEquivalent: "4")
        captureItem.keyEquivalentModifierMask = [.shift, .command]
        captureItem.target = self
        menu.addItem(captureItem)

        menu.addItem(.separator())

        let permissionTitle = "Screen Recording: Checking…"
        let permissionItem = NSMenuItem(title: permissionTitle, action: nil, keyEquivalent: "")
        permissionItem.isEnabled = false
        menu.addItem(permissionItem)
        permissionIndicator = permissionItem

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(settingsAction), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SwiftShot", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func captureAction() {
        appState?.startRegionCapture()
    }

    @objc private func settingsAction() {
        openSettings()
    }

    @objc private func quitAction() {
        appState?.quit()
    }

    // MARK: - Settings window

    func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: SettingsView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
        window.title = "SwiftShot Settings"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}
