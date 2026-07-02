import AppKit
import AFrameKit

/// One parameter row: name label + the control appropriate to the parameter's
/// display type + a formatted value readout. Emits raw Int values.
final class ParameterRowView: NSView {
    let descriptor: ParameterDescriptor
    let range: ClosedRange<Int>?
    var onChange: ((Int) -> Void)?

    private(set) var value: Int

    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private var slider: NSSlider?
    private var modePopup: NSPopUpButton?  // levelWithMode mode selector
    private var enumPopup: NSPopUpButton?
    private var toggle: NSSwitch?

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
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.alignment = .right
        nameLabel.lineBreakMode = .byTruncatingTail
        if case .custom(let note) = descriptor.display {
            toolTip = note
        }

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byClipping

        let control = makeControl()

        let stack = NSStackView(views: [nameLabel, control, valueLabel])
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
            valueLabel.widthAnchor.constraint(equalToConstant: 78),
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
            valueLabel.isHidden = true
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

        default:
            let bounds = range ?? -32768...32767
            return makeSlider(min: bounds.lowerBound, max: bounds.upperBound)
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
        default:
            slider?.integerValue = newValue
        }
        valueLabel.stringValue = ParameterFormatter.string(for: newValue, display: descriptor.display)
    }

    private func emit(_ newValue: Int) {
        value = newValue
        valueLabel.stringValue = ParameterFormatter.string(for: newValue, display: descriptor.display)
        onChange?(newValue)
    }

    @objc private func sliderChanged() {
        guard let slider else { return }
        if case .levelWithMode = descriptor.display {
            compositeChanged()
        } else {
            emit(slider.integerValue)
        }
    }

    @objc private func compositeChanged() {
        let level = slider?.integerValue ?? 0
        let mode = modePopup?.selectedTag() ?? 0
        emit(mode * 256 + level)
    }

    @objc private func enumChanged() {
        emit(enumPopup?.selectedTag() ?? 0)
    }

    @objc private func toggleChanged() {
        emit(toggle?.state == .on ? 1 : 0)
    }
}
