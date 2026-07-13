import AppKit
import AFrameKit

/// A mixer-style vertical fader for level/send parameters, modeled on the
/// original aFrameEdit's channel strips: a short title, a vertical slider,
/// a typeable level readout, and — for `.levelWithMode` parameters — the
/// mode selector (e.g. --/P+/P- or M+/M-) at the bottom, mirroring the
/// hardware's composite `mode × 256 + level` encoding.
final class VerticalFaderView: NSView {
    let descriptor: ParameterDescriptor
    var onChange: ((Int) -> Void)?

    private(set) var value: Int

    private let slider: NSSlider
    private let field = NSTextField(string: "")
    private var modePopup: NSPopUpButton?
    private let levelRange: ClosedRange<Int>

    /// `title` is the strip-local name ("Lev", "C Snd"); the full parameter
    /// name goes into the tooltip.
    init(title: String, descriptor: ParameterDescriptor, range: ClosedRange<Int>?, value: Int) {
        self.descriptor = descriptor
        self.value = value
        // Composite params carry the mode in the high byte; the fader itself
        // always travels the 0–127 level lane. Plain params use their range.
        if case .levelWithMode = descriptor.display {
            levelRange = 0...127
        } else {
            levelRange = range ?? 0...127
        }
        slider = NSSlider(value: 0, minValue: Double(levelRange.lowerBound),
                          maxValue: Double(levelRange.upperBound), target: nil, action: nil)
        super.init(frame: .zero)
        build(title: title)
        apply(value: value)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build(title: String) {
        toolTip = descriptor.name

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = Palette.secondaryText
        titleLabel.alignment = .center

        slider.isVertical = true
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.heightAnchor.constraint(equalToConstant: 100).isActive = true

        field.controlSize = .small
        field.alignment = .center
        field.bezelStyle = .roundedBezel
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.focusRingType = .default
        field.target = self
        field.action = #selector(fieldCommitted)
        field.widthAnchor.constraint(equalToConstant: 44).isActive = true

        var views: [NSView] = [titleLabel, slider, field]

        if case .levelWithMode(let modes) = descriptor.display {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 10)
            for (i, mode) in modes.enumerated() {
                popup.addItem(withTitle: mode)
                popup.lastItem?.tag = i
            }
            popup.target = self
            popup.action = #selector(modeChanged)
            popup.widthAnchor.constraint(equalToConstant: 56).isActive = true
            modePopup = popup
            views.append(popup)
        }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(6, after: slider)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
        ])
    }

    // MARK: Value plumbing

    private var mode: Int {
        guard case .levelWithMode = descriptor.display else { return 0 }
        return value >= 0 ? value / 256 : 0
    }

    /// Updates the controls without emitting a change.
    func apply(value newValue: Int) {
        value = newValue
        let level = newValue - mode * 256
        slider.integerValue = level
        field.stringValue = "\(level)"
        modePopup?.selectItem(withTag: mode)
    }

    private func emit(level: Int) {
        let composed = (modePopup?.selectedTag() ?? 0) * 256 + level
        value = composed
        field.stringValue = "\(level)"
        onChange?(composed)
    }

    @objc private func sliderChanged() {
        emit(level: slider.integerValue)
    }

    @objc private func modeChanged() {
        emit(level: slider.integerValue)
    }

    @objc private func fieldCommitted() {
        guard let typed = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) else {
            apply(value: value)  // revert unparseable input
            return
        }
        let level = Swift.max(levelRange.lowerBound, Swift.min(levelRange.upperBound, typed))
        slider.integerValue = level
        emit(level: level)
    }
}
