import Foundation

/// Independent, causal wheel animator. Direct distance is conserved; a short
/// two-report roll earns a velocity-based tail. No minimum gesture duration.
struct GlidePhysics {
    /// One animation frame: pixel displacement plus the CGEvent phase fields.
    struct Frame {
        var x: Double = 0
        var y: Double = 0
        var phase: Int64 = 0
        var momentum: Int64 = 0
    }

    /// Pixels for one `CONFIG_PMW3610_SCROLL_TICK` of ball travel at 1x.
    static let basePixelsPerTick = 32.0

    // Coast presets offered by the settings window. The value is the time scale
    // τ of the curve below, so a larger number keeps the page moving longer.
    static let weakMomentum = 0.22
    static let standardMomentum = 0.61
    static let strongMomentum = 0.90

    /// Roll rate at which a tick is worth its full pixel value. Above this the
    /// response is unchanged; the accepted feel lives here and must not move.
    static let fullSpeedRate = 12.0     // ticks/s
    /// Below this the ball is barely turning and the page barely follows.
    static let creepRate = 2.0          // ticks/s
    static let creepGain = 0.30
    /// A gap longer than this is a fresh touch, not a slow roll. Ticks are
    /// timed across gestures because a creep ends the gesture between every
    /// one of them, and a rate measured only inside a gesture would never see
    /// a creep at all.
    static let rollWindow = 0.75        // seconds
    /// BOBTAIL_MOTION_IDLE_MS: the telemetry holds for this long after the
    /// last sensor count, so subtract it to find when the ball really stopped.
    static let telemetryIdle = 0.040    // seconds
    /// How long the ball may keep turning past its last tick before the coast
    /// it hands over is gone. A hand easing to a stop crosses this; a hand
    /// stopping a fast roll dead does not.
    static let handoffWindow = 0.12     // seconds

    var pixelsPerTick = GlidePhysics.basePixelsPerTick
    var momentum = 0.61
    var response = 0.010
    var motionActive = false { didSet { if motionActive { sensorTracked = true } } }
    private var sensorTracked = false
    private(set) var active = false
    private(set) var coasting = false
    private var began = false
    private var momentumBegan = false
    private var pendingX = 0.0, pendingY = 0.0
    private var vx = 0.0, vy = 0.0
    private var lastX = 0.0, lastY = 0.0
    private var lastInput = 0.0, lastFrame = 0.0
    private var reports = 0
    private var interval = 0.016
    private var released = false
    private var coastAge = 0.0
    private var coastTau = 0.61
    private var exitRate = 0.0
    /// Smoothed physical roll rate. Kept apart from the pixel velocity so the
    /// friction curve still sees the ball's real speed after attenuation.
    private var tickRate = GlidePhysics.fullSpeedRate
    private var lastTickTime = 0.0
    /// Last frame at which the telemetry said the ball was still turning.
    private var ballTurning = 0.0
    /// The fastest this roll ever got. A trackball keeps spinning after the
    /// hand leaves it, so the rate at the hand-off is the ball dying, not how
    /// hard it was thrown -- and reading friction off the dying end made a
    /// hard flick brake like a crawl.
    private var peakRate = 0.0
    /// Pixels a second the outstanding travel is being paid out at: whatever is
    /// owed, spread over the time the next notch is due in. Since that is
    /// exactly what each frame emits, it is also the speed the page is moving,
    /// and it does not change with the refresh rate the way a figure measured
    /// back out of the emitted frames would.
    private var drainRate = 0.0

    private static func ease(_ value: Double) -> Double {
        let v = min(1, max(0, value))
        return v * v * (3 - 2 * v)
    }

    /// Physical wheel rate, independent of the user's pixel-speed slider.
    /// Keep the accepted normal roll (45–90 ticks/s) unchanged.
    static func frictionScale(ticksPerSecond rate: Double) -> Double {
        return 0.35 + 0.65 * ease((rate - 8) / 37) + 1.2 * ease((rate - 90) / 150)
    }

    /// How much of a tick's pixel value a roll at this rate is worth.
    ///
    /// The firmware quantises travel into CONFIG_PMW3610_SCROLL_TICK notches,
    /// so creeping the ball still arrives as full-size ticks and the page
    /// lurches a whole notch per nudge. A trackpad has no such floor: a finger
    /// barely moving barely scrolls. Fade the tick down towards a creep as the
    /// rate falls, and leave every normal roll exactly where it was.
    static func speedGain(ticksPerSecond rate: Double) -> Double {
        return creepGain + (1 - creepGain)
            * ease((rate - creepRate) / (fullSpeedRate - creepRate))
    }

