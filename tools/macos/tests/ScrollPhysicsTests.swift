import Foundation

@main
enum ScrollPhysicsTests {
    typealias Stamped = (time: Double, frame: ScrollPhysics.Frame)

    /// Roll the ball: `count` single-tick reports spaced `interval` apart, then
    /// let the engine settle.
    static func roll(interval: Double, count: Int,
                     momentum: Double = ScrollPhysics.firmwareMomentum,
                     pixelsPerTick: Double = ScrollPhysics.basePixelsPerTick,
                     hz: Double = 120, release: Bool = false) -> [Stamped] {
        var engine = ScrollPhysics()
        engine.momentum = momentum
        engine.pixelsPerTick = pixelsPerTick
        let start = 10.0
        let inputs = (0..<count).map { start + Double($0) * interval }
        var out: [Stamped] = []
        var next = 0
        var released = false
        var time = start
        while time < (inputs.last ?? start) + 3 {
            while next < inputs.count && inputs[next] <= time + 1e-9 {
                out += engine.feed(x: 0, y: 1, time: inputs[next]).map { (time, $0) }
                next += 1
            }
            if release && next == inputs.count && !released {
                engine.finishInput()
                released = true
            }
            out += engine.step(time: time).map { (time, $0) }
            time += 1 / hz
        }
        return out
    }

    static func coasted(_ frames: [Stamped]) -> [Stamped] {
        frames.filter { $0.frame.momentum == 1 || $0.frame.momentum == 2 }
    }

    /// Coast distance measured in device ticks, which is the unit the firmware
    /// engine worked in and the only one that does not move with the speed.
    static func coastTicks(_ frames: [Stamped], pixelsPerTick: Double = ScrollPhysics.basePixelsPerTick) -> Double {
        coasted(frames).reduce(0) { $0 + $1.frame.y } / pixelsPerTick
    }

    static func coastSpan(_ frames: [Stamped]) -> Double {
        let times = coasted(frames).map { $0.time }
        guard let first = times.first, let last = times.last else { return 0 }
        return last - first
    }

    static func main() {
        let ppt = ScrollPhysics.basePixelsPerTick

        // Direct travel is conserved at both refresh rates when inertia is off.
        for hz in [60.0, 120.0] {
            let frames = roll(interval: 0.025, count: 4, momentum: 0, hz: hz)
            precondition(abs(frames.reduce(0) { $0 + $1.frame.y } - 4 * ppt) < 0.001)
            precondition(frames.filter { $0.frame.phase == 1 }.count == 1)
            precondition(frames.filter { $0.frame.phase == 4 }.count == 1)
            precondition(frames.allSatisfy { $0.frame.momentum == 0 })
            precondition(frames.allSatisfy { $0.frame.x == 0 })
        }

        // The driver refused to coast anything under MIN_TICKS, and so does
        // this. A few ticks of precision work stops where the hand left it.
        for count in 1...4 {
            precondition(coasted(roll(interval: 0.008, count: count)).isEmpty)
        }
        // ...and five ticks is a flick. The pixel-velocity version this
        // replaced rejected exactly this case: a crisp flick was over in under
        // 60 ms, so its duration gate threw away the hardest flicks of all.
        precondition(coastTicks(roll(interval: 0.008, count: 5)) > 5)

        // The default reproduces CONFIG_PMW3610_SCROLL_MOMENTUM: seven wheel
        // ticks over roughly 0.28 s, now drawn as smooth pixels.
        let flick = roll(interval: 0.016, count: 12)
        precondition(coastTicks(flick) > 5.5 && coastTicks(flick) < 7)
        precondition(coastSpan(flick) > 0.22 && coastSpan(flick) < 0.32)
        let steps = coasted(flick).map { $0.frame.y }
        precondition(zip(steps, steps.dropFirst()).allSatisfy { $0 >= $1 - 1e-12 })
        precondition(flick.allSatisfy { $0.frame.x == 0 })

        // A slow drag is not a flick, at any setting.
        precondition(coasted(roll(interval: 0.080, count: 8)).isEmpty)
        precondition(coasted(roll(interval: 0.080, count: 8, momentum: 1)).isEmpty)

        // The slider has to be worth touching: monotone, and a ten-fold spread
        // rather than the same slow drift at every position.
        let sweep = [0.15, 0.25, 0.5, 0.75, 1.0].map { coastTicks(roll(interval: 0.016, count: 12, momentum: $0)) }
        precondition(zip(sweep, sweep.dropFirst()).allSatisfy { $0 < $1 })
        precondition(sweep.last! > 8 * sweep.first!)
        precondition(coasted(roll(interval: 0.016, count: 12, momentum: 0)).isEmpty)
        // The label in the settings window comes from the closed form, so it
        // has to agree with what the engine actually emits.
        for momentum in [0.15, 0.5, 1.0] {
            let measured = coastTicks(roll(interval: 0.016, count: 12, momentum: momentum))
            precondition(abs(measured - ScrollPhysics.coastTicks(momentum: momentum)) < 0.2)
        }

        // Inertia must not depend on the speed setting. Measuring velocity in
        // pixels used to tie the two together: at 0.25x nothing ever coasted.
        let speeds = [0.25, 1.0, 3.0].map { speed -> Double in
            let pixels = ppt * speed
            return coastTicks(roll(interval: 0.030, count: 10, pixelsPerTick: pixels), pixelsPerTick: pixels)
        }
        precondition(speeds.allSatisfy { abs($0 - speeds[0]) < 0.001 })
        precondition(speeds[0] > 1)

        // Letting go of the scroll layer does not stop the coast, the same way
        // a trackpad does not stop the instant the fingers lift.
        precondition(coastTicks(roll(interval: 0.016, count: 8, release: true)) > 5)

        // A direction reversal discards the pending old tail. Cancel and sleep
        // never burst.
        var reversing = ScrollPhysics()
        _ = reversing.feed(x: 0, y: 4, time: 1)
        _ = reversing.feed(x: 0, y: 4, time: 1.02)
        _ = reversing.step(time: 1.03)
        _ = reversing.feed(x: 0, y: -1, time: 1.04)
        precondition(reversing.step(time: 1.05).allSatisfy { $0.y <= 0 })
        _ = reversing.cancel()
        precondition(reversing.step(time: 1.06).isEmpty)
        _ = reversing.feed(x: 0, y: 4, time: 2)
        precondition(reversing.step(time: 100).allSatisfy { $0.x == 0 && $0.y == 0 })
        precondition(!reversing.active)

        print("Scroll physics: conserved travel, refresh rates, the firmware coast, "
              + "the flick threshold, slider range, speed independence, reversal and cancellation passed.")
    }
}
