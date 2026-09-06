//
//  BobTailBar — BobTailESC 用 macOS メニューバー常駐アプリ
//
//  1. 現在のレイヤーをメニューバーにリアルタイム表示する
//     キーボードは各レイヤーを保持している間、専用の HID コードを押しっぱなしにする。
//     Scroll は Keyboard page の F22、他（Num/Sym/Gesture/Fn/Mac/Win）は
//     Consumer page の未割り当てコード（0x01D0–0x01D5）。どちらも macOS が
//     keyDown イベントを組み立てないので、アプリへ文字として漏れない
//     （昔の Help キーも互換のため HID で読む）。
//     本アプリは HID で受け取って表示に変える。CGEvent になる普通のキーは
//     押しているキーのハイライト用に見るだけで、他アプリへは渡す。
//  2. 左右それぞれのバッテリー残量を % で表示する
//     ZMK が公開する 2 つの Battery Service を CoreBluetooth で直接読む。
//  3. ジェスチャのボール変換はファームウェア側。本アプリはレイヤー表示とバッテリー用
//

import AppKit
import CoreBluetooth
import CoreGraphics
import IOKit
import IOKit.hid

// MARK: - キーボードから送られてくる通知キー (macOS の仮想キーコード)

enum IndicatorKey {
    // Num/Sym/Gesture/Fn/Mac/Win は Consumer page の未割り当てコード（0x01D0–0x01D5）で
    // 届く。macOS のどのキーボードにも対応する仮想キーコードが無いので、
    // アクセシビリティが外れていても keyDown/keyUp イベントは一切組み立てられず、
    // BobTailBar のタップが止まっていても前面のアプリへ文字として漏れない
    // （ファームウェア側の理由は config/BobTail.keymap の IND_* 定義そばを参照）。
    // 内部 ID は 1000 番台にして、実在の macOS 仮想キーコード（0–127 程度）や
    // pressedCodes に載る値と絶対に衝突しないようにしてある
    static let num: Int64 = 1001
    static let sym: Int64 = 1002
    static let scroll: Int64 = 1008 // Keep real macOS Help/Insert (114) available.
    static let gesture: Int64 = 1003
    static let fn: Int64 = 1004
    static let macMode: Int64 = 1005
    static let winMode: Int64 = 1006
    static let mouse: Int64 = 1007

    static let all: Set<Int64> = [num, sym, scroll, gesture, fn, macMode, winMode, mouse]

    /// USB HID usage（Keyboard page か Consumer page）→ 内部 ID
    static func fromHIDUsage(page: UInt32, usage: UInt32) -> Int64? {
        if page == UInt32(kHIDPage_Consumer) {
            switch usage {
            case 0x01D0: return num
            case 0x01D1: return sym
            case 0x01D2: return gesture
            case 0x01D3: return fn
            case 0x01D4: return macMode
            case 0x01D5: return winMode
            case 0x01D6: return mouse
            default: return nil
            }
        }
        if page == UInt32(kHIDPage_KeyboardOrKeypad) {
            switch usage {
            case 0x71: return scroll   // F22（現行。macOS はキーイベントにしない）
            case 0x75: return scroll   // Help（旧ファームウェア）
            default: return nil
            }
        }
        return nil
    }
}

enum ArrowKey {
    static let left: CGKeyCode = 123
    static let right: CGKeyCode = 124
    static let down: CGKeyCode = 125
    static let up: CGKeyCode = 126
}

/// Loaded bindings are the sole source of key positions, including GitHub edits.
enum KeyHighlight {
    static func layerIndices(held: Set<Int64>) -> [Int] {
        let targets: [Int64: String] = [IndicatorKey.num: "num", IndicatorKey.sym: "sym",
            IndicatorKey.gesture: "gesture", IndicatorKey.fn: "fn", IndicatorKey.scroll: "scroll"]
        let wanted = Set(held.compactMap { targets[$0] })
        let state = KeyboardState.shared
        let base = KeymapLayers.keys(layerId: "base", os: state.effectiveOS)
        let mouse = KeymapLayers.keys(layerId: "mouse", os: state.effectiveOS)
        return base.indices.filter { index in
            (base[index].goto.map { wanted.contains($0) } ?? false) ||
            (wanted.contains("scroll") && mouse[index].goto == "scroll")
        }
    }

