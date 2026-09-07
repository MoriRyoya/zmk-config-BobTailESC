import AppKit
import CoreGraphics

/// Synthesises the trackpad's pinch -- the zoom applications actually
/// implement. The accessibility shortcut magnifies the whole screen instead,
/// which is a different thing, and not what a zoom control on a mouse does.
///
/// macOS publishes no API for building one. The encoding below was not
/// guessed: every field was found by constructing an event and asking NSEvent
/// to decode it, which is the same decoding AppKit performs before handing an
/// event to an application. A gesture is CGEventType 29; field 110 says which
/// gesture it is (8 = kIOHIDEventTypeZoom), 113 carries the magnification, and
/// 132 the phase, where 1, 2 and 4 read back as began, changed and ended.
///
/// Detents are coalesced into a single pinch: turning holds the gesture open
/// and it ends once the hand stops, so an application sees one continuous zoom
/// rather than a burst of unrelated ones.
final class ZoomGesture {
    private static let gesture = CGEventType(rawValue: 29)
    private static let kindField = CGEventField(rawValue: 110)
    private static let magnitudeField = CGEventField(rawValue: 113)
    private static let phaseField = CGEventField(rawValue: 132)
    private static let zoomKind: Int64 = 8
    static let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4

    /// Long enough to bridge a steady turn, short enough that the pinch ends
    /// while the hand is still on the encoder.
    private static let idle = 0.18

    private var open = false
    private var closer: Timer?
    private(set) var steps = 0

    private let deliver: (CGEvent) -> Void
    private let automaticFinish: Bool

    init(automaticFinish: Bool = true,
         deliver: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.deliver = deliver
        self.automaticFinish = automaticFinish
    }

    deinit { closer?.invalidate() }

    func step(zoomingIn: Bool) {
        let amount = Preferences.shared.encoderZoomStep * (zoomingIn ? 1 : -1)
        guard post(magnification: amount, phase: open ? Self.changed : Self.began) else { return }
        open = true
        steps += 1
        guard automaticFinish else { return }
        closer?.invalidate()
        let timer = Timer(timeInterval: Self.idle, repeats: false) { [weak self] _ in self?.finish() }
        RunLoop.main.add(timer, forMode: .common)
        closer = timer
    }

    /// Close the pinch. Safe to call when none is open.
    func finish() {
        closer?.invalidate()
        closer = nil
        guard open else { return }
        open = false
        post(magnification: 0, phase: Self.ended)
    }

    @discardableResult
    private func post(magnification: Double, phase: Int64) -> Bool {
        guard let gesture = Self.gesture, let kindField = Self.kindField,
              let magnitudeField = Self.magnitudeField, let phaseField = Self.phaseField,
              let event = CGEvent(source: nil) else { return false }
        event.type = gesture
        event.setIntegerValueField(kindField, value: Self.zoomKind)
        event.setDoubleValueField(magnitudeField, value: magnification)
        event.setIntegerValueField(phaseField, value: phase)
        // Never send anything AppKit would not read back as a pinch. If a
        // future macOS changes this encoding the encoder goes inert, which is
        // recoverable, instead of emitting some other gesture, which is not.
        guard let decoded = NSEvent(cgEvent: event), decoded.type == .magnify else { return false }
        deliver(event)
        return true
    }
}
