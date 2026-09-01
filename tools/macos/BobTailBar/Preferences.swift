import Foundation
import ServiceManagement

struct MenuBarToken: Codable, Equatable {
    var id: String
    var enabled: Bool
}

final class Preferences {
    static let shared = Preferences()
    static let didChange = Notification.Name("BobTailBarPreferencesDidChange")

    static let catalog: [(id: String, title: String, hint: String)] = [
        ("layer", "レイヤー", "ABC / 123 / SYM など"),
        ("os", "OS モード", "mac または win"),
        ("batteryL", "左バッテリー", "左手側の残量 %"),
        ("batteryR", "右バッテリー", "右手側の残量 %"),
        ("batteryMin", "少ない方のバッテリー", "左右で低いほうだけ"),
        ("gesture", "ジェスチャ", "GES または off"),
    ]

    private let defaults = UserDefaults.standard

    var tokens: [MenuBarToken] {
        get {
            if let data = defaults.data(forKey: "tokens"),
               let decoded = try? JSONDecoder().decode([MenuBarToken].self, from: data),
               !decoded.isEmpty {
                return Self.normalized(decoded)
            }
            return Self.defaultTokens
        }
        set {
            let data = try? JSONEncoder().encode(Self.normalized(newValue))
            defaults.set(data, forKey: "tokens")
            ping()
        }
    }

    var separator: String {
        get { defaults.string(forKey: "separator") ?? "  " }
        set { defaults.set(newValue, forKey: "separator"); ping() }
    }

