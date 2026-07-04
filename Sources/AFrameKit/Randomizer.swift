import Foundation

/// Parameter randomization math, kept pure so it can be unit-tested apart from
/// the editor UI that drives it.
public enum Randomizer {
    /// Blends `current` toward `randomTarget` by `rate` (0...1), then rounds and
    /// clamps to `range`. rate 0 leaves the value unchanged; rate 1 jumps fully
    /// to the random target; values in between are proportionally varied around
    /// the current setting. This gives the "amount" feel of the rate control.
    public static func blend(current: Int, randomTarget: Int, rate: Double,
                             range: ClosedRange<Int>) -> Int {
        let r = Swift.max(0, Swift.min(1, rate))
        let mixed = Double(current) * (1 - r) + Double(randomTarget) * r
        let rounded = Int(mixed.rounded())
        return Swift.max(range.lowerBound, Swift.min(range.upperBound, rounded))
    }
}
