import AppKit
import AFrameKit
import UniformTypeIdentifiers

/// The tone copier — Snaproll's take on the factory editor's "Tone Edit2"
/// screen. Two panes of 80 tone sets (an instrument+effect pair per index):
/// the left ("From") is a read-only source, the right ("To") accumulates
/// copies in a pending overlay. Each pane is independently sourced from the
/// connected aFrame (one bulk project read) or a `.prj` project file, so
/// tones can be copied device→file, file→device, and file→file.
///
/// Commit semantics follow the To source: to a file, the overlay is applied
/// to the loaded project image and saved via a save panel (no device risk);
/// to the aFrame, the changed sets are uploaded via the edit buffer after a
/// confirmation alert and an automatic project backup.
final class ToneCopyWindowController: NSWindowController {
    /// Asks the session for a device project snapshot (routed back through
    /// `deliverSnapshot`).
    var onFetchDevice: (() -> Void)?
    /// Uploads changed tone sets to the device (Stage 3: session.writeToneSets).
    var onWriteToneSets: (([ToneSetChange]) -> Void)?

    private let fromPane = TonePaneView(title: "From")
    private let toPane = TonePaneView(title: "To")
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let addAllButton = NSButton(title: "Add All", target: nil, action: nil)
    private let commitButton = NSButton(title: "Commit", target: nil, action: nil)
    private let hintLabel = NSTextField(labelWithString: "")

