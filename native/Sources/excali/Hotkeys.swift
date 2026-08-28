import AppKit
import Carbon.HIToolbox

/// Registers system-wide global hotkeys via Carbon (works regardless of app activation).
final class HotkeyManager {
    private var refs: [EventHotKeyRef?] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x4558_4C49 // 'EXLI'

    init() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                if let handler = mgr.handlers[hkID.id] {
                    DispatchQueue.main.async { handler() }
                }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    /// Register (id -> handler). Call `unregisterAll()` first to rebind.
    func register(id: UInt32, hotkey: Hotkey, handler: @escaping () -> Void) {
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: signature, id: id)
        RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    func unregisterAll() {
        for ref in refs where ref != nil { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
    }
}
