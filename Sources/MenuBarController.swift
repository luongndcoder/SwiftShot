import AppKit
import SwiftUI

/// Builds the NSStatusItem menu-bar icon + dropdown.
@MainActor
final class MenuBarController {
    private var statusItem: NSStatusItem?
    /// Weak to avoid a retain cycle with `AppState` (which owns this controller).
    private weak var appState: AppState?
    private var settingsWindow: NSWindow?

    private var permissionIndicator: NSMenuItem?
    private var lastPermissionGranted: Bool?
    private var elapsedIndicator: NSMenuItem?
    private var recordingTimer: Timer?

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
        lastPermissionGranted = granted
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
        label.alignment = .center
        label.textColor = isError ? .systemRed : .labelColor
        label.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(label)
        label.frame = (panel.contentView?.bounds ?? panel.frame).insetBy(dx: 12, dy: 8)

        // Position near the status item, above the menu bar.
        if let button = statusItem?.button, let window = button.window {
            let screen = window.screen ?? NSScreen.main
            let originY = (screen?.frame.maxY ?? 0) - 70
            let frame = NSRect(x: window.frame.midX - 130, y: originY, width: 260, height: 44)
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

        if appState?.isRecordingNow == true {
            let elapsedItem = NSMenuItem(title: "● Recording 00:00", action: nil, keyEquivalent: "")
            elapsedItem.isEnabled = false
            menu.addItem(elapsedItem)
            elapsedIndicator = elapsedItem

            let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecordAction), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)
        } else {
            elapsedIndicator = nil

            let recordFullItem = NSMenuItem(title: "Record Full Screen", action: #selector(recordFullAction), keyEquivalent: "")
            recordFullItem.target = self
            menu.addItem(recordFullItem)

            let recordRegionItem = NSMenuItem(title: "Record Region…", action: #selector(recordRegionAction), keyEquivalent: "")
            recordRegionItem.target = self
            menu.addItem(recordRegionItem)
        }

        menu.addItem(.separator())

        // The menu is rebuilt when the recording state flips; keep showing the
        // last known permission state instead of falling back to "Checking…"
        // (the permission poller only reports *changes*, so it might never
        // correct a reset title again).
        let permissionTitle: String
        switch lastPermissionGranted {
        case .some(true): permissionTitle = "Screen Recording: Granted ✓"
        case .some(false): permissionTitle = "Screen Recording: Needs Permission"
        case .none: permissionTitle = "Screen Recording: Checking…"
        }
        let permissionItem = NSMenuItem(title: permissionTitle, action: nil, keyEquivalent: "")
        permissionItem.isEnabled = false
        menu.addItem(permissionItem)
        permissionIndicator = permissionItem

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(settingsAction), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesAction), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SwiftShot", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func captureAction() {
        appState?.startRegionCapture()
    }

    @objc private func checkForUpdatesAction() {
        appState?.checkForUpdates()
    }

    @objc private func recordFullAction() {
        appState?.startFullScreenRecording()
    }

    @objc private func recordRegionAction() {
        appState?.startRegionRecordingPicker()
    }

    @objc private func stopRecordAction() {
        appState?.stopRecording()
    }

    // MARK: - Recording state

    /// Rebuilds the menu for the new recording state and runs the elapsed timer.
    func setRecording(_ recording: Bool) {
        recordingTimer?.invalidate()
        recordingTimer = nil
        if recording {
            updateElapsed()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateElapsed()
                }
            }
        } else {
            statusItem?.button?.title = ""
        }
        rebuildMenu()
        if recording {
            updateElapsed()
        }
    }

    private func updateElapsed() {
        guard let startedAt = appState?.recordingStartedAt else { return }
        let total = max(0, Int(Date().timeIntervalSince(startedAt)))
        let text = total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
        elapsedIndicator?.title = "● Recording \(text)"
        statusItem?.button?.title = " \(text)"
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

        guard let settings = appState?.settings else { return }

        let hostingView = NSHostingView(rootView: SettingsView(settings: settings))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
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
