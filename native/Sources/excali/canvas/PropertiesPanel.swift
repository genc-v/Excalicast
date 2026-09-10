import AppKit

/// Excalidraw-style properties panel: appears on the left when a creating tool is active or an item
/// is selected. Sets stroke color, fill, stroke width, and font size — applied to the selection (or
/// the tool defaults for the next element). With advanced options on, adds a custom color picker and
/// an arbitrary stroke-width field.
final class PropertiesPanel: NSView {
    var onStroke: ((String) -> Void)?
    var onFill: ((String) -> Void)?
    var onWidth: ((CGFloat) -> Void)?
    var onFont: ((CGFloat) -> Void)?

    static let strokeColors = ["#1e1e1e", "#e03131", "#2f9e44", "#1971c2", "#f08c00"]
    static let fillColors = ["transparent", "#ffc9c9", "#b2f2bb", "#a5d8ff", "#ffec99"]
    private static let widths: [CGFloat] = [1, 2, 4]
    private static let fonts: [CGFloat] = [16, 20, 28, 40]

    private var strokeSwatches: [NSButton] = []
    private var fillSwatches: [NSButton] = []
    private let widthSeg = NSSegmentedControl(labels: ["S", "M", "L"], trackingMode: .selectOne, target: nil, action: nil)
    private let fontSeg = NSSegmentedControl(labels: ["S", "M", "L", "XL"], trackingMode: .selectOne, target: nil, action: nil)
    private let widthField = NSTextField()
    private let fillSection = NSStackView()
    private let widthSection = NSStackView()
    private let fontSection = NSStackView()
    private let root = NSStackView()

    private var pickingFill = false
    private var currentStroke = "#1e1e1e"
    private var currentFill = "transparent"

    init() {
        super.init(frame: .zero)
        let bg = NSVisualEffectView()
        bg.material = .hudWindow; bg.blendingMode = .withinWindow; bg.state = .active
        bg.wantsLayer = true; bg.layer?.cornerRadius = 12
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)

