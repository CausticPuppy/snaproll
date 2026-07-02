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

    /// The fixed unit for a display type, shown as a static label beside an
    /// editable value field. Nil when the type has no fixed unit (`.bpmSyncTime`
    /// carries a context-dependent unit and keeps it inline).
    public static func unit(for display: ParameterDisplay) -> String? {
        switch display {
        case .raw(let u), .signed(let u):
            return u
        case .scaled(_, let u, _):
            return u
        default:
            return nil
        }
    }

    /// The value portion for an editable field: `string(for:)` with the fixed
    /// unit stripped off (the UI renders that unit as a separate label).
    public static func valueText(for value: Int, display: ParameterDisplay) -> String {
        let full = string(for: value, display: display)
        guard let unit = unit(for: display) else { return full }
        return stripUnit(full, unit)
    }

    /// Inverts `string(for:display:)` so a user can type a value in the same
    /// form the readout shows. Returns the raw Int, or nil if the text can't be
    /// interpreted for this display type. For `.levelWithMode` the returned Int
    /// is just the 0–127 level (the mode is owned by the row's popup).
    /// `.onOff` and `.enumerated` are driven by their own controls and never
    /// accept typed input.
    public static func parse(_ input: String, display: ParameterDisplay) -> Int? {
        let s = input.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        switch display {
        case .raw(let unit), .signed(let unit):
            return Int(stripUnit(s, unit))
        case .scaled(let divisor, let unit, _):
            guard let d = Double(stripUnit(s, unit)) else { return nil }
            return Int((d * Double(divisor)).rounded())
        case .pan:
            let up = s.uppercased()
            if up.hasPrefix("L"), let n = Int(up.dropFirst()) { return 64 - n }
            if up.hasPrefix("R"), let n = Int(up.dropFirst()) { return 64 + n }
            if up.hasPrefix("C") { return 64 }
            return Int(s)
        case .centerEdge:
            let up = s.uppercased()
            if let slash = up.firstIndex(of: "/") {
                let ePart = up[up.index(after: slash)...]
                if ePart.hasPrefix("E"), let n = Int(ePart.dropFirst()) { return n }
            }
            if up.hasPrefix("E"), let n = Int(up.dropFirst()) { return n }
            if up.hasPrefix("C"), let n = Int(up.dropFirst()) { return 100 - n }
            return Int(s)
        case .bpmSyncTime:
            // Only the positive (millisecond) side is typeable; BPM-sync values
            // are best set with the slider.
            guard let ms = Double(stripUnit(s, "ms")) else { return nil }
            return Int((ms * 10).rounded())
        case .levelWithMode:
            let level = s.prefix { $0.isNumber || $0 == "-" }
            return Int(level)
        case .custom:
            return Int(s)
        case .onOff, .enumerated:
            return nil
        }
    }

    private static func stripUnit(_ s: String, _ unit: String?) -> String {
        guard let unit, s.hasSuffix(unit) else { return s }
        return String(s.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
    }
}
