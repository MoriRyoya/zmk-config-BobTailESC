// App classes are compiled unchanged, with only the launch statements replaced by this harness.
import Foundation

let repo = URL(fileURLWithPath: CommandLine.arguments[1])
let source = try String(contentsOf: repo.appendingPathComponent("config/BobTail.keymap"), encoding: .utf8)
UserDefaults.standard.setVolatileDomain([
    "osSource": "mac", "keymapSourceKind": "folder", "keymapFolderPath": repo.path,
    "scrollDefaultsVersion": 7, "reverseBobTailScroll": false,
    "scrollSmoothingEnabled": true, "scrollSpeed": 1.0,
    "scrollMomentum": GlidePhysics.standardMomentum, "scrollResponse": 0.024
], forName: UserDefaults.argumentDomain)

for enabled in [true, false] {
    let raw = enabled ? source : source.replacingOccurrences(of: "#define LAYER_INDICATOR 1", with: "#define LAYER_INDICATOR 0")
    let payload = KeymapSource.parse(text: raw, folder: nil)!
    precondition(payload.layers.count == 7)
    precondition(payload.layers.allSatisfy { $0.mac.count == 43 && $0.win.count == 43 })
    let base = payload.layers.first { $0.id == "base" }!.mac
    precondition(base[40].tap == "Enter" && base[40].hold.isEmpty)
    precondition(base[16].tap == "?" && base[16].hold.isEmpty)
    precondition(base[34].tap == "⇧" && base[41].goto == "sym")
    precondition(base[37].goto == "gesture" && base[42].goto == "fn")
}
precondition(KeymapSource.label("LEFT_BRACE") == "{")
precondition(KeymapSource.label("RIGHT_BRACKET") == "]")
precondition(KeymapSource.label("LEFT_PARENTHESIS") == "(")
precondition(KeymapSource.label("ASTERISK") == "*")
precondition(KeymapSource.label("LC(LS(TAB))") == "⌃⇧Tab")
let payload = KeymapSource.parse(text: source, folder: nil)!
let num = payload.layers.first { $0.id == "num" }!.mac
for digit in 1...9 {
    let code = KeyCodes.chord("N\(digit)")!.code
    let expected = [1: 1, 2: 2, 3: 3, 4: 11, 5: 12, 6: 13, 7: 23, 8: 24, 9: 25][digit]!
    precondition(KeyHighlight.indices(code: code, flags: [], keys: num) == [expected])
}
precondition(KeyHighlight.indices(code: 33, flags: .maskShift, keys: num) == [16]) // {
precondition(KeyHighlight.indices(code: 33, flags: [], keys: num) == [40]) // [
let relocated = source.replacingOccurrences(of: "&kp N1  &kp N2", with: "&kp N2  &kp N1")
let moved = KeymapSource.parse(text: relocated, folder: nil)!.layers.first { $0.id == "num" }!.mac
precondition(KeyHighlight.indices(code: 18, flags: [], keys: moved) == [2])

