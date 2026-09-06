import AppKit
import CoreGraphics

/// Smooth only discrete BobTail wheel events corroborated by device-level HID
/// input. Native trackpads already supply phases and pixel deltas, and pass
/// through untouched.
///
/// The two sources arrive on independent paths: the IOHID report comes straight
/// off the device, the CGEvent comes back down from the window server. Neither
/// is guaranteed to reach the run loop first, so the corroboration here is a
/// running per-axis tally rather than a strict "the receipt must already be
/// waiting" match. Requiring the receipt first, and throwing the tally away on
/// every miss, is what made a lost race poison every event after it: the
/// evidence that would have matched the next event had just been deleted, so
/// the next event missed too, and nothing was ever smoothed.
final class ScrollController {
    static let eventTag: Int64 = 0x424F425343524C
    /// A BobTail wheel report counts as evidence for this long. Generous,
    /// because it only has to outlast the gap between the two paths.
    private static let evidenceWindow = 0.5

    private var physics = ScrollPhysics()
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    /// Tick counts from BobTail reports no CGEvent has claimed yet, per axis,
    /// oldest first. One report becomes one wheel event, so an event takes one
    /// entry -- not every tick waiting, which would inflate a burst whenever
    /// two reports landed before either event did.
    private var receipts: [Bool: [Double]] = [:]
    /// Reports a CGEvent claimed before they arrived, per axis. The report
    /// cancels one out instead of being counted a second time.
    private var claimedEarly: [Bool: Double] = [:]
    private var claimedAt: [Bool: Double] = [:]
    /// When BobTail last reported on this axis.
    private var lastReport: [Bool: Double] = [:]
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
        let amount = abs(ticks)
        guard amount.isFinite, amount > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        expire(now)
        lastReport[horizontal] = now
        if let debt = claimedEarly[horizontal], debt > 0 {
            // An event already went out on the strength of this report.
            claimedEarly[horizontal] = debt - 1
            return
        }
        var queue = receipts[horizontal] ?? []
        queue.append(amount)
        if queue.count > 32 { queue.removeFirst(queue.count - 32) }
        receipts[horizontal] = queue
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
        let horizontal = abs(x) > abs(y)
        expire(now)
        var ticks = 0.0
        if var queue = receipts[horizontal], !queue.isEmpty {
            ticks = queue.removeFirst()
            receipts[horizontal] = queue
        } else if seenRecently(horizontal, now: now) {
            // BobTail is scrolling this axis; this event's report just has not
            // landed yet. Claim one tick and let the report settle the debt.
            ticks = 1
            claim(horizontal, now: now)
        } else {
            // No evidence at all: some other device's wheel. Leave it alone,
            // and remember that one event went by so a report arriving late
            // does not get counted on top of it.
            claim(horizontal, now: now)
            cancel()
            return false
        }
        if physics.active && event.flags != flags { cancel() }
        if !physics.active { location = event.location }
        flags = event.flags
        physics.pixelsPerTick = ScrollPhysics.basePixelsPerTick * Preferences.shared.scrollSpeed
        physics.response = Preferences.shared.scrollResponse
        physics.momentum = Preferences.shared.scrollMomentum
        // Sensor tick magnitude with the OS event's sign, so natural scrolling
        // is honoured without macOS wheel acceleration being applied twice.
        let dx = horizontal ? copysign(ticks, x) : 0
        let dy = horizontal ? 0 : copysign(ticks, y)
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
        // Device evidence deliberately survives: it is not physics state, and
        // discarding it here used to make one missed event break every event
        // that followed.
    }

    private func seenRecently(_ horizontal: Bool, now: Double) -> Bool {
        guard let last = lastReport[horizontal] else { return false }
        return now - last <= Self.evidenceWindow
    }

    /// Capped, so a long burst from some other mouse cannot run up a debt big
    /// enough to swallow the start of the next BobTail scroll.
    private func claim(_ horizontal: Bool, now: Double) {
        claimedEarly[horizontal] = min(4, (claimedEarly[horizontal] ?? 0) + 1)
        claimedAt[horizontal] = now
    }

    /// Forget an axis once BobTail has been quiet on it, so a stale tally can
    /// never be spent on an unrelated device. The two halves age on their own
    /// clocks: an event that ran ahead of its report is only ever settled by
    /// the report that follows it.
    private func expire(_ now: Double) {
        for horizontal in [false, true] {
            if !seenRecently(horizontal, now: now) { receipts[horizontal] = [] }
            let claimed = claimedAt[horizontal] ?? -Self.evidenceWindow
            if now - claimed > Self.evidenceWindow { claimedEarly[horizontal] = 0 }
        }
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
