import Foundation

/// The value of an instrument pan parameter that supports pressure-pan control:
/// MixMainPan (idx 50), MixSub Pan (idx 51), MixXtraPan (idx 52).
///
/// The raw Int16 packs an L/R position and a "pressure pan control" mode as
/// `value = mode × 256 + position`, position 1…127 (64 = C00 center) and mode
/// 0…11 (12 modes, manual p.22). Hardware-confirmed against VER.2.00:
/// captures/20260708-213318/pan_probe.txt. (MixDryCPan/MixDryEPan carry only a
/// position — range [1,127] — and use the plain `.pan` display.)
public struct PanValue: Equatable {
    public var position: Int   // 1…127, 64 = center
    public var mode: Int       // 0…11

    public init(position: Int, mode: Int) {
        self.position = position
        self.mode = mode
    }

    public init(raw: Int) {
        let mode = raw / 256
        let pos = raw % 256
        if PanMap.modeRange.contains(mode), PanMap.positionRange.contains(pos) {
            self.position = pos
            self.mode = mode
        } else {
            // Off-grid (device-tolerated but meaningless): clamp to a plain
            // centered position with no mode.
            self.position = min(PanMap.positionRange.upperBound,
                                max(PanMap.positionRange.lowerBound, raw))
            self.mode = 0
        }
    }

    public var raw: Int { mode * 256 + position }
}

/// Rendering and label tables for `PanValue`, plus the category→variant split
/// the two-popup editor uses (the 12 modes group as 5 categories).
public enum PanMap {
    public static let positionRange = 1...127
    public static let modeRange = 0...11

    /// The 12 pressure-pan modes in the device's order (manual p.22). Flat names
    /// for read-only labels and tests.
    public static let modeNames = [
        "Off",                                             // 0
        "Pressure +127", "Pressure -127",                  // 1,2
        "Pressure +63", "Pressure -63",                    // 3,4
        "Ping Pong L\u{2192}R", "Ping Pong R\u{2192}L",    // 5,6
        "Random +63", "Random -63", "Random \u{00B1}63",   // 7,8,9
        "Pitch Hi\u{2192}R", "Pitch Hi\u{2192}L",          // 10,11
    ]

    /// The two-level structure the editor's category + variant popups present.
    /// Each entry is (category label, [variant labels]); a mode index maps to a
    /// (category, variant) pair via `decompose`/`compose`.
    public static let categories: [(name: String, variants: [String])] = [
        ("Off", []),
        ("Pressure", ["+127", "-127", "+63", "-63"]),
        ("Ping Pong", ["L\u{2192}R", "R\u{2192}L"]),
        ("Random", ["+63", "-63", "\u{00B1}63"]),
        ("Pitch", ["Hi\u{2192}R", "Hi\u{2192}L"]),
    ]

    /// mode → (category index, variant index within that category).
    public static func decompose(mode: Int) -> (category: Int, variant: Int) {
        var m = mode
        for (ci, cat) in categories.enumerated() {
            let count = max(cat.variants.count, 1)   // "Off" has one implicit slot
            if m < count { return (ci, cat.variants.isEmpty ? 0 : m) }
            m -= count
        }
        return (0, 0)
    }

    /// (category index, variant index) → mode, clamped to valid combinations.
    public static func compose(category: Int, variant: Int) -> Int {
        var mode = 0
        for ci in 0..<category where categories.indices.contains(ci) {
            mode += max(categories[ci].variants.count, 1)
        }
        let cat = categories.indices.contains(category) ? categories[category] : categories[0]
        if cat.variants.isEmpty { return mode }          // "Off"
        return mode + min(variant, cat.variants.count - 1)
    }

    /// Position rendered the way the hardware LCD does: "C00", "L63", "R32".
    public static func positionString(_ p: Int) -> String {
        if p == 64 { return "C00" }
        return p < 64 ? "L\(64 - p)" : "R\(p - 64)"
    }

    /// e.g. "L63" (mode Off) or "C00 · Pressure +127".
    public static func label(raw: Int) -> String {
        let v = PanValue(raw: raw)
        let pos = positionString(v.position)
        if v.mode == 0 { return pos }
        let name = modeNames.indices.contains(v.mode) ? modeNames[v.mode] : "?"
        return pos + " \u{00B7} " + name
    }
}
