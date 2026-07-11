import AppKit
import AFrameKit
import UniformTypeIdentifiers

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSMenuItemValidation, NSWindowDelegate {
    private let session = EditorSession()
    private let editorVC = EditorViewController()
    private var monitorWC: MonitorWindowController?
    private var groupEditorWC: GroupEditorWindowController?
    private var toneCopyWC: ToneCopyWindowController?

    // Latest project tone-name lists, relayed to the group editor to resolve
    // slot patch numbers into names.
    private var instNames: [String] = []
    private var effectNames: [String] = []

    /// Set once teardown starts, so the window closing as part of app
    /// termination doesn't re-enter `NSApp.terminate`.
    private var isShuttingDown = false

    // Toolbar controls
    private let portPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let randomizeButton = NSButton(
        image: NSImage(systemSymbolName: "die.face.5", accessibilityDescription: "Randomize")!,
        target: nil, action: nil)

    private let randomizePopover = NSPopover()
    private let randomizeVC = RandomizePopoverViewController()

    // Group/tone navigation bar (top of the detail pane)
    private let groupNav = GroupNavView()

    // Status bar
    private let statusLabel = NSTextField(labelWithString: "Not connected")
    private let firmwareLabel = NSTextField(labelWithString: "")
    private let statusDot = NSTextField(labelWithString: "●")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Snaproll"
        window.minSize = NSSize(width: 720, height: 600)
        window.center()
        self.init(window: window)
        window.delegate = self
        buildContent()
        buildToolbar()
        wireSession()
        refreshPorts()
    }

    // MARK: Layout

    private func buildContent() {
        // Detail area: nav bar + editor + status bar. Tone browsing lives in the
        // editor header's popup, so there's no sidebar pane.
        let detailVC = NSViewController()
        let container = NSView()
        detailVC.view = container

        addChildIfNeeded(editorVC, to: detailVC)
        let editorView = editorVC.view
        editorView.translatesAutoresizingMaskIntoConstraints = false

        // Navigation bar across the top of the detail pane, above the editor.
        let navBackground = NSVisualEffectView()
        navBackground.material = .headerView
        navBackground.blendingMode = .withinWindow
        navBackground.translatesAutoresizingMaskIntoConstraints = false
        groupNav.translatesAutoresizingMaskIntoConstraints = false
        navBackground.addSubview(groupNav)

        let navDivider = NSBox()
        navDivider.boxType = .separator
        navDivider.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(navBackground)
        container.addSubview(navDivider)
        container.addSubview(editorView)

        statusDot.font = .systemFont(ofSize: 9)
        statusDot.textColor = .systemRed
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = Palette.secondaryText
        statusLabel.lineBreakMode = .byTruncatingTail
        firmwareLabel.font = .systemFont(ofSize: 11)
        firmwareLabel.textColor = Palette.tertiaryText
        firmwareLabel.alignment = .right

        let statusStack = NSStackView(views: [statusDot, statusLabel, NSView(), firmwareLabel])
        statusStack.orientation = .horizontal
        statusStack.spacing = 6
        statusStack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        statusStack.translatesAutoresizingMaskIntoConstraints = false

        let statusBackground = NSVisualEffectView()
        statusBackground.material = .titlebar
        statusBackground.blendingMode = .withinWindow
        statusBackground.translatesAutoresizingMaskIntoConstraints = false
        statusBackground.addSubview(statusStack)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusBackground)
        container.addSubview(divider)

        NSLayoutConstraint.activate([
            navBackground.topAnchor.constraint(equalTo: container.topAnchor),
            navBackground.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            navBackground.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            navBackground.heightAnchor.constraint(equalToConstant: 40),
            groupNav.leadingAnchor.constraint(equalTo: navBackground.leadingAnchor),
            groupNav.trailingAnchor.constraint(equalTo: navBackground.trailingAnchor),
            groupNav.topAnchor.constraint(equalTo: navBackground.topAnchor),
            groupNav.bottomAnchor.constraint(equalTo: navBackground.bottomAnchor),

            navDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            navDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            navDivider.topAnchor.constraint(equalTo: navBackground.bottomAnchor),

            editorView.topAnchor.constraint(equalTo: navDivider.bottomAnchor),
            editorView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editorView.bottomAnchor.constraint(equalTo: statusBackground.topAnchor),

            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: statusBackground.topAnchor),

            statusBackground.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBackground.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBackground.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBackground.heightAnchor.constraint(equalToConstant: 26),

            statusStack.topAnchor.constraint(equalTo: statusBackground.topAnchor),
            statusStack.leadingAnchor.constraint(equalTo: statusBackground.leadingAnchor),
            statusStack.trailingAnchor.constraint(equalTo: statusBackground.trailingAnchor),
            statusStack.bottomAnchor.constraint(equalTo: statusBackground.bottomAnchor),
        ])

        window?.contentViewController = detailVC
    }

    private func addChildIfNeeded(_ child: NSViewController, to parent: NSViewController) {
        parent.addChild(child)
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    // MARK: Toolbar delegate

    private static let connectionItemID = NSToolbarItem.Identifier("connection")
    private static let groupsItemID = NSToolbarItem.Identifier("groups")
    private static let toneCopyItemID = NSToolbarItem.Identifier("toneCopy")
    private static let monitorItemID = NSToolbarItem.Identifier("monitor")
    private static let randomizeItemID = NSToolbarItem.Identifier("randomize")
    private static let saveItemID = NSToolbarItem.Identifier("save")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.groupsItemID, Self.toneCopyItemID, Self.monitorItemID, Self.randomizeItemID,
         .flexibleSpace, Self.connectionItemID, Self.saveItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.connectionItemID:
            portPopup.controlSize = .regular
            portPopup.widthAnchor.constraint(equalToConstant: 210).isActive = true
            connectButton.target = self
            connectButton.action = #selector(toggleConnection)
            connectButton.bezelStyle = .texturedRounded
            let stack = NSStackView(views: [portPopup, connectButton])
            stack.orientation = .horizontal
            stack.spacing = 6
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = stack
            item.label = "Connection"
            return item
        case Self.groupsItemID:
            let button = NSButton(
                image: NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: "Groups")!,
                target: self, action: #selector(showGroupEditor))
            button.bezelStyle = .texturedRounded
            button.imagePosition = .imageOnly
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = button
            item.label = "Groups"
            item.toolTip = "Open the group map editor"
            return item
        case Self.toneCopyItemID:
            let button = NSButton(
                image: NSImage(systemSymbolName: "arrow.left.arrow.right.square",
                               accessibilityDescription: "Tone Copy")!,
                target: self, action: #selector(showToneCopy))
            button.bezelStyle = .texturedRounded
            button.imagePosition = .imageOnly
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = button
            item.label = "Tone Copy"
            item.toolTip = "Copy tone sets between the aFrame and project files"
            return item
        case Self.monitorItemID:
            let button = NSButton(
                image: NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Monitor")!,
                target: self, action: #selector(showMonitor))
            button.bezelStyle = .texturedRounded
            button.imagePosition = .imageOnly
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = button
            item.label = "Monitor"
            item.toolTip = "Open the real-time pressure / level monitor"
            return item
        case Self.randomizeItemID:
            randomizeButton.target = self
            randomizeButton.action = #selector(showRandomize)
            randomizeButton.bezelStyle = .texturedRounded
            randomizeButton.imagePosition = .imageOnly
            randomizeButton.isEnabled = false
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = randomizeButton
            item.label = "Randomize"
            item.toolTip = "Randomize parameters of the current tone"
            return item
        case Self.saveItemID:
            saveButton.target = self
            saveButton.action = #selector(saveCurrentTone)
            saveButton.bezelStyle = .texturedRounded
            saveButton.keyEquivalent = "s"
            saveButton.keyEquivalentModifierMask = [.command]
            saveButton.isEnabled = false
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = saveButton
            item.label = "Save"
            item.toolTip = "Write the edit buffer to its project slot (⌘S)"
            return item
        default:
            return nil
        }
    }

    // MARK: Ports

    @objc private func refreshPorts() {
        let previous = portPopup.titleOfSelectedItem
        portPopup.removeAllItems()
        portPopup.addItem(withTitle: "Mock Device")
        let ports = SerialPortDiscovery.candidatePorts()
            .filter { !$0.contains("Bluetooth") && !$0.contains("debug") }
        if !ports.isEmpty {
            portPopup.menu?.addItem(.separator())
            portPopup.addItems(withTitles: ports)
        }
        if let previous, portPopup.itemTitles.contains(previous) {
            portPopup.selectItem(withTitle: previous)
        } else if let hardware = ports.first {
            portPopup.selectItem(withTitle: hardware)
        }
    }

    // MARK: Session wiring

    private func wireSession() {
        randomizePopover.contentViewController = randomizeVC
        randomizePopover.behavior = .transient
        randomizeVC.onRandomize = { [weak self] idx, rate in
            guard let self, let idx else { return }
            let targets = self.editorVC.randomizeTargets()
            guard targets.indices.contains(idx) else { return }
            self.editorVC.randomize(target: targets[idx], rate: rate)
            self.randomizeVC.setUndoEnabled(self.editorVC.hasRandomizeUndo)
        }
        randomizeVC.onUndo = { [weak self] in
            self?.editorVC.undoRandomize()
            self?.randomizeVC.setUndoEnabled(false)
        }

        groupNav.onNavigate = { [weak self] group, number in
            self?.session.recallGroupSlot(group: group, num: number)
        }

        groupNav.onDomainChange = { [weak self] sel in
            self?.changeDomain(sel)
        }
        editorVC.onSelectTone = { [weak self] sel, num in
            self?.session.selectTone(sel, num: num)
        }
        editorVC.onParamChange = { [weak self] sel, index, value in
            self?.session.setParameter(sel, index: index, value: value)
        }
        editorVC.onRename = { [weak self] sel, name in
            self?.session.rename(sel, to: name)
        }

        session.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .connected(let firmware, let group):
                self.statusDot.textColor = .systemGreen
                self.statusLabel.stringValue =
                    "Connected · Group \(ToneGroup(rawValue: group.group)?.description ?? "?")-\(String(format: "%02d", group.number + 1))"
                self.firmwareLabel.stringValue = firmware
                self.connectButton.title = "Disconnect"
                self.connectButton.isEnabled = true
                self.saveButton.isEnabled = true
                self.randomizeButton.isEnabled = true
                self.groupNav.update(from: group)
                if self.monitorWC?.window?.isVisible == true {
                    self.session.startMonitoring()
                }
                if self.groupEditorWC?.window?.isVisible == true {
                    self.session.loadGroups()
                }
                self.toneCopyWC?.setConnected(true)
            case .disconnected:
                self.statusDot.textColor = .systemRed
                self.statusLabel.stringValue = "Not connected"
                self.firmwareLabel.stringValue = ""
                self.connectButton.title = "Connect"
                self.connectButton.isEnabled = true
                self.saveButton.isEnabled = false
                self.randomizeButton.isEnabled = false
                self.randomizePopover.close()
                self.editorVC.clear()
                self.monitorWC?.setIdle("Not connected")
                self.groupEditorWC?.setIdle()
                self.toneCopyWC?.setConnected(false)
                self.groupNav.setIdle()
            case .names(let sel, let list):
                self.editorVC.setToneNames(list, for: sel)
                if sel == .instrument { self.instNames = list } else { self.effectNames = list }
                self.groupEditorWC?.setNames(inst: self.instNames, effect: self.effectNames)
            case .toneLoaded(let sel, let num, let tone):
                self.editorVC.showTone(tone, num: num, for: sel)
            case .meters(let peak, let pressure):
                self.monitorWC?.update(peak: peak, pressure: pressure)
            case .groups(let list, let current):
                self.groupEditorWC?.update(lists: list, current: current)
                self.groupNav.update(from: current)
            case .groupsWritten(let changed):
                self.statusLabel.stringValue = changed == 0
                    ? "Group map already matches — nothing to write"
                    : "Wrote \(changed) group slot\(changed == 1 ? "" : "s") — persists at normal power-off"
            case .projectSnapshot(let project):
                self.toneCopyWC?.deliverSnapshot(project)
            case .toneSetsWritten(let count):
                self.toneCopyWC?.deviceWriteFinished()
                self.statusLabel.stringValue =
                    "Wrote \(count) tone set\(count == 1 ? "" : "s") — persists at normal power-off"
            case .projectSaved(let name, let url):
                let label = name.isEmpty ? url.lastPathComponent : "“\(name)” to \(url.lastPathComponent)"
                self.statusLabel.stringValue = "Saved project \(label)"
            case .projectLoaded(let name, let backup):
                let note = backup.map { " (previous project backed up as \($0.lastPathComponent))" } ?? ""
                self.statusLabel.stringValue = "Loaded project “\(name)”\(note)"
            case .saved(let sel, let num):
                let kind = sel == .instrument ? "instrument" : "effect"
                self.statusLabel.stringValue =
                    "Saved \(kind) to slot \(String(format: "%02d", num + 1)) — persists at normal power-off"
            case .status(let text):
                self.statusLabel.stringValue = text
            case .error(let text):
                self.statusLabel.stringValue = "⚠ \(text)"
                if !self.session.isConnected {
                    self.connectButton.title = "Connect"
                    self.connectButton.isEnabled = true
                }
            }
        }
    }

    // MARK: Actions

    /// Single point of truth for the instrument/effect view switch: updates the
    /// editor and keeps the nav-bar switcher in sync. `setDomain` is
    /// callback-free, so this can't loop.
    private func changeDomain(_ sel: ToneSelect) {
        editorVC.setDomain(sel)
        groupNav.setDomain(sel)
    }

    @objc func showInstrumentView(_ sender: Any?) {
        changeDomain(.instrument)
    }

    @objc func showEffectView(_ sender: Any?) {
        changeDomain(.effect)
    }

    @objc private func toggleConnection() {
        if session.isConnected {
            session.disconnect()
            return
        }
        refreshPorts()
        let transport: AFrameTransport
        if portPopup.indexOfSelectedItem == 0 {
            transport = MockAFrame()
        } else if let title = portPopup.titleOfSelectedItem, title.hasPrefix("/dev/") {
            transport = POSIXSerialPort(path: title)
        } else {
            statusLabel.stringValue = "Select a port or the mock device"
            return
        }
        connectButton.isEnabled = false
        statusLabel.stringValue = "Connecting…"
        session.connect(transport: transport)
    }

    @objc private func showMonitor() {
        if monitorWC == nil {
            let wc = MonitorWindowController()
            wc.onClose = { [weak self] in self?.session.stopMonitoring() }
            monitorWC = wc
        }
        monitorWC?.showWindow(nil)
        if session.isConnected {
            session.startMonitoring()
        } else {
            monitorWC?.setIdle("Waiting for connection…")
        }
    }

    @objc private func showRandomize() {
        randomizeVC.configurePicker(targets: editorVC.randomizeTargets().map(\.label),
                                    canUndo: editorVC.hasRandomizeUndo)
        randomizePopover.show(relativeTo: randomizeButton.bounds, of: randomizeButton, preferredEdge: .maxY)
    }

    @objc private func showGroupEditor() {
        if groupEditorWC == nil {
            let wc = GroupEditorWindowController()
            wc.onRecall = { [weak self] g, n in self?.session.recallGroupSlot(group: g, num: n) }
            wc.onWrite = { [weak self] lists in self?.session.writeGroupMap(lists) }
            wc.onReload = { [weak self] in self?.session.loadGroups() }
            wc.currentSelection = { [weak self] in
                guard let self,
                      let inst = self.editorVC.currentSlot(for: .instrument),
                      let effect = self.editorVC.currentSlot(for: .effect) else { return nil }
                return (inst, effect)
            }
            groupEditorWC = wc
        }
        groupEditorWC?.setNames(inst: instNames, effect: effectNames)
        groupEditorWC?.showWindow(nil)
        if session.isConnected {
            session.loadGroups()
        } else {
            groupEditorWC?.setIdle()
        }
    }

    @objc func showToneCopy() {
        if toneCopyWC == nil {
            let wc = ToneCopyWindowController()
            wc.onFetchDevice = { [weak self] in self?.session.fetchProjectSnapshot() }
            wc.onWriteToneSets = { [weak self] changes in
                self?.session.writeToneSets(changes.map { ($0.num, $0.inst, $0.effect) })
            }
            toneCopyWC = wc
        }
        toneCopyWC?.setConnected(session.isConnected)
        toneCopyWC?.showWindow(nil)
    }

    // MARK: Project file load / save

    private static let projectType = UTType(filenameExtension: "prj") ?? .data

    @objc func saveProjectAs(_ sender: Any?) {
        guard session.isConnected, let window else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.nameFieldStringValue = "aFrame Project.prj"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.session.saveProject(to: url)
        }
    }

    @objc func openProject(_ sender: Any?) {
        guard session.isConnected, let window else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.confirmAndLoadProject(url)
        }
    }

    /// Loading a project is destructive — it overwrites the whole device
    /// project — so require an explicit confirmation first.
    private func confirmAndLoadProject(_ url: URL) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Replace the aFrame's entire project?"
        alert.informativeText = """
            Loading “\(url.lastPathComponent)” overwrites all 160 patches and the \
            group map on the connected aFrame. The current project is backed up \
            first (to Application Support / Snaproll / Backups).
            """
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] resp in
            if resp == .alertFirstButtonReturn { self?.session.loadProject(from: url) }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openProject(_:)), #selector(saveProjectAs(_:)):
            return session.isConnected
        case #selector(showInstrumentView(_:)):
            menuItem.state = editorVC.domain == .instrument ? .on : .off
            return true
        case #selector(showEffectView(_:)):
            menuItem.state = editorVC.domain == .effect ? .on : .off
            return true
        default:
            return true
        }
    }

    @objc func saveCurrentTone() {
        guard session.isConnected, let slot = editorVC.currentSlot else { return }
        session.saveToProject(editorVC.domain, num: slot)
    }

    func shutDown() {
        isShuttingDown = true
        session.disconnect()
    }

    // MARK: NSWindowDelegate

    /// Closing the editor quits Snaproll. The app has no way to reopen the main
    /// window, so without this an auxiliary window that outlives it (Settings,
    /// Monitor, Group Editor) would keep the app running with nothing to show —
    /// `applicationShouldTerminateAfterLastWindowClosed` never fires while one
    /// of them is up.
    func windowWillClose(_ notification: Notification) {
        guard !isShuttingDown else { return }
        NSApp.terminate(nil)
    }
}
