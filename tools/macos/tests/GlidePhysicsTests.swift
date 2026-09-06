import Foundation

@main
enum GlidePhysicsTests {
    static func run(count: Int, hz: Double, momentum: Double = 0.65) -> [(Double, GlidePhysics.Frame)] {
        var p = GlidePhysics(); p.momentum = momentum
        var out: [(Double, GlidePhysics.Frame)] = []
        var input = 0
        for i in 0...Int(hz * 5) {
            let t = 10 + Double(i) / hz
            while input < count && 10 + Double(input) * 0.016 <= t + 1e-9 {
                out += p.feed(x: 0, y: 1, time: 10 + Double(input) * 0.016).map { (t, $0) }
                input += 1
            }
            out += p.step(time: t).map { (t, $0) }
        }
        return out
    }
    static func main() {
        precondition(GlidePhysics.frictionScale(ticksPerSecond: 12) < 0.5)
        precondition(GlidePhysics.frictionScale(ticksPerSecond: 62.5) == 1)
        precondition(GlidePhysics.frictionScale(ticksPerSecond: 240) > 2)
        // Compare equal direct travel at different physical roll speeds.
        func fling(gap: Double, ticks: Double) -> Double {
            var p = GlidePhysics(); p.pixelsPerTick = 32 * 1.64
            var tail = 0.0
            var next = 0
            for i in 0..<1000 {
                let time = 40 + Double(i) / 240
                while next < 6 && 40 + Double(next) * gap <= time {
                    _ = p.feed(x: 0, y: ticks, time: 40 + Double(next) * gap); next += 1
                }
                tail += p.step(time: time).filter { $0.momentum > 0 }.reduce(0) { $0 + $1.y }
            }
            return tail
        }
        let slowTail = fling(gap: 0.080, ticks: 1)
        let normalTail = fling(gap: 0.016, ticks: 1)
        let fastTail = fling(gap: 0.008, ticks: 2)
        precondition(slowTail < normalTail / 4)
        precondition(fastTail > normalTail * 4)
        for count in [1, 2, 3, 10] {
            let frames = run(count: count, hz: 120)
            let direct = frames.filter { $0.1.phase != 0 }.reduce(0) { $0 + $1.1.y }
            precondition(abs(direct - Double(count) * 32) < 1e-5)
            let coast = frames.filter { $0.1.momentum == 1 || $0.1.momentum == 2 }
            precondition(!coast.isEmpty)
            precondition(frames.filter { $0.1.phase == 1 }.count == 1)
            precondition(frames.filter { $0.1.phase == 4 }.count == 1)
            precondition(frames.filter { $0.1.momentum == 1 }.count == 1)
            precondition(frames.filter { $0.1.momentum == 3 }.count == 1)
            if count == 2 {
                precondition(coast.reduce(0) { $0 + $1.1.y } > 400)
                precondition(coast.last!.0 - coast.first!.0 > 1.0)
                let early = coast[10].1.y / coast[9].1.y
                let late = coast[80].1.y / coast[79].1.y
                precondition(late < early) // later equal-time intervals lose more velocity
            }
        }
        let totals = [60.0, 120, 144].map { hz in run(count: 3, hz: hz).reduce(0) { $0 + $1.1.y } }
        precondition(totals.max()! / totals.min()! < 1.02)
        let off = run(count: 3, hz: 120, momentum: 0)
        precondition(abs(off.reduce(0) { $0 + $1.1.y } - 96) < 1e-5)
        precondition(off.last!.1.momentum == 3) // prevent AppKit's inferred coast
        var p = GlidePhysics()
        _ = p.feed(x: 0, y: 1, time: 10)
        _ = p.feed(x: 0, y: 1, time: 10.016)
        for i in 1...30 { _ = p.step(time: 10.016 + Double(i) / 120) }
        precondition(p.coasting)
        let interrupted = p.feed(x: 0, y: -1, time: 10.28)
        precondition(interrupted.contains { $0.momentum == 3 })
        precondition(interrupted.allSatisfy { $0.y <= 0 })
        precondition(p.step(time: 10.29).allSatisfy { $0.y <= 0 })
        _ = p.cancel()
        precondition(p.step(time: 10.30).isEmpty)
        _ = p.feed(x: 0, y: 1, time: 11)
        precondition(p.step(time: 20).allSatisfy { $0.x == 0 && $0.y == 0 })
        p = GlidePhysics(); p.motionActive = true
        _ = p.feed(x: 0, y: 1, time: 30)
        for i in 1...60 { _ = p.step(time: 30 + Double(i) / 120) }
        precondition(!p.coasting) // sub-tick motion still keeps the finger gesture open
        p.motionActive = false
        precondition(p.step(time: 30.51).allSatisfy { $0.momentum != 1 && $0.momentum != 2 })
        precondition(!p.active) // old velocity cannot restart the coast after a precision stop
        print("Glide: small rolls coast, direct distance conserved, phases, 60/120/144 Hz, reversal, cancel and sleep passed.")
    }
}
