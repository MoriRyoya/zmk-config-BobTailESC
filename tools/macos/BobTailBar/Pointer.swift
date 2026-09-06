import AppKit
import CoreGraphics

/// Applies only to fresh, device-confirmed BobTail X/Y reports. Other mice and
/// a WindowServer-first event without a matching report pass through normally.
final class PointerController {
    private var physics = PointerPhysics()
    private var rawX = 0.0, rawY = 0.0
    private var reportTime = -1.0
    private let now: () -> Double
    private var observer: NSObjectProtocol?
    private(set) var processedReports = 0

    init(now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        observer = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil,
                                                          queue: .main) { [weak self] _ in self?.reset() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func noteMotion(horizontal: Bool, value: Double) {
        guard value.isFinite, value != 0 else { return }
        let time = now()
        if time - reportTime > 0.03 { rawX = 0; rawY = 0 }
        if horizontal { rawX += value } else { rawY += value }
        reportTime = time
    }

    func reset() {
        physics.reset(); rawX = 0; rawY = 0; reportTime = -1
    }

    @discardableResult
    func handle(_ event: CGEvent, displays: [CGRect]) -> Bool {
        let time = now()
        guard Preferences.shared.pointerPrecisionEnabled,
              time - reportTime <= 0.03, rawX != 0 || rawY != 0 else { reset(); return false }
        rawX = 0; rawY = 0
        // Work in WindowServer's units. Raw sensor counts and accelerated
        // screen coordinates must never share a persistent position anchor.
        let x = Double(event.getIntegerValueField(.mouseEventDeltaX))
        let y = Double(event.getIntegerValueField(.mouseEventDeltaY))
        guard x != 0 || y != 0 else { physics.reset(); return false }
        physics.precision = Preferences.shared.pointerPrecisionGain
        physics.speedGain = Preferences.shared.pointerSpeedGain
        physics.smoothing = Preferences.shared.pointerSmoothing
        let movement = physics.feed(x: x, y: y, time: time)
        // Attenuate this event only. Unmatched events, warps, and callbacks
        // arriving in either order cannot cause a jump back to an old anchor.
        let proposed = CGPoint(x: event.location.x + movement.x - x,
                               y: event.location.y + movement.y - y)
        let point = Self.clamp(proposed, to: displays)
        event.location = point
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(movement.x))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(movement.y))
        processedReports += 1
        return true
    }

    static func clamp(_ point: CGPoint, to displays: [CGRect]) -> CGPoint {
        guard !displays.isEmpty, !displays.contains(where: { $0.contains(point) }) else { return point }
        return displays.map { rect in
            CGPoint(x: min(rect.maxX - 1, max(rect.minX, point.x)),
                    y: min(rect.maxY - 1, max(rect.minY, point.y)))
        }.min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) }!
    }
}
