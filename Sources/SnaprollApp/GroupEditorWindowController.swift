import AppKit
import AFrameKit

/// A floating window for editing the aFrame's group map: the 8 performance
/// groups (A–D') each holding up to 40 (instrument, effect) slots.
///
/// Mirrors the factory editor's "Group Edit" screen with a hybrid commit
/// model: double-clicking a slot recalls it on the device immediately, while
/// structural edits — drag-drop reordering (within or across groups), Delete,
/// Insert, Store, and MAX — accumulate in an offline copy and only reach the
/// device when "Write" sends the changed slots.
final class GroupEditorWindowController: NSWindowController {
    var onRecall: ((_ group: Int, _ num: Int) -> Void)?
    var onWrite: ((_ lists: [GroupList]) -> Void)?
    var onReload: (() -> Void)?
    /// Supplies the tones currently loaded in the main editor — what "Store"
    /// writes into the selected slot. (Not derived from aFGA: the mock returns
    /// the slot's mapping there rather than the live selections, and the real
    /// device's behavior after aFE2 is unverified.)
    var currentSelection: (() -> (inst: Int, effect: Int)?)?

    // Offline model: `device` mirrors the last `.groups` payload; `edited` is
    // the working copy the tables render. Only the visible region (slots
    // below MAX) counts toward dirtiness — the tail is device filler.
    private var device: [GroupList] = []
    private var edited: [GroupList] = []
    private var current: GroupToneInfo?
    private var connected = false
    private var instNames: [String] = []
    private var effectNames: [String] = []
    /// Set while a `.groups` refresh caused by our own Write is expected, so
    /// the refresh adopts the device state instead of flagging a conflict.
    private var deviceChangedUnderneath = false

    private var sections: [GroupSectionView] = []
    private let insertField = NSTextField(string: "")
    private let insertStepper = NSStepper()
    private let placeholder = NSTextField(labelWithString: "Connect to an aFrame to edit groups")
    private let hintLabel = NSTextField(labelWithString: "")
    private let writeButton = NSButton(title: "Write", target: nil, action: nil)
    private let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    private let refreshButton = NSButton(title: "", target: nil, action: nil)
    private let storeButton = NSButton(title: "Store", target: nil, action: nil)
    private let insertButton = NSButton(title: "", target: nil, action: nil)
    private let toneListButton = NSButton(title: "Tone List", target: nil, action: nil)
    private let editBar = NSStackView()
    private let footer = NSStackView()
    private let sectionsStack = NSStackView()

