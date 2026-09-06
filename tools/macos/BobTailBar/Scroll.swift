import AppKit
import CoreGraphics

/// Smooth only discrete BobTail wheel events corroborated by device-level HID input.
/// Native trackpads already supply phases/pixel deltas and always pass through untouched.
final class ScrollController {
    static let eventTag: Int64 = 0x424F425343524C
    private var physics = ScrollPhysics()
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var receipts: [(time: Double, horizontal: Bool, ticks: Double)] = []
    private var location = CGPoint.zero
    private var flags: CGEventFlags = []
    private var remainderX = 0.0, remainderY = 0.0

    init() {
        observer = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.cancel()
        }
    }

    deinit {
        timer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func noteWheel(horizontal: Bool, ticks: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        receipts.removeAll { now - $0.time > 0.08 }
        receipts.append((now, horizontal, abs(ticks)))
        if receipts.count > 64 { receipts.removeFirst(receipts.count - 64) }
    }

    func handle(_ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.eventTag { return false }
        guard Preferences.shared.scrollSmoothingEnabled,
              event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
              event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0,
              event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 else {
            cancel()
            return false
        }
        let now = ProcessInfo.processInfo.systemUptime
        let x = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let y = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        guard x != 0 || y != 0 else { return false }
        receipts.removeAll { now - $0.time > 0.08 }
        guard let match = receipts.firstIndex(where: { $0.horizontal == (abs(x) > abs(y)) }) else {
            cancel()
            return false
        }
        let receipt = receipts.remove(at: match)
        if physics.active && event.flags != flags { cancel() }
        if !physics.active { location = event.location }
        flags = event.flags
        physics.response = Preferences.shared.scrollResponse
        physics.momentum = Preferences.shared.scrollMomentum
        let gain = 10 * Preferences.shared.scrollSpeed
        // Use sensor tick magnitude, with the OS event's sign (natural scrolling),
        // so macOS wheel acceleration is not applied a second time.
        let dx = receipt.horizontal ? copysign(receipt.ticks * gain, x) : 0
        let dy = receipt.horizontal ? 0 : copysign(receipt.ticks * gain, y)
        post(physics.feed(x: dx, y: dy, time: now))
        if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = 0.001
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        return true
    }

    func finishInput() { physics.finishInput() }

    func cancel() {
        post(physics.cancel())
        timer?.invalidate(); timer = nil
        remainderX = 0; remainderY = 0
        receipts.removeAll()
    }

    private func tick() {
        post(physics.step(time: ProcessInfo.processInfo.systemUptime))
        if !physics.active { timer?.invalidate(); timer = nil }
    }

    private func post(_ frames: [ScrollPhysics.Frame]) {
        for frame in frames {
            remainderX += frame.x; remainderY += frame.y
            let x = Int32(remainderX.rounded(.towardZero)), y = Int32(remainderY.rounded(.towardZero))
            remainderX -= Double(x); remainderY -= Double(y)
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                      wheel1: y, wheel2: x, wheel3: 0) else { continue }
            event.location = location
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: frame.phase)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: frame.momentum)
            event.post(tap: .cgSessionEventTap)
        }
    }
}