    static func indices(code: Int64, flags: CGEventFlags, keys: [OverlayKey]) -> [Int] {
        var matches: [(Int, Int)] = []
        for (index, key) in keys.enumerated() where !key.none {
            for expression in [key.output, key.holdOutput].compactMap({ $0 }) {
                guard let chord = KeyCodes.chord(expression), chord.code == code,
                      flags.intersection(chord.modifiers) == chord.modifiers else { continue }
                matches.append((index, chord.modifiers.rawValue.nonzeroBitCount))
            }
        }
        guard let specificity = matches.map({ $0.1 }).max() else { return [] }
        let best = Set(matches.filter { $0.1 == specificity }.map { $0.0 })
        // HID reports outputs, not switch positions. Identical chords cannot be distinguished;
        // leave an ambiguous match unlit rather than claim multiple switches are held.
        return best.count == 1 ? best.sorted() : []
    }
}

// MARK: - 権限

/// 2 つの許可があるが、対等ではない。
///
///   入力監視         … IOHID。レイヤー通知（Num/Sym/Gesture/Fn/Mac/Win/Scroll）は
///                       すべて CGEvent を一切発生させない usage で送っているので
///                       （config/BobTail.keymap の IND_* 定義そばを参照）、
///                       レイヤー表示が他アプリ使用中も追従するには、これが無いと
///                       始まらない。無いと「BobTailBar を選んでいるあいだしか
///                       更新されない」のではなく、他アプリでは一切更新されない
///   アクセシビリティ … CGEvent タップ。実際に打っているキーのハイライト（レイヤーの
///                       入り口キー以外）を他アプリでも拾うためだけに使う。無くても
///                       レイヤー表示そのものは入力監視だけで動く
///
/// ad-hoc 署名のまま再ビルドすると署名が変わり、macOS が両方とも失効させる。
enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }

    static var inputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        // 未決定のときだけダイアログが出る。拒否済みなら false が返るだけ
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openAccessibilitySettings() { openPane("Privacy_Accessibility") }
    static func openInputMonitoringSettings() { openPane("Privacy_ListenEvent") }

    /// 足りない許可の設定パネルを開く。両方足りなければ、より重要な入力監視から。
    /// メニューの赤い行と、HUD の警告文の両方から呼ぶための共通経路。
    static func openWhicheverIsMissing() {
        if !inputMonitoring {
            requestInputMonitoring()
            openInputMonitoringSettings()
        } else if !accessibility {
            requestAccessibility()
            openAccessibilitySettings()
        }
    }

    private static func openPane(_ anchor: String) {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 状態

final class KeyboardState {
    static let shared = KeyboardState()
    static let didChange = Notification.Name("BobTailKeyboardStateDidChange")
    static let pressedDidChange = Notification.Name("BobTailKeyboardPressedDidChange")

    private(set) var held = Set<Int64>()
    private(set) var pressedCodes = Set<Int64>()
    private var pressedPositions: [Int64: [Int]] = [:]
    private(set) var osMode = "macOS"
    var leftBattery: Int?
    var rightBattery: Int?
    var bluetoothStatus = "接続を確認中…"
    var monitorStatus = "キー監視を開始しています…"
    var motionStatus = "スクロール入力を待っています…"
    /// 他アプリを使っている最中もレイヤーを拾えているか
    private(set) var globalTracking = false
    var gestureEnabled: Bool {
        get { Preferences.shared.gestureEnabled }
        set { Preferences.shared.gestureEnabled = newValue }
    }

    var effectiveOS: String {
        switch Preferences.shared.osSource {
        case "mac": return "macOS"
        case "win": return "Windows"
        default: return osMode
        }
    }

    var layerId: String {
        switch layerName {
        case "Fn": return "fn"
        case "ジェスチャ": return "gesture"
        case "記号": return "sym"
        case "テンキー": return "num"
        case "スクロール": return "scroll"
        case "マウス": return "mouse"
        default: return "base"
        }
    }

    /// Actual layer stack, including Windows conditional layers above Sym.
    var activeLayerIDs: [String] {
        let ordinary: [(Int64, String)] = [(IndicatorKey.mouse, "mouse"), (IndicatorKey.scroll, "scroll")]
        let middle: [(Int64, String)] = effectiveOS == "Windows"
            ? [(IndicatorKey.sym, "sym"), (IndicatorKey.num, "num")]
            : [(IndicatorKey.num, "num"), (IndicatorKey.sym, "sym")]
        let top: [(Int64, String)] = [(IndicatorKey.gesture, "gesture"), (IndicatorKey.fn, "fn")]
        return (ordinary + middle + top).filter { held.contains($0.0) }.map { $0.1 }
    }

    var onChange: (() -> Void)?
    var onPressedChange: (() -> Void)?

    func notifyUI() {
        applyOnMain { self.notifyChange() }
    }

    private func notifyChange() {
        onChange?()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func notifyPressedChange() {
        onPressedChange?()
        NotificationCenter.default.post(name: Self.pressedDidChange, object: self)
    }

    /// 現在有効なレイヤー名。複数保持しているときはキーマップ側の優先順に合わせる。
    var layerName: String {
        if held.contains(IndicatorKey.fn) { return "Fn" }
        if held.contains(IndicatorKey.gesture) { return "ジェスチャ" }
        if effectiveOS == "Windows" && held.contains(IndicatorKey.num) { return "テンキー" }
        if held.contains(IndicatorKey.sym) { return "記号" }
        if held.contains(IndicatorKey.num) { return "テンキー" }
        if held.contains(IndicatorKey.scroll) { return "スクロール" }
        if held.contains(IndicatorKey.mouse) { return "マウス" }
        return "ベース"
    }

    var layerBadge: String {
        switch layerName {
        case "Fn": return "FN"
        case "ジェスチャ": return "GES"
        case "記号": return "SYM"
        case "テンキー": return "123"
        case "スクロール": return "SCR"
        case "マウス": return "AML"
        default: return effectiveOS == "Windows" ? "WIN" : "ABC"
        }
    }

    var isGestureLayerHeld: Bool { held.contains(IndicatorKey.gesture) }

    /// The Scroll layer is the keyboard's explicit source for trackball wheel
    /// input. ScrollController uses this as a local fallback when IOHID and
    /// WindowServer callbacks do not arrive in the same order.
    var isScrollLayerHeld: Bool { held.contains(IndicatorKey.scroll) }

    /// レイヤーの入り口キー。強調表示のトグルに関係なく常に光らせる
    var layerIndicatorIndices: [Int] {
        KeyHighlight.layerIndices(held: held)
    }

    /// レイヤーの入り口キー以外で、実際に押しているキー。トグルの対象
    var typedIndices: [Int] {
        Array(Set(pressedPositions.values.flatMap { $0 })).sorted()
    }

    func press(_ key: Int64) {
        applyOnMain {
            switch key {
            case IndicatorKey.macMode: self.osMode = "macOS"
            case IndicatorKey.winMode: self.osMode = "Windows"
            default: self.held.insert(key)
            }
            self.notifyChange()
        }
    }

    func release(_ key: Int64) {
        applyOnMain {
            self.held.remove(key)
            self.notifyChange()
        }
    }

    func noteKey(_ code: Int64, down: Bool, flags: CGEventFlags = []) {
        applyOnMain {
            let changed: Bool
            if down {
                changed = self.pressedCodes.insert(code).inserted
                if changed {
                    let keys = KeymapLayers.resolvedKeys(layerId: self.layerId, os: self.effectiveOS, activeLayers: self.activeLayerIDs)
                    self.pressedPositions[code] = KeyHighlight.indices(code: code, flags: flags, keys: keys)
                }
            } else {
                changed = self.pressedCodes.remove(code) != nil
                self.pressedPositions.removeValue(forKey: code)
            }
            if changed { self.notifyPressedChange() }
        }
    }

    func noteMouseButton(_ button: Int, down: Bool) {
        applyOnMain {
            let id = Int64(2000 + button)
            if down {
                self.pressedCodes.insert(id)
                let keys = KeymapLayers.resolvedKeys(layerId: self.layerId, os: self.effectiveOS, activeLayers: self.activeLayerIDs)
                self.pressedPositions[id] = keys.indices.filter { keys[$0].output == "MB\(button)" }
            } else {
                self.pressedCodes.remove(id)
                self.pressedPositions.removeValue(forKey: id)
            }
            self.notifyPressedChange()
        }
    }

    /// イベントタップが一時停止した際などに状態が固まらないようにする
    func clearHeld() {
        applyOnMain {
            guard !self.held.isEmpty || !self.pressedCodes.isEmpty else { return }
            self.held.removeAll()
            self.pressedCodes.removeAll()
            self.pressedPositions.removeAll()
            self.notifyChange()
            self.notifyPressedChange()
        }
    }

    func setMonitorStatus(_ text: String) {
        applyOnMain {
            guard self.monitorStatus != text else { return }
            self.monitorStatus = text
            self.notifyChange()
        }
    }

    func setGlobalTracking(_ value: Bool) {
        applyOnMain {
            guard self.globalTracking != value else { return }
            self.globalTracking = value
            self.notifyChange()
        }
    }

    private func applyOnMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }
}

// MARK: - イベントタップ

final class EventTapMonitor {
    private var tap: CFMachPort?
    private var hid: IOHIDManager?
    private var hidOpen = false
    private var retryTimer: Timer?
    private let gestures = GestureEngine()
    private let scrolling = ScrollController()
    private let pointing = PointerController()
    private var displays: [CGRect] = []

    func start() {
        refreshDisplays()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.scrolling.cancel(); self?.refreshDisplays(); self?.pointing.reset()
        }
        // ここでは許可を「見る」だけで「求め」ない。AXIsProcessTrustedWithOptions /
        // IOHIDRequestAccess は未決定の状態で呼ぶと本物のシステムダイアログが立ち、
        // 起動のたびに 2 枚重なって出ていた（しかも Apple 側の既知の不具合で、
        // アクセシビリティを先に確認すると入力監視のダイアログが出なくなることがある
        // — rdar://7381305）。許可を実際に求めるのは、ユーザーが赤い行や HUD の警告を
        // クリックして Permissions.openWhicheverIsMissing() を呼んだときだけにする
        startHID()
        startGlobalMonitor()
        tryStartTap()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.tryStartTap()
            self?.openHIDIfNeeded()
            self?.publishStatus()
        }
        publishStatus()
    }

    private func refreshDisplays() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetActiveDisplayList(16, &ids, &count) == .success {
            displays = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        }
    }

    @discardableResult
    private func tryStartTap() -> Bool {
        if let tap, CGEvent.tapIsEnabled(tap: tap) {
            publishStatus()
            return true
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            if CGEvent.tapIsEnabled(tap: tap) {
                publishStatus()
                return true
            }
            CFMachPortInvalidate(tap)
            self.tap = nil
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<EventTapMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            publishStatus()
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        publishStatus()
        return true
    }

    private func startGlobalMonitor() {
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handleNSEvent(event)
        }
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handleNSEvent(event)
            return IndicatorKey.all.contains(Int64(event.keyCode)) ? nil : event
        }
    }

    private func startHID() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // レイヤー通知は Keyboard ページ（Scroll = F22）と Consumer ページ
        // （Num/Sym/Gesture/Fn/Mac/Win）の 2 系統に分かれているので、両方の
        // トップレベルコレクションにマッチさせる。片方だけだと Consumer 側の
        // 通知が一切届かない
        let matching: [[String: Any]] = [
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard,
            ],
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_Consumer,
                kIOHIDDeviceUsageKey as String: kHIDUsage_Csmr_ConsumerControl,
            ],
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse,
            ],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<EventTapMonitor>.fromOpaque(context).takeUnretainedValue().handleHID(value)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context, EventTapMonitor.isBobTail(device) else { return }
            let monitor = Unmanaged<EventTapMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.scrolling.cancel()
            monitor.pointing.reset()
            KeyboardState.shared.clearHeld()
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        hid = manager
        openHIDIfNeeded()
    }

    /// 入力監視の許可が下りるまで開けない。あとから許可されることもあるので、
    /// 一度失敗しても諦めずに開き直す。
    @discardableResult
    private func openHIDIfNeeded() -> Bool {
        if !Permissions.inputMonitoring {
            if hidOpen, let hid {
                IOHIDManagerClose(hid, IOOptionBits(kIOHIDOptionsTypeNone))
                scrolling.cancel()
                KeyboardState.shared.clearHeld()
            }
            hidOpen = false
            return false
        }
        if hidOpen { return true }
        guard let hid else { return false }
        guard Permissions.inputMonitoring else { return false }
        hidOpen = IOHIDManagerOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        return hidOpen
    }

    private static func isBobTail(_ device: IOHIDDevice) -> Bool {
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        return product?.localizedCaseInsensitiveContains("bobtail") == true
    }

    private func handleHID(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard Self.isBobTail(IOHIDElementGetDevice(element)) else { return }
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let down = IOHIDValueGetIntegerValue(value) != 0
        if page == UInt32(kHIDPage_Consumer) && usage == 0x01D7 {
            scrolling.noteBallMotion(active: down)
            return
        }
        if down && page == UInt32(kHIDPage_GenericDesktop) &&
            (usage == UInt32(kHIDUsage_GD_X) || usage == UInt32(kHIDUsage_GD_Y)) {
            // Raw motion stops coasting even when a precision filter rounds
            // the cursor displacement down to zero.
            scrolling.cancel()
            pointing.noteMotion(horizontal: usage == UInt32(kHIDUsage_GD_X),
                                value: Double(IOHIDValueGetIntegerValue(value)))
            return
        }
        if down && page == UInt32(kHIDPage_GenericDesktop) && usage == UInt32(kHIDUsage_GD_Wheel) {
            scrolling.noteWheel(horizontal: false, ticks: Double(IOHIDValueGetIntegerValue(value)))
            return
        }
        if down && page == UInt32(kHIDPage_Consumer) && usage == 0x0238 {
            scrolling.noteWheel(horizontal: true, ticks: Double(IOHIDValueGetIntegerValue(value)))
            return
        }
        if page == UInt32(kHIDPage_Button) {
            KeyboardState.shared.noteMouseButton(Int(usage), down: down)
            return
        }
        guard let key = IndicatorKey.fromHIDUsage(page: page, usage: usage) else { return }
        if down {
            if key == IndicatorKey.scroll { scrolling.cancel() }
            KeyboardState.shared.press(key)
        } else {
            if key == IndicatorKey.gesture { gestures.cancel() }
            if key == IndicatorKey.scroll { scrolling.finishInput() }
            KeyboardState.shared.release(key)
        }
    }

    private func handleNSEvent(_ event: NSEvent) {
        let code = Int64(event.keyCode)
        if event.type == .flagsChanged {
            if let flag = KeyCodes.modifier(for: code) {
                KeyboardState.shared.noteKey(code, down: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)).contains(flag))
            }
            return
        }
        if !IndicatorKey.all.contains(code) {
            if event.type == .keyDown {
                if !event.isARepeat { KeyboardState.shared.noteKey(code, down: true, flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))) }
            } else {
                KeyboardState.shared.noteKey(code, down: false)
            }
            return
        }
        if event.type == .keyDown {
            if !event.isARepeat { KeyboardState.shared.press(code) }
        } else {
            if code == IndicatorKey.gesture { gestures.cancel() }
            KeyboardState.shared.release(code)
        }
    }

    private func publishStatus() {
        let status = "起動後: スクロール入力 \(scrolling.confirmedInputs) / 補間出力 \(scrolling.generatedFrames) / 慣性出力 \(scrolling.coastFrames) / 微小動作通知 \(scrolling.motionBrakes) / ポインタ調整 \(pointing.processedReports)"
        if KeyboardState.shared.motionStatus != status {
            KeyboardState.shared.motionStatus = status
            KeyboardState.shared.notifyUI()
        }
        let tapLive = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        // レイヤー通知は全部 CGEvent を発生させない usage で送っているので、
        // レイヤー表示が他アプリでも追従するかどうかは入力監視（IOHID）だけで決まる。
        // アクセシビリティは「実際に打っているキー」のハイライトにしか効かない
        KeyboardState.shared.setGlobalTracking(hidOpen)

        let text: String
        // スクロールの慣性は両方いる。CGEvent タップ（アクセシビリティ）で
        // ホイールを差し替え、IOHID（入力監視）で「BobTail のホイールだ」と
        // 確認する。片方でも欠けると黙って素通しになるので、ここで名指しする
        if hidOpen && tapLive {
            text = "キー監視: オン"
        } else if hidOpen {
            text = "キー監視: オン（アクセシビリティが無いので、押しているキーの強調表示とスクロールの慣性は効きません）"
        } else if tapLive {
            text = "キー監視: 不十分（入力監視が無く、他アプリでのレイヤー表示とスクロールの慣性が効きません）"
        } else if Permissions.inputMonitoring {
            text = "キー監視: 再接続中…"
        } else {
            text = "キー監視: このアプリ以外では追従しません（許可が必要）"
        }
        KeyboardState.shared.setMonitorStatus(text)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let state = KeyboardState.shared

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            gestures.cancel()
            scrolling.cancel()
            state.clearHeld()
            publishStatus()
            return Unmanaged.passUnretained(event)

        case .scrollWheel:
            pointing.reset()
            if scrolling.handle(event) { return nil }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            scrolling.cancel()
        case .flagsChanged:
            scrolling.cancel()
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if let flag = KeyCodes.modifier(for: code) {
                state.noteKey(code, down: event.flags.contains(flag))
            }
        case .keyDown, .keyUp:
            if type == .keyDown { scrolling.cancel() }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if !IndicatorKey.all.contains(code) {
                if type == .keyDown {
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                        state.noteKey(code, down: true, flags: event.flags)
                    }
                } else {
                    state.noteKey(code, down: false)
                }
                break
            }
            if type == .keyDown {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    state.press(code)
                }
            } else {
                if code == IndicatorKey.gesture {
                    gestures.cancel()
                }
                state.release(code)
            }
            return nil

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if event.getIntegerValueField(.mouseEventDeltaX) != 0 || event.getIntegerValueField(.mouseEventDeltaY) != 0 {
                scrolling.cancel()
                pointing.handle(event, displays: displays)
            }
            // ファームウェアは Gesture 押し中にカーソルを送らない。
            // マウス移動が来た = キーはもう離れている。残りジェスチャは捨てる。
            if state.isGestureLayerHeld {
                state.release(IndicatorKey.gesture)
            }
            gestures.cancel()
            break

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }
}

