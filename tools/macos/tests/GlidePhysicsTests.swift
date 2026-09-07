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
        // A normal roll keeps its full tick; a creep fades towards the floor.
        precondition(GlidePhysics.speedGain(ticksPerSecond: 62.5) == 1)
        precondition(GlidePhysics.speedGain(ticksPerSecond: GlidePhysics.fullSpeedRate) == 1)
        precondition(GlidePhysics.speedGain(ticksPerSecond: 0) == GlidePhysics.creepGain)
        for rate in stride(from: 0.0, through: 30.0, by: 0.25) {
            let here = GlidePhysics.speedGain(ticksPerSecond: rate)
            precondition(here >= GlidePhysics.speedGain(ticksPerSecond: rate - 0.25))
            precondition(here >= GlidePhysics.creepGain && here <= 1)
        }
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
        precondition(interrupted.allSatisfy { $0.y == 0 }) // the report brakes, it does not travel
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
        // Touching a coasting ball stops the page and travels nothing, the way
        // a finger landing on a trackpad does. In the scroll layer this report
        // is the only sign the hand is back, so it must not scroll a notch and
        // must not launch a fresh coast off its own velocity.
        var brake = GlidePhysics()
        _ = brake.feed(x: 0, y: 1, time: 40)
        _ = brake.feed(x: 0, y: 1, time: 40.016)
        for i in 1...30 { _ = brake.step(time: 40.016 + Double(i) / 120) }
        precondition(brake.coasting)
        let stopped = brake.feed(x: 0, y: 1, time: 40.3)
        precondition(stopped.contains { $0.momentum == 3 })
        precondition(stopped.allSatisfy { $0.x == 0 && $0.y == 0 })
        var settled: [GlidePhysics.Frame] = []
        for i in 1...240 { settled += brake.step(time: 40.3 + Double(i) / 120) }
        precondition(settled.allSatisfy { $0.x == 0 && $0.y == 0 })
        precondition(!settled.contains { $0.momentum == 1 || $0.momentum == 2 })
        precondition(!brake.active && !brake.coasting)

        // A roll that meant to keep going loses only that one braking report.
        var resume = GlidePhysics()
        _ = resume.feed(x: 0, y: 1, time: 50)
        _ = resume.feed(x: 0, y: 1, time: 50.016)
        for i in 1...30 { _ = resume.step(time: 50.016 + Double(i) / 120) }
        precondition(resume.coasting)
        _ = resume.feed(x: 0, y: 1, time: 50.3)
        var carried = 0.0
        for k in 1...6 {
            carried += resume.feed(x: 0, y: 1, time: 50.3 + Double(k) * 0.016).reduce(0) { $0 + $1.y }
        }
        for i in 1...600 { carried += resume.step(time: 50.4 + Double(i) / 120).reduce(0) { $0 + $1.y } }
        precondition(carried > 6 * 32) // six real ticks, at full value, plus a tail

        // A creeping ball scrolls far less per tick than a normal roll, so
        // "nearly stopped" reads as stopped instead of lurching a whole notch.
        // The ball is turning the whole time, which is what the 0x01D7
        // telemetry reports and what holds the creep inside one gesture.
        func rolled(gap: Double) -> Double {
            var p = GlidePhysics(); p.momentum = 0
            p.motionActive = true
            var travel = 0.0, clock = 60.0
            for _ in 0..<8 {
                travel += p.feed(x: 0, y: 1, time: clock).reduce(0) { $0 + $1.y }
                for i in 1...Int((gap * 240).rounded()) {
                    travel += p.step(time: clock + Double(i) / 240).reduce(0) { $0 + $1.y }
                }
                clock += gap
            }
            p.motionActive = false
            for i in 1...480 { travel += p.step(time: clock + Double(i) / 240).reduce(0) { $0 + $1.y } }
            return travel
        }
        let normalRoll = rolled(gap: 0.016)
        precondition(abs(normalRoll - 8 * 32) < 1e-5) // the accepted feel is untouched
        precondition(rolled(gap: 0.5) < normalRoll * 0.5)   // 2 ticks/s
        precondition(rolled(gap: 0.2) < rolled(gap: 0.08))  // 5 vs 12.5 ticks/s

        // Opening a roll is never faded by how slowly the last one ended, so a
        // re-touch that cancels a coast still starts at full value.
        var restart = GlidePhysics(); restart.momentum = 0
        restart.motionActive = true
        for k in 0..<4 { _ = restart.feed(x: 0, y: 1, time: 65 + Double(k) * 0.5) }
        restart.motionActive = false
        _ = restart.cancel()
        var opening = 0.0
        restart.motionActive = true
        opening += restart.feed(x: 0, y: 1, time: 67).reduce(0) { $0 + $1.y }
        restart.motionActive = false
        for i in 1...480 { opening += restart.step(time: 67 + Double(i) / 240).reduce(0) { $0 + $1.y } }
        precondition(abs(opening - 32) < 1e-5)

        // The hand-off fades with how long the ball kept turning past its last
        // tick, which is exactly how much it slowed. Stopping a fast roll dead
        // still flings; easing to a stop hands over nothing; in between is a
        // ramp, where a 160 ms cutoff used to make it all-or-nothing.
        func handoff(creep: Double) -> Double {
            var p = GlidePhysics()
            p.motionActive = true
            var clock = 70.0
            for _ in 0..<8 {
                _ = p.feed(x: 0, y: 1, time: clock)
                for i in 1...2 { _ = p.step(time: clock + Double(i) / 120) }
                clock += 0.016
            }
            var creeping = 0.0
            while creeping < creep { _ = p.step(time: clock + creeping); creeping += 1.0 / 120 }
            p.motionActive = false
            var coast = 0.0
            for i in 0...600 {
                coast += p.step(time: clock + creep + Double(i) / 120)
                    .filter { $0.momentum > 0 }.reduce(0) { $0 + $1.y }
            }
            return coast
        }
        let dead = handoff(creep: 0)
        precondition(dead > 200)
        precondition(handoff(creep: 0.05) < dead && handoff(creep: 0.05) > 0)
        precondition(handoff(creep: 0.09) < handoff(creep: 0.05))
        precondition(handoff(creep: 0.2) == 0)

        // A trackball keeps spinning after the hand leaves it, so a real flick
        // arrives as fast ticks followed by the ball's own spin-down. Reading
        // friction off that dying tail braked a hard throw like a crawl, so the
        // coast has to answer to how fast the roll ever got.
        func thrown(interval: Double) -> Double {
            var p = GlidePhysics()
            p.pixelsPerTick = 32 * 1.64
            p.momentum = 0.61
            p.motionActive = true
            var coast = 0.0, clock = 100.0, frame = 100.0
            func advance(to end: Double) {
                while frame < end {
                    frame += 1.0 / 120
                    coast += p.step(time: frame).filter { $0.momentum == 1 || $0.momentum == 2 }
                        .reduce(0) { $0 + $1.y }
                }
            }
            for _ in 0..<10 { _ = p.feed(x: 0, y: 1, time: clock); clock += interval; advance(to: clock) }
            var gap = interval
            for _ in 0..<3 {           // the ball freewheeling down to a stop
                gap *= 1.6; clock += gap
                _ = p.feed(x: 0, y: 1, time: clock)
                advance(to: clock)
            }
            p.motionActive = false
            advance(to: clock + 6)
            return coast
        }
        let flung = [0.008, 0.016, 0.032, 0.064].map { thrown(interval: $0) }
        for (fast, slow) in zip(flung, flung.dropFirst()) {
            precondition(fast > slow * 1.5) // every step up in speed carries further
        }
        // Absolute distance is deliberately not pinned tight here: the coast
        // leaves at the speed the page is actually moving, so a throw that the
        // ball spins down out of hands over less than one read off the notches
        // would. How far it then carries is the coast setting's job.
        precondition(flung[0] > 600 && flung[3] < 150)

        print("Glide: small rolls coast, direct distance conserved, phases, 60/120/144 Hz, braking on touch, creep fade, coast hand-off, throw scaling, reversal, cancel and sleep passed.")
    }
}
