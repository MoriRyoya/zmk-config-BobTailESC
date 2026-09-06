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
/// The coast is the deceleration every touch surface on the machine already
/// uses: velocity decays exponentially from the speed the ball was actually
/// travelling, so distance is `speed * momentum` and the tail arrives smoothly
/// instead of being cut off. `momentum` *is* that time constant in seconds, and
/// 0.50 is UIScrollView's normal deceleration rate (0.998 per ms) to three
/// decimal places -- which is why it reads as the machine behaving normally
/// rather than as an effect.
///
/// The driver's own coast, which this replaced, ran a different curve: it
/// stretched the gap between wheel ticks by 30% each time and gave up once the
/// gap passed 100 ms. That is about six ticks in a quarter of a second, and it
/// was tuned for discrete notches on a wheel rather than for pixels. Matching
/// it exactly turned out to be the wrong target -- it is over before the eye
/// reads it as motion at all.
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

    // Coast presets. The value is the exponential time constant in seconds, so
    // a flick travels `speed * momentum` and lasts `momentum * ln(speed/stop)`.
    static let weakMomentum = 0.22
    static let standardMomentum = 0.50
    static let strongMomentum = 0.90

    /// Under half a pixel per frame: the coast is over, whatever the maths say.
    static let stopSpeed = 60.0             // px/s
    static let maxCoastSeconds = 4.0
    static let maxCoastTicks = 200.0
    /// Fastest entry speed the coast will take, so a stutter in the reports
    /// cannot launch the page into orbit.
    static let maxFlickSpeed = 150.0        // ticks/s
    /// The flick the settings window quotes: one tick every 16 ms.
    static let referenceFlickSpeed = 62.5   // ticks/s

    // When a burst counts as a flick at all. Both come from the driver, which
    // got this part right: a couple of ticks of precision work has to stop
    // exactly where the hand left it.
    static let settle = 0.070               // SCROLL_MOMENTUM_SETTLE_MS
    static let cutoffInterval = 0.100       // SCROLL_MOMENTUM_MAX_INTERVAL_MS
    static let minTicks = 5.0               // SCROLL_MOMENTUM_MIN_TICKS

    var pixelsPerTick = ScrollPhysics.basePixelsPerTick
    /// Seconds for the direct scroll to catch up with the hand.
    var response = 0.024
    /// Coast time constant in seconds. 0 turns the coast off.
    var momentum = ScrollPhysics.standardMomentum

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
    private var coastSpeed = 0.0
    private var coastTau = 0.0
    private var coastTicks = 0.0
    private var coastElapsed = 0.0

    /// What a hard flick does at this setting. The settings window quotes both
    /// numbers, so the slider says what it does instead of being a bare
    /// percentage.
    static func coastPreview(momentum: Double,
                             pixelsPerTick: Double = ScrollPhysics.basePixelsPerTick)
        -> (ticks: Double, seconds: Double) {
        let tau = max(0, momentum)
        let stop = stopSpeed / max(1, pixelsPerTick)
        guard tau > 0, referenceFlickSpeed > stop else { return (0, 0) }
        return (min(maxCoastTicks, tau * (referenceFlickSpeed - stop)),
                min(maxCoastSeconds, tau * log(referenceFlickSpeed / stop)))
    }

    /// How long the ball has to be still before the coast takes over. A fast
    /// flick is unmistakable after two or three missed reports, and waiting the
    /// full settle there shows up as the page stopping and then setting off
    /// again. A slow drag gets the full window, so it is never mistaken for one.
    private var coastDelay: Double {
        guard intervalSamples > 0 else { return Self.settle }
        return min(Self.settle, max(0.035, 3 * tickInterval))
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
        let idle = finishRequested || time - lastInput >= coastDelay
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
    /// intent, spaced closely enough that the ball was still moving.
    private mutating func startCoast() -> Bool {
        guard momentum > 0,
              burstTicks >= Self.minTicks,
              intervalSamples > 0,
              tickInterval > 0,
              tickInterval <= Self.cutoffInterval
        else { return false }
        let speed = hypot(lastX, lastY)
        guard speed > 0 else { return false }
        coastDirX = lastX / speed
        coastDirY = lastY / speed
        // How committed the flick was. The ball reaches full tick rate in
        // three or four reports, so without this a 7 mm nudge would fling the
        // page as far as a deliberate throw. Full weight from twice the
        // threshold up, which is still well under a centimetre of ball.
        let commitment = min(1, burstTicks / (2 * Self.minTicks))
        coastSpeed = min(Self.maxFlickSpeed, commitment / tickInterval)
        coastTau = momentum
        coastTicks = 0
        coastElapsed = 0
        coasting = true
        return true
    }

    private mutating func coastFrames(elapsed: Double) -> [Frame] {
        let decay = exp(-elapsed / coastTau)
        let ticks = coastSpeed * coastTau * (1 - decay)
        coastSpeed *= decay
        coastTicks += ticks
        coastElapsed += elapsed
        var frames = [Frame(x: coastDirX * ticks * pixelsPerTick,
                            y: coastDirY * ticks * pixelsPerTick,
                            momentum: coastBegan ? 2 : 1)]
        coastBegan = true
        if coastSpeed * pixelsPerTick < Self.stopSpeed
            || coastTicks >= Self.maxCoastTicks
            || coastElapsed >= Self.maxCoastSeconds {
            frames += cancel()
        }
        return frames
    }
}
