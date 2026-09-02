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
    static let scroll: Int64 = 114  // 内部 ID（旧 Help の仮想キーコード。F22 は CGEvent にならない）
    static let gesture: Int64 = 1003
    static let fn: Int64 = 1004
    static let macMode: Int64 = 1005
    static let winMode: Int64 = 1006

    static let all: Set<Int64> = [num, sym, scroll, gesture, fn, macMode, winMode]

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

/// macOS 仮想キーコード → キーマップ上の物理位置
enum KeyHighlight {
    /// いま保持しているレイヤーの「入り口」キー。強調表示のオン / オフに関係なく、
    /// レイヤーバッジと同じ意味の常時表示として使う
    static func layerIndices(held: Set<Int64>) -> [Int] {
        var out = Set<Int>()
        if held.contains(IndicatorKey.num) { out.insert(39) }
        if held.contains(IndicatorKey.sym) { out.insert(40) }
        if held.contains(IndicatorKey.gesture) { out.insert(37) }
        if held.contains(IndicatorKey.fn) { out.insert(16) }
        if held.contains(IndicatorKey.scroll) { out.insert(19) }
        return out.sorted()
    }

    /// レイヤーの入り口キー以外で、実際にいま押しているキー。
    /// 「押しているキーを強調表示する」トグルの対象
    static func typedIndices(codes: Set<Int64>, layer: String) -> [Int] {
        var out = Set<Int>()
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
        122: [1], 120: [2], 99: [3], 109: [4],
        118: [11], 96: [12], 97: [13], 103: [14],
        98: [23], 100: [24], 101: [25], 111: [26],
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

// MARK: - 権限

/// レイヤー表示が他アプリ使用中も追従するには、2 つの許可が要る。
///
///   アクセシビリティ … CGEvent タップ。通知キーを他アプリに漏らさず飲み込む
///   入力監視         … IOHID。キーボードから直接読む
///
/// どちらも無いとローカルの NSEvent モニタしか動かず、
/// 「BobTailBar を選んでいるときだけ切り替わる」という症状になる。
/// ad-hoc 署名のまま再ビルドすると署名が変わり、macOS が両方とも失効させる。
enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }

    static var inputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static var globalTrackingReady: Bool { accessibility || inputMonitoring }

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

    /// 足りない許可の設定パネルを開く。両方足りなければアクセシビリティから。
    /// メニューの赤い行と、HUD の警告文の両方から呼ぶための共通経路。
    static func openWhicheverIsMissing() {
        if !accessibility {
            requestAccessibility()
            openAccessibilitySettings()
        } else if !inputMonitoring {
            requestInputMonitoring()
            openInputMonitoringSettings()
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
    private(set) var osMode = "macOS"
    var leftBattery: Int?
    var rightBattery: Int?
    var bluetoothStatus = "接続を確認中…"
    var monitorStatus = "キー監視を開始しています…"
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
        default: return "base"
        }
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

    /// レイヤーの入り口キー。強調表示のトグルに関係なく常に光らせる
    var layerIndicatorIndices: [Int] {
        KeyHighlight.layerIndices(held: held)
    }

    /// レイヤーの入り口キー以外で、実際に押しているキー。トグルの対象
    var typedIndices: [Int] {
        KeyHighlight.typedIndices(codes: pressedCodes, layer: layerId)
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

    func noteKey(_ code: Int64, down: Bool) {
        applyOnMain {
            let changed: Bool
            if down {
                changed = self.pressedCodes.insert(code).inserted
            } else {
                changed = self.pressedCodes.remove(code) != nil
            }
            if changed { self.notifyPressedChange() }
        }
    }

    /// イベントタップが一時停止した際などに状態が固まらないようにする
    func clearHeld() {
        applyOnMain {
            guard !self.held.isEmpty || !self.pressedCodes.isEmpty else { return }
            self.held.removeAll()
            self.pressedCodes.removeAll()
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

    func start() {
        // どちらも「未決定」のときだけダイアログが出る。拒否済みなら黙って false
        Permissions.requestAccessibility()
        Permissions.requestInputMonitoring()

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
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<EventTapMonitor>.fromOpaque(context).takeUnretainedValue().handleHID(value)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        hid = manager
        openHIDIfNeeded()
    }

    /// 入力監視の許可が下りるまで開けない。あとから許可されることもあるので、
    /// 一度失敗しても諦めずに開き直す。
    @discardableResult
    private func openHIDIfNeeded() -> Bool {
        if hidOpen { return true }
        guard let hid else { return false }
        guard Permissions.inputMonitoring else { return false }
        hidOpen = IOHIDManagerOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        return hidOpen
    }

    private func handleHID(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let down = IOHIDValueGetIntegerValue(value) != 0
        guard let key = IndicatorKey.fromHIDUsage(page: page, usage: usage) else { return }
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
        let tapLive = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        let global = tapLive || hidOpen
        KeyboardState.shared.setGlobalTracking(global)

        let text: String
        if tapLive && hidOpen {
            text = "キー監視: オン"
        } else if global {
            // 片方だけでも他アプリ使用中に追従はする。ただしタップが無いと
            // 通知キー（F13 など）を飲み込めず、前面のアプリへ漏れる
            text = tapLive
                ? "キー監視: オン（入力監視は未許可）"
                : "キー監視: オン（アクセシビリティ未許可。F13 等が他アプリに漏れます）"
        } else if Permissions.accessibility {
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
            KeyboardState.shared.notifyUI()
        }
    }

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        switch manager.state {
        case .poweredOn:
            discover()
        case .unauthorized:
            KeyboardState.shared.bluetoothStatus = "Bluetooth の使用が許可されていません"
            KeyboardState.shared.notifyUI()
        default:
            KeyboardState.shared.bluetoothStatus = "Bluetooth が利用できません"
            KeyboardState.shared.notifyUI()
        }
    }

    func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        sideByCharacteristic.removeAll()
        characteristicOrder.removeAll()
        peripheral.discoverServices([batteryService])
    }

    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        KeyboardState.shared.bluetoothStatus = "切断されました"
        KeyboardState.shared.notifyUI()
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
        KeyboardState.shared.notifyUI()
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
        KeyboardState.shared.notifyUI()
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
    private func renderPermissionItem() {
        if !Permissions.accessibility {
            permissionItem.title = "アクセシビリティを許可する…"
            permissionItem.isHidden = false
            permissionItem.isEnabled = true
        } else if !Permissions.inputMonitoring {
            permissionItem.title = "入力監視を許可する…"
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
