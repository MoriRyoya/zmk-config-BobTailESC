// App classes are compiled unchanged, with only the launch statements replaced by this harness.
import Foundation

let repo = URL(fileURLWithPath: CommandLine.arguments[1])
let source = try String(contentsOf: repo.appendingPathComponent("config/BobTail.keymap"), encoding: .utf8)
UserDefaults.standard.setVolatileDomain([
    "osSource": "mac", "keymapSourceKind": "folder", "keymapFolderPath": repo.path,
    "scrollSmoothingEnabled": true, "scrollSpeed": 1.0,
    "scrollMomentum": ScrollPhysics.standardMomentum, "scrollResponse": 0.024
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
let scroll = ScrollController()
let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 1, wheel2: 0, wheel3: 0)!
precondition(!scroll.handle(wheel)) // another device / unconfirmed wheel is untouched
scroll.noteWheel(horizontal: true, ticks: 1)
precondition(!scroll.handle(wheel)) // a receipt for another axis cannot capture it
scroll.noteWheel(horizontal: false, ticks: 1)
precondition(scroll.handle(wheel))
// Losing one race must not poison every event after it. cancel() used to throw
// the device evidence away along with the physics, so the report that would
// have matched the next wheel event had just been deleted -- the next event
// missed too, and nothing was ever smoothed again.
scroll.cancel()
scroll.noteWheel(horizontal: false, ticks: 1)
precondition(scroll.handle(wheel))
// The window server can also hand us the CGEvent before the HID report lands.
// The event is still smoothed, and the late report settles the debt rather
// than being counted a second time.
precondition(scroll.handle(wheel))
scroll.noteWheel(horizontal: false, ticks: 1)
precondition(scroll.handle(wheel))
scroll.cancel() // no tick was run, so this test posts no generated input
let trackpad = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 8, wheel2: 0, wheel3: 0)!
scroll.noteWheel(horizontal: false, ticks: 1)
precondition(!scroll.handle(trackpad))
wheel.setIntegerValueField(.eventSourceUserData, value: ScrollController.eventTag)
precondition(!scroll.handle(wheel)) // never process our own synthetic stream recursively
print("App regression checks: source parsing, symbol aliases, relocated digits, modifiers, AML and held-key lifecycle passed.")