        root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        root.addArrangedSubview(section("Stroke", swatchRow(&strokeSwatches, Self.strokeColors,
                                                            #selector(strokeTapped(_:)), #selector(pickStroke))))

        fillSection.orientation = .vertical; fillSection.alignment = .leading; fillSection.spacing = 4
        fillSection.addArrangedSubview(section("Background", swatchRow(&fillSwatches, Self.fillColors,
                                                                       #selector(fillTapped(_:)), #selector(pickFill))))
        root.addArrangedSubview(fillSection)

        widthSeg.target = self; widthSeg.action = #selector(widthChanged)
        widthField.formatter = NumberFormatter()
        widthField.placeholderString = "px"
        widthField.alignment = .right
        widthField.target = self; widthField.action = #selector(widthFieldChanged)
        widthField.translatesAutoresizingMaskIntoConstraints = false
        widthField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let widthRow = NSStackView(views: [widthSeg, widthField])
        widthRow.orientation = .horizontal; widthRow.spacing = 8
        widthSection.orientation = .vertical; widthSection.alignment = .leading; widthSection.spacing = 4
        widthSection.addArrangedSubview(section("Stroke width", widthRow))
        root.addArrangedSubview(widthSection)

        fontSection.orientation = .vertical; fontSection.alignment = .leading; fontSection.spacing = 4
        fontSeg.target = self; fontSeg.action = #selector(fontChanged)
        fontSection.addArrangedSubview(section("Font size", fontSeg))
        root.addArrangedSubview(fontSection)

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: leadingAnchor), bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            bg.topAnchor.constraint(equalTo: topAnchor), bg.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor), root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor), root.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build helpers

    private func section(_ title: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .secondaryLabelColor
        let s = NSStackView(views: [l, control])
        s.orientation = .vertical; s.alignment = .leading; s.spacing = 4
        return s
    }

    private func swatchRow(_ store: inout [NSButton], _ colors: [String], _ action: Selector, _ custom: Selector) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal; row.spacing = 6
        for (i, hex) in colors.enumerated() {
            let b = makeSwatch(); b.tag = i; b.action = action; b.target = self
            if hex == "transparent" {
                b.layer?.backgroundColor = NSColor.clear.cgColor
                b.title = "⊘"; b.contentTintColor = .secondaryLabelColor
            } else {
                b.layer?.backgroundColor = (NSColor.fromHex(hex) ?? .gray).cgColor
            }
            store.append(b); row.addArrangedSubview(b)
        }
        let picker = makeSwatch(); picker.title = "＋"; picker.action = custom; picker.target = self
        picker.contentTintColor = .secondaryLabelColor
        picker.layer?.backgroundColor = NSColor.clear.cgColor
        picker.toolTip = "Custom color…"
        row.addArrangedSubview(picker)
        return row
    }

    private func makeSwatch() -> NSButton {
        let b = NSButton(title: "", target: nil, action: nil)
        b.isBordered = false; b.wantsLayer = true
        b.layer?.cornerRadius = 5; b.layer?.borderWidth = 1
        b.layer?.borderColor = NSColor.separatorColor.cgColor
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    // MARK: - State

    func configure(stroke: String, fill: String, width: CGFloat, fontSize: CGFloat,
                   showFill: Bool, showWidth: Bool, showFont: Bool, advanced: Bool) {
        currentStroke = stroke; currentFill = fill
        highlight(strokeSwatches, Self.strokeColors.firstIndex(of: stroke))
        highlight(fillSwatches, Self.fillColors.firstIndex(of: fill))
        widthSeg.selectedSegment = Self.widths.firstIndex(of: width) ?? -1
        fontSeg.selectedSegment = Self.fonts.firstIndex(of: fontSize) ?? -1
        widthField.stringValue = "\(Int(width))"
        widthField.isHidden = !advanced
        fillSection.isHidden = !showFill
        widthSection.isHidden = !showWidth
        fontSection.isHidden = !showFont
    }

    private func highlight(_ swatches: [NSButton], _ selected: Int?) {
        for (i, b) in swatches.enumerated() {
            let on = i == selected
            b.layer?.borderColor = (on ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            b.layer?.borderWidth = on ? 2.5 : 1
        }
    }

    @objc private func strokeTapped(_ s: NSButton) { onStroke?(Self.strokeColors[s.tag]) }
    @objc private func fillTapped(_ s: NSButton) { onFill?(Self.fillColors[s.tag]) }
    @objc private func widthChanged() { if widthSeg.selectedSegment >= 0 { onWidth?(Self.widths[widthSeg.selectedSegment]) } }
    @objc private func fontChanged() { if fontSeg.selectedSegment >= 0 { onFont?(Self.fonts[fontSeg.selectedSegment]) } }
    @objc private func widthFieldChanged() {
        let v = CGFloat(widthField.doubleValue)
        if v > 0 { onWidth?(v) } // no upper cap — go as astronomical as you like
    }

    // MARK: - Custom color picker

    @objc private func pickStroke() { openColorPanel(fill: false) }
    @objc private func pickFill() { openColorPanel(fill: true) }

    private func openColorPanel(fill: Bool) {
        pickingFill = fill
        let cp = NSColorPanel.shared
        cp.setTarget(self)
        cp.setAction(#selector(colorPicked(_:)))
        cp.color = NSColor.fromHex(fill ? currentFill : currentStroke) ?? .black
        // Float above the screenSaver-level overlay so it's actually reachable.
        cp.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        cp.makeKeyAndOrderFront(nil)
    }

    @objc private func colorPicked(_ cp: NSColorPanel) {
        let hex = cp.color.toHex()
        if pickingFill { onFill?(hex) } else { onStroke?(hex) }
    }
}

extension NSColor {
    /// "#rrggbb" for the sRGB representation of this color.
    func toHex() -> String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
