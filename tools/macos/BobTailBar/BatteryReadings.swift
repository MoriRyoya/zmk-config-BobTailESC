import Foundation

/// Battery Level UUID (2A19) identifies the value's type, not an individual battery.
/// Keep each characteristic instance separate, and only publish a side identified by
/// its descriptors. CoreBluetooth's asynchronous discovery order is not a side map.
struct BatteryReadings {
    enum Side { case left, right }

    private struct Entry {
        var side: Side?
        var level: Int?
        var conflictingIdentity = false
    }

    private var entries = [ObjectIdentifier: Entry]()

    static func matchesKeyboard(name: String?) -> Bool {
        name?.hasPrefix("BobTail") == true
    }

    mutating func register(_ id: ObjectIdentifier) {
        if entries[id] == nil { entries[id] = Entry() }
    }

    func hasIdentity(_ id: ObjectIdentifier) -> Bool {
        entries[id]?.side != nil
    }

    mutating func reset() { entries.removeAll() }

    /// A failed read must not re-publish CBCharacteristic.value's previous contents.
    mutating func update(_ id: ObjectIdentifier, data: Data?) {
        guard entries[id] != nil else { return }
        entries[id]?.level = data.flatMap { value in
            guard value.count == 1, let byte = value.first, byte <= 100 else { return nil }
            return Int(byte)
        }
    }

    mutating func identify(_ id: ObjectIdentifier, userDescription: String) {
        let text = userDescription.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // BobTail has exactly one split peripheral: the left half, source 0.
        if text == "peripheral 0" || text == "peripheral" {
            identify(id, as: .left)
        }
    }

    mutating func identify(_ id: ObjectIdentifier, presentation: Data) {
        let bytes = Array(presentation)
        // Characteristic Presentation Format (2904), little-endian, uint8 percent.
        guard bytes.count == 7, bytes[0] == 0x04, bytes[1] == 0,
              bytes[2] == 0xAD, bytes[3] == 0x27, bytes[4] == 0x01 else { return }
        let description = UInt16(bytes[5]) | (UInt16(bytes[6]) << 8)
        switch description {
        case 0x0106: identify(id, as: .right) // Zephyr BAS: main (BobTail central)
        case 0x0108: identify(id, as: .left)  // ZMK BAS proxy: auxiliary
        default: break
        }
    }

    private mutating func identify(_ id: ObjectIdentifier, as side: Side) {
        guard var entry = entries[id], !entry.conflictingIdentity else { return }
        if let previous = entry.side, previous != side {
            entry.side = nil
            entry.conflictingIdentity = true
        } else {
            entry.side = side
        }
        entries[id] = entry
    }

    func level(for side: Side) -> Int? {
        let matches = entries.values.filter { $0.side == side }
        // Conflicting/duplicate services are unknown, not "whichever replied last".
        guard matches.count == 1 else { return nil }
        return matches.first?.level
    }
}
