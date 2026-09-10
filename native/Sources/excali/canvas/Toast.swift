import AppKit

/// A small transient HUD message ("Saved", "Copied to clipboard", …) so users learn what the
/// action buttons do without reading docs. Fades in on `show`, auto-fades after a moment.
final class ToastView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.blendingMode = .withinWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            bg.topAnchor.constraint(equalTo: topAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, duration: TimeInterval = 1.8) {
        label.stringValue = text
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.4; self?.animator().alphaValue = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