    private var connected = false
    /// Which panes are waiting on a device snapshot.
    private var awaitingSnapshot: [TonePaneView] = []

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Tone Copy"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 400)
        window.setFrameAutosaveName("ToneCopy")
        self.init(window: window)
        buildContent()
    }

    private func buildContent() {
        fromPane.isDestination = false
        toPane.isDestination = true
        for pane in [fromPane, toPane] {
            pane.onSourceRequest = { [weak self] kind in self?.sourceRequested(kind, pane: pane) }
            pane.onChanged = { [weak self] in self?.refreshControls() }
        }
        fromPane.onReturnKey = { [weak self] in self?.add() }

        addButton.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: "Add")
        addButton.imagePosition = .imageLeading
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(add)
        addButton.toolTip = "Copy the selected From tone set into the selected To slot (Return)"

        addAllButton.image = NSImage(systemSymbolName: "arrow.right.doc.on.clipboard",
                                     accessibilityDescription: "Add all")
        addAllButton.imagePosition = .imageLeading
        addAllButton.bezelStyle = .rounded
        addAllButton.target = self
        addAllButton.action = #selector(addAll)
        addAllButton.toolTip = "Copy every From tone set into the same-numbered To slot"

        let center = NSStackView(views: [addButton, addAllButton])
        center.orientation = .vertical
        center.spacing = 8

        let panes = NSStackView(views: [fromPane, center, toPane])
        panes.orientation = .horizontal
        panes.alignment = .centerY
        panes.spacing = 10
        panes.distribution = .fill
        panes.translatesAutoresizingMaskIntoConstraints = false
        fromPane.widthAnchor.constraint(equalTo: toPane.widthAnchor).isActive = true
        fromPane.heightAnchor.constraint(equalTo: panes.heightAnchor).isActive = true
        toPane.heightAnchor.constraint(equalTo: panes.heightAnchor).isActive = true

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = Palette.secondaryText
        hintLabel.lineBreakMode = .byTruncatingTail

        commitButton.bezelStyle = .rounded
        commitButton.keyEquivalent = "\r"
        commitButton.target = self
        commitButton.action = #selector(commit)

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [hintLabel, footerSpacer, commitButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let outer = NSStackView(views: [panes, footer])
        outer.orientation = .vertical
        outer.spacing = 10
        outer.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        outer.translatesAutoresizingMaskIntoConstraints = false
        footer.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: -32).isActive = true

        let root = NSView()
        root.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: root.topAnchor),
            outer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window?.contentView = root
        refreshControls()
    }

    // MARK: Input from MainWindowController

    func setConnected(_ connected: Bool) {
        self.connected = connected
        fromPane.deviceAvailable = connected
        toPane.deviceAvailable = connected
        refreshControls()
    }

    /// Routes a `.projectSnapshot` event to the pane(s) that asked for it.
    func deliverSnapshot(_ project: DSPProject) {
        for pane in awaitingSnapshot {
            pane.setProject(project, source: .device)
        }
        awaitingSnapshot = []
        refreshControls()
    }

    /// Called after the session confirms a device write: clear the pending
    /// marks and re-fetch the device project so device-sourced panes show
    /// what's actually on the aFrame now.
    func deviceWriteFinished() {
        toPane.clearPending()
        var wantsFresh = false
        for pane in [fromPane, toPane] {
            if case .device = pane.source {
                if !awaitingSnapshot.contains(where: { $0 === pane }) {
                    awaitingSnapshot.append(pane)
                }
                wantsFresh = true
            }
        }
        if wantsFresh { onFetchDevice?() }
        refreshControls()
    }

    // MARK: Sources

    private func sourceRequested(_ kind: TonePaneView.SourceKind, pane: TonePaneView) {
        switch kind {
        case .device:
            guard connected else { return }
            if !awaitingSnapshot.contains(where: { $0 === pane }) {
                awaitingSnapshot.append(pane)
            }
            onFetchDevice?()
        case .file:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "prj") ?? .data]
            panel.allowsMultipleSelection = false
            panel.beginSheetModal(for: window!) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    let project = try ProjectFile.load(url)
                    pane.setProject(project, source: .file(url))
                } catch {
                    self?.presentError(error, title: "Couldn't read \(url.lastPathComponent)")
                }
                self?.refreshControls()
            }
        }
    }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window!)
    }

    // MARK: Copying

    @objc private func add() {
        guard let fromRow = fromPane.selectedRow, let set = fromPane.toneSet(at: fromRow),
              let toRow = toPane.selectedRow else { NSSound.beep(); return }
        toPane.stagePending(at: toRow, set: set)
        // Factory behavior: both selections advance so repeated Return fills down.
        fromPane.select(row: min(fromRow + 1, DSPProject.patchCount - 1))
        toPane.select(row: min(toRow + 1, DSPProject.patchCount - 1))
        refreshControls()
    }

    @objc private func addAll() {
        guard fromPane.hasProject else { NSSound.beep(); return }
        for n in 0..<DSPProject.patchCount {
            if let set = fromPane.toneSet(at: n) {
                toPane.stagePending(at: n, set: set)
            }
        }
        refreshControls()
    }

    // MARK: Commit

    @objc private func commit() {
        let changes = toPane.pendingChanges()
        guard !changes.isEmpty else { return }
        switch toPane.source {
        case .device:
            confirmDeviceWrite(changes)
        case .file(let url):
            saveToFile(changes, suggestedURL: url)
        case .none:
            break
        }
    }

    private func confirmDeviceWrite(_ changes: [ToneSetChange]) {
        guard connected else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Write \(changes.count) tone set\(changes.count == 1 ? "" : "s") to the aFrame?"
        alert.informativeText = """
            The device's tone slots will be overwritten. The current project \
            is backed up automatically first, and the change persists when the \
            aFrame is powered off normally while still connected.
            """
        alert.addButton(withTitle: "Write")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.onWriteToneSets?(changes)
        }
    }

    private func saveToFile(_ changes: [ToneSetChange], suggestedURL: URL) {
        guard var project = toPane.project else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "prj") ?? .data]
        panel.nameFieldStringValue = suggestedURL.lastPathComponent
        panel.directoryURL = suggestedURL.deletingLastPathComponent()
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            for c in changes {
                project.setToneSet(num: c.num, inst: c.inst, effect: c.effect)
            }
            do {
                try ProjectFile.save(project, to: url)
                self?.toPane.setProject(project, source: .file(url))
                self?.hintLabel.stringValue = "Saved \(changes.count) tone set\(changes.count == 1 ? "" : "s") to \(url.lastPathComponent)"
            } catch {
                self?.presentError(error, title: "Couldn't save \(url.lastPathComponent)")
            }
            self?.refreshControls()
        }
    }

    // MARK: State

    private func refreshControls() {
        let pendingCount = toPane.pendingChanges().count
        addButton.isEnabled = fromPane.selectedRow != nil && toPane.selectedRow != nil
            && fromPane.hasProject && toPane.hasProject
        addAllButton.isEnabled = fromPane.hasProject && toPane.hasProject
        switch toPane.source {
        case .device:
            commitButton.title = "Write \(pendingCount) to aFrame"
            commitButton.isEnabled = pendingCount > 0 && connected
        case .file:
            commitButton.title = "Save to File…"
            commitButton.isEnabled = pendingCount > 0
        case .none:
            commitButton.title = "Commit"
            commitButton.isEnabled = false
        }
        if !fromPane.hasProject || !toPane.hasProject {
            hintLabel.stringValue = "Load both panes from the aFrame or a .prj project file"
        } else if pendingCount > 0 {
            hintLabel.stringValue = "\(pendingCount) tone set\(pendingCount == 1 ? "" : "s") staged — Commit to apply"
        } else {
            hintLabel.stringValue = "Select a From row and a To row, then Add (Return) · Delete blanks a To slot"
        }
    }
}