    mutating func feed(x: Double, y: Double, time: Double, alreadyDelivered: Bool = false) -> [Frame] {
        guard x.isFinite, y.isFinite, time.isFinite, x != 0 || y != 0 else { return [] }
        var frames: [Frame] = []
        let turns = x * lastX + y * lastY <= 0 && reports > 0
        // Touching a coasting ball has to stop the page, the way putting a
        // finger on a trackpad does. In the scroll layer the firmware sends no
        // X/Y at all, so this report is the first and only sign the hand is
        // back -- and a tick that both stops the coast and scrolls a whole
        // notch does not read as a stop. Swallow it instead: brake, no travel,
        // no velocity. A roll that means to keep going rebuilds its speed from
        // the next report, exactly as a swipe does after a finger lands.
        // Only a ball that had stopped and started again is the hand coming
        // back. While it is still freewheeling down, its own ticks must not be
        // read as a brake -- that is the roll finishing, not a new touch.
        let braking = coasting && !motionActive
        // A gap this long is a new roll -- unless the telemetry says the ball
        // never stopped turning, which makes it one slow roll, not two. Chopping
        // a creep into a gesture per tick restarted the phases every notch and
        // made every tick look like an opening one. The wider cap is only a
        // guard against a lost telemetry release.
        let stale = motionActive ? 1.0 : 0.12
        if coasting || turns || (active && time - lastInput > stale) { frames = cancel() }
        if !active { active = true; lastFrame = time; lastInput = time; interval = 0.016 }
        let gap = time - lastInput
        let ticks = max(abs(x), abs(y))
        let sinceTick = lastTickTime > 0 ? time - lastTickTime : Double.infinity
        if sinceTick > Self.rollWindow || sinceTick <= 0 {
            tickRate = Self.fullSpeedRate
        } else {
            // Speeding up counts at once; only slowing down is smoothed. A
            // roll must never be held back by how slow the last one ended.
            let instant = ticks / sinceTick
            tickRate = instant > tickRate ? instant : tickRate * 0.45 + instant * 0.55
        }
        lastTickTime = time
        // The report that opens a gesture is a deliberate notch of travel and
        // always worth full value. Only a roll already under way can creep --
        // and with the 0x01D7 telemetry holding the gesture open, a creep
        // stays inside one gesture, so the fade still sees it.
        let gain = reports == 0 ? 1 : Self.speedGain(ticksPerSecond: tickRate)
        let px = x * pixelsPerTick * gain, py = y * pixelsPerTick * gain
        if reports > 0 && gap > 0 {
            interval = min(0.1, max(0.004, gap))
            let newX = px / interval, newY = py / interval
            vx = reports == 1 ? newX : vx * 0.45 + newX * 0.55
            vy = reports == 1 ? newY : vy * 0.45 + newY * 0.55
        } else { vx = px / 0.045; vy = py / 0.045 }
        let speed = hypot(vx, vy)
        peakRate = max(peakRate, tickRate)
        // The friction curve wants the ball's real speed, not the attenuated
        // pixel speed, or a creep would also be read as a low-friction flick.
        // It reads the peak rather than the instant: how far a throw carries
        // is set by the throw, and the spin-down that follows is the ball
        // handing the roll over, not the hand asking it to stop. The launch
        // velocity is still the current one, so this lengthens the glide
        // without stepping the page up as the coast takes over.
        exitRate = min(600, max(peakRate, tickRate))
        // Fast multi-tick reports must not hit the old 4,000 px/s ceiling.
        if speed > 18000 { vx *= 18000 / speed; vy *= 18000 / speed }
        if braking { vx = 0; vy = 0 }
        if !alreadyDelivered && !braking { pendingX += px; pendingY += py }
        // One notch, paid out over one gap, is the speed the ball is turning
        // at. As it slows the gaps lengthen and the payout stretches with them,
        // so the page decelerates exactly as the hand did instead of stopping
        // dead between notches. Read off this notch rather than off everything
        // outstanding: how much of the last one is left over depends on where
        // the frames happened to fall, and the speed must not.
        // A braking report buys no travel, so it sets no speed either -- the
        // coast reads its send-off from this, and would otherwise undo the stop.
        drainRate = braking ? 0 : hypot(px, py) / max(0.004, interval)
        lastX = x; lastY = y; lastInput = time; released = false; reports += 1
        // A small nonzero first pixel establishes a real gesture immediately;
        // the remaining direct distance is emitted on the animation clock.
        if !began && !braking {
            let length = hypot(px, py)
            let first = alreadyDelivered ? 0.0 : min(3, length)
            let dx = length > 0 ? px / length * first : 0
            let dy = length > 0 ? py / length * first : 0
            if first > 0 {
                pendingX -= dx; pendingY -= dy
                frames.append(Frame(x: dx, y: dy, phase: 1)); began = true
            }
        }
        return frames
    }

    mutating func finishInput() { released = true }

