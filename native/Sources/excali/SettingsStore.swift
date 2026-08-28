import Carbon.HIToolbox
import Foundation

/// A configurable global shortcut, stored as a Carbon keycode + Carbon modifier mask.
struct Hotkey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon: cmdKey | shiftKey | optionKey | controlKey
}

/// App settings persisted in UserDefaults. Defaults match the previous Tauri build.
enum SettingsStore {
    private static let d = UserDefaults.standard

    // Show the Excalidraw grid on the canvas (off by default).
    static var gridEnabled: Bool {
        get { d.object(forKey: "gridEnabled") as? Bool ?? false }
        set { d.set(newValue, forKey: "gridEnabled") }
    }

    // Ask (Save / Discard / Cancel) before clearing a whiteboard for a new one.
    static var confirmNewWhiteboard: Bool {
        get { d.object(forKey: "confirmNewWhiteboard") as? Bool ?? true }
        set { d.set(newValue, forKey: "confirmNewWhiteboard") }
    }

    // Ask to save on close if the overlay has been open at least this many seconds (0 = never).
    static var confirmCloseSeconds: Int {
        get { d.object(forKey: "confirmCloseSeconds") as? Int ?? 15 }
        set { d.set(newValue, forKey: "confirmCloseSeconds") }
    }

    // Keep at most this many non-pinned saved items; older ones are auto-deleted (0 = unlimited).
    static var maxItems: Int {
        get { d.object(forKey: "maxItems") as? Int ?? 50 }
        set { d.set(newValue, forKey: "maxItems") }
    }

    // Pinned file paths (never auto-deleted, shown in their own gallery section).
    static var pinnedPaths: Set<String> {
        get { Set(d.stringArray(forKey: "pinnedPaths") ?? []) }
        set { d.set(Array(newValue), forKey: "pinnedPaths") }
    }
    static func isPinned(_ path: String) -> Bool { pinnedPaths.contains(path) }
    static func togglePin(_ path: String) {
        var s = pinnedPaths
        if s.contains(path) { s.remove(path) } else { s.insert(path) }
        pinnedPaths = s
    }

    /// Absolute folder for saved files; empty means the app's default (~/Documents/Excalicast).
    static var saveDir: String {
        get { d.string(forKey: "saveDir") ?? "" }
        set { d.set(newValue, forKey: "saveDir") }
    }

    /// The effective save folder (created if needed). Defaults to ~/Documents/Excalicast.
    static func resolvedSaveDir() -> String {
        let dir = saveDir.isEmpty ? "\(NSHomeDirectory())/Documents/Excalicast" : saveDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static let defaultAnnotate = Hotkey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | shiftKey))
    static let defaultWhiteboard = Hotkey(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey | shiftKey))
    static let defaultRecenter = Hotkey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | shiftKey))
    static let defaultDismiss = Hotkey(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(cmdKey | shiftKey))
    static let defaultOpenGallery = Hotkey(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(cmdKey | shiftKey))

    private static func hotkey(_ key: String, _ fallback: Hotkey) -> Hotkey {
        let code = d.object(forKey: "\(key).code") as? Int
        let mods = d.object(forKey: "\(key).mods") as? Int
        if let code, let mods { return Hotkey(keyCode: UInt32(code), modifiers: UInt32(mods)) }
        return fallback
    }

    private static func setHotkey(_ key: String, _ hk: Hotkey) {
        d.set(Int(hk.keyCode), forKey: "\(key).code")
        d.set(Int(hk.modifiers), forKey: "\(key).mods")
    }

    static var annotate: Hotkey {
        get { hotkey("hk.annotate", defaultAnnotate) }
        set { setHotkey("hk.annotate", newValue) }
    }
    static var whiteboard: Hotkey {
        get { hotkey("hk.whiteboard", defaultWhiteboard) }
        set { setHotkey("hk.whiteboard", newValue) }
    }
    static var recenter: Hotkey {
        get { hotkey("hk.recenter", defaultRecenter) }
        set { setHotkey("hk.recenter", newValue) }
    }
    static var dismiss: Hotkey {
        get { hotkey("hk.dismiss", defaultDismiss) }
        set { setHotkey("hk.dismiss", newValue) }
    }
    static var openGallery: Hotkey {
        get { hotkey("hk.open", defaultOpenGallery) }
        set { setHotkey("hk.open", newValue) }
    }
}
