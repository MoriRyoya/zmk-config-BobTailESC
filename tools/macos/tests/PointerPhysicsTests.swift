import Foundation

@main
enum PointerPhysicsTests {
    static func main() {
        var slow = PointerPhysics(), fast = PointerPhysics()
        var slowTotal = 0.0, fastTotal = 0.0
        for i in 0..<100 {
            slowTotal += slow.feed(x: 1, y: 0, time: Double(i) * 0.016).x
            fastTotal += fast.feed(x: 16, y: 0, time: Double(i) * 0.016).x
        }
        precondition(slowTotal > 20 && slowTotal < 50)
        precondition(fastTotal / 1600 > slowTotal / 100 * 2)
        var noise = PointerPhysics()
        var position = 0.0, maxTravel = 0.0
        for i in 0..<300 {
            position += noise.feed(x: i % 2 == 0 ? 1 : -1, y: 0, time: Double(i) * 0.008).x
            maxTravel = max(maxTravel, abs(position))
        }
        precondition(maxTravel <= 1)
        let still = fast.feed(x: 0, y: 0, time: 2)
        precondition(still.x == 0 && still.y == 0)
        precondition(fast.feed(x: -1, y: 0, time: 2.008).x <= 0)
        slow.reset()
        precondition(slow.feed(x: 1, y: 0, time: 100).x <= 1)
        precondition(slow.feed(x: .nan, y: 0, time: 101).x == 0)
        // Callback batching, fast-to-slow changes, stationary axes and reversals
        // must never amplify native movement or move in the opposite direction.
        var burst = PointerPhysics(); burst.speedGain = 3
        for i in 0..<1000 {
            let x = [60.0, 1, -1, 0, -50, 1][i % 6]
            let y = i % 4 == 0 ? 2.0 : 0.0
            let out = burst.feed(x: x, y: y, time: 200 + Double(i) * 0.0001)
            precondition(abs(out.x) <= abs(x) && abs(out.y) <= abs(y))
            precondition(out.x * x >= 0 && out.y * y >= 0)
        }
        print("Pointer: precision gain, acceleration, alternating tremor, no idle drift, reversal and reset passed.")
    }
}
