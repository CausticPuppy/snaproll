import AppKit
import AFrameKit

/// One parameter row: name label + the control appropriate to the parameter's
/// display type + a formatted value readout. Emits raw Int values.
final class ParameterRowView: NSView {
    let descriptor: ParameterDescriptor
    let range: ClosedRange<Int>?
    var onChange: ((Int) -> Void)?

    /// Live sibling context for display types that fold in other parameter
    /// values (e.g. the mute readout's "ON(n)" needs the tone's Mute Sens).
    /// The editor sets this; the readout re-reads it on every render.
    var contextProvider: (() -> ParameterFormatter.Context)?

    private(set) var value: Int

    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let unitLabel = NSTextField(labelWithString: "")
    private var valueStack: NSStackView?

    /// Whether the value readout accepts typed input. Controls that already own
    /// their value (switch, enum popup) don't; slider-backed rows do, so wide
    /// ranges can be set precisely without fighting the slider's resolution.
    private var valueIsTypeable: Bool {
        switch descriptor.display {
        case .onOff, .enumerated, .tune, .scaleControl, .panWithMode: return false
        default: return true
        }
    }
    private var slider: NSSlider?
    private var modePopup: NSPopUpButton?  // levelWithMode mode selector
    private var enumPopup: NSPopUpButton?
    private var toggle: NSSwitch?

    // Tune control: Hz/Note mode toggle over a deck that swaps a Hz field for a
    // note popup + cents field. Avoids the single-slider trap of Tune's gapped,
    // two-band valid range by composing only valid values.
    private var tuneMode: NSSegmentedControl?
    private var tuneHzField: NSTextField?
    private var tuneHzView: NSView?
    private var tuneNotePopup: NSPopUpButton?
    private var tuneCentsField: NSTextField?
    private var tuneNoteView: NSView?

    // SC control: a scale popup (OFF, MTriad…Chrmtic) + a scale-control-mode
    // popup (13 modes). The mode popup is disabled while the scale is OFF.
    private var scScalePopup: NSPopUpButton?
    private var scModePopup: NSPopUpButton?

    // Pan control: an L/R position slider plus a pressure-pan category popup
    // that drives a dependent variant popup (the 12 modes group as 5 categories).
    private var panCategoryPopup: NSPopUpButton?
    private var panVariantPopup: NSPopUpButton?

    static let rowHeight: CGFloat = 26

