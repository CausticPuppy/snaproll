import AppKit
import AFrameKit

/// A floating window with real-time graphs of the aFrame's performance sensors:
/// pressure pitch/mute as scrolling line charts (aFG9) plus the input/output
/// peak level meters (aFG8). Fed `.meters` samples by the main controller.
final class MonitorWindowController: NSWindowController, NSWindowDelegate {
    /// Called when the window closes so the owner can stop the poll loop.
    var onClose: (() -> Void)?

    private let pitchChart = StripChartView(title: "Pressure Pitch", color: .systemBlue)
    private let muteChart = StripChartView(title: "Pressure Mute", color: .systemPurple)
    private let inCenter = LevelMeterView(title: "In C")
    private let inEdge = LevelMeterView(title: "In E")
    private let outL = LevelMeterView(title: "Out L")
    private let outR = LevelMeterView(title: "Out R")

    private let statusLabel = NSTextField(labelWithString: "Waiting for connection…")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        window.title = "Monitor"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 380)
        self.init(window: window)
        window.delegate = self
        buildContent()
    }

    private func buildContent() {
        let charts = NSStackView(views: [pitchChart, muteChart])
        charts.orientation = .vertical
        charts.spacing = 12
        charts.distribution = .fillEqually
        pitchChart.translatesAutoresizingMaskIntoConstraints = false
        muteChart.translatesAutoresizingMaskIntoConstraints = false

        let inputGroup = meterGroup(title: "INPUT", meters: [inCenter, inEdge])
        let outputGroup = meterGroup(title: "OUTPUT", meters: [outL, outR])
        let metersRow = NSStackView(views: [inputGroup, NSView(), outputGroup])
        metersRow.orientation = .horizontal
        metersRow.alignment = .top
        metersRow.distribution = .gravityAreas

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor

        let outer = NSStackView(views: [charts, metersRow, statusLabel])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 14
        outer.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16)
        outer.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: content.topAnchor),
            outer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            charts.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: -32),
            metersRow.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: -32),
            pitchChart.heightAnchor.constraint(equalToConstant: 110),
            muteChart.heightAnchor.constraint(equalToConstant: 110),
        ])
        window?.contentView = content
    }

    private func meterGroup(title: String, meters: [LevelMeterView]) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        let row = NSStackView(views: meters)
        row.orientation = .horizontal
        row.spacing = 8
        for m in meters {
            m.widthAnchor.constraint(equalToConstant: 46).isActive = true
            m.heightAnchor.constraint(equalToConstant: 120).isActive = true
        }
        let group = NSStackView(views: [label, row])
        group.orientation = .vertical
        group.alignment = .centerX
        group.spacing = 6
        return group
    }

    // MARK: Feed

    func update(peak: PeakLevels, pressure: PressureLevels) {
        pitchChart.append(Double(pressure.pitch))
        muteChart.append(Double(pressure.mute))
        inCenter.setValue(peak.inCenter)
        inEdge.setValue(peak.inEdge)
        outL.setValue(peak.outL)
        outR.setValue(peak.outR)
        statusLabel.stringValue = "Live · 30 Hz"
        statusLabel.textColor = .secondaryLabelColor
    }

    /// Clears the traces/meters and shows the idle message (e.g. on disconnect).
    func setIdle(_ message: String) {
        pitchChart.clear()
        muteChart.clear()
        [inCenter, inEdge, outL, outR].forEach { $0.clear() }
        statusLabel.stringValue = message
        statusLabel.textColor = .tertiaryLabelColor
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
