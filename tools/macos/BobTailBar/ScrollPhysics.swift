import Foundation

/// Tick-domain scroll model for the BobTail trackball.
///
/// Everything here counts *device ticks* -- one quantum of ball travel as the
/// firmware defines it (`CONFIG_PMW3610_SCROLL_TICK`). Pixels appear only when
/// a frame is emitted, so a flick always coasts the same distance relative to
/// the hand no matter where the speed slider sits. Measuring velocity in pixels
/// instead, as the first version did, quietly tied "does this flick coast at
/// all" to the speed setting: at 0.25x nothing ever coasted.
///
/// The coast reproduces the firmware engine it replaced
/// (`CONFIG_PMW3610_SCROLL_MOMENTUM`, now off in BobTail_R.conf). That engine
/// emitted a wheel tick every `interval`, stretched `interval` by
/// `DECAY_PERMILLE` after each one, and gave up once it passed
/// `MAX_INTERVAL_MS`. Stretching a gap by a fixed ratio per tick is the same as
/// stretching it at a fixed rate per second, so in continuous time
///
///     interval(t) = interval0 + (growth - 1) * t
///     speed(t)    = 1 / interval(t)                    ticks per second
///     ticks(a, b) = ln(interval(b) / interval(a)) / (growth - 1)
///
/// which is what `step` integrates. At the firmware defaults -- 16 ms floor,
/// 100 ms cutoff, 1.3x growth -- that is 6.1 ticks over 0.28 s: the same coast,
/// drawn as smooth pixels instead of seven discrete notches.
struct ScrollPhysics {
    struct Frame {
        var x: Double = 0
        var y: Double = 0
        var phase: Int64 = 0
        var momentum: Int64 = 0
    }

    /// Pixels one tick is worth at the 1.00x speed setting. A wheel notch has
    /// always been 3 lines x 16 px on macOS, and that is what the firmware's
    /// wheel reports turned into before the smoothing moved here.
    static let basePixelsPerTick = 48.0

    // Firmware reference values, from pmw3610/Kconfig. Named so the driver and
    // the app can be compared line by line.
    static let settle = 0.070            // SCROLL_MOMENTUM_SETTLE_MS
    static let minInterval = 0.016       // SCROLL_MOMENTUM_MIN_INTERVAL_MS
    static let cutoffInterval = 0.100    // SCROLL_MOMENTUM_MAX_INTERVAL_MS
    static let firmwareGrowth = 1.3      // SCROLL_MOMENTUM_DECAY_PERMILLE
    static let minTicks = 5.0            // SCROLL_MOMENTUM_MIN_TICKS
    static let maxTicks = 40.0           // SCROLL_MOMENTUM_MAX_TICKS

    /// The slider position that lands exactly on the firmware defaults.
    static let firmwareMomentum = 0.5

    var pixelsPerTick = ScrollPhysics.basePixelsPerTick
    /// Seconds for the direct scroll to catch up with the hand.
    var response = 0.024
    /// 0 turns the coast off. 0.5 is the firmware.
    var momentum = ScrollPhysics.firmwareMomentum

    private(set) var active = false
    private var coasting = false
    private var began = false
    private var coastBegan = false
    private var pendingX = 0.0, pendingY = 0.0
    private var lastX = 0.0, lastY = 0.0
    private var lastInput = 0.0, lastFrame = 0.0
    private var burstTicks = 0.0
    private var tickInterval = 0.0
    private var intervalSamples = 0
    private var finishRequested = false
    private var coastDirX = 0.0, coastDirY = 0.0
    private var coastInterval = 0.0
    private var coastTicks = 0.0
    private var coastGrowth = 0.0
    private var coastCeiling = 0.0

    /// How the slider maps onto the firmware's two coast parameters. 0.5 lands
    /// on the shipped driver values; the ends are a real 0.5-to-15 tick spread,
    /// so moving the control actually shows up on screen.
    static func coastShape(momentum: Double) -> (growth: Double, ceiling: Double)? {
        let m = min(1, max(0, momentum))
        guard m > 0 else { return nil }
        let growth = 1 + (firmwareGrowth - 1) * (firmwareMomentum / max(0.05, m))
        let ceiling = minInterval + (cutoffInterval - minInterval) * (firmwareMomentum + m)
        return (growth, ceiling)
    }

    /// Ticks a full-speed flick coasts at this setting. The settings window
    /// shows it so the slider says what it does.
    static func coastTicks(momentum: Double) -> Double {
        guard let shape = coastShape(momentum: momentum), shape.ceiling > minInterval else { return 0 }
        return min(maxTicks, log(shape.ceiling / minInterval) / (shape.growth - 1))
    }

