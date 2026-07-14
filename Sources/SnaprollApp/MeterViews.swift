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

/// The header's compact input monitor: labeled horizontal peak bars for the
/// two input zones (Center and Edge, from aFG8), sitting where the retired
/// mini monitor used to. Clicking it opens the full Monitor window. The rest
/// of the signal path reads downward from here — pressure traces in the
/// Pressure card, output L/R meters in the Master strip.
final class InputMonitorView: NSView {
    /// Fired on click; the owner opens the full Monitor window.
    var onOpen: (() -> Void)?

    private var connected = false
    private var levels: [Double] = [0, 0]  // Center, Edge
    private let levelMax = 15.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateTooltip()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 30) }

    func setConnected(_ connected: Bool) {
        self.connected = connected
        if !connected { levels = [0, 0] }
        updateTooltip()
        needsDisplay = true
    }

    func update(inCenter: Int, inEdge: Int) {
        guard connected else { return }
        levels = [inCenter, inEdge].map { Swift.min(Double($0), levelMax) }
        needsDisplay = true
    }

    private func updateTooltip() {
        toolTip = connected
            ? "Input level (Center / Edge) — click to open the Monitor window"
            : "Input monitor (connect to an aFrame to start) — click to open the Monitor window"
    }

    override func mouseDown(with event: NSEvent) {
        onOpen?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let alpha: CGFloat = connected ? 1 : 0.35
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let bg = NSBezierPath(roundedRect: b, xRadius: 6, yRadius: 6)
            NSColor.controlBackgroundColor.setFill()
            bg.fill()

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(alpha),
            ]
            ("IN" as NSString).draw(at: NSPoint(x: 8, y: b.midY - 6), withAttributes: titleAttrs)

            let rowAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(alpha),
            ]
            let barX: CGFloat = 36
            let barW = b.width - barX - 8
            let rows: [(String, Double, CGFloat)] = [("C", levels[0], b.midY + 2.5),
                                                     ("E", levels[1], b.midY - 8.5)]
            for (label, v, y) in rows {
                (label as NSString).draw(at: NSPoint(x: barX - 10, y: y - 1), withAttributes: rowAttrs)
                let track = NSRect(x: barX, y: y, width: barW, height: 5)
                NSColor.separatorColor.withAlphaComponent(0.4).setFill()
                NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
                let frac = CGFloat(v / levelMax)
                if frac > 0 {
                    let fill = NSRect(x: track.minX, y: track.minY,
                                      width: track.width * frac, height: track.height)
                    (frac > 0.85 ? NSColor.systemRed
                        : frac > 0.6 ? .systemYellow : .systemGreen)
                        .withAlphaComponent(alpha).setFill()
                    NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
                }
            }

            NSColor.separatorColor.setStroke()
            bg.lineWidth = 1
            bg.stroke()
        }
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
