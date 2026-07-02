import AppKit
import AFrameKit

final class MainWindowController: NSWindowController {
    private let session = DeviceSession()
    private var pollTimer: Timer?

    // Controls
    private let portPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let mockCheckbox = NSButton(checkboxWithTitle: "Mock device", target: nil, action: nil)
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let versionLabel = NSTextField(labelWithString: "—")
    private let modeLabel = NSTextField(labelWithString: "—")
    private let lcdField = NSTextField(labelWithString: " \n ")
    private let statusLabel = NSTextField(labelWithString: "Not connected")

    private let meterNames = ["In Center", "In Edge", "Out L", "Out R", "Press Pitch", "Press Mute"]
    private var meters: [NSLevelIndicator] = []

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "aFrame Edit"
        window.center()
        self.init(window: window)
        buildUI()
        refreshPorts()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        refreshButton.target = self
        refreshButton.action = #selector(refreshPorts)
        connectButton.target = self
        connectButton.action = #selector(toggleConnection)
        mockCheckbox.target = self
        mockCheckbox.action = #selector(mockToggled)

        let portRow = NSStackView(views: [portPopup, refreshButton, mockCheckbox, connectButton])
        portRow.orientation = .horizontal
        portRow.spacing = 8
        portPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let infoGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Firmware:"), versionLabel],
            [NSTextField(labelWithString: "Mode:"), modeLabel],
        ])
        infoGrid.rowSpacing = 4
        infoGrid.columnSpacing = 12

        lcdField.font = NSFont.monospacedSystemFont(ofSize: 18, weight: .medium)
        lcdField.textColor = NSColor(calibratedRed: 0.7, green: 0.95, blue: 1.0, alpha: 1)
        lcdField.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        lcdField.drawsBackground = true
        lcdField.alignment = .center
        lcdField.maximumNumberOfLines = 2
        lcdField.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true

        let meterGrid = NSGridView(numberOfColumns: 2, rows: 0)
        meterGrid.rowSpacing = 6
        meterGrid.columnSpacing = 12
        for name in meterNames {
            let indicator = NSLevelIndicator()
            indicator.levelIndicatorStyle = .continuousCapacity
            indicator.minValue = 0
            indicator.maxValue = 15
            indicator.warningValue = 10
            indicator.criticalValue = 14
            indicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
            meters.append(indicator)
            let label = NSTextField(labelWithString: name)
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
            meterGrid.addRow(with: [label, indicator])
        }

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [portRow, infoGrid, lcdField, meterGrid, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            lcdField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
    }

    // MARK: Actions

    @objc private func refreshPorts() {
        portPopup.removeAllItems()
        let ports = SerialPortDiscovery.candidatePorts()
        if ports.isEmpty {
            portPopup.addItem(withTitle: "No serial ports found")
        } else {
            portPopup.addItems(withTitles: ports)
        }
        portPopup.isEnabled = !ports.isEmpty && mockCheckbox.state == .off
    }

    @objc private func mockToggled() {
        portPopup.isEnabled = mockCheckbox.state == .off && portPopup.numberOfItems > 0
    }

    @objc private func toggleConnection() {
        if session.isConnected {
            stopPolling()
            session.disconnect()
            connectButton.title = "Connect"
            statusLabel.stringValue = "Disconnected"
            versionLabel.stringValue = "—"
            modeLabel.stringValue = "—"
            return
        }

        let transport: AFrameTransport
        if mockCheckbox.state == .on {
            transport = MockAFrame()
        } else if let title = portPopup.titleOfSelectedItem, title.hasPrefix("/dev/") {
            transport = POSIXSerialPort(path: title)
        } else {
            statusLabel.stringValue = "Select a port or enable the mock device"
            return
        }

        connectButton.isEnabled = false
        statusLabel.stringValue = "Connecting…"
        session.connect(transport: transport) { [weak self] result in
            guard let self else { return }
            self.connectButton.isEnabled = true
            switch result {
            case .success(let version):
                self.versionLabel.stringValue = version
                self.connectButton.title = "Disconnect"
                self.statusLabel.stringValue = "Connected"
                self.startPolling()
            case .failure(let error):
                self.statusLabel.stringValue = "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollOnce()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        for m in meters { m.doubleValue = 0 }
    }

    private func pollOnce() {
        session.pollStatus { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let status):
                self.modeLabel.stringValue = "\(status.mode)"
                self.lcdField.stringValue = "\(status.lcdLine1)\n\(status.lcdLine2)"
                let values = [
                    status.peaks.inCenter, status.peaks.inEdge,
                    status.peaks.outL, status.peaks.outR,
                    status.pressure.pitch, status.pressure.mute,
                ]
                for (meter, v) in zip(self.meters, values) {
                    meter.doubleValue = Double(v)
                }
            case .failure(let error):
                self.statusLabel.stringValue = "Poll error: \(error.localizedDescription)"
            }
        }
    }
}
