import AppKit

/// The Randomize popover. In picker mode (toolbar) it offers a target scope; in
/// fixed mode (a section's dice button) it shows the section title instead. Both
/// modes share the rate slider and Randomize / Undo actions. Owns no logic —
/// it reports choices via callbacks.
final class RandomizePopoverViewController: NSViewController {
    /// `targetIndex` is the picker selection, or nil in fixed-section mode.
    var onRandomize: ((_ targetIndex: Int?, _ rate: Double) -> Void)?
    var onUndo: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let targetCaption = RandomizePopoverViewController.caption("Target")
    private let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rateSlider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let rateValue = NSTextField(labelWithString: "50%")
    private let randomizeButton = NSButton(title: "Randomize", target: nil, action: nil)
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)

    override func loadView() {
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        rateSlider.target = self
        rateSlider.action = #selector(rateChanged)
        rateSlider.isContinuous = true
        rateValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        rateValue.textColor = .secondaryLabelColor
        rateValue.alignment = .right
        rateValue.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let rateRow = NSStackView(views: [rateSlider, rateValue])
        rateRow.orientation = .horizontal
        rateRow.spacing = 8
        rateSlider.setContentHuggingPriority(.init(1), for: .horizontal)

        randomizeButton.target = self
        randomizeButton.action = #selector(randomize)
        randomizeButton.bezelStyle = .rounded
        randomizeButton.keyEquivalent = "\r"
        undoButton.target = self
        undoButton.action = #selector(undo)
        undoButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [undoButton, NSView(), randomizeButton])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [titleLabel, targetCaption, targetPopup,
                                        RandomizePopoverViewController.caption("Rate"), rateRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 240),
            targetPopup.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            rateRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        view = container
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    /// Toolbar mode: choose among targets.
    func configurePicker(targets: [String], canUndo: Bool) {
        titleLabel.isHidden = true
        targetCaption.isHidden = false
        targetPopup.isHidden = false
        targetPopup.removeAllItems()
        targetPopup.addItems(withTitles: targets)
        randomizeButton.isEnabled = !targets.isEmpty
        undoButton.isEnabled = canUndo
    }

    /// Per-section mode: a fixed scope shown as a title, no picker.
    func configureFixed(title: String, canUndo: Bool) {
        titleLabel.stringValue = title
        titleLabel.isHidden = false
        targetCaption.isHidden = true
        targetPopup.isHidden = true
        randomizeButton.isEnabled = true
        undoButton.isEnabled = canUndo
    }

    func setUndoEnabled(_ enabled: Bool) { undoButton.isEnabled = enabled }

    @objc private func rateChanged() {
        rateValue.stringValue = "\(Int(rateSlider.doubleValue))%"
    }

    @objc private func randomize() {
        onRandomize?(targetPopup.isHidden ? nil : targetPopup.indexOfSelectedItem, rateSlider.doubleValue)
    }

    @objc private func undo() { onUndo?() }
}
