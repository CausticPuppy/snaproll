import AppKit
import AFrameKit

/// A floating window for editing the aFrame's group map: the 8 performance
/// groups (A–D') each holding up to 40 (instrument, effect) slots. Click a slot
/// to recall it on the device, "Store" to write the current selection into a
/// slot, and the MAX popup to set how many slots a group exposes.
final class GroupEditorWindowController: NSWindowController {
    var onRecall: ((_ group: Int, _ num: Int) -> Void)?
    var onStore: ((_ group: Int, _ num: Int, _ max: Int) -> Void)?
    var onSetMax: ((_ group: Int, _ max: Int) -> Void)?
    var onReload: (() -> Void)?

    private var lists: [GroupList] = []
    private var current: GroupToneInfo?
    private var instNames: [String] = []
    private var effectNames: [String] = []

    private let currentLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let placeholder = NSTextField(labelWithString: "Connect to an aFrame to edit groups")

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Group Editor"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 360)
        self.init(window: window)
        buildContent()
    }

    private func buildContent() {
        currentLabel.font = .systemFont(ofSize: 11)
        currentLabel.textColor = .secondaryLabelColor
        currentLabel.lineBreakMode = .byTruncatingTail

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = .systemFont(ofSize: 13)

        let outer = NSStackView(views: [currentLabel, placeholder, stack])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 12
        outer.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        outer.translatesAutoresizingMaskIntoConstraints = false

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(outer)

        let scroll = NSScrollView()
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor

        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: content.topAnchor),
            outer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: -32),
        ])
        window?.contentView = scroll
        render()
    }

    // MARK: Input

    func setNames(inst: [String], effect: [String]) {
        instNames = inst
        effectNames = effect
        render()
    }

    func update(lists: [GroupList], current: GroupToneInfo) {
        self.lists = lists
        self.current = current
        render()
    }

    func setIdle() {
        lists = []
        current = nil
        render()
    }

    private func name(_ names: [String], _ index: Int, _ prefix: String) -> String {
        names.indices.contains(index) ? names[index] : "\(prefix)\(index + 1)"
    }

    // MARK: Rendering

    private func render() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !lists.isEmpty else {
            placeholder.isHidden = false
            currentLabel.stringValue = ""
            return
        }
        placeholder.isHidden = true

        if let current {
            let inst = name(instNames, current.instNum, "I")
            let effect = name(effectNames, current.effectNum, "E")
            currentLabel.stringValue = "Store writes the current selection:  \(inst)  /  \(effect)"
        }

        for (g, list) in lists.enumerated() {
            stack.addArrangedSubview(groupSection(group: g, list: list))
        }
    }

    private func groupSection(group: Int, list: GroupList) -> NSView {
        let title = NSTextField(labelWithString: "Group \(ToneGroup(rawValue: group)?.description ?? "\(group)")")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let maxLabel = NSTextField(labelWithString: "MAX")
        maxLabel.font = .systemFont(ofSize: 11)
        maxLabel.textColor = .secondaryLabelColor

        let maxPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        maxPopup.controlSize = .small
        maxPopup.font = .systemFont(ofSize: 11)
        for m in 1...DSPProject.memorySlots {
            maxPopup.addItem(withTitle: "\(m)")
            maxPopup.lastItem?.tag = m
        }
        maxPopup.selectItem(withTag: list.max)
        maxPopup.tag = group
        maxPopup.target = self
        maxPopup.action = #selector(maxChanged(_:))

        let header = NSStackView(views: [title, NSView(), maxLabel, maxPopup])
        header.orientation = .horizontal
        header.spacing = 6

        var rows: [NSView] = [header]
        for n in 0..<max(1, min(list.max, list.slots.count)) {
            rows.append(slotRow(group: group, num: n, slot: list.slots[n]))
        }
        let section = NSStackView(views: rows)
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 3
        section.setCustomSpacing(6, after: header)
        for row in rows.dropFirst() {
            row.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        header.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func slotRow(group: Int, num: Int, slot: GroupSlot) -> NSView {
        let isCurrent = current.map { $0.group == group && $0.number == num } ?? false
        let tag = group * DSPProject.memorySlots + num

        let numText = String(format: "%02d", num + 1)
        let inst = name(instNames, slot.inst, "I")
        let effect = name(effectNames, slot.effect, "E")
        let recall = NSButton(title: "\(numText)   \(inst)  ▸  \(effect)", target: self, action: #selector(recallSlot(_:)))
        recall.tag = tag
        recall.isBordered = false
        recall.alignment = .left
        recall.contentTintColor = isCurrent ? .controlAccentColor : nil
        recall.font = isCurrent ? .systemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 12)
        recall.toolTip = "Recall this slot on the aFrame"
        recall.setContentHuggingPriority(.init(1), for: .horizontal)

        let store = NSButton(title: "Store", target: self, action: #selector(storeSlot(_:)))
        store.tag = tag
        store.bezelStyle = .rounded
        store.controlSize = .small
        store.font = .systemFont(ofSize: 11)
        store.toolTip = "Store the current selection into this slot"

        let row = NSStackView(views: [recall, store])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    // MARK: Actions

    @objc private func recallSlot(_ sender: NSButton) {
        let (g, n) = decode(sender.tag)
        onRecall?(g, n)
    }

    @objc private func storeSlot(_ sender: NSButton) {
        let (g, n) = decode(sender.tag)
        let max = lists.indices.contains(g) ? lists[g].max : DSPProject.memorySlots
        onStore?(g, n, max)
    }

    @objc private func maxChanged(_ sender: NSPopUpButton) {
        onSetMax?(sender.tag, sender.selectedTag())
    }

    private func decode(_ tag: Int) -> (Int, Int) {
        (tag / DSPProject.memorySlots, tag % DSPProject.memorySlots)
    }
}