/// One staged copy: replace tone set `num` with the given halves.
struct ToneSetChange {
    let num: Int
    let inst: DSPPatch?
    let effect: DSPPatch?
}

// MARK: - Pane

/// One side of the copier: a source picker (aFrame / project file), a path
/// label, and an 80-row table of tone sets. The destination pane additionally
/// carries the pending overlay and supports Delete-to-blank.
private final class TonePaneView: NSView {
    enum SourceKind { case device, file }
    enum Source {
        case none
        case device
        case file(URL)
    }

    var onSourceRequest: ((SourceKind) -> Void)?
    var onChanged: (() -> Void)?
    var onReturnKey: (() -> Void)?

    var isDestination = false
    var deviceAvailable = false {
        didSet { sourcePopup.item(at: 1)?.isEnabled = deviceAvailable }
    }

    private(set) var source: Source = .none
    private(set) var project: DSPProject?
    /// Destination overlay: staged tone sets keyed by slot number.
    private var pending: [Int: ToneSetChange] = [:]

    private let titleLabel = NSTextField(labelWithString: "")
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pathLabel = NSTextField(labelWithString: "")
    private let table = ToneSetTableView()

    var hasProject: Bool { project != nil }

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title.uppercased()
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = Palette.sectionTitle

        sourcePopup.addItem(withTitle: "Choose Source…")
        sourcePopup.addItem(withTitle: "aFrame")
        sourcePopup.addItem(withTitle: "Project File…")
        sourcePopup.item(at: 0)?.isEnabled = false
        sourcePopup.autoenablesItems = false
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChosen)

        pathLabel.font = .systemFont(ofSize: 10)
        pathLabel.textColor = Palette.tertiaryText
        pathLabel.lineBreakMode = .byTruncatingMiddle

        let header = NSStackView(views: [titleLabel, sourcePopup])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let numCol = NSTableColumn(identifier: .init("num"))
        numCol.title = "No."
        numCol.width = 30
        let instCol = NSTableColumn(identifier: .init("inst"))
        instCol.title = "Instrument"
        instCol.width = 120
        let fxCol = NSTableColumn(identifier: .init("effect"))
        fxCol.title = "Effect"
        fxCol.width = 120
        for col in [numCol, instCol, fxCol] { table.addTableColumn(col) }
        table.style = .inset
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        table.onDeleteRow = { [weak self] row in self?.deletePressed(row) }
        table.onReturnKey = { [weak self] in self?.onReturnKey?() }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true

        let stack = NSStackView(views: [header, pathLabel, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pathLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Source & data

    @objc private func sourceChosen() {
        switch sourcePopup.indexOfSelectedItem {
        case 1: onSourceRequest?(.device)
        case 2: onSourceRequest?(.file)
        default: break
        }
        // Selection is confirmed via setProject; don't leave a stale choice.
        syncPopup()
    }

    func setProject(_ project: DSPProject, source: Source) {
        self.project = project
        self.source = source
        pending = [:]
        syncPopup()
        table.reloadData()
        onChanged?()
    }

    private func syncPopup() {
        switch source {
        case .none:
            sourcePopup.selectItem(at: 0)
            pathLabel.stringValue = " "
        case .device:
            sourcePopup.selectItem(at: 1)
            pathLabel.stringValue = "aFrame project “\(project?.name ?? "")”"
        case .file(let url):
            sourcePopup.selectItem(at: 2)
            pathLabel.stringValue = url.path
        }
    }

    // MARK: Tone sets

    /// The effective tone set at `num` — the pending overlay wins over the
    /// loaded project (so staged copies can themselves be re-copied).
    func toneSet(at num: Int) -> (inst: DSPPatch, effect: DSPPatch)? {
        if let staged = pending[num] {
            if let i = staged.inst, let e = staged.effect { return (i, e) }
        }
        guard let project, (0..<DSPProject.patchCount).contains(num) else { return nil }
        return (project.instPatch[num], project.effectPatch[num])
    }

    func stagePending(at num: Int, set: (inst: DSPPatch, effect: DSPPatch)) {
        guard isDestination, hasProject else { return }
        // Copying a blank/blank set produces a NAKED set, like the factory.
        let inst = set.inst.name.isEmpty ? DSPPatch.naked() : set.inst
        let effect = set.effect.name.isEmpty ? DSPPatch.naked() : set.effect
        pending[num] = ToneSetChange(num: num, inst: inst, effect: effect)
        table.reloadData(forRowIndexes: [num], columnIndexes: [0, 1, 2])
    }

    private func deletePressed(_ row: Int) {
        guard isDestination, hasProject else { return }
        // Factory semantics: Delete blanks the To slot (a NAKED set). If the
        // row only had a staged copy, this replaces it with the blank.
        pending[row] = ToneSetChange(num: row, inst: .naked(), effect: .naked())
        table.reloadData(forRowIndexes: [row], columnIndexes: [0, 1, 2])
        onChanged?()
    }

    func pendingChanges() -> [ToneSetChange] {
        pending.values.sorted { $0.num < $1.num }
    }

    func clearPending() {
        pending = [:]
        table.reloadData()
    }

    // MARK: Selection

    var selectedRow: Int? {
        table.selectedRow >= 0 ? table.selectedRow : nil
    }

    func select(row: Int) {
        guard row < DSPProject.patchCount else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }
}

extension TonePaneView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        hasProject ? DSPProject.patchCount : 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("toneSetCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            let text = NSTextField(labelWithString: "")
            text.font = .systemFont(ofSize: 11)
            text.lineBreakMode = .byTruncatingTail
            let fresh = NSTableCellView()
            fresh.identifier = id
            fresh.textField = text
            text.translatesAutoresizingMaskIntoConstraints = false
            fresh.addSubview(text)
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: fresh.leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(equalTo: fresh.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: fresh.centerYAnchor),
            ])
            cell = fresh
        }

        let staged = pending[row]
        let display: (String, String)
        if let staged, let i = staged.inst, let e = staged.effect {
            display = (i.name.isEmpty ? "NAKED" : i.name, e.name.isEmpty ? "NAKED" : e.name)
        } else if let set = toneSet(at: row) {
            display = (set.inst.name.isEmpty ? "NAKED" : set.inst.name,
                       set.effect.name.isEmpty ? "NAKED" : set.effect.name)
        } else {
            display = ("—", "—")
        }

        let value: String
        var color = NSColor.labelColor
        switch tableColumn?.identifier.rawValue {
        case "num":
            value = String(format: "%02d", row + 1)
            color = Palette.tertiaryText
        case "inst":
            value = display.0
        default:
            value = display.1
        }
        if staged != nil && tableColumn?.identifier.rawValue != "num" {
            color = .systemOrange  // pending, not yet committed
        }
        cell.textField?.stringValue = value
        cell.textField?.textColor = color
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onChanged?()
    }
}

/// Table forwarding Delete/Backspace and Return on a selected row.
private final class ToneSetTableView: NSTableView {
    var onDeleteRow: ((Int) -> Void)?
    var onReturnKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<UInt16> = [51, 117]  // backspace, forward delete
        if deleteKeys.contains(event.keyCode), selectedRow >= 0 {
            onDeleteRow?(selectedRow)
            return
        }
        if event.keyCode == 36, selectedRow >= 0 {  // return
            onReturnKey?()
            return
        }
        super.keyDown(with: event)
    }
}
