import AppKit
import Carbon.HIToolbox
import CoreGraphics
import SwiftUI

// MARK: - Hotkey display / capture helpers

func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if flags.contains(.command) { m |= UInt32(cmdKey) }
    if flags.contains(.shift) { m |= UInt32(shiftKey) }
    if flags.contains(.option) { m |= UInt32(optionKey) }
    if flags.contains(.control) { m |= UInt32(controlKey) }
    return m
}

private let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

func keyLabel(_ keyCode: UInt32) -> String {
    let map: [Int: String] = [
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z", kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "esc",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Slash: "/",
        kVK_ANSI_Period: ".", kVK_ANSI_Comma: ",",
    ]
    return map[Int(keyCode)] ?? "key\(keyCode)"
}

func hotkeyLabel(_ hk: Hotkey) -> String {
    var s = ""
    if hk.modifiers & UInt32(controlKey) != 0 { s += "⌃" }
    if hk.modifiers & UInt32(optionKey) != 0 { s += "⌥" }
    if hk.modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
    if hk.modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
    return s + keyLabel(hk.keyCode)
}

// MARK: - Settings window controller

final class SettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onChanged: () -> Void

    init(onChanged: @escaping () -> Void) {
        self.onChanged = onChanged
    }

    func show() {
        if window == nil {
            let view = SettingsView(onChanged: onChanged)
            let hosting = NSHostingController(rootView: view)
            let w = NSWindow(contentViewController: hosting)
            w.title = "Excalicast Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.setContentSize(NSSize(width: 480, height: 500))
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        // Promote to a regular app so the settings window reliably comes to the front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only app.
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - SwiftUI view

struct SettingsView: View {
    let onChanged: () -> Void

    @State private var advanced = SettingsStore.advancedOptions
    @State private var theme = SettingsStore.theme
    @State private var strokeWidth = SettingsStore.strokeWidth
    @State private var maxItems = SettingsStore.maxItems
    @State private var trashWarning = 0
    @State private var saveDir = SettingsStore.saveDir
    @State private var annotate = SettingsStore.annotate
    @State private var whiteboard = SettingsStore.whiteboard
    @State private var openGallery = SettingsStore.openGallery
    @State private var recenter = SettingsStore.recenter
    @State private var dismiss = SettingsStore.dismiss
    @State private var recording: Int? = nil
    @State private var monitor: Any? = nil
    @State private var permission = CGPreflightScreenCaptureAccess()

    var body: some View {
        Form {
            Section("Canvas") {
                Picker("Theme", selection: $theme) {
                    Text("Follow system").tag(SettingsStore.Theme.auto)
                    Text("Light").tag(SettingsStore.Theme.light)
                    Text("Dark").tag(SettingsStore.Theme.dark)
                }
                .onChange(of: theme) { _, v in SettingsStore.theme = v; onChanged() }

                Picker("Default stroke", selection: $strokeWidth) {
                    Text("Thin").tag(1.0)
                    Text("Medium").tag(2.0)
                    Text("Bold").tag(4.0)
                }
                .onChange(of: strokeWidth) { _, v in SettingsStore.strokeWidth = v; onChanged() }

                Toggle("Advanced style options (custom colors + any stroke width)", isOn: $advanced)
                    .onChange(of: advanced) { _, v in
                        SettingsStore.advancedOptions = v; onChanged()
                    }
                HStack {
                    Text("Saved items")
                    Spacer()
                    TextField("0", value: $maxItems, formatter: NumberFormatter())
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: maxItems) { _, v in
                            let n = max(0, v)
                            SettingsStore.maxItems = n
                            trashWarning = (n > 0 && SavedDocuments.nonPinnedCount() > n)
                                ? SavedDocuments.nonPinnedCount() - n
                                : 0
                            onChanged()
                        }
                }
                Text("How many documents to keep. 0 means infinite — every document is kept. Pinned items are never counted. Older items beyond this number are moved to the Trash (not permanently deleted).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if trashWarning > 0 {
                    Label("Lowering this from infinite will move \(trashWarning) older item\(trashWarning == 1 ? "" : "s") to the Trash.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("Shortcuts") {
                hotkeyRow("Annotate screen", index: 1, value: annotate)
                hotkeyRow("New whiteboard", index: 4, value: whiteboard)
                hotkeyRow("Open saved…", index: 5, value: openGallery)
                hotkeyRow("Recenter / open last", index: 2, value: recenter)
                hotkeyRow("Dismiss overlay", index: 3, value: dismiss)
            }
            Section("Save location") {
                HStack {
                    Text(saveDir.isEmpty ? "~/Documents/Excalicast (default)" : saveDir)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if !saveDir.isEmpty {
                        Button("Reset") { saveDir = ""; SettingsStore.saveDir = "" }
                    }
                    Button("Choose…") { chooseFolder() }
                }
                Text("Save writes a .png and an editable .excalidraw file here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Permission") {
                HStack {
                    Text("Screen Recording")
                    Spacer()
                    Text(permission ? "Granted" : "Not granted")
                        .foregroundStyle(permission ? .green : .red)
                    if !permission {
                        Button("Grant…") { grant() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    @ViewBuilder
    private func hotkeyRow(_ title: String, index: Int, value: Hotkey) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(recording == index ? "Press keys…" : hotkeyLabel(value)) {
                toggleRecording(index)
            }
            .buttonStyle(.bordered)
            .frame(minWidth: 96)
        }
    }

    private func toggleRecording(_ index: Int) {
        if recording == index { stopRecording(); return }
        stopRecording()
        recording = index
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stopRecording(); return nil }
            if modifierKeyCodes.contains(event.keyCode) { return nil }
            let mods = carbonModifiers(from: event.modifierFlags)
            if mods == 0 { return nil } // require a modifier
            let hk = Hotkey(keyCode: UInt32(event.keyCode), modifiers: mods)
            apply(hk, to: index)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recording = nil
    }

    private func apply(_ hk: Hotkey, to index: Int) {
        switch index {
        case 1: annotate = hk; SettingsStore.annotate = hk
        case 2: recenter = hk; SettingsStore.recenter = hk
        case 3: dismiss = hk; SettingsStore.dismiss = hk
        case 4: whiteboard = hk; SettingsStore.whiteboard = hk
        case 5: openGallery = hk; SettingsStore.openGallery = hk
        default: break
        }
        onChanged()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            saveDir = url.path
            SettingsStore.saveDir = url.path
        }
    }

    private func grant() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        permission = CGPreflightScreenCaptureAccess()
    }
}
