import AppKit

/// Excalidraw-style properties panel: appears on the left when a creating tool is active or an item
/// is selected. Lets you set stroke color, fill, stroke width, and font size — applied to the
/// selection (or the tool defaults for the next element).
final class PropertiesPanel: NSView {
    var onStroke: ((String) -> Void)?
    var onFill: ((String) -> Void)?
    var onWidth: ((CGFloat) -> Void)?
    var onFont: ((CGFloat) -> Void)?

    // Excalidraw's default palettes.
    static let strokeColors = ["#1e1e1e", "#e03131", "#2f9e44", "#1971c2", "#f08c00"]
    static let fillColors = ["transparent", "#ffc9c9", "#b2f2bb", "#a5d8ff", "#ffec99"]
    private static let widths: [CGFloat] = [1, 2, 4]
    private static let fonts: [CGFloat] = [16, 20, 28, 40]

    private var strokeSwatches: [NSButton] = []
    private var fillSwatches: [NSButton] = []
    private let widthSeg = NSSegmentedControl(labels: ["S", "M", "L"], trackingMode: .selectOne, target: nil, action: nil)
    private let fontSeg = NSSegmentedControl(labels: ["S", "M", "L", "XL"], trackingMode: .selectOne, target: nil, action: nil)
    private let fillSection = NSStackView()
    private let fontSection = NSStackView()
    private let root = NSStackView()

    init() {
        super.init(frame: .zero)
        let bg = NSVisualEffectView()
        bg.material = .hudWindow; bg.blendingMode = .withinWindow; bg.state = .active
        bg.wantsLayer = true; bg.layer?.cornerRadius = 12
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        root.addArrangedSubview(section(title: "Stroke", control: swatchRow(&strokeSwatches, Self.strokeColors, #selector(strokeTapped(_:)))))
        fillSection.orientation = .vertical; fillSection.alignment = .leading; fillSection.spacing = 4
        fillSection.addArrangedSubview(section(title: "Background", control: swatchRow(&fillSwatches, Self.fillColors, #selector(fillTapped(_:)))))
        root.addArrangedSubview(fillSection)

        widthSeg.target = self; widthSeg.action = #selector(widthChanged)
        root.addArrangedSubview(section(title: "Stroke width", control: widthSeg))

        fontSection.orientation = .vertical; fontSection.alignment = .leading; fontSection.spacing = 4
        fontSeg.target = self; fontSeg.action = #selector(fontChanged)
        fontSection.addArrangedSubview(section(title: "Font size", control: fontSeg))
        root.addArrangedSubview(fontSection)

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            bg.topAnchor.constraint(equalTo: topAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build helpers

    private func section(title: String, control: NSView) -> NSView {
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .secondaryLabelColor
        let s = NSStackView(views: [l, control])
        s.orientation = .vertical; s.alignment = .leading; s.spacing = 4
        return s
    }

    private func swatchRow(_ store: inout [NSButton], _ colors: [String], _ action: Selector) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal; row.spacing = 6
        for (i, hex) in colors.enumerated() {
            let b = NSButton(title: "", target: self, action: action)
            b.tag = i
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 5
            b.layer?.borderWidth = 1
            b.layer?.borderColor = NSColor.separatorColor.cgColor
            if hex == "transparent" {
                b.layer?.backgroundColor = NSColor.clear.cgColor
                b.title = "⊘"; b.contentTintColor = .secondaryLabelColor
            } else {
                b.layer?.backgroundColor = (NSColor.fromHex(hex) ?? .gray).cgColor
            }
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            store.append(b)
            row.addArrangedSubview(b)
        }
        return row
    }

    // MARK: - State

    /// Update controls to reflect current values and show/hide the fill/font sections.
    func configure(stroke: String, fill: String, width: CGFloat, fontSize: CGFloat,
                   showFill: Bool, showFont: Bool) {
        highlight(strokeSwatches, selected: Self.strokeColors.firstIndex(of: stroke))
        highlight(fillSwatches, selected: Self.fillColors.firstIndex(of: fill))
        widthSeg.selectedSegment = Self.widths.firstIndex(of: width) ?? -1
        fontSeg.selectedSegment = Self.fonts.firstIndex(of: fontSize) ?? -1
        fillSection.isHidden = !showFill
        fontSection.isHidden = !showFont
    }

    private func highlight(_ swatches: [NSButton], selected: Int?) {
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
}
