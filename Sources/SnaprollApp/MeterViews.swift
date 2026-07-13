import AppKit
import AFrameKit

/// A scrolling strip chart: samples enter at the right and scroll left, over a
/// fixed window of recent history. The vertical scale sticks to the largest
/// value seen (rounded up to a nice step) so the trace never rescales downward
/// jarringly. Current value is printed in the corner.
final class StripChartView: NSView {
    private let title: String
    private let traceColor: NSColor
    private let capacity: Int
    private let floorMax: Double
    private var samples: [Double] = []
    private var displayMax: Double

    init(title: String, color: NSColor, capacity: Int = 240, floorMax: Double = 16) {
        self.title = title
        self.traceColor = color
        self.capacity = capacity
        self.floorMax = floorMax
        self.displayMax = floorMax
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 110)
    }

    func append(_ value: Double) {
        samples.append(value)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        if value > displayMax { displayMax = niceCeil(value) }
        needsDisplay = true
    }

    func clear() {
        samples.removeAll()
        displayMax = floorMax
        needsDisplay = true
    }

    /// Rounds up to a 1/2/5 × 10ⁿ step so the axis lands on tidy numbers.
    private func niceCeil(_ v: Double) -> Double {
        guard v > 0 else { return floorMax }
        let mag = pow(10, floor(log10(v)))
        let frac = v / mag
        let step = frac <= 1 ? 1.0 : (frac <= 2 ? 2.0 : (frac <= 5 ? 5.0 : 10.0))
        return Swift.max(step * mag, floorMax)
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let bg = NSBezierPath(roundedRect: b, xRadius: 8, yRadius: 8)
            NSColor.controlBackgroundColor.setFill()
            bg.fill()

            NSGraphicsContext.saveGraphicsState()
            bg.addClip()

            NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
            let grid = NSBezierPath()
            grid.lineWidth = 0.5
            for i in 1..<4 {
                let y = b.height * CGFloat(i) / 4
                grid.move(to: NSPoint(x: 0, y: y))
                grid.line(to: NSPoint(x: b.width, y: y))
            }
            grid.stroke()

            if samples.count > 1 {
                let path = NSBezierPath()
                path.lineWidth = 1.5
                path.lineJoinStyle = .round
                let stepX = b.width / CGFloat(capacity - 1)
                let startIndex = capacity - samples.count
                for (i, s) in samples.enumerated() {
                    let x = CGFloat(startIndex + i) * stepX
                    let raw = CGFloat(s / displayMax) * (b.height - 4) + 2
                    let y = Swift.min(Swift.max(raw, 2), b.height - 2)
                    let pt = NSPoint(x: x, y: y)
                    if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
                }
                traceColor.setStroke()
                path.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()

            NSColor.separatorColor.setStroke()
            bg.lineWidth = 1
            bg.stroke()

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            (title as NSString).draw(at: NSPoint(x: 8, y: b.height - 18), withAttributes: titleAttrs)

            let current = samples.last.map { String(format: "%.0f", $0) } ?? "—"
            let valAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: traceColor,
            ]
            let vs = current as NSString
            let sz = vs.size(withAttributes: valAttrs)
            vs.draw(at: NSPoint(x: b.width - sz.width - 8, y: b.height - 18), withAttributes: valAttrs)
        }
    }
}

/// A toolbar-sized live monitor: a scrolling pressure sparkline (pitch blue,
/// mute purple) beside four mini peak bars (In C/E, Out L/R). Clicking it
/// toggles live polling on/off; the paused and disconnected states draw
/// dimmed with a play glyph so the toggle is discoverable.
final class MiniMonitorView: NSView {
    /// Fired on click; the owner flips the active state and re-renders.
    var onToggle: (() -> Void)?