    mutating func step(time: Double) -> [Frame] {
        guard active else { return [] }
        let dt = time - lastFrame
        guard dt > 0 else { return [] }
        if dt > 0.25 { return cancel() }
        lastFrame = time
        if motionActive { ballTurning = time }
        if coasting {
            let tau = coastTau
            // The initial drag is unchanged. Friction then grows quadratically
            // with coast age, so the end grips instead of drifting indefinitely.
            // Integrate the same curve at every refresh rate (Simpson's rule).
            let age = coastAge / tau
            func remaining(_ seconds: Double) -> Double {
                let next = (coastAge + seconds) / tau
                return exp(-(next - age) - (next * next * next - age * age * age) / 3)
            }
            let decay = remaining(dt)
            let distance = dt / 6 * (1 + 4 * remaining(dt / 2) + decay)
            let dx = vx * distance, dy = vy * distance
            vx *= decay; vy *= decay; coastAge += dt
            var out = [Frame(x: dx, y: dy, momentum: momentumBegan ? 2 : 1)]
            momentumBegan = true
            if hypot(vx, vy) < 8 || coastAge >= 4 { out += cancel() }
            return out
        }
        // Without the 0x01D7 telemetry there is nothing but a timer to say the
        // roll is over. With it, the ball itself says so, and waiting out a
        // second threshold on top only holds the page still.
        let idle = !motionActive && (released || sensorTracked
            || time - lastInput >= min(0.075, max(0.032, interval * 2.2)))
        // Move at the speed the roll is actually going, rather than spending
        // each notch as its own decaying pulse. One notch every 16 ms against a
        // 10 ms time constant was almost gone before the next arrived, so the
        // page surged and stalled 60 times a second instead of travelling, and
        // there was no steady speed left for the coast to continue from.
        // Spread what is owed across the time the next notch is due in, rather
        // than spending it as fast as an exponential will allow. At a steady
        // roll that is a constant speed; as the ball slows and the gaps grow,
        // the last notch is drawn out over a longer one, which is exactly the
        // deceleration the hand performed -- and it keeps the page moving
        // through the wait for the telemetry to confirm the ball has stopped.
        let alpha = 1 - exp(-dt / max(0.008, response))
        let remaining = hypot(pendingX, pendingY)
        // A constant rate, not a constant fraction: a fraction of a shrinking
        // remainder is an exponential that never actually arrives.
        let share = drainRate > 0 && remaining > 0 ? min(1, drainRate * dt / remaining) : alpha
        var dx = pendingX * share, dy = pendingY * share
        if idle && hypot(pendingX - dx, pendingY - dy) < 0.5 { dx = pendingX; dy = pendingY }
        pendingX -= dx; pendingY -= dy
        var out: [Frame] = []
        if dx != 0 || dy != 0 {
            out.append(Frame(x: dx, y: dy, phase: began ? 2 : 1)); began = true
        }
        if idle && hypot(pendingX, pendingY) < 0.001 {
            if began { out.append(Frame(phase: 4)); began = false }
            // Even one notch has a small tail; two closely spaced reports
            // preserve the measured exit speed. Slow precision rolls do not fling.
            // Leave at the speed the page is travelling at, not at one worked
            // back out of the notches. Asked to glide on from what it was
            // doing, this is the only number that answers the question.
            let heading = hypot(lastX, lastY)
            if heading > 0 && drainRate > 0 {
                vx = lastX / heading * drainRate
                vy = lastY / heading * drainRate
            }
            let commitment = reports == 1 ? 0.3 : min(1, 0.25 + Double(reports) * 0.125)
            vx *= commitment; vy *= commitment
            // The last tick measured the ball's speed then, not now. Every roll
            // decelerates into its stop, so handing the coast that stale speed
            // makes the page surge exactly as the hand finishes. The telemetry
            // says how long the ball kept turning without earning another tick,
            // which is precisely how much it slowed: fade the hand-off by it.
            // A continuous ramp, where a 160 ms cutoff used to make the same
            // roll either coast in full or not at all.
            if sensorTracked {
                let turnedUntil = max(lastInput, ballTurning - Self.telemetryIdle)
                let fade = max(0, 1 - (turnedUntil - lastInput) / Self.handoffWindow)
                vx *= fade; vy *= fade
            }
            if momentum > 0 && hypot(vx, vy) >= 40 {
                coastTau = max(0.05, momentum * Self.frictionScale(ticksPerSecond: exitRate))
                coasting = true; coastAge = 0
            } else {
                // Some AppKit views infer their own coast from an ended
                // gesture. Explicitly terminate it when inertia is disabled.
                out.append(Frame(momentum: 3))
                out += cancel()
            }
        }
        return out
    }

    mutating func cancel() -> [Frame] {
        var out: [Frame] = []
        if began { out.append(Frame(phase: 8)) }
        if momentumBegan || began || coasting { out.append(Frame(momentum: 3)) }
        let p = pixelsPerTick, m = momentum, r = response, moving = motionActive
        let rate = tickRate, tick = lastTickTime
        self = GlidePhysics(); pixelsPerTick = p; momentum = m; response = r; motionActive = moving
        // The roll rate outlives the gesture: a creep cancels between every
        // tick, and forgetting the rate there would rate it as a fresh touch.
        tickRate = rate; lastTickTime = tick
        return out
    }
}
