import Foundation

/// Adaptive causal low-pass on device velocity, with low-speed precision gain.
/// No delayed samples or extrapolation, and no motion emitted after input stops.
struct PointerPhysics {
    var precision = 0.35
    var speedGain = 1.0
    var smoothing = 1.0
    private var lastTime: Double?
    private var vx = 0.0, vy = 0.0
    private var remainderX = 0.0, remainderY = 0.0

    mutating func reset() { lastTime = nil; vx = 0; vy = 0; remainderX = 0; remainderY = 0 }

    mutating func feed(x: Double, y: Double, time: Double) -> (x: Double, y: Double) {
        guard x.isFinite, y.isFinite, time.isFinite else { reset(); return (0, 0) }
        if x == 0 && y == 0 { return (0, 0) }
        let gap = lastTime.map { time - $0 } ?? 0.008
        if gap > 0.08 || gap < 0 { reset() }
        let dt = min(0.025, max(0.008, gap > 0.08 ? 0.008 : gap))
        lastTime = time
        let rawX = x / dt, rawY = y / dt
        let speed = hypot(rawX, rawY)
        // Open the filter at speed; slow adjustments receive more attenuation.
        let blend = hypot(x, y) <= 2 ? 0 : min(1, max(0, (speed - 70) / 850))
        let low = min(1, max(0.15, precision)), high = min(1, max(0.5, speedGain))
        let gain = low + (high - low) * blend * blend * (3 - 2 * blend)
        let cutoff = 12 + 85 * blend
        let alpha = 1 - smoothing + smoothing * (1 - exp(-2 * .pi * cutoff * dt))
        vx += alpha * (rawX - vx); vy += alpha * (rawY - vy)
        // Never let a velocity filter make a reversal move in the old direction.
        if vx * rawX <= 0 { vx = 0 }
        if vy * rawY <= 0 { vy = 0 }
        if remainderX * x <= 0 { remainderX = 0 }
        if remainderY * y <= 0 { remainderY = 0 }
        // A fast packet cannot leak its velocity into the following tiny move,
        // or create motion on an axis that is now stationary. Never amplify
        // the OS displacement: native acceleration already ran before this tap.
        remainderX += copysign(min(abs(x), abs(vx * dt)) * gain, x)
        remainderY += copysign(min(abs(y), abs(vy * dt)) * gain, y)
        let outX = copysign(min(abs(x), abs(remainderX.rounded(.towardZero))), x)
        let outY = copysign(min(abs(y), abs(remainderY.rounded(.towardZero))), y)
        remainderX -= outX; remainderY -= outY
        return (outX, outY)
    }
}
