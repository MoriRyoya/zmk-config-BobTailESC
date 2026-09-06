import Foundation

/// Time-based displacement filter. Frame rate changes never change total direct travel.
struct ScrollPhysics {
    struct Frame {
        var x: Double = 0
        var y: Double = 0
        var phase: Int64 = 0
        var momentum: Int64 = 0
    }
    var response = 0.024
    var momentum = 0.35
    private(set) var active = false
    private var coasting = false
    private var began = false
    private var coastBegan = false
    private var pendingX = 0.0, pendingY = 0.0
    private var velocityX = 0.0, velocityY = 0.0
    private var lastInput = 0.0, lastFrame = 0.0, firstInput = 0.0
    private var inputCount = 0
    private var finishRequested = false
    private var coastStart = 0.0
    private let settle = 0.09

    mutating func feed(x: Double, y: Double, time: Double) -> [Frame] {
        guard x.isFinite, y.isFinite, time.isFinite, x != 0 || y != 0 else { return [] }
        var frames: [Frame] = []
        if coasting { frames = cancel() }
        if !active {
            active = true
            firstInput = time
            lastFrame = time - 1.0 / 120.0
            lastInput = time
        }
        let gap = time - lastInput
        let reversed = x * velocityX < 0 || y * velocityY < 0
        if reversed || gap > settle {
            // New direction brakes the old tail immediately.
            if reversed { pendingX = 0; pendingY = 0 }
            velocityX = 0; velocityY = 0
            inputCount = 0
            firstInput = time
        }
        if gap > 0.001 && gap <= settle && !reversed {
            let alpha = 1 - exp(-gap / 0.045)
            velocityX += alpha * (x / gap - velocityX)
            velocityY += alpha * (y / gap - velocityY)
        }
        pendingX += x; pendingY += y
        lastInput = time
        inputCount += 1
        finishRequested = false
        return frames
    }

    mutating func finishInput() { finishRequested = true }

    mutating func cancel() -> [Frame] {
        var frames: [Frame] = []
        if coasting && coastBegan { frames.append(Frame(momentum: 3)) }
        else if began { frames.append(Frame(phase: 4)) }
        let savedResponse = response, savedMomentum = momentum
        self = ScrollPhysics()
        response = savedResponse; momentum = savedMomentum
        return frames
    }

    mutating func step(time: Double) -> [Frame] {
        guard active else { return [] }
        let elapsed = time - lastFrame
        guard elapsed > 0 else { return [] }
        // Never replay a large burst after sleep or a blocked run loop.
        if elapsed > 0.25 { return cancel() }
        lastFrame = time
        if coasting {
            let tau = 0.08 + min(1, max(0, momentum)) * 0.52
            let decay = exp(-elapsed / tau)
            let dx = velocityX * tau * (1 - decay)
            let dy = velocityY * tau * (1 - decay)
            velocityX *= decay; velocityY *= decay
            if hypot(velocityX, velocityY) < 5 || time - coastStart > 2.5 { return cancel() }
            let frame = Frame(x: dx, y: dy, momentum: coastBegan ? 2 : 1)
            coastBegan = true
            return [frame]
        }

        let alpha = 1 - exp(-elapsed / max(0.01, response))
        var dx = pendingX * alpha, dy = pendingY * alpha
        let idle = finishRequested || time - lastInput >= settle
        if idle && hypot(pendingX - dx, pendingY - dy) < 0.1 {
            dx = pendingX; dy = pendingY
        }
        pendingX -= dx; pendingY -= dy
        var frames: [Frame] = []
        if dx != 0 || dy != 0 {
            frames.append(Frame(x: dx, y: dy, phase: began ? 2 : 1))
            began = true
        }
        if idle && hypot(pendingX, pendingY) < 0.001 {
            if began { frames.append(Frame(phase: 4)); began = false }
            let speed = hypot(velocityX, velocityY)
            if momentum > 0 && inputCount >= 4 && lastInput - firstInput >= 0.06 && speed >= 120 {
                // Clamp fast flicks and attenuate their exit velocity to keep the stopping point controllable.
                let scale = min(1, 2200 / speed) * 0.65
                velocityX *= scale; velocityY *= scale
                coasting = true; coastStart = time
            } else {
                frames += cancel()
            }
        }
        return frames
    }
}
