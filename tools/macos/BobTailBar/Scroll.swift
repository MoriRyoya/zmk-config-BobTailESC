import AppKit
import CoreGraphics

/// Adds optional momentum to BobTail's discrete wheel events.
///
/// IOHID identifies BobTail; WindowServer provides the user's scroll direction.
/// Confirmed input is replaced with a display-paced pixel gesture and tail.
/// Unconfirmed first events are held briefly, then passed through unchanged if
/// no matching HID report arrives.
final class ScrollController {
    static let eventTag: Int64 = 0x424F425343524C
    private static let pairingWindow = 0.050
    private static let reverseWait = 0.008

    private struct Report {
        let time: Double
        let horizontal: Bool
        let ticks: Double
    }
    private struct ObservedEvent {
        let time: Double
        let horizontal: Bool
        let event: CGEvent
        let engineRecorded: Bool
        var bobTailFallback = false
    }

    private var reports: [Report] = []
    /// Events already delivered to the application. A later HID report only
    /// records them for momentum; it must never replay their direct movement.
    private var observed: [ObservedEvent] = []
    /// Only used while reverse mode waits for the first HID report.
    private var deferred: [ObservedEvent] = []
    private var lastReport: [Bool: Double] = [:]

    private var glide = GlidePhysics()
    private(set) var confirmedInputs = 0
    private(set) var generatedFrames = 0
    private(set) var coastFrames = 0
    private(set) var motionBrakes = 0
    private var template: CGEvent?
    private var animationClock: ScrollAnimationClock?
    private var observer: NSObjectProtocol?
    private var remainderX = 0.0
    private var remainderY = 0.0
    private var emittedGesture = false
    private var emittedMomentum = false

    private let now: () -> Double
    private let deliver: (CGEvent) -> Void
    private let automaticAnimation: Bool

