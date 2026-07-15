import AppKit
import AFrameKit

/// A channel-strip pan control sized for the mixer console band: a short
/// slider with the hardware-style readout ("C00"/"L63"/"R32") beside it, and —
/// for `.panWithMode` params — the pressure-pan category/variant popups on a
/// second row. Double-click recenters to C00, keeping the mode.
final class CompactPanView: NSView {
    let descriptor: ParameterDescriptor
    var onChange: ((Int) -> Void)?

    private(set) var value: Int

    private let slider: NSSlider
    private let valueLabel = NSTextField(labelWithString: "")
    private var categoryPopup: NSPopUpButton?
    private var variantPopup: NSPopUpButton?

    private var hasMode: Bool {
        if case .panWithMode = descriptor.display { return true }
        return false
    }

    init(descriptor: ParameterDescriptor, value: Int) {
        self.descriptor = descriptor
        self.value = value
        slider = NSSlider(value: 64,
                          minValue: Double(PanMap.positionRange.lowerBound),
                          maxValue: Double(PanMap.positionRange.upperBound),
                          target: nil, action: nil)
        super.init(frame: .zero)
        build()
        apply(value: value)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        toolTip = descriptor.name

        slider.controlSize = .mini
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        // Fixed width keeps the slider snug against its readout, so the pair
        // reads as one control instead of a strip-wide slider with a distant
        // value floating at the far edge.
        slider.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let dbl = NSClickGestureRecognizer(target: self, action: #selector(recenter))
        dbl.numberOfClicksRequired = 2
        dbl.delaysPrimaryMouseButtonEvents = false
        slider.addGestureRecognizer(dbl)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let panRow = NSStackView(views: [slider, valueLabel])
        panRow.orientation = .horizontal
        panRow.alignment = .centerY
        panRow.spacing = 5

        var rows: [NSView] = [panRow]

        if hasMode {
            let cat = NSPopUpButton(frame: .zero, pullsDown: false)
            cat.controlSize = .small
            cat.font = .systemFont(ofSize: 9.5)
            for (i, c) in PanMap.categories.enumerated() {
                cat.addItem(withTitle: c.name)
                cat.lastItem?.tag = i
            }
            cat.target = self
            cat.action = #selector(categoryChanged)
            categoryPopup = cat

            let variant = NSPopUpButton(frame: .zero, pullsDown: false)
            variant.controlSize = .small
            variant.font = .systemFont(ofSize: 9.5)
            variant.target = self
            variant.action = #selector(emitFromControls)
            variantPopup = variant

            let modeRow = NSStackView(views: [cat, variant])
            modeRow.orientation = .horizontal
            modeRow.spacing = 3
            modeRow.distribution = .fillEqually
            rows.append(modeRow)
        } else {
            // Placeholder matching the mode row's height, so strips without
            // pressure-pan popups (Dry C/E, Master Bal) keep their faders on
            // the same line as the strips that have them.
            let placeholder = NSView()
            placeholder.heightAnchor.constraint(equalToConstant: 19).isActive = true
            rows.append(placeholder)
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // The slider + readout pair stays centered at its natural width; only
        // the mode popups spread across the strip.
        if hasMode, let modeRow = rows.dropFirst().first {
            modeRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    /// Fills the variant popup for a category; "Off" has no variants, so the
    /// popup shows a disabled placeholder (mirrors ParameterRowView's pan).
    private func repopulateVariants(category: Int, select: Int) {
        guard let variant = variantPopup else { return }
        variant.removeAllItems()
        let variants = PanMap.categories.indices.contains(category)
            ? PanMap.categories[category].variants : []
        if variants.isEmpty {
            variant.addItem(withTitle: "\u{2014}")
            variant.isEnabled = false
        } else {
            for (i, name) in variants.enumerated() {
                variant.addItem(withTitle: name)
                variant.lastItem?.tag = i
            }
            variant.selectItem(withTag: Swift.max(0, Swift.min(select, variants.count - 1)))
            variant.isEnabled = true
        }
    }

    /// Updates the controls without emitting a change.
    func apply(value newValue: Int) {
        value = newValue
        if hasMode {
            let v = PanValue(raw: newValue)
            slider.integerValue = v.position
            valueLabel.stringValue = PanMap.positionString(v.position)
            let (ci, vi) = PanMap.decompose(mode: v.mode)
            categoryPopup?.selectItem(withTag: ci)
            repopulateVariants(category: ci, select: vi)
        } else {
            slider.integerValue = newValue
            valueLabel.stringValue = PanMap.positionString(newValue)
        }
    }

    @objc private func sliderChanged() { emitFromControls() }

    @objc private func categoryChanged() {
        repopulateVariants(category: categoryPopup?.selectedTag() ?? 0, select: 0)
        emitFromControls()
    }

    @objc private func recenter() {
        slider.integerValue = 64
        emitFromControls()
    }

    @objc private func emitFromControls() {
        let pos = slider.integerValue
        let newValue: Int
        if hasMode {
            let mode = PanMap.compose(category: categoryPopup?.selectedTag() ?? 0,
                                      variant: variantPopup?.selectedTag() ?? 0)
            newValue = PanValue(position: pos, mode: mode).raw
        } else {
            newValue = pos
        }
        value = newValue
        valueLabel.stringValue = PanMap.positionString(pos)
        onChange?(newValue)
    }
}

/// The Master strip's live L/R output meters: two mini vertical bars on the
/// aFrame's 0–15 peak scale, matching a VerticalFaderView's silhouette (title,
/// bar block sized like the slider, caption below) so they sit flush beside
/// the Lev fader.
final class StripMeterPairView: NSView {
    /// Fired on click; the owner opens the full Monitor window.
    var onOpen: (() -> Void)?

    private let bars = MeterBarsView()

    init() {
        super.init(frame: .zero)

        let title = NSTextField(labelWithString: "Out")
        title.font = .systemFont(ofSize: 10, weight: .medium)
        title.textColor = Palette.secondaryText
        title.alignment = .center

        bars.heightAnchor.constraint(equalToConstant: 100).isActive = true
        bars.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let caption = NSTextField(labelWithString: "L  R")
        caption.font = .systemFont(ofSize: 9, weight: .medium)
        caption.textColor = Palette.secondaryText
        caption.alignment = .center

        let stack = NSStackView(views: [title, bars, caption])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(6, after: bars)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
        ])
        setContentHuggingPriority(.required, for: .vertical)
        toolTip = "Live output level (L/R)"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if let onOpen { onOpen() } else { super.mouseDown(with: event) }
    }

    override func resetCursorRects() {
        if onOpen != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    func update(l: Int, r: Int) { bars.setValues(l: l, r: r) }
    func clear() { bars.setValues(l: 0, r: 0) }

    private final class MeterBarsView: NSView {
        private var l: Double = 0
        private var r: Double = 0
        private let maxValue = 15.0

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError() }

        func setValues(l: Int, r: Int) {
            self.l = Swift.min(Double(l), maxValue)
            self.r = Swift.min(Double(r), maxValue)
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let b = bounds
            let barW: CGFloat = 8, gap: CGFloat = 6
            let startX = b.midX - barW - gap / 2
            effectiveAppearance.performAsCurrentDrawingAppearance {
                for (i, v) in [l, r].enumerated() {
                    let track = NSRect(x: startX + CGFloat(i) * (barW + gap), y: 0,
                                       width: barW, height: b.height)
                    NSColor.separatorColor.withAlphaComponent(0.4).setFill()
                    NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
                    let frac = CGFloat(v / maxValue)
                    if frac > 0 {
                        let fill = NSRect(x: track.minX, y: 0,
                                          width: barW, height: track.height * frac)
                        (frac > 0.85 ? NSColor.systemRed
                            : frac > 0.6 ? .systemYellow : .systemGreen).setFill()
                        NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
                    }
                }
            }
        }
    }
}
