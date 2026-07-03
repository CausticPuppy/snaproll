import AppKit
import AFrameKit
import UniformTypeIdentifiers

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSMenuItemValidation {
    private let session = EditorSession()
    private let sidebarVC = SidebarViewController()
    private let editorVC = EditorViewController()
    private var sidebarSplitItem: NSSplitViewItem?
    private var monitorWC: MonitorWindowController?
    private var groupEditorWC: GroupEditorWindowController?

    // Latest project tone-name lists, relayed to the group editor to resolve
    // slot patch numbers into names.
    private var instNames: [String] = []
    private var effectNames: [String] = []

    // Toolbar controls
    private let portPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    // Status bar
    private let statusLabel = NSTextField(labelWithString: "Not connected")
    private let firmwareLabel = NSTextField(labelWithString: "")
    private let statusDot = NSTextField(labelWithString: "●")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "aFrame Edit"
        window.minSize = NSSize(width: 960, height: 600)
        window.center()
        self.init(window: window)
        buildContent()
        buildToolbar()
        wireSession()
        refreshPorts()
    }

    // MARK: Layout

    private func buildContent() {
        let split = NSSplitViewController()
        // A plain item (not `sidebarWithViewController:`) so the pane never
        // auto-collapses when the window is narrowed; it's toggled only by the
        // toolbar button. High holding priority keeps its width fixed while the
        // detail pane absorbs window resizing.
        let sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 300
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        sidebarSplitItem = sidebarItem
        split.addSplitViewItem(sidebarItem)

        // Detail area: editor + status bar
        let detailVC = NSViewController()
        let container = NSView()
        detailVC.view = container

        addChildIfNeeded(editorVC, to: detailVC)
        let editorView = editorVC.view
        editorView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(editorView)

        statusDot.font = .systemFont(ofSize: 9)
        statusDot.textColor = .systemRed
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        firmwareLabel.font = .systemFont(ofSize: 11)
        firmwareLabel.textColor = .tertiaryLabelColor
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
            editorView.topAnchor.constraint(equalTo: container.topAnchor),
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

        let detailItem = NSSplitViewItem(viewController: detailVC)
        detailItem.minimumThickness = 640
        split.addSplitViewItem(detailItem)

        window?.contentViewController = split
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

    private static let sidebarItemID = NSToolbarItem.Identifier("sidebarToggle")
    private static let connectionItemID = NSToolbarItem.Identifier("connection")
    private static let groupsItemID = NSToolbarItem.Identifier("groups")
    private static let monitorItemID = NSToolbarItem.Identifier("monitor")
    private static let saveItemID = NSToolbarItem.Identifier("save")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarItemID, .space, Self.connectionItemID, .flexibleSpace,
         Self.groupsItemID, Self.monitorItemID, Self.saveItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.sidebarItemID:
            let button = NSButton(
                image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")!,
                target: self, action: #selector(toggleSidebar))
            button.bezelStyle = .texturedRounded
            button.imagePosition = .imageOnly
            button.keyEquivalent = "s"
            button.keyEquivalentModifierMask = [.control, .command]
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = button
            item.label = "Sidebar"
            item.toolTip = "Show or hide the tone browser (⌃⌘S)"
            return item
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
        sidebarVC.onDomainChange = { [weak self] sel in
            self?.editorVC.setDomain(sel)
        }
        sidebarVC.onSelectTone = { [weak self] sel, num in
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
                self.sidebarVC.setSelected(num: group.instNum, for: .instrument)
                self.sidebarVC.setSelected(num: group.effectNum, for: .effect)
                if self.monitorWC?.window?.isVisible == true {
                    self.session.startMonitoring()
                }
                if self.groupEditorWC?.window?.isVisible == true {
                    self.session.loadGroups()
                }
            case .disconnected:
                self.statusDot.textColor = .systemRed
                self.statusLabel.stringValue = "Not connected"
                self.firmwareLabel.stringValue = ""
                self.connectButton.title = "Connect"
                self.connectButton.isEnabled = true
                self.saveButton.isEnabled = false
                self.sidebarVC.clear()
                self.editorVC.clear()
                self.monitorWC?.setIdle("Not connected")
                self.groupEditorWC?.setIdle()
            case .names(let sel, let list):
                self.sidebarVC.setNames(list, for: sel)
                if sel == .instrument { self.instNames = list } else { self.effectNames = list }
                self.groupEditorWC?.setNames(inst: self.instNames, effect: self.effectNames)
            case .toneLoaded(let sel, let num, let tone):
                self.editorVC.showTone(tone, num: num, for: sel)
                self.sidebarVC.setSelected(num: num, for: sel)
            case .meters(let peak, let pressure):
                self.monitorWC?.update(peak: peak, pressure: pressure)
            case .groups(let list, let current):
                self.groupEditorWC?.update(lists: list, current: current)
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

    @objc private func toggleSidebar() {
        guard let item = sidebarSplitItem else { return }
        item.animator().isCollapsed.toggle()
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

    @objc private func showGroupEditor() {
        if groupEditorWC == nil {
            let wc = GroupEditorWindowController()
            wc.onRecall = { [weak self] g, n in self?.session.recallGroupSlot(group: g, num: n) }
            wc.onStore = { [weak self] g, n, m in self?.session.storeCurrentToGroup(group: g, num: n, max: m) }
            wc.onSetMax = { [weak self] g, m in self?.session.setGroupMax(group: g, max: m) }
            wc.onReload = { [weak self] in self?.session.loadGroups() }
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
            first (to Application Support / aFrame Edit / Backups).
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
        default:
            return true
        }
    }

    @objc func saveCurrentTone() {
        guard session.isConnected, let slot = editorVC.currentSlot else { return }
        session.saveToProject(editorVC.domain, num: slot)
    }

    func shutDown() {
        session.disconnect()
    }
}
