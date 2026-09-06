import Foundation

@main
enum ScrollPhysicsTests {
    typealias Stamped = (time: Double, frame: ScrollPhysics.Frame)

    /// Roll the ball: `count` single-tick reports spaced `interval` apart, then
    /// let the engine settle.
    static func roll(interval: Double, count: Int,
                     momentum: Double = ScrollPhysics.standardMomentum,
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
        while time < (inputs.last ?? start) + 6 {
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

    /// Coast distance in device ticks, the unit the engine works in and the
    /// only one that does not move with the speed setting.
    static func coastTicks(_ frames: [Stamped],
                           pixelsPerTick: Double = ScrollPhysics.basePixelsPerTick) -> Double {
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

        // Precision work stops where the hand left it, at any setting.
        for count in 1...4 {
            precondition(coasted(roll(interval: 0.008, count: count)).isEmpty)
            precondition(coasted(roll(interval: 0.008, count: count, momentum: 1)).isEmpty)
        }
        // A slow drag is not a flick either, however long it runs.
        precondition(coasted(roll(interval: 0.080, count: 12)).isEmpty)
        precondition(coasted(roll(interval: 0.080, count: 12, momentum: 1)).isEmpty)
        // Five ticks is a flick. The pixel-velocity version this replaced
        // rejected exactly this case: a crisp flick is over in under 60 ms, so
        // its duration gate threw away the hardest flicks of all.
        precondition(coastTicks(roll(interval: 0.008, count: 5)) > 10)

        // The default has to read as a coast, not as the scroll failing to stop
        // cleanly. A hard flick carries a screen and a half over about two
        // seconds; the driver's own curve, which this replaced, was six ticks in
        // a quarter second and was over before the eye called it motion.
        let flick = roll(interval: 0.016, count: 12)
        precondition(coastTicks(flick) > 25 && coastTicks(flick) < 36)
        precondition(coastSpan(flick) > 1.6 && coastSpan(flick) < 2.4)
        let steps = coasted(flick).map { $0.frame.y }
        precondition(zip(steps, steps.dropFirst()).allSatisfy { $0 >= $1 - 1e-12 })
        precondition(flick.allSatisfy { $0.frame.x == 0 })
        // It ends by slowing below what a screen can show, never by being cut
        // off part way: the last frame is under a pixel.
        precondition(steps.last! < 1)

        // Faster ball, longer coast: the exit speed is the ball's own.
        precondition(coastTicks(roll(interval: 0.008, count: 20)) > coastTicks(flick))
        precondition(coastTicks(roll(interval: 0.030, count: 10)) < coastTicks(flick))
        // A bare five-tick flick is under a centimetre of ball, so it must not
        // throw the page as far as a committed one.
        precondition(coastTicks(roll(interval: 0.008, count: 5))
                     < coastTicks(roll(interval: 0.008, count: 20)) * 0.6)

        // The three presets have to be clearly different from each other, in
        // order, and all of them worth using.
        let presets = [ScrollPhysics.weakMomentum,
                       ScrollPhysics.standardMomentum,
                       ScrollPhysics.strongMomentum].map { coastTicks(roll(interval: 0.016, count: 12, momentum: $0)) }
        precondition(zip(presets, presets.dropFirst()).allSatisfy { $1 > $0 * 1.5 })
        precondition(presets[0] > 8)
        precondition(coasted(roll(interval: 0.016, count: 12, momentum: 0)).isEmpty)
        // The settings window quotes the closed form, so it has to agree with
        // what the engine emits.
        for momentum in [ScrollPhysics.weakMomentum,
                         ScrollPhysics.standardMomentum,
                         ScrollPhysics.strongMomentum] {
            let frames = roll(interval: 0.016, count: 12, momentum: momentum)
            let preview = ScrollPhysics.coastPreview(momentum: momentum)
            precondition(abs(coastTicks(frames) - preview.ticks) < 1)
            precondition(abs(coastSpan(frames) - preview.seconds) < 0.1)
        }

        // Inertia must never be gated by the speed setting. Measuring velocity
        // in pixels used to tie the two together: at 0.25x nothing coasted at
        // all. Pixel travel scales with the setting, as it should, so what is
        // checked here is the tick count. The few percent it does move is the
        // stop threshold doing its job -- that one is a pixel criterion, and a
        // coast goes invisible sooner when a tick is worth less.
        let speeds = [0.25, 1.0, 3.0].map { speed -> Double in
            let pixels = ppt * speed
            return coastTicks(roll(interval: 0.030, count: 10, pixelsPerTick: pixels), pixelsPerTick: pixels)
        }
        precondition(speeds.allSatisfy { $0 > 5 })
        precondition(speeds.max()! < speeds.min()! * 1.25)

        // Letting go of the scroll layer does not stop the coast, the same way
        // a trackpad does not stop the instant the fingers lift.
        precondition(coastTicks(roll(interval: 0.016, count: 8, release: true)) > 20)

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

        print("Scroll physics: conserved travel, refresh rates, the flick threshold, "
              + "coast length and shape, presets, speed independence, reversal and cancellation passed.")
    }
}
