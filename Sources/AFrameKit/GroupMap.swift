import Foundation

/// Pure helpers for editing the project's group→tone mapping offline and
/// committing it as a minimal sequence of device writes.
public enum GroupMap {
    /// One slot write: select the slot's tones (aFE2×2) then store them with
    /// the group's MAX (aFE1).
    public struct Change: Equatable {
        public let group: Int
        public let num: Int
        public let slot: GroupSlot
        public let max: Int
        public init(group: Int, num: Int, slot: GroupSlot, max: Int) {
            self.group = group
            self.num = num
            self.slot = slot
            self.max = max
        }
    }

    /// Diffs `desired` against `current`, returning the minimal per-slot
    /// writes that make the device match `desired`. Only slots within the
    /// desired MAX matter (slots beyond it are invisible). A group whose MAX
    /// alone changed gets a single rewrite of slot 0 with its existing
    /// contents — aFE1 is the only MAX setter and always writes a slot.
    public static func diff(current: [GroupList], desired: [GroupList]) -> [Change] {
        var changes = [Change]()
        for g in 0..<min(current.count, desired.count) {
            let want = desired[g]
            let have = current[g]
            var wroteGroup = false
            for n in 0..<min(want.max, want.slots.count) {
                let slot = want.slots[n]
                if n >= have.slots.count || have.slots[n] != slot {
                    changes.append(Change(group: g, num: n, slot: slot, max: want.max))
                    wroteGroup = true
                }
            }
            if want.max != have.max && !wroteGroup {
                let slot = want.slots.first ?? GroupSlot(inst: 0, effect: 0)
                changes.append(Change(group: g, num: 0, slot: slot, max: want.max))
            }
        }
        return changes
    }
}
