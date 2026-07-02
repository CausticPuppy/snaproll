import Foundation

/// Renders raw parameter values the way the hardware LCD does (with minor
/// cosmetic liberties like spacing), for display in the editor UI.
public enum ParameterFormatter {
    public static func string(for value: Int, display: ParameterDisplay) -> String {
        switch display {
        case .raw(let unit):
            return withUnit("\(value)", unit)
        case .signed(let unit):
            return withUnit(value > 0 ? "+\(value)" : "\(value)", unit)
        case .scaled(let divisor, let unit, let signed):
            let decimals = divisor >= 100 ? 2 : (divisor >= 10 ? 1 : 0)
            var s = String(format: "%.\(decimals)f", Double(value) / Double(divisor))
            if signed && value > 0 { s = "+" + s }
            return withUnit(s, unit)
        case .pan:
            if value == 64 { return "C00" }
            return value < 64 ? "L\(64 - value)" : "R\(value - 64)"
        case .centerEdge:
            return "C\(100 - value)/E\(value)"
        case .onOff:
            return value == 0 ? "Off" : "On"
        case .enumerated(let labels):
            return labels[value] ?? "\(value)"
        case .levelWithMode(let modes):
            let mode = value >= 0 ? value / 256 : 0
            let level = value - mode * 256
            let label = modes.indices.contains(mode) ? modes[mode] : "?"
            return "\(level) \(label)"
        case .bpmSyncTime:
            if value >= 0 {
                return String(format: "%.1f ms", Double(value) / 10)
            }
            let code = (-value) >> 8
            let fine = (-value) & 0xFF
            let divisions = [0: "4", 1: ".8", 2: "8", 4: "16", 7: "T16"]
            let name = divisions[code] ?? "div\(code)"
            return fine == 0 ? "♩\(name)" : "♩\(name) +\(fine)"
        case .custom:
            return "\(value)"
        }
    }

    private static func withUnit(_ s: String, _ unit: String?) -> String {
        unit.map { "\(s) \($0)" } ?? s
    }
}
