//
//  BobTailBar — BobTailESC 用 macOS メニューバー常駐アプリ
//
//  1. 現在のレイヤーをメニューバーにリアルタイム表示する
//     キーボードは各レイヤーを保持している間 F13 / F16–F18 / F21 を押しっぱなしにする。
//     F14 / F15 は macOS の輝度キーなので使わない。
//     本アプリはそれを横取りして表示に変え、他アプリには渡さない。
//  2. 左右それぞれのバッテリー残量を % で表示する
//     ZMK が公開する 2 つの Battery Service を CoreBluetooth で直接読む。
//  3. ジェスチャのボール変換はファームウェア側。本アプリはレイヤー表示とバッテリー用
//

import AppKit
import CoreBluetooth
import CoreGraphics
import IOKit.hid

// MARK: - キーボードから送られてくる通知キー (macOS の仮想キーコード)

enum IndicatorKey {
    static let num: Int64 = 105     // F13  Num+Nav
    static let sym: Int64 = 144     // F21  (F15 は macOS の輝度＋)
    static let scroll: Int64 = 106  // F16
    static let gesture: Int64 = 64  // F17
    static let fn: Int64 = 79       // F18
    static let macMode: Int64 = 80  // F19
    static let winMode: Int64 = 90  // F20

    static let all: Set<Int64> = [num, sym, scroll, gesture, fn, macMode, winMode]

    /// USB HID Keyboard usage → macOS 仮想キーコード
    static func fromHIDUsage(_ usage: UInt32) -> Int64? {
        switch usage {
        case 0x68: return num      // F13
        case 0x70: return sym      // F21
        case 0x6B: return scroll   // F16
        case 0x6C: return gesture  // F17
        case 0x6D: return fn       // F18
        case 0x6E: return macMode  // F19
        case 0x6F: return winMode  // F20
        default: return nil
        }
    }
}

enum ArrowKey {
    static let left: CGKeyCode = 123
    static let right: CGKeyCode = 124
    static let down: CGKeyCode = 125
    static let up: CGKeyCode = 126
}

/// macOS 仮想キーコード → キーマップ上の物理位置
enum KeyHighlight {
    static func indices(codes: Set<Int64>, held: Set<Int64>, layer: String) -> [Int] {
        var out = Set<Int>()
        if held.contains(IndicatorKey.num) { out.insert(39) }
        if held.contains(IndicatorKey.sym) { out.insert(40) }
        if held.contains(IndicatorKey.gesture) { out.insert(37) }
        if held.contains(IndicatorKey.fn) { out.insert(16) }
        if held.contains(IndicatorKey.scroll) { out.insert(19) }
        for code in codes {
            for index in map(code, layer: layer) { out.insert(index) }
        }
        return out.sorted()
    }

    private static func map(_ code: Int64, layer: String) -> [Int] {
        switch layer {
        case "num":
            if let found = num[code] { return found }
        case "fn":
            if let found = fn[code] { return found }
        case "sym":
            if let found = sym[code] { return found }
        default:
            break
        }
        return base[code] ?? []
    }

    /// A=0 … など ANSI / JIS
    private static let base: [Int64: [Int]] = [
        12: [0], 13: [1], 14: [2], 15: [3], 17: [4],
        16: [5], 32: [6], 34: [7], 31: [8], 35: [9],
        0: [10], 1: [11], 2: [12], 3: [13], 5: [14],
        4: [17], 38: [18], 40: [19], 37: [20], 41: [21],
        6: [22], 7: [23], 8: [24], 9: [25], 11: [26],
        53: [27], 51: [28],
        45: [29], 46: [30], 43: [31], 47: [32], 44: [33],
        48: [34],
        59: [12, 35], 62: [19],
        55: [10, 36], 54: [21],
        56: [13], 60: [18],
        58: [11, 38], 61: [20, 41],
        102: [38], 104: [41],
        49: [39], 36: [40],
    ]

    private static let num: [Int64: [Int]] = [
        47: [0], 65: [0],
        26: [1], 89: [1],
        28: [2], 91: [2],
        25: [3], 92: [3],
        24: [4], 69: [4],
        75: [10], 44: [10],
        21: [11], 86: [11],
        23: [12], 87: [12],
        22: [13], 88: [13],
        27: [14], 78: [14],
        123: [18],
        125: [19],
        124: [20],
        29: [22], 82: [22],
        18: [23], 83: [23],
        19: [24], 84: [24],
        20: [25], 85: [25],
        81: [26],
        117: [28], 51: [28],
        33: [29],
        30: [30],
        42: [33],
        126: [7],
    ]

    private static let fn: [Int64: [Int]] = [
        98: [1], 100: [2], 101: [3], 111: [4],
        118: [11], 96: [12], 97: [13], 103: [14],
        122: [23], 120: [24], 99: [25], 109: [26],
        71: [21],
    ]