    init(now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         automaticAnimation: Bool = true,
         deliver: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) }) {
        self.now = now
        self.deliver = deliver
        self.automaticAnimation = automaticAnimation
        observer = NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.cancel() }
    }

    deinit {
        animationClock?.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func noteWheel(horizontal: Bool, ticks: Double) {
        guard ticks.isFinite, ticks != 0 else { return }
        let time = now()
        expire(at: time)
        lastReport[horizontal] = time

        // Match a WindowServer-first event. It was already visible to the app,
        // so only prime the engine and remember its sign/template.
        if let index = deferred.firstIndex(where: { $0.horizontal == horizontal }) {
            let item = deferred.remove(at: index)
            let suppressed = process(item.event, report: Report(time: time, horizontal: horizontal,
                                                                ticks: abs(ticks)), alreadyDelivered: false)
            if !suppressed {
                post(item.event)
            }
            schedule()
            return
        }
        if let index = observed.firstIndex(where: { $0.horizontal == horizontal && time - $0.time <= Self.pairingWindow }) {
            let item = observed.remove(at: index)
            if !item.engineRecorded {
                processAlreadyDelivered(item.event, report: Report(time: time, horizontal: horizontal,
                                                                   ticks: abs(ticks)))
            }
            schedule()
            return
        }

        reports.append(Report(time: time, horizontal: horizontal, ticks: abs(ticks)))
        if reports.count > 64 { reports.removeFirst(reports.count - 64) }
        schedule()
    }

    /// Returns true only when the event was consumed and a replacement will be
    /// delivered. Returning false keeps the original event's timing intact.
    func handle(_ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.eventTag { return false }
        let (horizontal, x, y) = axis(of: event)
        guard x != 0 || y != 0 else { return false }

        // Phase-bearing input belongs to a native gesture or another smoother.
        if event.getIntegerValueField(.scrollWheelEventScrollPhase) != 0 ||
            event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 {
            cancelMotionOnly()
            return false
        }

        // A wheel report carrying a zoom modifier is not scrolling. macOS
        // magnifies at the pointer on Control and applications zoom on
        // Command, so reversing one inverts the zoom and interpolating one
        // turns a notch into a burst of them. Shift is not in this list: it is
        // a real scroll modifier. The left encoder rides this path.
        if !event.flags.isDisjoint(with: [.maskControl, .maskCommand, .maskAlternate]) {
            cancelMotionOnly()
            return false
        }

        let prefs = Preferences.shared
        guard prefs.scrollSmoothingEnabled || prefs.reverseScroll else { return false }
        let time = now()
        expire(at: time)

        if let index = reports.firstIndex(where: { $0.horizontal == horizontal && time - $0.time <= Self.pairingWindow }) {
            let report = reports.remove(at: index)
            let suppress = process(event, report: report, alreadyDelivered: false)
            schedule()
            return suppress
        }

        // The Scroll indicator is a fallback when HID and WindowServer
        // callbacks race (the indicator itself still needs input monitoring).
        // The layer is the keyboard's own statement that this wheel event came
        // from the trackball, so the roll can be animated on the wheel event's
        // own timestamps. A later HID report only removes this observation.
        if KeyboardState.shared.isScrollLayerHeld {
            if prefs.scrollSmoothingEnabled {
                // Fast rolls can contain several ticks per HID report. Wait
                // for that magnitude instead of recording every CG-first event
                // as one tick and silently throwing the later count away.
                deferred.append(ObservedEvent(time: time, horizontal: horizontal,
                    event: event.copy()!, engineRecorded: false, bobTailFallback: true))
                if deferred.count > 8 { releaseDeferred(deferred.removeFirst()) }
                schedule()
                return true
            }
            let report = Report(time: time, horizontal: horizontal, ticks: 1)
            let suppress = process(event, report: report, alreadyDelivered: false)
            observed.append(ObservedEvent(time: time, horizontal: horizontal,
                                          event: event.copy()!, engineRecorded: true))
            if observed.count > 64 { observed.removeFirst(observed.count - 64) }
            schedule()
            return suppress
        }

        // With reverse disabled the event can always pass immediately. If a
        // HID report arrives a moment later, observed[] will prime the coast.
        // Reverse mode waits only for the first report to avoid changing an
        // unrelated mouse's direction.
        let recent = lastReport[horizontal].map { time - $0 <= Self.pairingWindow } ?? false
        if (prefs.reverseScroll && !recent) || prefs.scrollSmoothingEnabled {
            if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 { return false }
            deferred.append(ObservedEvent(time: time, horizontal: horizontal,
                                          event: event.copy()!, engineRecorded: false))
            if deferred.count > 8 { post(deferred.removeFirst().event) }
            schedule()
            return true
        }

        if prefs.reverseScroll { Self.scale(event, by: -1) }
        observed.append(ObservedEvent(time: time, horizontal: horizontal,
                                      event: event.copy()!, engineRecorded: false))
        if observed.count > 64 { observed.removeFirst(observed.count - 64) }
        return false
    }

    /// The Scroll key was released, so no further wheel report can arrive for
    /// this roll. A trackpad does not wait for a settle timer once the fingers
    /// lift, and neither does the tail.
    func finishInput() { glide.finishInput() }

    /// Firmware sends this before wheel quantization. Only stop an existing
    /// tail: a delayed onset notification must not discard a new direct roll.
    func noteBallMotion(active: Bool) {
        if active { motionBrakes += 1 }
        if active && glide.coasting {
            cancelMotionOnly()
            schedule()
        }
        glide.motionActive = active
    }

    func cancel() {
        cancelMotionOnly()
        glide.motionActive = false
        animationClock?.stop()
        animationClock = nil
        reports.removeAll()
        observed.removeAll()
        let pending = deferred
        deferred.removeAll()
        for item in pending { post(item.event) }
    }

    private func cancelMotionOnly() {
        postFrames(glide.cancel())
        template = nil
        lastReport.removeAll()
        remainderX = 0
        remainderY = 0
    }

    private func process(_ event: CGEvent, report: Report, alreadyDelivered: Bool) -> Bool {
        let prefs = Preferences.shared
        confirmedInputs += 1
        if !alreadyDelivered && prefs.reverseScroll { Self.scale(event, by: -1) }
        template = event.copy()

        guard prefs.scrollSmoothingEnabled else {
            // A deferred reverse-only event has not been sent yet.
            return false
        }

        let (_, x, y) = axis(of: event)
        glide.pixelsPerTick = GlidePhysics.basePixelsPerTick * prefs.scrollSpeed
        glide.momentum = prefs.scrollMomentum
        glide.response = prefs.scrollResponse
        postFrames(glide.feed(x: report.horizontal ? copysign(report.ticks, x) : 0,
                              y: report.horizontal ? 0 : copysign(report.ticks, y),
                              time: report.time, alreadyDelivered: alreadyDelivered))
        return !alreadyDelivered
    }

    private func processAlreadyDelivered(_ event: CGEvent, report: Report) {
        _ = process(event, report: report, alreadyDelivered: true)
    }

    func advance() {
        let time = now()
        expire(at: time)
        postFrames(glide.step(time: time))
        schedule()
    }

    private func schedule() {
        guard automaticAnimation else { return }
        let needsClock = !deferred.isEmpty || glide.active
        guard needsClock else { animationClock?.stop(); animationClock = nil; return }
        // Never move the next frame into the future on each HID callback.
        // A busy 125 Hz input stream used to starve a 120 Hz animation forever.
        guard animationClock == nil else { return }
        let clock = ScrollAnimationClock { [weak self] in
            self?.advance()
        }
        animationClock = clock
        clock.start()
    }

    private func expire(at time: Double) {
        reports.removeAll { time - $0.time > Self.pairingWindow }
        observed.removeAll { time - $0.time > Self.pairingWindow }
        while let first = deferred.first, time - first.time >= Self.reverseWait {
            let item = deferred.removeFirst()
            releaseDeferred(item)
        }
    }

    private func releaseDeferred(_ item: ObservedEvent) {
        guard item.bobTailFallback else { post(item.event); return }
        let field: CGEventField = item.horizontal ? .scrollWheelEventDeltaAxis2 : .scrollWheelEventDeltaAxis1
        let magnitude = max(1, abs(Double(item.event.getIntegerValueField(field))))
        let report = Report(time: item.time, horizontal: item.horizontal, ticks: magnitude)
        if !process(item.event, report: report, alreadyDelivered: false) { post(item.event) }
        observed.append(ObservedEvent(time: item.time, horizontal: item.horizontal,
                                      event: item.event, engineRecorded: true))
        if observed.count > 64 { observed.removeFirst(observed.count - 64) }
    }

    private func post(_ event: CGEvent) {
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        deliver(event)
    }

    private func postFrames(_ frames: [GlidePhysics.Frame]) {
        for frame in frames {
            remainderX += frame.x
            remainderY += frame.y
            let x = Int32(remainderX.rounded(.towardZero))
            let y = Int32(remainderY.rounded(.towardZero))
            remainderX -= Double(x)
            remainderY -= Double(y)
            // Preserve subpixels, but avoid empty changed/began events.
            if x == 0 && y == 0 && (frame.phase == 1 || frame.phase == 2 || frame.momentum == 1 || frame.momentum == 2) { continue }
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                      wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0) else { continue }
            if let template { event.location = template.location; event.flags = template.flags }
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            var phase = frame.phase, momentum = frame.momentum
            if phase == 1 || phase == 2 { phase = emittedGesture ? 2 : 1; emittedGesture = true }
            if momentum == 1 || momentum == 2 { momentum = emittedMomentum ? 2 : 1; emittedMomentum = true }
            if phase == 4 || phase == 8 { emittedGesture = false }
            if momentum == 3 { emittedMomentum = false; remainderX = 0; remainderY = 0 }
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            generatedFrames += 1
            if frame.momentum == 1 || frame.momentum == 2 { coastFrames += 1 }
            post(event)
            if momentum == 3 {
                // AppKit can keep an inferred coast after momentum-ended.
                // A zero-distance touch/cancel pair also terminates that coast.
                // No private gesture event types or extra wheel displacement.
                postFrames([GlidePhysics.Frame(phase: 128), GlidePhysics.Frame(phase: 8)])
            }
        }
    }

    private func axis(of event: CGEvent) -> (Bool, Double, Double) {
        let fixedX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let fixedY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let x = fixedX != 0 ? fixedX : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        let y = fixedY != 0 ? fixedY : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        return (abs(x) > abs(y), x, y)
    }

    static func scale(_ event: CGEvent, by gain: Double) {
        let integral: [CGEventField] = [
            .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
            .scrollWheelEventDeltaAxis3, .scrollWheelEventPointDeltaAxis1,
            .scrollWheelEventPointDeltaAxis2, .scrollWheelEventPointDeltaAxis3,
        ]
        let fractional: [CGEventField] = [
            .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
            .scrollWheelEventFixedPtDeltaAxis3,
        ]
        let ints = integral.map { event.getIntegerValueField($0) }
        let doubles = fractional.map { event.getDoubleValueField($0) }
        for (field, value) in zip(integral, ints) {
            event.setIntegerValueField(field, value: Int64((Double(value) * gain).rounded()))
        }
        for (field, value) in zip(fractional, doubles) {
            event.setDoubleValueField(field, value: value * gain)
        }
    }
}
