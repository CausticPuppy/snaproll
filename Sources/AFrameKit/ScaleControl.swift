import Foundation

/// The two-axis value of an instrument SC ("scale control by pressure")
/// parameter: MainSC (idx 9), Sub SC (idx 21), XtraSC (idx 77).
///
/// The raw Int16 packs a musical scale and a scale-control mode into one field:
/// `value = mode × 256 + scale`, where `scale` 1…29 selects the scale
/// (`ParameterMap.scaleNames`) and `mode` 0…12 selects one of 13 note-sequencing
/// modes. `scale == 0` is OFF regardless of mode. Hardware-confirmed against
/// VER.2.00: captures/20260708-210922/sc_probe.txt (the device tolerates values
/// down to −256 and off-grid scale parts, but only this grid is meaningful).
public enum SCValue: Equatable {
    case off
    /// `code` 1…29 (`ScaleControlMap.scaleCodes`), `mode` 0…12
    /// (`ScaleControlMap.modeNames`).
    case scale(code: Int, mode: Int)

    public init(raw: Int) {
        guard raw > 0 else { self = .off; return }
        let mode = raw / 256
        let code = raw % 256
        if ScaleControlMap.scaleCodes.contains(code), ScaleControlMap.modeRange.contains(mode) {
            self = .scale(code: code, mode: mode)
        } else {
            self = .off
        }
    }

    public var raw: Int {
        switch self {
        case .off: return 0
        case .scale(let code, let mode): return mode * 256 + code
        }
    }
}

/// Rendering and label tables for `SCValue`.
public enum ScaleControlMap {
    /// Valid scale codes (0 = OFF, 1…29 = MTriad…Chrmtic).
    public static let scaleCodes = 1...29
    public static let modeRange = 0...12

    /// The 13 scale-control modes, in the device's order (manual p.20). The
    /// hardware shows each as a short arrow glyph the LCD reader can't decode;
    /// these are the descriptive names.
    public static let modeNames = [
        "Pressure \u{2191}", "Pressure \u{2193}",                          // 0,1
        "Random \u{2191}", "Random \u{2193}", "Random \u{2195}",           // 2,3,4
        "Sequence \u{2191}", "Sequence \u{2193}",                          // 5,6
        "Sequence \u{2195}", "Sequence \u{21C5}",                          // 7,8
        "Skip \u{2191}", "Skip \u{2193}", "Skip \u{2195}", "Skip \u{21C5}",// 9,10,11,12
    ]

    public static func scaleName(_ code: Int) -> String {
        ParameterMap.scaleNames[code] ?? "\(code)"
    }

    /// e.g. "OFF" or "MScale · Sequence ↑".
    public static func label(raw: Int) -> String {
        switch SCValue(raw: raw) {
        case .off: return "OFF"
        case .scale(let code, let mode):
            let m = modeNames.indices.contains(mode) ? modeNames[mode] : "?"
            return scaleName(code) + " \u{00B7} " + m
        }
    }
}
