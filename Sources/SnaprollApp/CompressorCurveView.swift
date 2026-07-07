import AppKit

/// A read-only input→output transfer plot for the effect compressor, mirroring
/// the original aFrameEdit "Comp Curve" monitor. Both axes span −48…0 dB. The
/// curve is derived from threshold, ratio, knee and make-up gain; attack and
/// release don't shape the static curve, so they aren't drawn. When the
/// compressor is switched off the plot shows an idle grid, matching the
/// original (which hides the curve unless Comp Sw is ON).
final class CompressorCurveView: NSView {
    private var thresholdDb = 0.0
    private var ratio = 1.0
    private var kneeWidthDb = 0.0
    private var makeupGainDb = 0.0
    private var isOn = false

    private static let minDb = -48.0
    private static let maxDb = 0.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Feeds the plot the current compressor settings (dB where noted).
    func update(thresholdDb: Double, ratio: Double, kneeWidthDb: Double,
                makeupGainDb: Double, isOn: Bool) {
        self.thresholdDb = thresholdDb
        self.ratio = ratio
        self.kneeWidthDb = kneeWidthDb
        self.makeupGainDb = makeupGainDb
        self.isOn = isOn
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Soft-knee compression transfer function (dB in → dB out, make-up added).
    private func output(for input: Double) -> Double {
        let t = thresholdDb, w = kneeWidthDb
        let slope = ratio.isInfinite ? 0.0 : 1.0 / ratio
        let y: Double
        if w <= 0 {
            y = input <= t ? input : t + (input - t) * slope
        } else {
            let d = input - t
            if 2 * d < -w {
                y = input                                   // below the knee
            } else if 2 * d > w {
                y = t + d * slope                           // above the knee
            } else {                                        // within the knee
                y = input + (slope - 1) * pow(d + w / 2, 2) / (2 * w)
            }
        }
        return y + makeupGainDb
    }

    override func draw(_ dirtyRect: NSRect) {
        let caption: CGFloat = 15          // room for the bottom labels
        let pad: CGFloat = 6
        // Keep the plot square and centered so the unity diagonal reads at a
        // true 45°, whatever aspect the card gives us.
        let side = min(bounds.width - 2 * pad, bounds.height - caption - pad)
        guard side > 4 else { return }
        let plot = NSRect(x: bounds.midX - side / 2, y: bounds.minY + caption,
                          width: side, height: side).integral

        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.controlBackgroundColor.setFill()
            let box = NSBezierPath(roundedRect: plot, xRadius: 6, yRadius: 6)
            box.fill()

            // Grid every 12 dB.
            NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
            let grid = NSBezierPath()
            grid.lineWidth = 1
            for step in 1..<4 {
                let f = CGFloat(step) / 4
                let gx = plot.minX + f * plot.width
                grid.move(to: NSPoint(x: gx, y: plot.minY))
                grid.line(to: NSPoint(x: gx, y: plot.maxY))
                let gy = plot.minY + f * plot.height
                grid.move(to: NSPoint(x: plot.minX, y: gy))
                grid.line(to: NSPoint(x: plot.maxX, y: gy))
            }
            grid.stroke()

            // 1:1 reference (unity gain) as a faint dashed diagonal.
            let unity = NSBezierPath()
            unity.lineWidth = 1
            unity.setLineDash([3, 3], count: 2, phase: 0)
            unity.move(to: NSPoint(x: plot.minX, y: plot.minY))
            unity.line(to: NSPoint(x: plot.maxX, y: plot.maxY))
            NSColor.tertiaryLabelColor.setStroke()
            unity.stroke()

            if isOn {
                let curve = NSBezierPath()
                curve.lineWidth = 2
                curve.lineJoinStyle = .round
                var started = false
                var db = Self.minDb
                while db <= Self.maxDb + 0.001 {
                    let p = NSPoint(x: x(for: db, in: plot), y: y(for: output(for: db), in: plot))
                    if started { curve.line(to: p) } else { curve.move(to: p); started = true }
                    db += 0.5
                }
                NSColor.controlAccentColor.setStroke()
                curve.stroke()
            }

            NSColor.separatorColor.setStroke()
            box.lineWidth = 1
            box.stroke()

            // Labels: 0 dB (top-left), −48 dB / 0 dB (bottom corners), title.
            let small = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 9),
                         .foregroundColor: NSColor.tertiaryLabelColor]
            ("0 dB" as NSString).draw(at: NSPoint(x: plot.minX + 2, y: plot.maxY - 12), withAttributes: small)
            ("−48 dB" as NSString).draw(at: NSPoint(x: plot.minX, y: 1), withAttributes: small)
            let right = "0 dB" as NSString
            let rw = right.size(withAttributes: small).width
            right.draw(at: NSPoint(x: plot.maxX - rw, y: 1), withAttributes: small)
            let title = "Comp Curve" as NSString
            let tw = title.size(withAttributes: small).width
            title.draw(at: NSPoint(x: plot.midX - tw / 2, y: 1), withAttributes: small)

            if !isOn {
                let idle = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 11),
                            .foregroundColor: NSColor.tertiaryLabelColor]
                let note = "Comp Sw off" as NSString
                let ns = note.size(withAttributes: idle)
                note.draw(at: NSPoint(x: plot.midX - ns.width / 2, y: plot.midY - ns.height / 2),
                          withAttributes: idle)
            }
        }
    }

    private func x(for db: Double, in plot: NSRect) -> CGFloat {
        plot.minX + CGFloat((db - Self.minDb) / (Self.maxDb - Self.minDb)) * plot.width
    }

    private func y(for db: Double, in plot: NSRect) -> CGFloat {
        let clamped = min(max(db, Self.minDb), Self.maxDb)
        return plot.minY + CGFloat((clamped - Self.minDb) / (Self.maxDb - Self.minDb)) * plot.height
    }
}