KeymapSource.shared.start()
let state = KeyboardState.shared
state.clearHeld()
state.press(IndicatorKey.mouse)
precondition(state.layerId == "mouse" && state.layerBadge == "AML")
state.press(IndicatorKey.scroll)
precondition(state.layerId == "scroll")
state.press(IndicatorKey.num)
precondition(state.layerId == "num")
precondition(state.layerIndicatorIndices.contains(39))
state.noteKey(18, down: true)
precondition(state.typedIndices == [1])
state.release(IndicatorKey.num)
precondition(state.typedIndices == [1]) // key-up after a layer change must clear the same switch
state.noteKey(18, down: false)
precondition(state.typedIndices.isEmpty)
state.release(IndicatorKey.scroll)
precondition(state.layerId == "mouse")
state.release(IndicatorKey.mouse)
precondition(state.layerId == "base")
state.press(IndicatorKey.sym)
precondition(state.layerIndicatorIndices == [41])
state.press(IndicatorKey.num)
precondition(state.layerId == "sym") // simultaneous thumbs no longer activate Fn
state.clearHeld()
state.press(IndicatorKey.fn)
precondition(state.layerIndicatorIndices == [42])
state.clearHeld()
precondition(IndicatorKey.fromHIDUsage(page: 0x0C, usage: 0x01D6) == IndicatorKey.mouse)
precondition(!IndicatorKey.all.contains(114)) // Help/Insert is an actual user key
let macStack = KeymapLayers.resolvedKeys(layerId: "sym", os: "macOS", activeLayers: ["num", "sym"])
let winStack = KeymapLayers.resolvedKeys(layerId: "num", os: "Windows", activeLayers: ["num", "sym"])
precondition(macStack[10].output == "SQT" && winStack[10].output == "SQT")
precondition(macStack[5].output == "CARET" && winStack[5].output == "HOME")
precondition(winStack[35].output == "LGUI" && winStack[36].output == "LCTRL")
// Capture delivery with a virtual clock: never inject test input into the Mac.
func scrollPreferences(reverse: Bool, enabled: Bool = true) {
    UserDefaults.standard.setVolatileDomain([
        "osSource": "mac", "keymapSourceKind": "folder", "keymapFolderPath": repo.path,
        "reverseBobTailScroll": reverse,
        "scrollSmoothingEnabled": enabled, "scrollSpeed": 1.0,
        "scrollMomentum": 0.5, "scrollResponse": 0.024
    ], forName: UserDefaults.argumentDomain)
}
func wheel(_ horizontal: Bool, _ sign: Int32) -> CGEvent {
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                        wheel1: horizontal ? 0 : sign, wheel2: horizontal ? sign : 0, wheel3: 0)!
    event.flags = .maskShift
    return event
}
for reverse in [false, true] {
    for horizontal in [false, true] {
        for sign: Int32 in [-1, 1] {
            for hidFirst in [false, true] {
                scrollPreferences(reverse: reverse)
                var time = 10.0
                var delivered: [CGEvent] = []
                let controller = ScrollController(now: { time }, automaticAnimation: false, deliver: { delivered.append($0.copy()!) })
                let input = wheel(horizontal, sign)
                if hidFirst { controller.noteWheel(horizontal: horizontal, ticks: Double(sign)) }
                let retained = controller.handle(input)
                if !retained { delivered.append(input.copy()!) }
                if !hidFirst { controller.noteWheel(horizontal: horizontal, ticks: Double(sign)) }
                for i in 1...40 { time = 10 + Double(i) / 120; controller.advance() }
                let field: CGEventField = horizontal ? .scrollWheelEventFixedPtDeltaAxis2 : .scrollWheelEventFixedPtDeltaAxis1
                let travel = delivered.reduce(0.0) { $0 + $1.getDoubleValueField(field) }
                precondition(travel * Double(sign) * (reverse ? -1 : 1) > 0)
                controller.cancel()
            }
        }
    }
}

// Reverse continues to work when inertia is disabled.
scrollPreferences(reverse: true, enabled: false)
var clock = 20.0
var posted: [CGEvent] = []
let controller = ScrollController(now: { clock }, automaticAnimation: false, deliver: { posted.append($0.copy()!) })
controller.noteWheel(horizontal: false, ticks: 1)
let reversed = wheel(false, 1)
precondition(!controller.handle(reversed))
precondition(reversed.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -1)
// A native trackpad and an unconfirmed mouse wheel must never be reversed.
let trackpad = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 8, wheel2: 0, wheel3: 0)!
precondition(!controller.handle(trackpad))
clock = 20.1
let otherWheel = wheel(false, 1)
precondition(controller.handle(otherWheel))
clock += 0.009; controller.advance()
precondition(posted.count == 1 && posted[0].getIntegerValueField(.scrollWheelEventDeltaAxis1) == 1)
// No stale debt: the very next confirmed tick is handled correctly.
controller.noteWheel(horizontal: false, ticks: 1)
let next = wheel(false, 1)
precondition(!controller.handle(next))
precondition(next.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -1)
controller.cancel()

// A real animation clock must keep emitting while HID/CG input arrives faster
// than the display. Only the delivery sink is fake; nothing is sent to the OS.
scrollPreferences(reverse: false)
state.press(IndicatorKey.scroll)
var liveFrames: [CGEvent] = []
let live = ScrollController(deliver: { liveFrames.append($0.copy()!) })
let start = Date()
let inputTimer = Timer(timeInterval: 0.004, repeats: true) { _ in
    live.noteWheel(horizontal: false, ticks: 1)
    precondition(live.handle(wheel(false, 1)))
}
RunLoop.main.add(inputTimer, forMode: .common)
RunLoop.main.run(until: start.addingTimeInterval(0.25))
inputTimer.invalidate()
precondition(liveFrames.count > 3, "Animation starved by the input stream")
precondition(liveFrames.contains { $0.getIntegerValueField(.scrollWheelEventScrollPhase) == 2 })
for event in liveFrames {
    let native = NSEvent(cgEvent: event)!
    precondition(native.hasPreciseScrollingDeltas)
    precondition(native.scrollingDeltaY >= 0)
}
live.cancel()
state.clearHeld()

