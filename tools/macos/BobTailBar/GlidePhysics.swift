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

    /// Physical wheel rate, independent of the user's pixel-speed slider.
    /// Keep the accepted normal roll (45–90 ticks/s) unchanged.
    static func frictionScale(ticksPerSecond rate: Double) -> Double {
        func ease(_ value: Double) -> Double {
            let v = min(1, max(0, value))
            return v * v * (3 - 2 * v)
        }
        return 0.35 + 0.65 * ease((rate - 8) / 37) + 1.2 * ease((rate - 90) / 150)
    }

    mutating func feed(x: Double, y: Double, time: Double, alreadyDelivered: Bool = false) -> [Frame] {
        guard x.isFinite, y.isFinite, time.isFinite, x != 0 || y != 0 else { return [] }
        var frames: [Frame] = []
        let turns = x * lastX + y * lastY <= 0 && reports > 0
        if coasting || turns || (active && time - lastInput > 0.12) { frames = cancel() }
        if !active { active = true; lastFrame = time; lastInput = time; interval = 0.016 }
        let gap = time - lastInput
        let px = x * pixelsPerTick, py = y * pixelsPerTick
        if reports > 0 && gap > 0 {
            interval = min(0.1, max(0.004, gap))
            let newX = px / interval, newY = py / interval
            vx = reports == 1 ? newX : vx * 0.45 + newX * 0.55
            vy = reports == 1 ? newY : vy * 0.45 + newY * 0.55
        } else { vx = px / 0.045; vy = py / 0.045 }
        let speed = hypot(vx, vy)
        exitRate = pixelsPerTick > 0 ? min(600, speed / pixelsPerTick) : 0
        // Fast multi-tick reports must not hit the old 4,000 px/s ceiling.
        if speed > 18000 { vx *= 18000 / speed; vy *= 18000 / speed }
        if !alreadyDelivered { pendingX += px; pendingY += py }
        lastX = x; lastY = y; lastInput = time; released = false; reports += 1
        // A small nonzero first pixel establishes a real gesture immediately;
        // the remaining direct distance is emitted on the animation clock.
        if !began {
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
        let idle = !motionActive && (released || time - lastInput >= min(0.075, max(0.032, interval * 2.2)))
        let alpha = 1 - exp(-dt / max(0.008, response))
        var dx = pendingX * alpha, dy = pendingY * alpha
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
            let commitment = reports == 1 ? 0.3 : min(1, 0.25 + Double(reports) * 0.125)
            vx *= commitment; vy *= commitment
            // Motion telemetry can hold a gesture open through slow sub-tick
            // adjustments. An old wheel velocity must not launch a new fling.
            if sensorTracked && time - lastInput > 0.16 { vx = 0; vy = 0 }
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
        self = GlidePhysics(); pixelsPerTick = p; momentum = m; response = r; motionActive = moving
        return out
    }
}