    var showBatteryPrefix: Bool {
        get { defaults.object(forKey: "showBatteryPrefix") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showBatteryPrefix"); ping() }
    }

    var menubarFontSize: Double {
        get {
            let value = defaults.double(forKey: "menubarFontSize")
            return value == 0 ? 11 : value
        }
        set { defaults.set(newValue, forKey: "menubarFontSize"); ping() }
    }

        var gestureEnabled: Bool {
            get { defaults.object(forKey: "gestureEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "gestureEnabled"); ping() }
    }

    var gestureThreshold: Double {
        get {
            let value = defaults.double(forKey: "gestureThreshold")
            return value == 0 ? 45 : value
        }
        set { defaults.set(newValue, forKey: "gestureThreshold"); ping() }
    }

    var gestureCooldown: Double {
        get {
            let value = defaults.double(forKey: "gestureCooldown")
            return value == 0 ? 0.45 : value
        }
        set { defaults.set(newValue, forKey: "gestureCooldown"); ping() }
    }

    /// keyboard = F19/F20 に追従。mac / win ならアプリ側で固定。
    var osSource: String {
        get { defaults.string(forKey: "osSource") ?? "keyboard" }
        set { defaults.set(newValue, forKey: "osSource"); ping() }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: "launchAtLogin") }
        set {
            defaults.set(newValue, forKey: "launchAtLogin")
            applyLoginItem(newValue)
            ping()
        }
    }

    var keepKeymapOnTop: Bool {
        get { defaults.bool(forKey: "keepKeymapOnTop") }
        set { defaults.set(newValue, forKey: "keepKeymapOnTop"); ping() }
    }

    var keymapOverlayEnabled: Bool {
        get { defaults.object(forKey: "keymapOverlayEnabled2") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keymapOverlayEnabled2"); ping() }
    }

    /// 0.25 ... 1.0（ウィンドウの alpha）。UI の「透明度」は 1 - この値。
    var keymapOverlayOpacity: Double {
        get {
            if defaults.object(forKey: "keymapOverlayOpacity") == nil { return 0.78 }
            return min(1, max(0.25, defaults.double(forKey: "keymapOverlayOpacity")))
        }
        set { defaults.set(min(1, max(0.25, newValue)), forKey: "keymapOverlayOpacity"); ping() }
    }

    /// キーマップ重ね表示の倍率。0.55 ... 1.7（端ドラッグでも更新される）
    var keymapOverlayScale: Double {
        get {
            if defaults.object(forKey: "keymapOverlayScale") == nil { return 1.0 }
            return min(1.7, max(0.55, defaults.double(forKey: "keymapOverlayScale")))
        }
        set { defaults.set(min(1.7, max(0.55, newValue)), forKey: "keymapOverlayScale"); ping() }
    }

    /// オーバーレイ実サイズ。未設定なら scale から算出。
    var keymapOverlayPixelSize: NSSize {
        get {
            let width = defaults.double(forKey: "keymapOverlayWidth")
            let height = defaults.double(forKey: "keymapOverlayHeight")
            if width >= 420, height >= 250 {
                return NSSize(width: width, height: height)
            }
            let scale = CGFloat(keymapOverlayScale)
            return NSSize(
                width: (820 * scale).rounded(),
                height: (488 * scale).rounded()
            )
        }
        set {
            let width = min(1400, max(420, newValue.width.rounded()))
            let height = min(900, max(250, newValue.height.rounded()))
            let same =
                defaults.object(forKey: "keymapOverlayWidth") as? Double == Double(width) &&
                defaults.object(forKey: "keymapOverlayHeight") as? Double == Double(height)
            defaults.set(Double(width), forKey: "keymapOverlayWidth")
            defaults.set(Double(height), forKey: "keymapOverlayHeight")
            defaults.set(min(1.7, max(0.55, Double(width / 820))), forKey: "keymapOverlayScale")
            if !same { ping() }
        }
    }

    var keymapOverlayClickThrough: Bool {
        get { defaults.object(forKey: "keymapOverlayClickThrough") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keymapOverlayClickThrough"); ping() }
    }

    var keymapOverlayHideOnBase: Bool {
        get { defaults.object(forKey: "keymapOverlayHideOnBase2") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keymapOverlayHideOnBase2"); ping() }
    }

    var keymapHighlightPressed: Bool {
        get { defaults.object(forKey: "keymapHighlightPressed") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keymapHighlightPressed"); ping() }
    }

    /// auto / folder / github / bundled
    var keymapSourceKind: String {
        get { defaults.string(forKey: "keymapSourceKind") ?? "auto" }
        set { defaults.set(newValue, forKey: "keymapSourceKind"); ping() }
    }

    var keymapFolderPath: String? {
        get { defaults.string(forKey: "keymapFolderPath") }
        set { defaults.set(newValue, forKey: "keymapFolderPath"); ping() }
    }

    var keymapGitHubRepo: String {
        get { defaults.string(forKey: "keymapGitHubRepo") ?? "MoriRyoya/zmk-config-BobTailESC" }
        set { defaults.set(newValue, forKey: "keymapGitHubRepo"); ping() }
    }

    var keymapGitHubBranch: String {
        get {
            let value = defaults.string(forKey: "keymapGitHubBranch") ?? ""
            return value.isEmpty ? "feature/researcher-keymap" : value
        }
        set { defaults.set(newValue, forKey: "keymapGitHubBranch"); ping() }
    }

    var keymapGitHubPath: String {
        get {
            let value = defaults.string(forKey: "keymapGitHubPath") ?? ""
            return value.isEmpty ? "config/BobTail.keymap" : value
        }
        set { defaults.set(newValue, forKey: "keymapGitHubPath"); ping() }
    }

    var keymapGitHubToken: String {
        get { defaults.string(forKey: "keymapGitHubToken") ?? "" }
        set { defaults.set(newValue, forKey: "keymapGitHubToken"); ping() }
    }

    /// bottomRight / bottomLeft / topRight / topLeft
    var keymapOverlayCorner: String {
        get { defaults.string(forKey: "keymapOverlayCorner") ?? "bottomRight" }
        set { defaults.set(newValue, forKey: "keymapOverlayCorner"); ping() }
    }

    static var defaultTokens: [MenuBarToken] {
        [
            .init(id: "layer", enabled: true),
            .init(id: "batteryL", enabled: true),
            .init(id: "batteryR", enabled: true),
            .init(id: "os", enabled: false),
            .init(id: "batteryMin", enabled: false),
            .init(id: "gesture", enabled: false),
        ]
    }

    private static func normalized(_ tokens: [MenuBarToken]) -> [MenuBarToken] {
        var seen = Set<String>()
        var result: [MenuBarToken] = []
        for token in tokens where catalog.contains(where: { $0.id == token.id }) && seen.insert(token.id).inserted {
            result.append(token)
        }
        for item in catalog where !seen.contains(item.id) {
            result.append(.init(id: item.id, enabled: false))
        }
        return result
    }

    func title(for id: String) -> String {
        Self.catalog.first(where: { $0.id == id })?.title ?? id
    }

    func composeMenubar(state: KeyboardState) -> String {
        let sep = separator
        var parts: [String] = []
        for token in tokens where token.enabled {
            switch token.id {
            case "layer":
                parts.append(state.layerBadge)
            case "os":
                parts.append(state.effectiveOS == "Windows" ? "win" : "mac")
            case "batteryL":
                parts.append(batteryText(prefix: showBatteryPrefix ? "L" : nil, value: state.leftBattery))
            case "batteryR":
                parts.append(batteryText(prefix: showBatteryPrefix ? "R" : nil, value: state.rightBattery))
            case "batteryMin":
                let minValue = [state.leftBattery, state.rightBattery].compactMap { $0 }.min()
                parts.append(batteryText(prefix: nil, value: minValue))
            case "gesture":
                parts.append(gestureEnabled ? (state.isGestureLayerHeld ? "GES" : "ges") : "off")
            default:
                break
            }
        }
        return parts.isEmpty ? "BT" : parts.joined(separator: sep)
    }

    private func batteryText(prefix: String?, value: Int?) -> String {
        let body = value.map { "\($0)%" } ?? "—"
        if let prefix { return "\(prefix)\(body)" }
        return body
    }

    private func ping() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func applyLoginItem(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                defaults.set(!enabled, forKey: "launchAtLogin")
            }
        }
    }
}