    private lazy var toneListPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = toneListVC
        return popover
    }()
    private let toneListVC = ToneListViewController()

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Group Editor"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 400)
        window.setFrameAutosaveName("GroupEditor")
        self.init(window: window)
        buildContent()
    }

    private var isDirty: Bool {
        !Self.visibleEqual(edited, device)
    }

    /// Compares only what the player can reach: MAX and the slots below it.
    private static func visibleEqual(_ a: [GroupList], _ b: [GroupList]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            guard x.max == y.max else { return false }
            if !x.slots.prefix(x.max).elementsEqual(y.slots.prefix(y.max)) { return false }
        }
        return true
    }

    // MARK: Layout

    private func buildContent() {
        placeholder.textColor = Palette.tertiaryText
        placeholder.font = .systemFont(ofSize: 13)

        // Edit bar: insert control + store + tone list, all selection-driven.
        insertField.placeholderString = "01"
        insertField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        insertField.alignment = .center
        insertField.widthAnchor.constraint(equalToConstant: 40).isActive = true
        insertField.toolTip = "Tone number (1–80) to insert"
        insertStepper.minValue = 1
        insertStepper.maxValue = Double(DSPProject.patchCount)
        insertStepper.valueWraps = false
        insertStepper.integerValue = 1
        insertStepper.target = self
        insertStepper.action = #selector(insertStepperChanged)
        insertField.stringValue = "1"

        insertButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Insert tone")
        insertButton.bezelStyle = .rounded
        insertButton.target = self
        insertButton.action = #selector(insertTone)
        insertButton.toolTip = "Insert this tone number after the selected slot"

        storeButton.bezelStyle = .rounded
        storeButton.target = self
        storeButton.action = #selector(storeIntoSelection)
        storeButton.toolTip = "Replace the selected slot with the current selection (applies on Write)"

        toneListButton.bezelStyle = .rounded
        toneListButton.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: "Tone list")
        toneListButton.imagePosition = .imageLeading
        toneListButton.target = self
        toneListButton.action = #selector(showToneList)
        toneListButton.toolTip = "Reference list of tones 01–80"

        let insertCaption = NSTextField(labelWithString: "INSERT")
        insertCaption.font = .systemFont(ofSize: 10, weight: .semibold)
        insertCaption.textColor = Palette.sectionTitle

        let barSpacer = NSView()
        barSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        editBar.setViews([insertCaption, insertField, insertStepper, insertButton,
                          storeButton, barSpacer, toneListButton], in: .leading)
        editBar.orientation = .horizontal
        editBar.alignment = .centerY
        editBar.spacing = 6
        editBar.setCustomSpacing(12, after: insertButton)

        sectionsStack.orientation = .vertical
        sectionsStack.alignment = .leading
        sectionsStack.spacing = 12

        let outer = NSStackView(views: [placeholder, sectionsStack])
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
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // Footer: dirty hint + refresh / revert / write.
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = Palette.secondaryText
        hintLabel.lineBreakMode = .byTruncatingTail

        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.toolTip = "Re-read the group map from the aFrame"

        revertButton.bezelStyle = .rounded
        revertButton.target = self
        revertButton.action = #selector(revert)
        revertButton.toolTip = "Discard offline edits and restore the device's group map"

        writeButton.bezelStyle = .rounded
        writeButton.keyEquivalent = "\r"
        writeButton.target = self
        writeButton.action = #selector(write)
        writeButton.toolTip = "Write the changed slots to the aFrame"

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        footer.setViews([hintLabel, footerSpacer, refreshButton, revertButton, writeButton], in: .leading)
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 10, right: 16)
        footer.translatesAutoresizingMaskIntoConstraints = false

        let editBarBox = NSStackView(views: [editBar])
        editBarBox.orientation = .vertical
        editBarBox.alignment = .leading
        editBarBox.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 0, right: 16)
        editBarBox.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(editBarBox)
        root.addSubview(scroll)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            editBarBox.topAnchor.constraint(equalTo: root.topAnchor),
            editBarBox.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editBarBox.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editBar.widthAnchor.constraint(equalTo: editBarBox.widthAnchor, constant: -32),
            scroll.topAnchor.constraint(equalTo: editBarBox.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            outer.topAnchor.constraint(equalTo: content.topAnchor),
            outer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sectionsStack.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: -32),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window?.contentView = root
        render()
    }

    // MARK: Input from MainWindowController

    func setNames(inst: [String], effect: [String]) {
        instNames = inst
        effectNames = effect
        render()
    }

    func update(lists: [GroupList], current: GroupToneInfo) {
        let wasDirty = isDirty
        self.current = current
        connected = true
        if !wasDirty || device.isEmpty {
            device = lists
            edited = lists
            deviceChangedUnderneath = false
        } else if Self.visibleEqual(lists, edited) {
            // The device caught up with our edits (our own Write, or an
            // identical change made elsewhere) — clean, no conflict.
            device = lists
            edited = lists
            deviceChangedUnderneath = false
        } else {
            // Keep offline edits; warn only if the device map actually moved
            // away from what our edits are based on.
            if !Self.visibleEqual(lists, device) { deviceChangedUnderneath = true }
            device = lists
        }
        render()
    }

    /// Disconnect: offline edits survive so work isn't lost, but Write and
    /// the live controls disable until reconnect.
    func setIdle() {
        connected = false
        current = nil
        render()
    }

    private func name(_ names: [String], _ index: Int, _ prefix: String) -> String {
        names.indices.contains(index) && !names[index].isEmpty ? names[index] : "\(prefix)\(index + 1)"
    }

    // MARK: Rendering

    private func render() {
        let hasData = !edited.isEmpty
        placeholder.isHidden = hasData
        editBar.isHidden = !hasData
        footer.isHidden = !hasData

        if sections.count != edited.count {
            sections.forEach { $0.removeFromSuperview() }
            sections = edited.indices.map { g in
                let section = GroupSectionView(group: g)
                section.onSelectionChanged = { [weak self] in self?.selectionChanged(inGroup: g) }
                section.onRecall = { [weak self] num in self?.recall(group: g, num: num) }
                section.onDelete = { [weak self] num in self?.deleteSlot(group: g, num: num) }
                section.onMaxChanged = { [weak self] max in self?.maxChanged(group: g, max: max) }
                section.onMove = { [weak self] src, dest in self?.moveSlot(from: src, to: dest) }
                sectionsStack.addArrangedSubview(section)
                section.widthAnchor.constraint(equalTo: sectionsStack.widthAnchor).isActive = true
                return section
            }
        }
        for (g, section) in sections.enumerated() {
            let deviceCurrent = (connected && current?.group == g) ? current?.number : nil
            section.render(list: edited[g],
                           currentNum: deviceCurrent,
                           dirty: !Self.groupVisibleEqual(edited[g], device.indices.contains(g) ? device[g] : edited[g]),
                           rowTitle: { [weak self] slot in self?.rowTitle(slot) ?? "" })
        }

        let dirty = isDirty
        window?.isDocumentEdited = dirty
        writeButton.isEnabled = dirty && connected
        revertButton.isEnabled = dirty
        refreshButton.isEnabled = connected
        storeButton.isEnabled = connected && selection() != nil
        insertButton.isEnabled = selection() != nil
        if !connected && hasData {
            hintLabel.stringValue = dirty
                ? "Disconnected — edits kept, reconnect to Write"
                : "Disconnected"
        } else if deviceChangedUnderneath && dirty {
            hintLabel.stringValue = "⚠ Device group map changed underneath — Revert to load it"
        } else if dirty {
            hintLabel.stringValue = "Offline edits — Write to apply"
        } else {
            hintLabel.stringValue = "Drag to reorder · double-click to recall"
        }
    }

    private static func groupVisibleEqual(_ a: GroupList, _ b: GroupList) -> Bool {
        a.max == b.max && a.slots.prefix(a.max).elementsEqual(b.slots.prefix(b.max))
    }

    private func rowTitle(_ slot: GroupSlot) -> String {
        "\(name(instNames, slot.inst, "I"))  ▸  \(name(effectNames, slot.effect, "E"))"
    }

    // MARK: Selection (single selection across all 8 tables)

    private var reentrantSelection = false

    private func selectionChanged(inGroup group: Int) {
        guard !reentrantSelection else { return }
        reentrantSelection = true
        for (g, section) in sections.enumerated() where g != group {
            section.clearSelection()
        }
        reentrantSelection = false
        render()
    }

    /// The single selected slot across all groups, if any.
    private func selection() -> (group: Int, num: Int)? {
        for (g, section) in sections.enumerated() {
            if let row = section.selectedRow { return (g, row) }
        }
        return nil
    }

    // MARK: Edits (all mutate `edited` only)

    private func recall(group: Int, num: Int) {
        guard connected else { return }
        // Recall is live and indexes the device's current map. If this group
        // has unwritten edits, the device's slot may hold something other
        // than the row being shown — refuse rather than recall a surprise.
        if device.indices.contains(group), edited.indices.contains(group),
           !Self.groupVisibleEqual(edited[group], device[group]) {
            NSSound.beep()
            hintLabel.stringValue = "⚠ Write or revert this group's edits before recalling from it"
            return
        }
        onRecall?(group, num)
    }

    private func deleteSlot(group: Int, num: Int) {
        guard edited.indices.contains(group),
              num < edited[group].max, edited[group].max > 1 else { return }
        edited[group].slots.remove(at: num)
        edited[group].slots.append(GroupSlot(inst: 0, effect: 0))
        edited[group].max -= 1
        render()
    }

    private func maxChanged(group: Int, max: Int) {
        guard edited.indices.contains(group) else { return }
        edited[group].max = Swift.max(1, Swift.min(DSPProject.memorySlots, max))
        render()
    }

    private func moveSlot(from src: (group: Int, num: Int), to dest: (group: Int, num: Int)) {
        guard edited.indices.contains(src.group), edited.indices.contains(dest.group),
              src.num < edited[src.group].max else { return }
        let slot = edited[src.group].slots[src.num]
        if src.group == dest.group {
            var insertAt = dest.num
            if insertAt > src.num { insertAt -= 1 }  // account for the removal
            edited[src.group].slots.remove(at: src.num)
            edited[src.group].slots.insert(slot, at: insertAt)
        } else {
            guard edited[dest.group].max < DSPProject.memorySlots,
                  edited[src.group].max > 1 else { NSSound.beep(); return }
            edited[src.group].slots.remove(at: src.num)
            edited[src.group].slots.append(GroupSlot(inst: 0, effect: 0))
            edited[src.group].max -= 1
            edited[dest.group].slots.insert(slot, at: Swift.min(dest.num, edited[dest.group].max))
            edited[dest.group].slots.removeLast()
            edited[dest.group].max += 1
        }
        render()
    }

    @objc private func insertStepperChanged() {
        insertField.stringValue = "\(insertStepper.integerValue)"
    }

    @objc private func insertTone() {
        guard let sel = selection(), edited.indices.contains(sel.group) else { NSSound.beep(); return }
        guard let n = Int(insertField.stringValue.trimmingCharacters(in: .whitespaces)),
              (1...DSPProject.patchCount).contains(n) else { NSSound.beep(); return }
        guard edited[sel.group].max < DSPProject.memorySlots else { NSSound.beep(); return }
        insertStepper.integerValue = n
        // The factory editor inserts a tone *number* — the same index into
        // both the instrument and effect lists — behind the selection.
        let slot = GroupSlot(inst: n - 1, effect: n - 1)
        let at = Swift.min(sel.num + 1, edited[sel.group].max)
        edited[sel.group].slots.insert(slot, at: at)
        edited[sel.group].slots.removeLast()
        edited[sel.group].max += 1
        render()
        sections[sel.group].select(row: at)
    }

    @objc private func storeIntoSelection() {
        guard let sel = selection(), connected,
              let tones = currentSelection?(),
              edited.indices.contains(sel.group), sel.num < edited[sel.group].max else { return }
        edited[sel.group].slots[sel.num] = GroupSlot(inst: tones.inst, effect: tones.effect)
        render()
    }

    @objc private func showToneList() {
        toneListVC.configure(inst: instNames, effect: effectNames)
        toneListPopover.show(relativeTo: toneListButton.bounds, of: toneListButton, preferredEdge: .maxY)
    }

    // MARK: Commit

    @objc private func write() {
        guard connected, isDirty else { return }
        onWrite?(edited)
    }

    @objc private func revert() {
        edited = device
        deviceChangedUnderneath = false
        render()
    }

    @objc private func refresh() {
        onReload?()
    }
}