    private var connected = false
    private var active = false
    private var pitch: [Double] = []
    private var mute: [Double] = []
    private var levels: [Double] = [0, 0, 0, 0]
    private let capacity = 90  // ~3 s of history at 30 Hz
    private let pressureMax = 100.0
    private let levelMax = 15.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateTooltip()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 27) }

    func setState(connected: Bool, active: Bool) {
        self.connected = connected
        self.active = active
        if !connected || !active { clearTraces() }
        updateTooltip()
        needsDisplay = true
    }

    func update(peak: PeakLevels, pressure: PressureLevels) {
        guard connected, active else { return }
        pitch.append(Double(pressure.pitch))
        mute.append(Double(pressure.mute))
        if pitch.count > capacity {
            pitch.removeFirst(pitch.count - capacity)
            mute.removeFirst(mute.count - capacity)
        }
        levels = [peak.inCenter, peak.inEdge, peak.outL, peak.outR].map {
            Swift.min(Double($0), levelMax)
        }
        needsDisplay = true
    }

    private func clearTraces() {
        pitch.removeAll()
        mute.removeAll()
        levels = [0, 0, 0, 0]
    }

    private func updateTooltip() {
        toolTip = !connected
            ? "Live monitor (connect to an aFrame to start)"
            : (active ? "Live monitor — click to pause"
                      : "Live monitor paused — click to resume")
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let dimmed = !connected || !active
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let bg = NSBezierPath(roundedRect: b, xRadius: 6, yRadius: 6)
            NSColor.controlBackgroundColor.setFill()
            bg.fill()

            // Right block: four mini peak bars.
            let barW: CGFloat = 5, barGap: CGFloat = 3
            let barsW = barW * 4 + barGap * 3
            let barArea = NSRect(x: b.maxX - barsW - 8, y: 5, width: barsW, height: b.height - 10)
            for (i, v) in levels.enumerated() {
                let track = NSRect(x: barArea.minX + CGFloat(i) * (barW + barGap),
                                   y: barArea.minY, width: barW, height: barArea.height)
                NSColor.separatorColor.withAlphaComponent(0.4).setFill()
                NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
                let frac = CGFloat(v / levelMax)
                if frac > 0 {
                    let fill = NSRect(x: track.minX, y: track.minY,
                                      width: track.width, height: track.height * frac)
                    (frac > 0.85 ? NSColor.systemRed
                        : frac > 0.6 ? .systemYellow : .systemGreen)
                        .withAlphaComponent(dimmed ? 0.3 : 1).setFill()
                    NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
                }
            }

            // Left block: the pressure sparkline.
            let plot = NSRect(x: 6, y: 5, width: barArea.minX - 14, height: b.height - 10)
            for (samples, color) in [(pitch, NSColor.systemBlue), (mute, .systemPurple)]
            where samples.count > 1 {
                let path = NSBezierPath()
                path.lineWidth = 1.2
                let stepX = plot.width / CGFloat(capacity - 1)
                let start = capacity - samples.count
                for (i, s) in samples.enumerated() {
                    let x = plot.minX + CGFloat(start + i) * stepX
                    let y = plot.minY + Swift.min(CGFloat(s / pressureMax), 1) * plot.height
                    let pt = NSPoint(x: x, y: y)
                    i == 0 ? path.move(to: pt) : path.line(to: pt)
                }
                color.withAlphaComponent(dimmed ? 0.3 : 0.9).setStroke()
                path.stroke()
            }

            // Paused / disconnected: a play glyph over the (flat) sparkline.
            if dimmed {
                let symbol = connected ? "play.fill" : "waveform.slash"
                if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) {
                    let tinted = image.tinted(with: .tertiaryLabelColor)
                    tinted.draw(in: NSRect(x: plot.midX - 6, y: plot.midY - 6, width: 12, height: 12))
                }
            }

            NSColor.separatorColor.setStroke()
            bg.lineWidth = 1
            bg.stroke()
        }
    }
}

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            color.set()
            rect.fill()
            self.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        return image
    }
}

/// A classic vertical level meter with a green→yellow→red gradient and a
/// slowly-falling peak-hold marker. Values are the aFrame's 0–15 peak steps.
final class LevelMeterView: NSView {
    private let title: String
    private let maxValue: Double
    private var value: Double = 0
    private var peak: Double = 0

    init(title: String, maxValue: Double = 15) {
        self.title = title
        self.maxValue = maxValue
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 46, height: 110) }

    func setValue(_ v: Int) {
        value = Swift.min(Double(v), maxValue)
        peak = Swift.max(value, peak - 0.15)  // ~4.5 units/sec decay at 30 Hz
        needsDisplay = true
    }

    func clear() { value = 0; peak = 0; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let labelH: CGFloat = 16
        let track = NSRect(x: b.midX - 11, y: labelH, width: 22, height: b.height - labelH)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let trackPath = NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4)
            NSColor.controlBackgroundColor.setFill()
            trackPath.fill()
            NSColor.separatorColor.setStroke()
            trackPath.lineWidth = 1
            trackPath.stroke()

            let frac = CGFloat(value / maxValue)
            if frac > 0 {
                NSGraphicsContext.saveGraphicsState()
                let fillRect = NSRect(x: track.minX, y: track.minY,
                                      width: track.width, height: track.height * frac)
                NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).addClip()
                let gradient = NSGradient(colors: [.systemGreen, .systemYellow, .systemRed],
                                          atLocations: [0.0, 0.7, 1.0], colorSpace: .deviceRGB)
                gradient?.draw(in: fillRect, angle: 90)
                NSGraphicsContext.restoreGraphicsState()
            }

            if peak > 0 {
                let py = track.minY + track.height * CGFloat(peak / maxValue)
                NSColor.labelColor.setStroke()
                let line = NSBezierPath()
                line.lineWidth = 1.5
                line.move(to: NSPoint(x: track.minX, y: py))
                line.line(to: NSPoint(x: track.maxX, y: py))
                line.stroke()
            }

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let ts = title as NSString
            let sz = ts.size(withAttributes: attrs)
            ts.draw(at: NSPoint(x: b.midX - sz.width / 2, y: 0), withAttributes: attrs)
        }
    }
}
