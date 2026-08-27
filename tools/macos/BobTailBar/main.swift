//
//  BobTailBar — BobTailESC 用 macOS メニューバー常駐アプリ
//
//  1. 現在のレイヤーをメニューバーにリアルタイム表示する
//     キーボードは各レイヤーを保持している間 F13〜F18 を押しっぱなしにする。
//     本アプリはそれを横取りして表示に変え、他アプリには渡さない。
//  2. 左右それぞれのバッテリー残量を % で表示する
//     ZMK が公開する 2 つの Battery Service を CoreBluetooth で直接読む。
//  3. ジェスチャレイヤー保持中のトラックボール操作を macOS ジェスチャに変換する
//     上 = Mission Control / 下 = App Exposé / 左右 = デスクトップ切り替え
//     ボールの動きに追従する（純正トラックパッドの 3/4 本指スワイプと同じ経路）
//

import AppKit
import CoreBluetooth
import CoreGraphics

// MARK: - キーボードから送られてくる通知キー (macOS の仮想キーコード)

enum IndicatorKey {
    static let num: Int64 = 105     // F13  Num+Nav
    static let sym: Int64 = 113     // F15
    static let scroll: Int64 = 106  // F16
    static let gesture: Int64 = 64  // F17
    static let fn: Int64 = 79       // F18
    static let macMode: Int64 = 80  // F19
    static let winMode: Int64 = 90  // F20

    static let all: Set<Int64> = [num, sym, scroll, gesture, fn, macMode, winMode]
}

enum ArrowKey {
    static let left: CGKeyCode = 123
    static let right: CGKeyCode = 124
    static let down: CGKeyCode = 125
    static let up: CGKeyCode = 126
}

// MARK: - 状態

final class KeyboardState {
    static let shared = KeyboardState()

    private(set) var held = Set<Int64>()
    private(set) var osMode = "macOS"
    var leftBattery: Int?
    var rightBattery: Int?
    var bluetoothStatus = "接続を確認中…"
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

    func press(_ key: Int64) {
        switch key {
        case IndicatorKey.macMode: osMode = "macOS"
        case IndicatorKey.winMode: osMode = "Windows"
        default: held.insert(key)
        }
        onChange?()
    }

    func release(_ key: Int64) {
        held.remove(key)
        onChange?()
    }

    /// イベントタップが一時停止した際などに状態が固まらないようにする
    func clearHeld() {
        guard !held.isEmpty else { return }
        held.removeAll()
        onChange?()
    }
}

// MARK: - イベントタップ

final class EventTapMonitor {
    private var tap: CFMachPort?
    private let gestures = GestureEngine()

    func start() -> Bool {
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
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let state = KeyboardState.shared

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            gestures.finish()
            state.clearHeld()
            return Unmanaged.passUnretained(event)

        case .keyDown, .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            guard IndicatorKey.all.contains(code) else { break }
            if type == .keyDown {
                // オートリピートは無視する
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    state.press(code)
                }
            } else {
                if code == IndicatorKey.gesture {
                    gestures.finish()
                }
                state.release(code)
            }
            // 通知用のキーは他アプリへ渡さない
            return nil

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            guard state.gestureEnabled, state.isGestureLayerHeld else {
                gestures.finishIfNeeded()
                break
            }
            let dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
            let dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
            gestures.feed(deltaX: dx, deltaY: dy)
            // ジェスチャ中はポインタを動かさない
            return nil

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
    private let gestureItem = NSMenuItem(title: "トラックボールジェスチャ", action: #selector(toggleGesture), keyEquivalent: "")
    private let keymapItem = NSMenuItem(title: "キーマップオーバーレイ", action: #selector(toggleKeymapOverlay), keyEquivalent: "k")

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
            status?.render()
        }
        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { _ in
            status.render()
        }

        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )

        let tap = EventTapMonitor()
        if tap.start() {
            self.tap = tap
        } else {
            KeyboardState.shared.bluetoothStatus = trusted
                ? "キー監視を開始できませんでした"
                : "「アクセシビリティ」で許可後、再起動してください"
        }

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