// MARK: - Group section (header + fixed-height table)

/// One group's header (name, dirty dot, MAX popup) and slot table. The table
/// is given an explicit height (it lives inside the window's single scroll
/// view) and reports selection, recall, delete, MAX, and drag-drop moves back
/// to the window controller, which owns the model.
private final class GroupSectionView: NSView {
    var onSelectionChanged: (() -> Void)?
    var onRecall: ((Int) -> Void)?
    var onDelete: ((Int) -> Void)?
    var onMaxChanged: ((Int) -> Void)?
    var onMove: ((_ src: (group: Int, num: Int), _ dest: (group: Int, num: Int)) -> Void)?

    let group: Int
    private var list = GroupList(max: 0, slots: [])
    private var currentNum: Int?
    private var rowTitle: ((GroupSlot) -> String) = { _ in "" }

    private let titleLabel = NSTextField(labelWithString: "")
    private let dirtyDot = NSTextField(labelWithString: "●")
    private let maxPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let table = SlotTableView()
    private var tableHeight: NSLayoutConstraint!
    /// Suppresses selection notifications while render/clear/select mutate
    /// the table programmatically — selectRowIndexes posts the change
    /// synchronously, which would otherwise re-enter render() until the
    /// stack overflows.
    private var isProgrammaticSelection = false

