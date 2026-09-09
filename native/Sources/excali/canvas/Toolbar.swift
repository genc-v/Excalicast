import AppKit

/// A compact floating toolbar overlaid on the canvas: tool picker on the left, document actions on
/// the right. Communicates via callbacks; the controller owns the wiring.
final class ToolbarView: NSView {
    var onTool: ((Tool) -> Void)?
    var onAction: ((String) -> Void)?

    private var toolButtons: [Tool: NSButton] = [:]

    private static let tools: [(Tool, String, String)] = [
        (.select, "cursorarrow", "Select (V)"),
        (.rectangle, "rectangle", "Rectangle (R)"),
        (.diamond, "diamond", "Diamond (D)"),
        (.ellipse, "circle", "Ellipse (O)"),
        (.arrow, "arrow.up.right", "Arrow (A)"),
        (.line, "line.diagonal", "Line (L)"),
        (.text, "textformat", "Text (T)"),
    ]
    private static let actions: [(String, String, String)] = [
        ("new", "plus.square", "New whiteboard"),
        ("recenter", "scope", "Recenter"),
        ("copy", "doc.on.doc", "Copy to clipboard"),
        ("save", "square.and.arrow.down", "Save"),
        ("close", "xmark", "Close"),
    ]

    init() {
        super.init(frame: .zero)
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.blendingMode = .withinWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for (tool, symbol, tip) in Self.tools {
            let b = makeButton(symbol: symbol, tip: tip, action: #selector(toolTapped(_:)))
            b.tag = toolTag(tool)
            toolButtons[tool] = b
            stack.addArrangedSubview(b)
        }
        let sep = NSBox(); sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.heightAnchor.constraint(equalToConstant: 22).isActive = true
        stack.addArrangedSubview(sep)
        for (name, symbol, tip) in Self.actions {
            let b = makeButton(symbol: symbol, tip: tip, action: #selector(actionTapped(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(name)
            stack.addArrangedSubview(b)
        }

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            bg.topAnchor.constraint(equalTo: stack.topAnchor),
            bg.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        highlight(.select)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func makeButton(symbol: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.imageScaling = .scaleProportionallyDown
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.setButtonType(.momentaryChange)
        b.toolTip = tip
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }

    private func toolTag(_ t: Tool) -> Int { Self.tools.firstIndex { $0.0 == t } ?? 0 }

    @objc private func toolTapped(_ sender: NSButton) {
        let tool = Self.tools[sender.tag].0
        highlight(tool)
        onTool?(tool)
    }

    @objc private func actionTapped(_ sender: NSButton) {
        onAction?(sender.identifier?.rawValue ?? "")
    }

    /// Reflect the active tool (e.g. after a shape auto-reverts to select, or a keyboard shortcut).
    func highlight(_ tool: Tool) {
        for (t, b) in toolButtons {
            b.contentTintColor = (t == tool) ? .controlAccentColor : .secondaryLabelColor
        }
    }
}

/// A compact "− 100% +" zoom control (bottom-left, Excalidraw-style). Clicking the percentage
/// resets to 100%.
final class ZoomControlView: NSView {
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onReset: (() -> Void)?

    private let percentButton = NSButton()

    init() {
        super.init(frame: .zero)
        let bg = NSVisualEffectView()
        bg.material = .hudWindow; bg.blendingMode = .withinWindow; bg.state = .active
        bg.wantsLayer = true; bg.layer?.cornerRadius = 10
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)

        let minus = textButton("−", #selector(zoomOut))
        let plus = textButton("+", #selector(zoomIn))
        percentButton.title = "100%"
        percentButton.isBordered = false
        percentButton.bezelStyle = .texturedRounded
        percentButton.target = self
        percentButton.action = #selector(reset)
        percentButton.toolTip = "Reset to 100%"
        percentButton.setButtonType(.momentaryChange)
        percentButton.font = .systemFont(ofSize: 12, weight: .medium)

        let stack = NSStackView(views: [minus, percentButton, plus])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        percentButton.widthAnchor.constraint(equalToConstant: 46).isActive = true

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            bg.topAnchor.constraint(equalTo: topAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func textButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.bezelStyle = .texturedRounded
        b.setButtonType(.momentaryChange)
        b.font = .systemFont(ofSize: 15, weight: .medium)
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    func setZoom(_ z: CGFloat) { percentButton.title = "\(Int((z * 100).rounded()))%" }

    @objc private func zoomIn() { onZoomIn?() }
    @objc private func zoomOut() { onZoomOut?() }
    @objc private func reset() { onReset?() }
}
