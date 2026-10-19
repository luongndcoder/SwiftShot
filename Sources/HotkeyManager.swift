import AppKit
import Carbon.HIToolbox
import Combine

/// Registers a global system hotkey via Carbon's RegisterEventHotKey.
final class HotkeyManager {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var callback: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()
    private var currentCombo: KeyCombo?

    func configure(action: @escaping () -> Void) {
        callback = action
    }

    /// Binds a new KeyCombo, unregistering any previous registration.
    func bind(settings: Settings) {
        settings.$hotkey
            .removeDuplicates()
            .sink { [weak self] combo in
                self?.bind(combo: combo)
            }
            .store(in: &cancellables)
        bind(combo: settings.hotkey)
    }

    private func bind(combo: KeyCombo) {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        currentCombo = combo

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

        let carbonFlags: UInt32 =
            (combo.modifiers.contains(.command) ? UInt32(cmdKey) : 0)
            | (combo.modifiers.contains(.shift) ? UInt32(shiftKey) : 0)
            | (combo.modifiers.contains(.control) ? UInt32(controlKey) : 0)
            | (combo.modifiers.contains(.option) ? UInt32(optionKey) : 0)

        let hotKeyID = EventHotKeyID(signature: FourCharCode(0x5353_5348), id: UInt32(combo.key.keyCode))
        RegisterEventHotKey(UInt32(combo.key.keyCode), carbonFlags, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let handler = eventHandler { RemoveEventHandler(handler) }
    }
}