    static let dragType = NSPasteboard.PasteboardType("com.snaproll.groupslot")

    init(group: Int) {
        self.group = group
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = "Group \(ToneGroup(rawValue: group)?.description ?? "\(group)")"
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        dirtyDot.font = .systemFont(ofSize: 9)
        dirtyDot.textColor = .systemOrange
        dirtyDot.toolTip = "This group has offline edits"

        let maxLabel = NSTextField(labelWithString: "MAX")
        maxLabel.font = .systemFont(ofSize: 11)
        maxLabel.textColor = Palette.secondaryText

        maxPopup.controlSize = .small
        maxPopup.font = .systemFont(ofSize: 11)
        for m in 1...DSPProject.memorySlots {
            maxPopup.addItem(withTitle: "\(m)")
            maxPopup.lastItem?.tag = m
        }
        maxPopup.target = self
        maxPopup.action = #selector(maxChanged)
        maxPopup.toolTip = "Number of slots this group exposes (applies on Write)"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [titleLabel, dirtyDot, spacer, maxLabel, maxPopup])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        let column = NSTableColumn(identifier: .init("slot"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.registerForDraggedTypes([Self.dragType])
        table.onDeleteRow = { [weak self] row in self?.onDelete?(row) }

        let stack = NSStackView(views: [header, table])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        tableHeight = table.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            table.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableHeight,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func render(list: GroupList, currentNum: Int?, dirty: Bool,
                rowTitle: @escaping (GroupSlot) -> String) {
        self.list = list
        self.currentNum = currentNum
        self.rowTitle = rowTitle
        dirtyDot.isHidden = !dirty
        maxPopup.selectItem(withTag: list.max)
        let selected = table.selectedRow
        isProgrammaticSelection = true
        table.reloadData()
        tableHeight.constant = CGFloat(visibleRows) * (table.rowHeight + table.intercellSpacing.height)
        if selected >= 0 && selected < visibleRows {
            table.selectRowIndexes([selected], byExtendingSelection: false)
        }
        isProgrammaticSelection = false
    }

    private var visibleRows: Int {
        max(1, min(list.max, list.slots.count))
    }

    var selectedRow: Int? {
        table.selectedRow >= 0 ? table.selectedRow : nil
    }

    func clearSelection() {
        isProgrammaticSelection = true
        table.deselectAll(nil)
        isProgrammaticSelection = false
    }

    func select(row: Int) {
        guard row < visibleRows else { return }
        isProgrammaticSelection = true
        table.selectRowIndexes([row], byExtendingSelection: false)
        isProgrammaticSelection = false
    }

    @objc private func maxChanged() {
        onMaxChanged?(maxPopup.selectedTag())
    }

    @objc private func rowDoubleClicked() {
        guard table.clickedRow >= 0 else { return }
        onRecall?(table.clickedRow)
    }
}

extension GroupSectionView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { visibleRows }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("slotCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SlotCell
            ?? SlotCell(identifier: id)
        guard list.slots.indices.contains(row) else { return cell }
        cell.configure(num: row, title: rowTitle(list.slots[row]), isCurrent: row == currentNum)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection else { return }
        if table.selectedRow >= 0 { onSelectionChanged?() }
    }

    // MARK: Drag & drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setPropertyList([group, row], forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingPasteboard.availableType(from: [Self.dragType]) != nil else { return [] }
        if op == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let plist = info.draggingPasteboard.propertyList(forType: Self.dragType) as? [Int],
              plist.count == 2 else { return false }
        onMove?((group: plist[0], num: plist[1]), (group: group, num: row))
        return true
    }
}

