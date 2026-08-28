import AppKit

// Menu-bar (accessory) app: no Dock icon, driven by a status item + global hotkeys.
let app = ExcaliApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