// MARK: - バッテリー (CoreBluetooth)

final class BatteryMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var keyboard: CBPeripheral?
    private var readings = BatteryReadings()
    private var characteristics = [ObjectIdentifier: CBCharacteristic]()
    private var refreshTimer: Timer?
    private var retryTimer: Timer?

    private let batteryService = CBUUID(string: "180F")
    private let batteryLevel = CBUUID(string: "2A19")
    private let userDescription = CBUUID(string: "2901")
    private let presentationFormat = CBUUID(string: "2904")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        refreshTimer?.invalidate()
        retryTimer?.invalidate()
    }

    func refresh() {
        guard central.state == .poweredOn else { return }
        if let keyboard, keyboard.state == .connected {
            if characteristics.isEmpty {
                keyboard.discoverServices([batteryService])
            }
            for (id, characteristic) in characteristics {
                keyboard.readValue(for: characteristic)
                if !readings.hasIdentity(id) {
                    keyboard.discoverDescriptors(for: characteristic)
                }
            }
        } else if keyboard?.state != .connecting {
            discover()
        }
    }

    private func discover() {
        guard central.state == .poweredOn else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [batteryService])
        // A mouse/headset can expose BAS too. Never substitute another connected device.
        if let match = connected.first(where: { BatteryReadings.matchesKeyboard(name: $0.name) }) {
            clearReadings()
            keyboard = match
            match.delegate = self
            central.connect(match, options: nil)
            setStatus("\(match.name ?? "BobTail") に接続中…")
        } else {
            clearReadings()
            setStatus("BobTail が見つかりません")
        }
    }

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        retryTimer?.invalidate()
        clearReadings()
        switch manager.state {
        case .poweredOn:
            discover()
        case .unauthorized:
            keyboard = nil
            setStatus("Bluetooth の使用が許可されていません")
        default:
            keyboard = nil
            setStatus("Bluetooth が利用できません")
        }
    }

    func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard keyboard === peripheral else { return }
        retryTimer?.invalidate()
        clearReadings()
        setStatus("接続済み（残量を取得中…）")
        peripheral.discoverServices([batteryService])
    }

    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard keyboard === peripheral else { return }
        clearReadings()
        setStatus("切断されました（再接続待ち）")
        if central.state == .poweredOn { central.connect(peripheral, options: nil) }
    }

    func centralManager(_ manager: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard keyboard === peripheral else { return }
        clearReadings()
        keyboard = nil
        setStatus("接続できませんでした（再試行待ち）")
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.discover()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard keyboard === peripheral,
              invalidatedServices.contains(where: { $0.uuid == batteryService }) else { return }
        clearReadings()
        setStatus("バッテリー情報を再取得中…")
        peripheral.discoverServices([batteryService])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard keyboard === peripheral, peripheral.state == .connected else { return }
        guard error == nil else {
            setStatus("バッテリーサービスを取得できません")
            return
        }
        let services = (peripheral.services ?? []).filter { $0.uuid == batteryService }
        if services.isEmpty { setStatus("バッテリーサービスが見つかりません") }
        for service in services {
            peripheral.discoverCharacteristics([batteryLevel], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard keyboard === peripheral, peripheral.state == .connected,
              service.uuid == batteryService else { return }
        guard error == nil else {
            setStatus("バッテリー情報を取得できません")
            return
        }
        for characteristic in service.characteristics ?? [] where characteristic.uuid == batteryLevel {
            let id = ObjectIdentifier(characteristic)
            characteristics[id] = characteristic
            readings.register(id)
            peripheral.discoverDescriptors(for: characteristic)
            peripheral.readValue(for: characteristic)
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        publish()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        guard accepts(peripheral, characteristic), error == nil else { return }
        for descriptor in characteristic.descriptors ?? []
            where descriptor.uuid == userDescription || descriptor.uuid == presentationFormat {
            peripheral.readValue(for: descriptor)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        guard error == nil, let characteristic = descriptor.characteristic,
              accepts(peripheral, characteristic) else { return }
        let id = ObjectIdentifier(characteristic)
        if descriptor.uuid == userDescription, let text = descriptor.value as? String {
            readings.identify(id, userDescription: text)
        } else if descriptor.uuid == presentationFormat, let data = descriptor.value as? Data {
            readings.identify(id, presentation: data)
        }
        publish()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard accepts(peripheral, characteristic) else { return }
        readings.update(ObjectIdentifier(characteristic), data: error == nil ? characteristic.value : nil)
        publish()
    }

    private func accepts(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic) -> Bool {
        keyboard === peripheral && peripheral.state == .connected &&
            characteristics[ObjectIdentifier(characteristic)] != nil
    }

    private func clearReadings() {
        characteristics.removeAll()
        readings.reset()
        KeyboardState.shared.leftBattery = nil
        KeyboardState.shared.rightBattery = nil
    }

    private func setStatus(_ text: String) {
        KeyboardState.shared.bluetoothStatus = text
        KeyboardState.shared.notifyUI()
    }

    private func publish() {
        let state = KeyboardState.shared
        state.leftBattery = readings.level(for: .left)
        state.rightBattery = readings.level(for: .right)
        setStatus(state.leftBattery != nil && state.rightBattery != nil
            ? "接続済み" : "接続済み（未取得の残量は — 表示）")
    }
}

// MARK: - メニューバー

final class StatusController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private let layerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let modeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let leftItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let rightItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let statusItemRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let monitorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "", action: #selector(fixPermissions), keyEquivalent: "")
    private let gestureItem = NSMenuItem(title: "トラックボールジェスチャ", action: #selector(toggleGesture), keyEquivalent: "")
    private let keymapItem = NSMenuItem(title: "レイヤーでキーマップを表示", action: #selector(toggleKeymapOverlay), keyEquivalent: "k")

    override init() {
        super.init()
        buildMenu()
        item.menu = menu
        render()
    }

    private func buildMenu() {
        let header = NSMenuItem(title: "BobTailESC", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(layerItem)
        menu.addItem(modeItem)
        menu.addItem(.separator())
        menu.addItem(leftItem)
        menu.addItem(rightItem)
        menu.addItem(statusItemRow)

        monitorItem.target = self
        monitorItem.action = #selector(fixPermissions)
        menu.addItem(monitorItem)

        permissionItem.target = self
        menu.addItem(permissionItem)
        menu.addItem(.separator())

        gestureItem.target = self
        menu.addItem(gestureItem)

        keymapItem.target = self
        menu.addItem(keymapItem)

        let settings = NSMenuItem(title: "設定…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let refresh = NSMenuItem(title: "バッテリーを再取得", action: #selector(refreshBattery), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        [layerItem, modeItem, leftItem, rightItem, statusItemRow].forEach { $0.isEnabled = false }
        // monitorItem だけは別: 追従できていない（赤い）ときだけ押せるようにして、
        // クリックでそのまま足りない許可の設定パネルへ飛べるようにする。isEnabled は render() で管理する
        monitorItem.isEnabled = false
    }

    var batteryMonitor: BatteryMonitor?

    @objc private func fixPermissions() {
        Permissions.openWhicheverIsMissing()
    }

    @objc private func toggleGesture() {
        KeyboardState.shared.gestureEnabled.toggle()
        render()
    }

    @objc private func refreshBattery() {
        batteryMonitor?.refresh()
    }

    @objc private func toggleKeymapOverlay() {
        AppWindows.shared.toggleKeymapOverlay()
        render()
    }

    @objc private func openSettings() {
        AppWindows.shared.showSettings()
    }

    func render() {
        let state = KeyboardState.shared
        let prefs = Preferences.shared

        item.button?.attributedTitle = menubarTitle(state: state, prefs: prefs)

        layerItem.title = "レイヤー: \(state.layerName)"
        modeItem.title = "モード: \(state.effectiveOS)"
        leftItem.attributedTitle = batteryRow(label: "左 (L)", value: state.leftBattery)
        rightItem.attributedTitle = batteryRow(label: "右 (R)", value: state.rightBattery)
        statusItemRow.title = state.bluetoothStatus
        monitorItem.attributedTitle = monitorRow(state: state)
        monitorItem.isEnabled = !state.globalTracking
        renderPermissionItem()
        gestureItem.state = prefs.gestureEnabled ? .on : .off
        keymapItem.state = prefs.keymapOverlayEnabled ? .on : .off
        AppWindows.shared.syncKeymap()
    }

    /// 追従できていないときは赤で出す。ここが黙って劣化するのが一番困る。
    private func monitorRow(state: KeyboardState) -> NSAttributedString {
        let color: NSColor = state.globalTracking ? .labelColor : .systemRed
        return NSAttributedString(
            string: state.monitorStatus,
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color]
        )
    }

    /// 許可が揃っていれば出さない。足りないときだけ具体的な行き先を出す。
    /// 両方欠けているときは、レイヤー表示そのものを止めている入力監視を先に出す。
    private func renderPermissionItem() {
        if !Permissions.inputMonitoring {
            permissionItem.title = "入力監視を許可する…"
            permissionItem.isHidden = false
            permissionItem.isEnabled = true
        } else if !Permissions.accessibility {
            permissionItem.title = "アクセシビリティを許可する…"
            permissionItem.isHidden = false
            permissionItem.isEnabled = true
        } else {
            permissionItem.isHidden = true
        }
    }

    /// レイヤーを保持している間だけ色を付ける。メニューを開かなくても、
    /// いま別の層に居ることが視界の端で分かる。
    private func menubarTitle(state: KeyboardState, prefs: Preferences) -> NSAttributedString {
        let text = prefs.composeMenubar(state: state)
        let font = NSFont.monospacedDigitSystemFont(ofSize: prefs.menubarFontSize, weight: .semibold)
        let holding = state.layerId != "base"
        let color: NSColor = holding ? prefs.layerActiveColor : .labelColor
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    /// 残量が少ないときだけ赤くする。ふだんは静かにしておく。
    private func batteryRow(label: String, value: Int?) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        guard let value else {
            return NSAttributedString(
                string: "\(label): —",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            )
        }
        let filled = max(0, min(5, Int((Double(value) / 100 * 5).rounded())))
        let bar = String(repeating: "●", count: filled) + String(repeating: "○", count: 5 - filled)
        let color: NSColor = value <= 15 ? .systemRed : (value <= 30 ? .systemOrange : .labelColor)
        return NSAttributedString(
            string: "\(label): \(bar)  \(value)%",
            attributes: [.font: font, .foregroundColor: color]
        )
    }
}

// MARK: - 編集メニュー（LSUIElement でもテキスト欄のコピー / 貼り付けを有効化）

enum AppMenu {
    static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "BobTailBar を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem(title: "編集", action: nil, keyEquivalent: "")
        main.addItem(editItem)
        let editMenu = NSMenu(title: "編集")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "元に戻す", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "やり直し", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "切り取り", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "貼り付け", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "すべて選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = main
    }

    static func textEditMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "切り取り", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "貼り付け", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(.separator())
        menu.addItem(withTitle: "すべて選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }
}

// MARK: - エントリポイント

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusController?
    private var tap: EventTapMonitor?
    private var battery: BatteryMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMenu.install()

        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            ?? Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }

        let status = StatusController()
        self.status = status
        KeyboardState.shared.onChange = { [weak status] in
            if Thread.isMainThread {
                status?.render()
            } else {
                DispatchQueue.main.async { status?.render() }
            }
        }
        KeyboardState.shared.onPressedChange = {
            AppWindows.shared.pushKeymapPressed()
        }
        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { _ in
            status.render()
        }
        KeymapSource.shared.start()
        AppWindows.shared.prepareKeymapOverlay()

        let tap = EventTapMonitor()
        self.tap = tap
        tap.start()

        let battery = BatteryMonitor()
        self.battery = battery
        status.batteryMonitor = battery
        status.render()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