/// Table that forwards Delete/Backspace on a selected row.
private final class SlotTableView: NSTableView {
    var onDeleteRow: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<UInt16> = [51, 117]  // backspace, forward delete
        if deleteKeys.contains(event.keyCode), selectedRow >= 0 {
            onDeleteRow?(selectedRow)
            return
        }
        super.keyDown(with: event)
    }
}

private final class SlotCell: NSTableCellView {
    private let numLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let currentMark = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        numLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        numLabel.textColor = Palette.tertiaryText
        numLabel.alignment = .right
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        currentMark.image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                                    accessibilityDescription: "Current slot")
        currentMark.contentTintColor = .controlAccentColor
        currentMark.toolTip = "Currently recalled on the aFrame"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [numLabel, titleLabel, spacer, currentMark])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            numLabel.widthAnchor.constraint(equalToConstant: 22),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(num: Int, title: String, isCurrent: Bool) {
        numLabel.stringValue = String(format: "%02d", num + 1)
        titleLabel.stringValue = title
        currentMark.isHidden = !isCurrent
    }
}

// MARK: - Tone list popover (read-only 01–80 reference)

/// The factory editor's "Tone List": a read-only reference of the 80 tone
/// numbers with their instrument and effect names, for picking Insert numbers.
private final class ToneListViewController: NSViewController {
    private let tableView = NSTableView()
    private var inst: [String] = []
    private var effect: [String] = []