    init(descriptor: ParameterDescriptor, range: ClosedRange<Int>?, value: Int) {
        self.descriptor = descriptor
        self.range = range
        self.value = value
        super.init(frame: .zero)
        build()
        apply(value: value)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Construction

    private func build() {
        nameLabel.stringValue = descriptor.name
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = Palette.parameterName
        nameLabel.alignment = .right
        nameLabel.lineBreakMode = .byTruncatingTail
        if case .custom(let note) = descriptor.display {
            toolTip = note
        } else if case .muteSensitivity = descriptor.display {
            toolTip = "0 = OFF · 1 = ON (uses the tone's Mute Sens) · ±N = per-tone sensitivity offset"
        } else if case .tune = descriptor.display {
            toolTip = "Tuning as absolute frequency (16–12544 Hz) or a note (C0–G9) plus cents (−50…+49)"
        } else if case .scaleControl = descriptor.display {
            toolTip = "Pressure scale: a musical scale plus one of 13 note-sequencing modes (arrows = up/down direction)"
        } else if case .panWithMode = descriptor.display {
            toolTip = "L/R pan position plus a pressure-pan mode (category + variant); Off = no pressure panning"
        }

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byClipping
        valueLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        if valueIsTypeable {
            valueLabel.isEditable = true
            valueLabel.isSelectable = true
            valueLabel.isBordered = true
            valueLabel.bezelStyle = .roundedBezel
            valueLabel.drawsBackground = true
            valueLabel.controlSize = .small
            valueLabel.focusRingType = .default
            valueLabel.target = self
            valueLabel.action = #selector(valueCommitted)
        }

        // Fixed units live in their own static label so the field holds only the
        // value (e.g. "123" | "Hz"). Empty when the parameter has no fixed unit.
        unitLabel.stringValue = ParameterFormatter.unit(for: descriptor.display) ?? ""
        unitLabel.font = .systemFont(ofSize: 11)
        unitLabel.textColor = Palette.secondaryText
        unitLabel.alignment = .left
        unitLabel.lineBreakMode = .byClipping
        unitLabel.setContentHuggingPriority(.required, for: .horizontal)
        unitLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Value + unit share the fixed-width readout column; the field fills
        // whatever the unit doesn't use, so the layout budget is unchanged.
        let valueStack = NSStackView(views: [valueLabel, unitLabel])
        valueStack.orientation = .horizontal
        valueStack.spacing = 3
        valueStack.alignment = .centerY
        valueStack.distribution = .fill
        self.valueStack = valueStack

        let control = makeControl()

        let stack = NSStackView(views: [nameLabel, control, valueStack])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: ParameterRowView.rowHeight),
            nameLabel.widthAnchor.constraint(equalToConstant: 104),
            valueStack.widthAnchor.constraint(equalToConstant: 78),
        ])
    }

    private func makeControl() -> NSView {
        switch descriptor.display {
        case .onOff:
            let sw = NSSwitch()
            sw.controlSize = .mini
            sw.target = self
            sw.action = #selector(toggleChanged)
            toggle = sw
            valueLabel.isHidden = false
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let stack = NSStackView(views: [sw, spacer])
            stack.orientation = .horizontal
            return stack

        case .enumerated(let labels):
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 11)
            for key in labels.keys.sorted() {
                popup.addItem(withTitle: labels[key]!)
                popup.lastItem?.tag = key
            }
            popup.target = self
            popup.action = #selector(enumChanged)
            enumPopup = popup
            valueStack?.isHidden = true
            return popup

        case .levelWithMode(let modes):
            let s = makeSlider(min: 0, max: 127)
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 10)
            for (i, mode) in modes.enumerated() {
                popup.addItem(withTitle: mode)
                popup.lastItem?.tag = i
            }
            popup.target = self
            popup.action = #selector(compositeChanged)
            popup.widthAnchor.constraint(equalToConstant: 58).isActive = true
            modePopup = popup
            let stack = NSStackView(views: [s, popup])
            stack.orientation = .horizontal
            stack.spacing = 4
            return stack

        case .tune:
            valueStack?.isHidden = true  // controls carry the readout; reclaim the width
            return makeTuneControl()

        case .scaleControl:
            valueStack?.isHidden = true  // both popups carry the readout
            return makeSCControl()

        case .panWithMode:
            return makePanControl()  // slider + popups; readout keeps the L/R text

        default:
            let bounds = range ?? -32768...32767
            return makeSlider(min: bounds.lowerBound, max: bounds.upperBound)
        }
    }

    private func makeTuneControl() -> NSView {
        let seg = NSSegmentedControl(labels: ["Hz", "Note"], trackingMode: .selectOne,
                                     target: self, action: #selector(tuneModeChanged))
        seg.controlSize = .small
        seg.segmentDistribution = .fillEqually
        seg.setContentHuggingPriority(.required, for: .horizontal)
        tuneMode = seg

        let hz = NSTextField(string: "")
        hz.controlSize = .small
        hz.alignment = .right
        hz.bezelStyle = .roundedBezel
        hz.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        hz.target = self
        hz.action = #selector(tuneCommitted)
        hz.widthAnchor.constraint(equalToConstant: 52).isActive = true
        tuneHzField = hz
        let hzUnit = NSTextField(labelWithString: "Hz")
        hzUnit.font = .systemFont(ofSize: 11)
        hzUnit.textColor = Palette.secondaryText
        let hzView = NSStackView(views: [hz, hzUnit])
        hzView.spacing = 3
        tuneHzView = hzView

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        for midi in TuneMap.midiRange {
            popup.addItem(withTitle: TuneMap.noteName(midi: midi))
            popup.lastItem?.tag = midi
        }
        popup.target = self
        popup.action = #selector(tuneCommitted)
        tuneNotePopup = popup
        let cents = NSTextField(string: "")
        cents.controlSize = .small
        cents.alignment = .right
        cents.bezelStyle = .roundedBezel
        cents.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        cents.target = self
        cents.action = #selector(tuneCommitted)
        cents.widthAnchor.constraint(equalToConstant: 40).isActive = true
        tuneCentsField = cents
        let noteView = NSStackView(views: [popup, cents])
        noteView.spacing = 3
        tuneNoteView = noteView

        // Both editors live in one slot; only the active mode's is shown.
        let deck = NSStackView(views: [hzView, noteView])
        deck.spacing = 0
        let stack = NSStackView(views: [seg, deck])
        stack.orientation = .horizontal
        stack.spacing = 6
        return stack
    }

    private func makeSCControl() -> NSView {
        let scale = NSPopUpButton(frame: .zero, pullsDown: false)
        scale.controlSize = .small
        scale.font = .systemFont(ofSize: 11)
        scale.addItem(withTitle: "OFF")
        scale.lastItem?.tag = 0
        for code in ScaleControlMap.scaleCodes {
            scale.addItem(withTitle: ScaleControlMap.scaleName(code))
            scale.lastItem?.tag = code
        }
        scale.target = self
        scale.action = #selector(scChanged)
        scScalePopup = scale

        let mode = NSPopUpButton(frame: .zero, pullsDown: false)
        mode.controlSize = .small
        mode.font = .systemFont(ofSize: 11)
        for (i, name) in ScaleControlMap.modeNames.enumerated() {
            mode.addItem(withTitle: name)
            mode.lastItem?.tag = i
        }
        mode.target = self
        mode.action = #selector(scChanged)
        scModePopup = mode

        let stack = NSStackView(views: [scale, mode])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.distribution = .fillEqually
        return stack
    }

    private func makePanControl() -> NSView {
        let s = makeSlider(min: PanMap.positionRange.lowerBound,
                           max: PanMap.positionRange.upperBound)   // L/R position

        let cat = NSPopUpButton(frame: .zero, pullsDown: false)
        cat.controlSize = .small
        cat.font = .systemFont(ofSize: 10)
        for (i, c) in PanMap.categories.enumerated() {
            cat.addItem(withTitle: c.name)
            cat.lastItem?.tag = i
        }
        cat.target = self
        cat.action = #selector(panCategoryChanged)
        cat.widthAnchor.constraint(equalToConstant: 74).isActive = true
        panCategoryPopup = cat

        let variant = NSPopUpButton(frame: .zero, pullsDown: false)
        variant.controlSize = .small
        variant.font = .systemFont(ofSize: 10)
        variant.target = self
        variant.action = #selector(panVariantChanged)
        variant.widthAnchor.constraint(equalToConstant: 58).isActive = true
        panVariantPopup = variant

        let stack = NSStackView(views: [s, cat, variant])
        stack.orientation = .horizontal
        stack.spacing = 4
        return stack
    }

    /// Fills the variant popup for a category, selecting `select` (clamped).
    /// "Off" has no variants, so the popup shows a disabled placeholder.
    private func repopulatePanVariants(category: Int, select: Int) {
        guard let variant = panVariantPopup else { return }
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

    private func makeSlider(min: Int, max: Int) -> NSSlider {
        let s = NSSlider(value: 0, minValue: Double(min), maxValue: Double(max),
                         target: self, action: #selector(sliderChanged))
        s.controlSize = .small
        s.isContinuous = true
        s.setContentHuggingPriority(.init(1), for: .horizontal)
        s.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        slider = s
        return s
    }

    // MARK: Value plumbing

    /// Updates the controls without emitting a change.
    func apply(value newValue: Int) {
        value = newValue
        switch descriptor.display {
        case .onOff:
            toggle?.state = newValue == 0 ? .off : .on
        case .enumerated:
            enumPopup?.selectItem(withTag: newValue)
        case .levelWithMode:
            let mode = newValue >= 0 ? newValue / 256 : 0
            slider?.integerValue = newValue - mode * 256
            modePopup?.selectItem(withTag: mode)
        case .tune:
            switch TuneValue(raw: newValue) {
            case .hz(let h):
                tuneMode?.selectedSegment = 0
                tuneHzView?.isHidden = false
                tuneNoteView?.isHidden = true
                tuneHzField?.stringValue = "\(h)"
            case .note(let midi, let cents):
                tuneMode?.selectedSegment = 1
                tuneHzView?.isHidden = true
                tuneNoteView?.isHidden = false
                tuneNotePopup?.selectItem(withTag: midi)
                tuneCentsField?.stringValue = TuneMap.centsString(cents)
            }
        case .scaleControl:
            switch SCValue(raw: newValue) {
            case .off:
                scScalePopup?.selectItem(withTag: 0)
                scModePopup?.isEnabled = false
            case .scale(let code, let mode):
                scScalePopup?.selectItem(withTag: code)
                scModePopup?.selectItem(withTag: mode)
                scModePopup?.isEnabled = true
            }
        case .panWithMode:
            let v = PanValue(raw: newValue)
            slider?.integerValue = v.position
            let (ci, vi) = PanMap.decompose(mode: v.mode)
            panCategoryPopup?.selectItem(withTag: ci)
            repopulatePanVariants(category: ci, select: vi)
        default:
            slider?.integerValue = newValue
        }
        valueLabel.stringValue = formattedValue(newValue)
    }

    private func emit(_ newValue: Int) {
        value = newValue
        valueLabel.stringValue = formattedValue(newValue)
        onChange?(newValue)
    }

    private func formattedValue(_ v: Int) -> String {
        // The pan readout stays short (just the L/R position); the mode lives in
        // the popups rather than the composite label.
        if case .panWithMode = descriptor.display {
            return PanMap.positionString(PanValue(raw: v).position)
        }
        return ParameterFormatter.valueText(for: v, display: descriptor.display,
                                            context: contextProvider?() ?? .init())
    }

    @objc private func sliderChanged() {
        guard let slider else { return }
        if case .levelWithMode = descriptor.display {
            compositeChanged()
        } else if case .panWithMode = descriptor.display {
            panEmit()
        } else {
            emit(slider.integerValue)
        }
    }

    @objc private func compositeChanged() {
        let level = slider?.integerValue ?? 0
        let mode = modePopup?.selectedTag() ?? 0
        emit(mode * 256 + level)
    }

    /// Commits a value typed into the readout field (Enter or focus loss).
    /// Reverts to the current value if the text can't be parsed; clamps valid
    /// input to the parameter's range and normalizes the display.
    @objc private func valueCommitted() {
        guard valueIsTypeable else { return }
        guard let parsed = ParameterFormatter.parse(valueLabel.stringValue, display: descriptor.display) else {
            apply(value: value)
            return
        }
        let newValue: Int
        if case .levelWithMode = descriptor.display {
            let level = Swift.max(0, Swift.min(127, parsed))
            let mode = modePopup?.selectedTag() ?? 0
            newValue = mode * 256 + level
        } else if let range {
            newValue = Swift.max(range.lowerBound, Swift.min(range.upperBound, parsed))
        } else {
            newValue = parsed
        }
        apply(value: newValue)   // moves the slider + normalizes the text
        onChange?(newValue)
    }

    /// Switches Hz↔Note, converting the current value so the pitch is
    /// preserved across the switch, then normalizes and emits.
    @objc private func tuneModeChanged() {
        let toNote = tuneMode?.selectedSegment == 1
        let newValue: Int
        switch TuneValue(raw: value) {
        case .hz(let h):
            if toNote {
                let n = TuneMap.nearestNote(forHz: h)
                newValue = TuneValue.note(midi: n.midi, cents: n.cents).raw
            } else {
                newValue = h
            }
        case .note(let midi, let cents):
            newValue = toNote ? TuneValue.note(midi: midi, cents: cents).raw
                              : TuneMap.hz(forMidi: midi, cents: cents)
        }
        apply(value: newValue)   // repopulates the active editor + mode
        onChange?(newValue)
    }

    /// Commits an edit from the Hz field, note popup, or cents field. Composes
    /// only valid values (Hz clamped to range; note+cents always in-band), so
    /// the device never sees a rejected Tune write.
    @objc private func tuneCommitted() {
        let newValue: Int
        if tuneMode?.selectedSegment == 1 {
            let midi = tuneNotePopup?.selectedTag() ?? 69
            let typed = Int((tuneCentsField?.stringValue ?? "").trimmingCharacters(in: .whitespaces)) ?? 0
            let cents = Swift.max(TuneMap.centsRange.lowerBound,
                                  Swift.min(TuneMap.centsRange.upperBound, typed))
            newValue = TuneValue.note(midi: midi, cents: cents).raw
        } else {
            let fallback: Int = { if case .hz(let h) = TuneValue(raw: value) { return h } else { return 440 } }()
            let typed = Int((tuneHzField?.stringValue ?? "").trimmingCharacters(in: .whitespaces)) ?? fallback
            newValue = Swift.max(TuneMap.hzRange.lowerBound,
                                 Swift.min(TuneMap.hzRange.upperBound, typed))
        }
        apply(value: newValue)   // clamps/normalizes the fields
        onChange?(newValue)
    }

    @objc private func enumChanged() {
        emit(enumPopup?.selectedTag() ?? 0)
    }

    /// Composes an SC value from the scale + mode popups. OFF (scale tag 0)
    /// disables the mode popup and emits 0; otherwise `mode × 256 + scale`.
    @objc private func scChanged() {
        let code = scScalePopup?.selectedTag() ?? 0
        if code == 0 {
            scModePopup?.isEnabled = false
            emit(0)
        } else {
            scModePopup?.isEnabled = true
            let mode = scModePopup?.selectedTag() ?? 0
            emit(SCValue.scale(code: code, mode: mode).raw)
        }
    }

    @objc private func toggleChanged() {
        emit(toggle?.state == .on ? 1 : 0)
    }

    // MARK: Pan (position slider + category/variant popups)

    @objc private func panCategoryChanged() {
        // A new category repopulates the variant popup (selecting its first).
        repopulatePanVariants(category: panCategoryPopup?.selectedTag() ?? 0, select: 0)
        panEmit()
    }

    @objc private func panVariantChanged() { panEmit() }

    private func panEmit() {
        let pos = slider?.integerValue ?? 64
        let mode = PanMap.compose(category: panCategoryPopup?.selectedTag() ?? 0,
                                  variant: panVariantPopup?.selectedTag() ?? 0)
        emit(PanValue(position: pos, mode: mode).raw)
    }
}