// A fast multi-tick report keeps its full magnitude regardless of callback order,
// including when the Scroll layer indicator arrives before the wheel's HID data.
for hidFirst in [false, true] {
    scrollPreferences(reverse: false)
    state.press(IndicatorKey.scroll)
    var fastTime = 60.0
    var fastFrames: [CGEvent] = []
    let fast = ScrollController(now: { fastTime }, automaticAnimation: false,
        deliver: { fastFrames.append($0.copy()!) })
    if hidFirst { fast.noteWheel(horizontal: false, ticks: 6) }
    precondition(fast.handle(wheel(false, 6)))
    if !hidFirst { fast.noteWheel(horizontal: false, ticks: 6) }
    for _ in 0..<30 { fastTime += 1.0 / 120; fast.advance() }
    let direct = fastFrames.filter { $0.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 }
        .reduce(0.0) { $0 + Double(NSEvent(cgEvent: $1)!.scrollingDeltaY) }
    precondition(abs(direct - 6 * 32) <= 1)
    fast.cancel(); state.clearHeld()
}

// A sub-wheel motion onset ends both our coast and AppKit's inferred coast.
var brakeTime = 65.0
var brakeFrames: [CGEvent] = []
let braking = ScrollController(now: { brakeTime }, automaticAnimation: false,
                               deliver: { brakeFrames.append($0.copy()!) })
for _ in 0..<2 {
    braking.noteWheel(horizontal: false, ticks: 1)
    precondition(braking.handle(wheel(false, 1)))
    brakeTime += 0.016
}
for _ in 0..<30 { brakeTime += 1.0 / 120; braking.advance() }
precondition(brakeFrames.contains { $0.getIntegerValueField(.scrollWheelEventMomentumPhase) == 1 })
brakeFrames.removeAll()
braking.noteBallMotion(active: true)
precondition(brakeFrames.count == 3)
precondition(brakeFrames[0].getIntegerValueField(.scrollWheelEventMomentumPhase) == 3)
precondition(brakeFrames[1].getIntegerValueField(.scrollWheelEventScrollPhase) == 128)
precondition(brakeFrames[2].getIntegerValueField(.scrollWheelEventScrollPhase) == 8)
precondition(brakeFrames.allSatisfy { NSEvent(cgEvent: $0)!.scrollingDeltaY == 0 })
braking.noteBallMotion(active: false)
for _ in 0..<120 { brakeTime += 1.0 / 120; braking.advance() }
precondition(brakeFrames.count == 3) // no further coast or delayed direct input
braking.cancel()

// Pointer modifies only this confirmed native delta, including after a warp.
var pointerTime = 70.0
let pointer = PointerController(now: { pointerTime })
let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
func mouse(_ x: CGFloat) -> CGEvent {
    let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                    mouseCursorPosition: CGPoint(x: x, y: 200), mouseButton: .left)!
    e.flags = .maskShift
    e.setIntegerValueField(.mouseEventDeltaX, value: 1)
    return e
}
precondition(!pointer.handle(mouse(200), displays: [screen]))
pointer.noteMotion(horizontal: true, value: 1)
precondition(pointer.handle(mouse(200), displays: [screen]))
for _ in 0..<16 {
    pointerTime += 0.008
    pointer.noteMotion(horizontal: true, value: 1)
    let e = mouse(500)
    precondition(pointer.handle(e, displays: [screen]))
    precondition(e.location.x >= 499 && e.location.x <= 500) // never pull back to 200
    precondition((0...1).contains(e.getIntegerValueField(.mouseEventDeltaX)))
    precondition(e.type == .leftMouseDragged && e.flags == .maskShift)
}
pointerTime += 0.1
precondition(!pointer.handle(mouse(600), displays: [screen]))
precondition(PointerController.clamp(CGPoint(x: -5, y: 900), to: [screen]) == CGPoint(x: 0, y: 799))

// Keep corner resizing but prevent the decorative hatch marks from returning.
let hudSource = try String(contentsOf: repo.appendingPathComponent("tools/macos/BobTailBar/KeymapView.swift"), encoding: .utf8)
precondition(!hudSource.contains("drawGrip("))
print("App checks: keymap/AML, scroll arrival orders and reverse, native pixel events, live animation under 250 Hz input, pointer device matching/clipping/drag, and undecorated corners passed.")