    override func loadView() {
        let numCol = NSTableColumn(identifier: .init("num"))
        numCol.title = "No."
        numCol.width = 34
        let instCol = NSTableColumn(identifier: .init("inst"))
        instCol.title = "Instrument"
        instCol.width = 130
        let fxCol = NSTableColumn(identifier: .init("effect"))
        fxCol.title = "Effect"
        fxCol.width = 130
        for col in [numCol, instCol, fxCol] { tableView.addTableColumn(col) }
        tableView.style = .inset
        tableView.rowHeight = 20
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.selectionHighlightStyle = .none

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        view = container
        preferredContentSize = NSSize(width: 330, height: 400)
    }

    func configure(inst: [String], effect: [String]) {
        self.inst = inst
        self.effect = effect
        tableView.reloadData()
    }
}

extension ToneListViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        max(inst.count, effect.count)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("toneListCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
        let text: NSTextField
        if let cell, let tf = cell.textField {
            text = tf
        } else {
            text = NSTextField(labelWithString: "")
            text.font = .systemFont(ofSize: 11)
            text.lineBreakMode = .byTruncatingTail
            let cell = NSTableCellView()
            cell.identifier = id
            cell.textField = text
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return configureToneListCell(cell, column: tableColumn, row: row)
        }
        guard let existing = cell else { return nil }
        return configureToneListCell(existing, column: tableColumn, row: row)
    }

    private func configureToneListCell(_ cell: NSTableCellView, column: NSTableColumn?, row: Int) -> NSTableCellView {
        let value: String
        switch column?.identifier.rawValue {
        case "num": value = String(format: "%02d", row + 1)
        case "inst": value = inst.indices.contains(row) ? inst[row] : "—"
        default: value = effect.indices.contains(row) ? effect[row] : "—"
        }
        cell.textField?.stringValue = value
        cell.textField?.textColor = column?.identifier.rawValue == "num" ? Palette.tertiaryText : .labelColor
        return cell
    }
}
