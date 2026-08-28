import CoreGraphics
import Foundation

/// トラックパッドの 3/4 本指スワイプと同じ経路（dock swipe）で
/// Mission Control / App Exposé / デスクトップ切替を送る。
/// CGEvent の非公開フィールドは Mac Mouse Fix / dockswipe と同じ配置。
enum DockSwipe {
    static let horizontal = 1
    static let vertical = 2
    static let hidType = 23
    static let began = 1
    static let changed = 2
    static let ended = 4
    static let cancelled = 8

    private static func field(_ raw: UInt32) -> CGEventField {
        CGEventField(rawValue: raw)!
    }

    private static func weirdFloat(_ axis: Int) -> Double {
        switch axis {
        case horizontal: return 1.401298464324817e-45
        case vertical: return 2.802596928649634e-45
        default: return 4.203895392974451e-45
        }
    }

    static func post(axis: Int, phase rawPhase: Int, origin: Double, lastDelta: Double) {
        var phase = rawPhase
        var exitSpeed = 0.0
        if phase == ended || phase == cancelled {
            exitSpeed = lastDelta * 100
        }
        if phase == ended {
            let lastSign = (lastDelta > 0 ? 1 : 0) - (lastDelta < 0 ? 1 : 0)
            let originSign = (origin > 0 ? 1 : 0) - (origin < 0 ? 1 : 0)
            if lastSign != originSign { phase = cancelled }
        }

        guard let marker = CGEvent(source: nil), let dock = CGEvent(source: nil) else { return }

        marker.setDoubleValueField(field(55), value: 29)
        marker.setDoubleValueField(field(41), value: 33231)

        dock.setDoubleValueField(field(55), value: 30)
        dock.setDoubleValueField(field(110), value: Double(hidType))
        dock.setDoubleValueField(field(132), value: Double(phase))
        dock.setDoubleValueField(field(134), value: Double(phase))
        dock.setDoubleValueField(field(124), value: origin)

        let bits = Int64(Float(origin).bitPattern)
        dock.setIntegerValueField(field(135), value: bits)
        dock.setDoubleValueField(field(41), value: 33231)

        let axisBits = weirdFloat(axis)
        dock.setDoubleValueField(field(119), value: axisBits)
        dock.setDoubleValueField(field(139), value: axisBits)
        dock.setDoubleValueField(field(123), value: Double(axis))
        dock.setDoubleValueField(field(165), value: Double(axis))
        dock.setIntegerValueField(field(136), value: 0)

        if phase == ended || phase == cancelled {
            dock.setDoubleValueField(field(129), value: exitSpeed)
            dock.setDoubleValueField(field(130), value: exitSpeed)
        }

        dock.post(tap: .cgSessionEventTap)
        marker.post(tap: .cgSessionEventTap)
    }
}

final class GestureEngine {
    private var originOffset = 0.0
    private var lastDelta = 0.0
    private var axis: Int?
    private var armedX = 0.0
    private var armedY = 0.0
    private var lastFired = Date.distantPast

    func reset() {
        originOffset = 0
        lastDelta = 0
        axis = nil
        armedX = 0
        armedY = 0
    }

    func finishIfNeeded() {
        cancel()
    }

    /// ジェスチャキーを離したとき。途中まで動いていればトラックパッドと同じく commit / cancel する。
    func finish() {
        guard let axis else {
            reset()
            return
        }
        let phase = abs(originOffset) >= 0.28 ? DockSwipe.ended : DockSwipe.cancelled
        DockSwipe.post(axis: axis, phase: phase, origin: originOffset, lastDelta: lastDelta)
        if phase == DockSwipe.ended {
            let capturedAxis = axis
            let capturedLast = lastDelta
            let capturedOrigin = originOffset
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                DockSwipe.post(
                    axis: capturedAxis,
                    phase: DockSwipe.ended,
                    origin: capturedOrigin,
                    lastDelta: capturedLast
                )
            }
        }
        reset()
    }

    /// カーソル移動が来た時点でジェスチャは終わっている。残りを Mission Control にしない。
    func cancel() {
        guard let axis else {
            reset()
            return
        }
        DockSwipe.post(axis: axis, phase: DockSwipe.cancelled, origin: originOffset, lastDelta: lastDelta)
        reset()
    }

    func feed(deltaX: Double, deltaY: Double) {
        if KeyboardState.shared.effectiveOS == "Windows" {
            feedWindows(deltaX: deltaX, deltaY: deltaY)
            return
        }
        feedTrackpad(deltaX: deltaX, deltaY: deltaY)
    }

    /// 上 = Mission Control、下 = App Exposé、左右 = デスクトップ切替。
    /// CG の Y は下が正なので、ボールを奥へ転がす（上）が Mission Control になるよう符号を反転する。
    private func feedTrackpad(deltaX: Double, deltaY: Double) {
        let prefs = Preferences.shared
        let scale = max(prefs.gestureThreshold, 20)
        let x = deltaX
        let y = -deltaY

        if axis == nil {
            armedX += x
            armedY += y
            let deadzone = max(10.0, scale * 0.18)
            if abs(armedX) < deadzone && abs(armedY) < deadzone { return }
            axis = abs(armedX) >= abs(armedY) ? DockSwipe.horizontal : DockSwipe.vertical
            let start = (axis == DockSwipe.horizontal ? armedX : armedY) / scale
            originOffset = start
            lastDelta = start
            DockSwipe.post(axis: axis!, phase: DockSwipe.began, origin: originOffset, lastDelta: lastDelta)
            armedX = 0
            armedY = 0
            return
        }

        let raw = axis == DockSwipe.horizontal ? x : y
        let step = raw / scale
        if step == 0 { return }
        originOffset += step
        lastDelta = step
        DockSwipe.post(axis: axis!, phase: DockSwipe.changed, origin: originOffset, lastDelta: lastDelta)
    }

    private func feedWindows(deltaX: Double, deltaY: Double) {
        let prefs = Preferences.shared
        guard Date().timeIntervalSince(lastFired) > prefs.gestureCooldown else { return }

        armedX += deltaX
        armedY += deltaY
        if abs(armedX) < prefs.gestureThreshold && abs(armedY) < prefs.gestureThreshold { return }

        if abs(armedX) > abs(armedY) {
            fireCtrlArrow(armedX < 0 ? ArrowKey.left : ArrowKey.right)
        } else {
            fireCtrlArrow(armedY < 0 ? ArrowKey.up : ArrowKey.down)
        }
        lastFired = Date()
        armedX = 0
        armedY = 0
    }

    private func fireCtrlArrow(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        down.flags = .maskControl
        up.flags = .maskControl
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