    private static let sym: [Int64: [Int]] = [
        18: [0], 19: [1], 20: [2], 21: [3], 23: [4],
        22: [5], 26: [6], 28: [7], 50: [8, 12], 44: [9],
        39: [10, 11], 42: [13], 27: [14],
        41: [17, 18], 43: [19], 47: [20], 24: [21],
        117: [28], 51: [28],
    ]
}

// MARK: - 状態

final class KeyboardState {
    static let shared = KeyboardState()

    private(set) var held = Set<Int64>()
    private(set) var pressedCodes = Set<Int64>()
    private(set) var osMode = "macOS"
    var leftBattery: Int?
    var rightBattery: Int?
    var bluetoothStatus = "接続を確認中…"
    var monitorStatus = "キー監視を開始しています…"
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
        default: return "base"
        }
    }

    var onChange: (() -> Void)?
    var onPressedChange: (() -> Void)?

    /// 現在有効なレイヤー名。複数保持しているときはキーマップ側の優先順に合わせる。
    var layerName: String {
        if held.contains(IndicatorKey.fn) { return "Fn" }
        if held.contains(IndicatorKey.num) && held.contains(IndicatorKey.sym) { return "Fn" }
        if held.contains(IndicatorKey.gesture) { return "ジェスチャ" }
        if held.contains(IndicatorKey.sym) { return "記号" }
        if held.contains(IndicatorKey.num) { return "テンキー" }
        if held.contains(IndicatorKey.scroll) { return "スクロール" }
        return "ベース"
    }

    var layerBadge: String {
        switch layerName {
        case "Fn": return "FN"
        case "ジェスチャ": return "GES"
        case "記号": return "SYM"
        case "テンキー": return "123"
        case "スクロール": return "SCR"
        default: return effectiveOS == "Windows" ? "WIN" : "ABC"
        }
    }

    var isGestureLayerHeld: Bool { held.contains(IndicatorKey.gesture) }

    var pressedIndices: [Int] {
        KeyHighlight.indices(codes: pressedCodes, held: held, layer: layerId)
    }

    func press(_ key: Int64) {
        applyOnMain {
            switch key {
            case IndicatorKey.macMode: self.osMode = "macOS"
            case IndicatorKey.winMode: self.osMode = "Windows"
            default: self.held.insert(key)
            }
            self.onChange?()
        }
    }

    func release(_ key: Int64) {
        applyOnMain {
            self.held.remove(key)
            self.onChange?()
        }
    }

    func noteKey(_ code: Int64, down: Bool) {
        applyOnMain {
            let changed: Bool
            if down {
                changed = self.pressedCodes.insert(code).inserted
            } else {
                changed = self.pressedCodes.remove(code) != nil
            }
            if changed { self.onPressedChange?() }
        }
    }

    /// イベントタップが一時停止した際などに状態が固まらないようにする
    func clearHeld() {
        applyOnMain {
            guard !self.held.isEmpty || !self.pressedCodes.isEmpty else { return }
            self.held.removeAll()
            self.pressedCodes.removeAll()
            self.onChange?()
            self.onPressedChange?()
        }
    }

    func setMonitorStatus(_ text: String) {
        applyOnMain {
            guard self.monitorStatus != text else { return }
            self.monitorStatus = text
            self.onChange?()
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
    private var retryTimer: Timer?
    private let gestures = GestureEngine()

    func start() {
        startHID()
        startGlobalMonitor()
        tryStartTap()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.tryStartTap()
        }
        publishStatus()
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
            self.tap = nil
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue)

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
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleNSEvent(event)
        }
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleNSEvent(event)
            return IndicatorKey.all.contains(Int64(event.keyCode)) ? nil : event
        }
    }

    private func startHID() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Any]] = [[
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard,
        ]]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<EventTapMonitor>.fromOpaque(context).takeUnretainedValue().handleHID(value)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hid = manager
    }

    private func handleHID(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let down = IOHIDValueGetIntegerValue(value) != 0
        guard page == UInt32(kHIDPage_KeyboardOrKeypad) else { return }
        guard let key = IndicatorKey.fromHIDUsage(usage) else { return }
        if down {
            KeyboardState.shared.press(key)
        } else {
            if key == IndicatorKey.gesture { gestures.cancel() }
            KeyboardState.shared.release(key)
        }
    }

    private func handleNSEvent(_ event: NSEvent) {
        let code = Int64(event.keyCode)
        if !IndicatorKey.all.contains(code) {
            if event.type == .keyDown {
                if !event.isARepeat { KeyboardState.shared.noteKey(code, down: true) }
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
        let trusted = AXIsProcessTrusted()
        if let tap, CGEvent.tapIsEnabled(tap: tap) {
            KeyboardState.shared.setMonitorStatus("キー監視: オン")
        } else if trusted {
            KeyboardState.shared.setMonitorStatus("キー監視: 再接続中…")
        } else {
            KeyboardState.shared.setMonitorStatus("キー監視: オフ（アクセシビリティを許可）")
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let state = KeyboardState.shared

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            gestures.finish()
            state.clearHeld()
            publishStatus()
            return Unmanaged.passUnretained(event)

        case .keyDown, .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if !IndicatorKey.all.contains(code) {
                if type == .keyDown {
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                        state.noteKey(code, down: true)
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

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
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
    /// 各バッテリーレベル characteristic が左右どちらのものかを覚えておく
    private var sideByCharacteristic = [CBUUID: String]()
    private var characteristicOrder = [CBCharacteristic]()

    private let batteryService = CBUUID(string: "180F")
    private let batteryLevel = CBUUID(string: "2A19")
    private let userDescription = CBUUID(string: "2901")

    /// CONFIG_ZMK_KEYBOARD_NAME と合わせる
    private let namePrefix = "BobTail"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard central.state == .poweredOn else { return }
        if let keyboard, keyboard.state == .connected {
            for characteristic in characteristicOrder {
                keyboard.readValue(for: characteristic)
            }
        } else {
            discover()
        }
    }

    private func discover() {
        let connected = central.retrieveConnectedPeripherals(withServices: [batteryService])
        if let match = connected.first(where: { ($0.name ?? "").hasPrefix(namePrefix) }) ?? connected.first {
            keyboard = match
            match.delegate = self
            central.connect(match, options: nil)
            KeyboardState.shared.bluetoothStatus = "\(match.name ?? "キーボード") に接続中…"
        } else {
            KeyboardState.shared.bluetoothStatus = "キーボードが見つかりません"
            KeyboardState.shared.onChange?()
        }
    }

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        switch manager.state {
        case .poweredOn:
            discover()
        case .unauthorized:
            KeyboardState.shared.bluetoothStatus = "Bluetooth の使用が許可されていません"
            KeyboardState.shared.onChange?()
        default:
            KeyboardState.shared.bluetoothStatus = "Bluetooth が利用できません"
            KeyboardState.shared.onChange?()
        }
    }

    func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        sideByCharacteristic.removeAll()
        characteristicOrder.removeAll()
        peripheral.discoverServices([batteryService])
    }

    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        KeyboardState.shared.bluetoothStatus = "切断されました"
        KeyboardState.shared.onChange?()
        central.connect(peripheral, options: nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == batteryService {
            peripheral.discoverCharacteristics([batteryLevel], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.uuid == batteryLevel {
            characteristicOrder.append(characteristic)
            peripheral.discoverDescriptors(for: characteristic)
            peripheral.readValue(for: characteristic)
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        KeyboardState.shared.bluetoothStatus = "接続済み"
        KeyboardState.shared.onChange?()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        for descriptor in characteristic.descriptors ?? [] where descriptor.uuid == userDescription {
            peripheral.readValue(for: descriptor)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        // ZMK は左手側(ペリフェラル)の characteristic に "Peripheral 0" という説明を付ける
        guard let text = descriptor.value as? String, let characteristic = descriptor.characteristic else { return }
        sideByCharacteristic[characteristic.uuid] = text.contains("Peripheral") ? "left" : "right"
        assignSides()
        publish(characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        assignSides()
        publish(characteristic)
    }

    /// 説明子が読めなかった場合の保険。ZMK は右手側(セントラル)の Battery Service を先に公開する
    private func assignSides() {
        guard sideByCharacteristic.isEmpty else { return }
        for (index, characteristic) in characteristicOrder.enumerated() {
            sideByCharacteristic[characteristic.uuid] = index == 0 ? "right" : "left"
        }
    }

    private func publish(_ characteristic: CBCharacteristic) {
        guard let data = characteristic.value, let level = data.first else { return }
        let side = sideByCharacteristic[characteristic.uuid]
            ?? (characteristicOrder.first?.uuid == characteristic.uuid ? "right" : "left")
        if side == "left" {
            KeyboardState.shared.leftBattery = Int(level)
        } else {
            KeyboardState.shared.rightBattery = Int(level)
        }
        KeyboardState.shared.bluetoothStatus = "接続済み"
        KeyboardState.shared.onChange?()
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
        menu.addItem(monitorItem)
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

        [layerItem, modeItem, leftItem, rightItem, statusItemRow, monitorItem].forEach { $0.isEnabled = false }
    }

    var batteryMonitor: BatteryMonitor?

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

        item.button?.title = prefs.composeMenubar(state: state)
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: prefs.menubarFontSize, weight: .semibold)

        layerItem.title = "レイヤー: \(state.layerName)"
        modeItem.title = "モード: \(state.effectiveOS)"
        leftItem.title  = "左 (L): " + (state.leftBattery.map { "\($0)%" } ?? "—")
        rightItem.title = "右 (R): " + (state.rightBattery.map { "\($0)%" } ?? "—")
        statusItemRow.title = state.bluetoothStatus
        monitorItem.title = state.monitorStatus
        gestureItem.state = prefs.gestureEnabled ? .on : .off
        keymapItem.state = prefs.keymapOverlayEnabled ? .on : .off
        AppWindows.shared.syncKeymap()
    }
}

// MARK: - エントリポイント

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusController?
    private var tap: EventTapMonitor?
    private var battery: BatteryMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )

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
