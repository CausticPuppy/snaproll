import AppKit
import AFrameKit

/// A compact bar for navigating tones within a performance group: a group
/// picker (A…D'), an editable slot number flanked by prev/next arrows, and a
/// read-only "/ MAX" count. It holds no device state beyond what the last
/// `update(from:)` set, and reports navigation requests via `onNavigate`.
final class GroupNavView: NSView {
    /// Requests a recall of the given group and zero-based slot number.
    var onNavigate: ((_ group: Int, _ number: Int) -> Void)?

    private let groupPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let prevButton = GroupNavView.arrowButton("chevron.left", "Previous tone")
    private let numberField = NSTextField(string: "")
    private let maxLabel = NSTextField(labelWithString: "/ –")
    private let nextButton = GroupNavView.arrowButton("chevron.right", "Next tone")

    private var group = 0
    private var number = 0
    private var maxCount = 0
    private var connected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        for g in ToneGroup.allCases { groupPopup.addItem(withTitle: g.description) }
        groupPopup.target = self
        groupPopup.action = #selector(groupChanged)

        prevButton.target = self
        prevButton.action = #selector(prev)
        nextButton.target = self
        nextButton.action = #selector(next)

        numberField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        numberField.alignment = .center
        numberField.bezelStyle = .roundedBezel
        numberField.focusRingType = .none
        numberField.target = self
        numberField.action = #selector(numberCommitted)
        numberField.widthAnchor.constraint(equalToConstant: 46).isActive = true

        maxLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        maxLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            GroupNavView.caption("Group"), groupPopup,
            GroupNavView.caption("Tone"), prevButton, numberField, maxLabel, nextButton,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setCustomSpacing(14, after: groupPopup)
        stack.setCustomSpacing(2, after: prevButton)
        stack.setCustomSpacing(2, after: numberField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private static func arrowButton(_ symbol: String, _ description: String) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: description)!,
            target: nil, action: nil)
        button.bezelStyle = .rounded
        button.imagePosition = .imageOnly
        button.toolTip = description
        return button
    }

    // MARK: State

    /// Reflects the device's current group/slot position.
    func update(from info: GroupToneInfo) {
        group = info.group
        number = info.number
        maxCount = info.max
        connected = true
        refresh()
    }

    /// Disables the bar (no device connected).
    func setIdle() {
        connected = false
        refresh()
    }

    private func refresh() {
        groupPopup.isEnabled = connected
        numberField.isEnabled = connected
        if connected {
            groupPopup.selectItem(at: group)
            numberField.stringValue = String(format: "%02d", number + 1)
            maxLabel.stringValue = "/ \(String(format: "%02d", maxCount))"
        } else {
            numberField.stringValue = "––"
            maxLabel.stringValue = "/ –"
        }
        // Bound the arrows to the group's active slots.
        prevButton.isEnabled = connected && number > 0
        nextButton.isEnabled = connected && number < maxCount - 1
    }

    // MARK: Actions

    @objc private func groupChanged() {
        guard connected else { return }
        onNavigate?(groupPopup.indexOfSelectedItem, 0)
    }

    @objc private func prev() {
        guard connected, number > 0 else { return }
        onNavigate?(group, number - 1)
    }

    @objc private func next() {
        guard connected, number < maxCount - 1 else { return }
        onNavigate?(group, number + 1)
    }

    @objc private func numberCommitted() {
        guard connected, maxCount > 0 else { refresh(); return }
        guard let typed = Int(numberField.stringValue.trimmingCharacters(in: .whitespaces)) else {
            refresh()  // revert unparseable input
            return
        }
        let clamped = min(max(typed, 1), maxCount)
        let target = clamped - 1
        guard target != number else { refresh(); return }
        onNavigate?(group, target)
    }
}
