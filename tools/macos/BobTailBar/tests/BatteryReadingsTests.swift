import Foundation

@main
enum BatteryReadingsTests {
    final class Characteristic {
        let uuid = "2A19" // Both halves intentionally have the same Bluetooth UUID.
    }

    static let mainPresentation = Data([0x04, 0, 0xAD, 0x27, 1, 0x06, 0x01])
    static let auxiliaryPresentation = Data([0x04, 0, 0xAD, 0x27, 1, 0x08, 0x01])

    static func permutations(_ values: [Int]) -> [[Int]] {
        if values.isEmpty { return [[]] }
        return values.flatMap { first in
            permutations(values.filter { $0 != first }).map { [first] + $0 }
        }
    }

    static func main() {
        let left = Characteristic(), right = Characteristic()
        let leftID = ObjectIdentifier(left), rightID = ObjectIdentifier(right)
        precondition(left.uuid == right.uuid && leftID != rightID)

        // Every descriptor/read callback ordering must preserve 25% left, 83% right.
        // Values can precede identities, and service discovery can finish either way.
        for registration in [[leftID, rightID], [rightID, leftID]] {
            for order in permutations([0, 1, 2, 3]) {
                var readings = BatteryReadings()
                registration.forEach { readings.register($0) }
                for event in order {
                    switch event {
                    case 0: readings.identify(leftID, userDescription: "Peripheral 0")
                    case 1: readings.identify(rightID, presentation: mainPresentation)
                    case 2: readings.update(leftID, data: Data([25]))
                    default: readings.update(rightID, data: Data([83]))
                    }
                    precondition(readings.level(for: .left).map { $0 == 25 } ?? true)
                    precondition(readings.level(for: .right).map { $0 == 83 } ?? true)
                }
                precondition(readings.level(for: .left) == 25)
                precondition(readings.level(for: .right) == 83)
            }
        }

        var readings = BatteryReadings()
        readings.register(leftID)
        readings.register(rightID)
        readings.update(leftID, data: Data([25]))
        readings.identify(leftID, userDescription: "unrecognized")
        precondition(readings.level(for: .left) == nil && readings.level(for: .right) == nil)
        readings.identify(leftID, presentation: auxiliaryPresentation)
        precondition(readings.level(for: .left) == 25)
        readings.identify(rightID, presentation: mainPresentation)

        // 0% and 100% are real measurements; malformed/failed reads are not.
        for value: UInt8 in [0, 100] {
            readings.update(rightID, data: Data([value]))
            precondition(readings.level(for: .right) == Int(value))
        }
        for invalid: Data? in [Data(), Data([101]), Data([255]), Data([25, 83]), nil] {
            readings.update(rightID, data: Data([83]))
            readings.update(rightID, data: invalid)
            precondition(readings.level(for: .right) == nil)
        }

        // A disconnect/service invalidation drops values and rejects late callbacks.
        readings.reset()
        readings.update(leftID, data: Data([25]))
        readings.identify(leftID, userDescription: "Peripheral 0")
        precondition(readings.level(for: .left) == nil && readings.level(for: .right) == nil)
        readings.register(leftID)
        readings.identify(leftID, userDescription: "Peripheral 0")
        precondition(readings.level(for: .left) == nil)
        readings.update(leftID, data: Data([71]))
        precondition(readings.level(for: .left) == 71)

        // Contradictory or duplicate identities must not assign arbitrary readings.
        readings.identify(leftID, presentation: mainPresentation)
        precondition(readings.level(for: .left) == nil && readings.level(for: .right) == nil)
        readings.reset()
        for id in [leftID, rightID] {
            readings.register(id)
            readings.identify(id, presentation: mainPresentation)
            readings.update(id, data: Data([25]))
        }
        precondition(readings.level(for: .right) == nil)

        precondition(BatteryReadings.matchesKeyboard(name: "BobTail"))
        precondition(BatteryReadings.matchesKeyboard(name: "BobTailESC"))
        precondition(!BatteryReadings.matchesKeyboard(name: "Magic Mouse"))
        precondition(!BatteryReadings.matchesKeyboard(name: nil))
        print("BatteryReadings: callback ordering, identity, validation, reconnect and device filtering passed")
    }
}