    /// `x` and `y` are signed tick counts, not pixels. The firmware locks the
    /// scroll axis, so one of them is always zero in practice.
    mutating func feed(x: Double, y: Double, time: Double) -> [Frame] {
        guard x.isFinite, y.isFinite, time.isFinite, x != 0 || y != 0 else { return [] }
        var frames: [Frame] = []
        if coasting { frames = cancel() }   // touching the ball ends the coast
        if !active {
            active = true
            lastFrame = time - 1.0 / 120.0
            lastInput = time
        }
        let gap = time - lastInput
        let reversed = x * lastX < 0 || y * lastY < 0
        if reversed || gap > Self.settle {
            // A reversal or a pause ends the flick. Whatever comes next has to
            // earn its own coast, which is how the driver's settle timer
            // behaved.
            if reversed { pendingX = 0; pendingY = 0 }
            burstTicks = 0
            tickInterval = 0
            intervalSamples = 0
        }
        let ticks = max(abs(x), abs(y))
        if gap > 0 && gap <= Self.settle && !reversed {
            // Spacing per tick, not per report: one report can carry several
            // ticks when the ball outruns the polling rate. Weighted towards
            // the tail, because the end of a flick is what sets the coast off.
            let perTick = gap / max(1, ticks)
            tickInterval = intervalSamples == 0 ? perTick : tickInterval + 0.5 * (perTick - tickInterval)
            intervalSamples += 1
        }
        pendingX += x
        pendingY += y
        lastX = x
        lastY = y
        lastInput = time
        burstTicks += ticks
        finishRequested = false
        return frames
    }

    /// The scroll layer was released. The driver kept coasting past that point
    /// too -- a trackpad does not stop the instant the fingers lift.
    mutating func finishInput() { finishRequested = true }

    mutating func cancel() -> [Frame] {
        var frames: [Frame] = []
        if coasting && coastBegan { frames.append(Frame(momentum: 3)) }
        else if began { frames.append(Frame(phase: 4)) }
        let savedPixels = pixelsPerTick, savedResponse = response, savedMomentum = momentum
        self = ScrollPhysics()
        pixelsPerTick = savedPixels
        response = savedResponse
        momentum = savedMomentum
        return frames
    }

    mutating func step(time: Double) -> [Frame] {
        guard active else { return [] }
        let elapsed = time - lastFrame
        guard elapsed > 0 else { return [] }
        // Never replay a large burst after sleep or a blocked run loop.
        if elapsed > 0.25 { return cancel() }
        lastFrame = time
        if coasting { return coastFrames(elapsed: elapsed) }

        let alpha = 1 - exp(-elapsed / max(0.01, response))
        var dx = pendingX * alpha, dy = pendingY * alpha
        let idle = finishRequested || time - lastInput >= Self.settle
        // Thresholds stay in pixels: a tick is worth whatever the speed
        // setting says, so a tick-sized epsilon would move with the slider.
        let scale = max(1, pixelsPerTick)
        if idle && hypot(pendingX - dx, pendingY - dy) * scale < 0.1 {
            dx = pendingX; dy = pendingY
        }
        pendingX -= dx; pendingY -= dy
        var frames: [Frame] = []
        if dx != 0 || dy != 0 {
            frames.append(Frame(x: dx * pixelsPerTick, y: dy * pixelsPerTick, phase: began ? 2 : 1))
            began = true
        }
        if idle && hypot(pendingX, pendingY) * scale < 0.001 {
            if began { frames.append(Frame(phase: 4)); began = false }
            if !startCoast() { frames += cancel() }
        }
        return frames
    }

    /// The driver's own test for "was that a flick": enough ticks to show
    /// intent, spaced closely enough to still be moving. A couple of ticks of
    /// precision work stops exactly where the hand left it.
    private mutating func startCoast() -> Bool {
        guard let shape = Self.coastShape(momentum: momentum),
              burstTicks >= Self.minTicks,
              intervalSamples > 0,
              tickInterval <= Self.cutoffInterval
        else { return false }
        let start = max(Self.minInterval, tickInterval)
        guard start < shape.ceiling else { return false }
        let speed = hypot(lastX, lastY)
        guard speed > 0 else { return false }
        coastDirX = lastX / speed
        coastDirY = lastY / speed
        coastInterval = start
        coastGrowth = shape.growth
        coastCeiling = shape.ceiling
        coastTicks = 0
        coasting = true
        return true
    }

    private mutating func coastFrames(elapsed: Double) -> [Frame] {
        let rate = coastGrowth - 1
        let before = coastInterval
        coastInterval += rate * elapsed
        let ticks = log(coastInterval / before) / rate
        coastTicks += ticks
        var frames = [Frame(x: coastDirX * ticks * pixelsPerTick,
                            y: coastDirY * ticks * pixelsPerTick,
                            momentum: coastBegan ? 2 : 1)]
        coastBegan = true
        if coastInterval >= coastCeiling || coastTicks >= Self.maxTicks {
            frames += cancel()
        }
        return frames
    }
}
