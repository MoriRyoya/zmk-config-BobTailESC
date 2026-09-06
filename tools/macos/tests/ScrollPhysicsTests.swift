import Foundation

@main
enum ScrollPhysicsTests {
    static func main() {
        // Direct travel is conserved at both refresh rates when inertia is off.
        for hz in [60.0, 120.0] {
            var engine = ScrollPhysics()
            engine.momentum = 0
            var frames: [ScrollPhysics.Frame] = []
            for i in 0..<300 {
                let time = 10 + Double(i) / hz
                if i < 12 && i % 3 == 0 { frames += engine.feed(x: 0, y: 10, time: time) }
                frames += engine.step(time: time)
            }
            precondition(abs(frames.reduce(0) { $0 + $1.y } - 40) < 0.001)
            precondition(frames.filter { $0.phase == 1 }.count == 1)
            precondition(frames.filter { $0.phase == 4 }.count == 1)
            precondition(frames.allSatisfy { $0.momentum == 0 })
            precondition(!engine.active)
        }
        // Small precision adjustments never coast.
        var small = ScrollPhysics()
        _ = small.feed(x: 0, y: 10, time: 1)
        let tiny = (0..<250).flatMap { small.step(time: 1 + Double($0) / 120) }
        precondition(tiny.allSatisfy { $0.momentum == 0 })

        func flick(momentum: Double) -> (ScrollPhysics, [ScrollPhysics.Frame]) {
            var engine = ScrollPhysics()
            engine.momentum = momentum
            var frames: [ScrollPhysics.Frame] = []
            for i in 0..<480 {
                let time = 10 + Double(i) / 120
                if i <= 12 && i % 2 == 0 { frames += engine.feed(x: 0, y: 15, time: time) }
                frames += engine.step(time: time)
            }
            return (engine, frames)
        }
        let (_, gentle) = flick(momentum: 0.2)
        let (finished, longer) = flick(momentum: 0.8)
        precondition(!finished.active)
        precondition(gentle.filter { $0.momentum == 1 }.count == 1)
        precondition(gentle.filter { $0.momentum == 3 }.count == 1)
        let coast = gentle.filter { $0.momentum == 1 || $0.momentum == 2 }.map { $0.y }
        precondition(zip(coast, coast.dropFirst()).allSatisfy { $0 >= $1 })
        precondition(longer.reduce(0) { $0 + $1.y } > gentle.reduce(0) { $0 + $1.y })
        precondition(gentle.allSatisfy { $0.x == 0 })

        // A direction reversal discards the pending old tail. Cancel and sleep never burst.
        var reversing = ScrollPhysics()
        _ = reversing.feed(x: 0, y: 20, time: 1)
        _ = reversing.feed(x: 0, y: 20, time: 1.02)
        _ = reversing.step(time: 1.03)
        _ = reversing.feed(x: 0, y: -5, time: 1.04)
        precondition(reversing.step(time: 1.05).allSatisfy { $0.y <= 0 })
        _ = reversing.cancel()
        precondition(reversing.step(time: 1.06).isEmpty)
        _ = reversing.feed(x: 0, y: 20, time: 2)
        precondition(reversing.step(time: 100).allSatisfy { $0.x == 0 && $0.y == 0 })
        precondition(!reversing.active)
        print("Scroll physics: conserved travel, refresh rates, precision nudges, decay, reversal and cancellation passed.")
    }
}
