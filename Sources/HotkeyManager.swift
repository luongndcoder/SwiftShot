import AppKit
import Carbon.HIToolbox
import Combine

/// Registers a global system hotkey via Carbon's RegisterEventHotKey.
final class HotkeyManager {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var callback: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()

    /// Called when the requested hotkey could not be registered (e.g. already taken by another app).
    var onRegistrationError: ((String) -> Void)?

    func configure(action: @escaping () -> Void) {
        callback = action
    }

    /// Binds the hotkey from `settings` and keeps it in sync with later changes.
    func bind(settings: Settings) {
        // `@Published` replays the current value on subscribe, so the initial binding
        // happens through the sink — no extra `bind(combo:)` call here.
        settings.$hotkey
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] combo in
                self?.bind(combo: combo)
            }
            .store(in: &cancellables)
    }

    private func bind(combo: KeyCombo) {
        installEventHandlerIfNeeded()
        unregisterHotKey()

        let carbonFlags: UInt32 =
            (combo.modifiers.contains(.command) ? UInt32(cmdKey) : 0)
            | (combo.modifiers.contains(.shift) ? UInt32(shiftKey) : 0)
            | (combo.modifiers.contains(.control) ? UInt32(controlKey) : 0)
            | (combo.modifiers.contains(.option) ? UInt32(optionKey) : 0)

        let hotKeyID = EventHotKeyID(signature: FourCharCode(0x5353_5348), id: UInt32(combo.keyCode))
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            carbonFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            NSLog("[SwiftShot] RegisterEventHotKey failed for \(combo.displayString) (status \(status))")
            onRegistrationError?("Hotkey \(combo.displayString) is already in use by another app.")
        }
    }

    /// The Carbon event handler is installed exactly once — re-installing it on every
    /// rebind would leak the previous handler and fire the callback multiple times.
    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { (_, _, userData) -> OSStatus in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.callback?()
            }
            return noErr
        }, 1, &eventType, selfPointer, &eventHandler)
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    deinit {
        unregisterHotKey()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }
}
