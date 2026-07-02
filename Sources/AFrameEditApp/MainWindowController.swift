import AppKit
import AFrameKit

final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private let session = EditorSession()
    private let sidebarVC = SidebarViewController()
    private let editorVC = EditorViewController()

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
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 300
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

    private static let connectionItemID = NSToolbarItem.Identifier("connection")
    private static let saveItemID = NSToolbarItem.Identifier("save")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.connectionItemID, .flexibleSpace, Self.saveItemID]
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
            case .disconnected:
                self.statusDot.textColor = .systemRed
                self.statusLabel.stringValue = "Not connected"
                self.firmwareLabel.stringValue = ""
                self.connectButton.title = "Connect"
                self.connectButton.isEnabled = true
                self.saveButton.isEnabled = false
                self.sidebarVC.clear()
                self.editorVC.clear()
            case .names(let sel, let list):
                self.sidebarVC.setNames(list, for: sel)
            case .toneLoaded(let sel, let num, let tone):
                self.editorVC.showTone(tone, num: num, for: sel)
                self.sidebarVC.setSelected(num: num, for: sel)
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

    @objc func saveCurrentTone() {
        guard session.isConnected, let slot = editorVC.currentSlot else { return }
        session.saveToProject(editorVC.domain, num: slot)
    }

    func shutDown() {
        session.disconnect()
    }
}
