import AppKit
import CoreServices
import Foundation

struct OverlayKey: Codable, Equatable {
    var tap: String
    var hold: String
    var kind: String
    var trans: Bool
    var none: Bool
    var goto: String?

    static let transKey = OverlayKey(tap: "↓", hold: "", kind: "trans", trans: true, none: false, goto: nil)
    static let noneKey = OverlayKey(tap: "", hold: "", kind: "none", trans: false, none: true, goto: nil)

    static func tap(_ text: String, kind: String = "", goto: String? = nil) -> OverlayKey {
        OverlayKey(tap: text, hold: "", kind: kind, trans: false, none: false, goto: goto)
    }

    static func hold(_ tap: String, _ hold: String, kind: String, goto: String? = nil) -> OverlayKey {
        OverlayKey(tap: tap, hold: hold, kind: kind, trans: false, none: false, goto: goto)
    }
}

struct OverlayLayer: Codable, Equatable {
    var id: String
    var name: String
    var mac: [OverlayKey]
    var win: [OverlayKey]
}

struct OverlayPayload: Codable, Equatable {
    var layers: [OverlayLayer]
    var source: String
}

/// ローカルフォルダまたは GitHub の `.keymap` を読み、オーバーレイへ反映する。
final class KeymapSource {
    static let shared = KeymapSource()
    static let didChange = Notification.Name("BobTailKeymapSourceDidChange")

    private(set) var payload: OverlayPayload?
    private(set) var statusText = "内蔵キーマップ"
    private var stream: FSEventStreamRef?
    private var reloadWork: DispatchWorkItem?
    private var pollTimer: Timer?
    private var githubETag: String?
    private var githubResolvedRef: String?
    private var githubTask: URLSessionDataTask?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    var kind: String {
        Preferences.shared.keymapSourceKind
    }

    var folderURL: URL? {
        get {
            if kind == "bundled" || kind == "github" { return nil }
            if let stored = Preferences.shared.keymapFolderPath, !stored.isEmpty {
                return URL(fileURLWithPath: stored)
            }
            if kind == "folder" { return nil }
            return Self.inferredFolder()
        }
        set {
            Preferences.shared.keymapFolderPath = newValue?.path
            restart()
        }
    }

    func start() {
        restart()
    }

    func restart() {
        stopWatching()
        stopPolling()
        githubETag = nil
        githubResolvedRef = nil
        reload()
        switch kind {
        case "github":
            startPolling()
        case "bundled":
            break
        default:
            if let folder = folderURL {
                startWatching(folder)
            }
        }
    }

    func reload() {
        switch kind {
        case "github":
            fetchGitHub()
        case "bundled":
            applyBundled(status: "アプリ内蔵のキーマップ")
        default:
            if let folder = folderURL, let parsed = Self.parse(text: nil, folder: folder) {
                apply(payload: parsed, status: parsed.source)
            } else if kind == "folder" {
                applyBundled(status: "フォルダのキーマップを読めません（内蔵を表示中）")
            } else if let inferred = Self.inferredFolder(), let parsed = Self.parse(text: nil, folder: inferred) {
                apply(payload: parsed, status: parsed.source)
            } else {
                applyBundled(status: "アプリ内蔵のキーマップ")
            }
        }
    }

    /// アプリバンドルに同梱した .keymap を読む。
    /// 読み込み先が見つからないときでも、表示が実機とずれないようにするための最後の砦。
    /// 内蔵の配列表を別に持つと、キーマップを直したときに片方だけ古くなる。
    private func applyBundled(status: String) {
        apply(payload: Self.bundledPayload(), status: status)
    }

    private static var cachedBundled: OverlayPayload??
    private static func bundledPayload() -> OverlayPayload? {
        if let cachedBundled { return cachedBundled }
        var parsed: OverlayPayload?
        if let url = Bundle.main.url(forResource: "BobTail", withExtension: "keymap"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            parsed = parse(text: text, folder: nil, source: "アプリ内蔵")
        }
        cachedBundled = .some(parsed)
        return parsed
    }

    func jsonString() -> String? {
        guard let payload else { return nil }
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func apply(payload: OverlayPayload?, status: String) {
        if self.payload == payload && statusText == status { return }
        self.payload = payload
        statusText = status
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private static func inferredFolder() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Documents/zmk-config-BobTailESC"),
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent(),
        ]
        return candidates.first { FileManager.default.isReadableFile(atPath: keymapURL(in: $0)?.path ?? "") }
    }

    private static func keymapURL(in folder: URL) -> URL? {
        let fm = FileManager.default
        let named = [
            folder.appendingPathComponent("config/BobTail.keymap"),
            folder.appendingPathComponent("BobTail.keymap"),
            folder.appendingPathComponent("config/keymap.keymap"),
        ]
        if let hit = named.first(where: { fm.isReadableFile(atPath: $0.path) }) {
            return hit
        }
        let searchRoots = [folder.appendingPathComponent("config"), folder, folder.appendingPathComponent("build")]
        for root in searchRoots {
            guard let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            if let keymap = files.first(where: { $0.pathExtension == "keymap" }) {
                return keymap
            }
        }
        return nil
    }

    // MARK: - GitHub

    private struct GitHubTarget {
        var owner: String
        var repo: String
        var ref: String?
        var path: String

        var label: String {
            let branch = ref.map { "@\($0)" } ?? ""
            return "\(owner)/\(repo)\(branch)"
        }
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.fetchGitHub()
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        githubTask?.cancel()
        githubTask = nil
    }

    private func fetchGitHub() {
        let prefs = Preferences.shared
        guard let target = Self.parseGitHub(
            repoField: prefs.keymapGitHubRepo,
            branchField: prefs.keymapGitHubBranch,
            pathField: prefs.keymapGitHubPath
        ) else {
            apply(payload: payload, status: "GitHub: リポジトリを入力してください")
            return
        }
        if payload == nil {
            apply(payload: nil, status: "GitHub: 取得中…")
        }
        resolveRef(target) { [weak self] resolved in
            self?.downloadGitHub(resolved)
        }
    }

    private static let fallbackBranch = "feature/researcher-keymap"

    private var hasGitHubToken: Bool {
        !Preferences.shared.keymapGitHubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func resolveRef(_ target: GitHubTarget, completion: @escaping (GitHubTarget) -> Void) {
        var next = target
        if next.ref == nil || next.ref?.isEmpty == true {
            next.ref = githubResolvedRef ?? Self.fallbackBranch
        }
        githubResolvedRef = next.ref
        completion(next)
    }

    private func downloadGitHub(_ target: GitHubTarget) {
        if hasGitHubToken {
            downloadViaAPI(target)
        } else {
            downloadViaCDN(target)
        }
    }

    private func githubFileURL(api: Bool, target: GitHubTarget) -> URL? {
        let ref = target.ref ?? Self.fallbackBranch
        let encodedPath = target.path
            .split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        if api {
            var parts = URLComponents(string: "https://api.github.com/repos/\(target.owner)/\(target.repo)/contents/\(encodedPath)")
            parts?.queryItems = [URLQueryItem(name: "ref", value: ref)]
            return parts?.url
        }
        let encodedRef = ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ref
        return URL(string: "https://raw.githubusercontent.com/\(target.owner)/\(target.repo)/\(encodedRef)/\(encodedPath)")
    }

    private func downloadViaAPI(_ target: GitHubTarget) {
        guard let url = githubFileURL(api: true, target: target) else {
            apply(payload: payload, status: "GitHub: URL が不正です")
            return
        }
        var request = URLRequest(url: url)
        applyGitHubHeaders(&request, accept: "application/vnd.github.raw")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let etag = githubETag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        startGitHubRequest(request, target: target, allowPrivateHint: false)
    }

    private func downloadViaCDN(_ target: GitHubTarget) {
        guard let url = githubFileURL(api: false, target: target) else {
            apply(payload: payload, status: "GitHub: URL が不正です")
            return
        }
        var request = URLRequest(url: url)
        applyGitHubHeaders(&request, accept: "text/plain")
        if let etag = githubETag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        startGitHubRequest(request, target: target, allowPrivateHint: true)
    }

    private func startGitHubRequest(_ request: URLRequest, target: GitHubTarget, allowPrivateHint: Bool) {
        githubTask?.cancel()
        githubTask = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handleGitHubResponse(
                    target: target,
                    data: data,
                    response: response as? HTTPURLResponse,
                    error: error,
                    allowPrivateHint: allowPrivateHint
                )
            }
        }
        githubTask?.resume()
    }

    private func handleGitHubResponse(
        target: GitHubTarget,
        data: Data?,
        response: HTTPURLResponse?,
        error: Error?,
        allowPrivateHint: Bool
    ) {
        if let error, (error as NSError).code == NSURLErrorCancelled { return }
        let code = response?.statusCode ?? 0
        if code == 304 {
            apply(payload: payload, status: "GitHub \(target.label)")
            return
        }
        if code == 401 || code == 403 {
            apply(payload: payload, status: payload == nil ? "GitHub: トークンが無効か、権限が不足しています" : "GitHub: 認証エラー（前回の配列）")
            return
        }
        if code == 404 {
            let hint = allowPrivateHint
                ? "GitHub: 見つかりません（非公開ならトークン、公開ならブランチ / パスを確認）"
                : "GitHub: 見つかりません（ブランチ / パス / トークンの権限を確認）"
            apply(payload: payload, status: hint)
            return
        }
        if let error {
            apply(payload: payload, status: "GitHub: \(error.localizedDescription)")
            return
        }
        guard let data, code == 200, let raw = Self.decodeGitHubFile(data) else {
            apply(payload: payload, status: "GitHub: 取得に失敗しました (\(code))")
            return
        }
        githubETag = response?.value(forHTTPHeaderField: "ETag")
        let source = "GitHub \(target.label)"
        guard let parsed = Self.parse(text: raw, folder: nil, source: source) else {
            apply(payload: payload, status: "GitHub: キーマップを解析できません")
            return
        }
        apply(payload: parsed, status: source)
    }

    private static func decodeGitHubFile(_ data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let b64 = json["content"] as? String {
            let cleaned = b64.replacingOccurrences(of: "\n", with: "")
            if let decoded = Data(base64Encoded: cleaned), let text = String(data: decoded, encoding: .utf8) {
                return text
            }
        }
        return String(data: data, encoding: .utf8)
    }

    private func applyGitHubHeaders(_ request: inout URLRequest, accept: String) {
        request.setValue("BobTailBar", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let token = Preferences.shared.keymapGitHubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func parseGitHub(repoField: String, branchField: String, pathField: String) -> GitHubTarget? {
        let pathDefault: String = {
            let trimmed = pathField.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "config/BobTail.keymap" : trimmed
        }()
        let branchTrim = branchField.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchOverride: String? = branchTrim.isEmpty ? fallbackBranch : branchTrim
        var text = repoField.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".git") { text.removeLast(4) }
        if text.isEmpty { return nil }

        if let url = URL(string: text), let host = url.host?.lowercased() {
            let parts = url.path.split(separator: "/").map(String.init)
            if host == "raw.githubusercontent.com", parts.count >= 3 {
                let filePath = parts.dropFirst(3).joined(separator: "/")
                return GitHubTarget(
                    owner: parts[0],
                    repo: parts[1],
                    ref: branchOverride ?? parts[2],
                    path: filePath.isEmpty ? pathDefault : filePath
                )
            }
            if host.contains("github"), parts.count >= 2 {
                let owner = parts[0]
                var repoName = parts[1]
                if repoName.hasSuffix(".git") { repoName.removeLast(4) }
                var ref = branchOverride
                var filePath = pathDefault
                if parts.count >= 3, ["blob", "tree", "raw"].contains(parts[2]) {
                    let rest = parts.dropFirst(3).joined(separator: "/")
                    if let range = rest.range(of: "config/") {
                        if ref == nil {
                            let prefix = String(rest[..<range.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            if !prefix.isEmpty { ref = prefix }
                        }
                        filePath = String(rest[range.lowerBound...])
                    } else if parts[2] == "tree" {
                        if ref == nil { ref = rest.isEmpty ? nil : rest }
                    } else if let km = rest.range(of: ".keymap", options: .backwards) {
                        let untilFile = rest[..<km.upperBound]
                        if let slash = untilFile.range(of: "/", options: .backwards) {
                            if ref == nil {
                                ref = String(rest[..<slash.lowerBound])
                            }
                            filePath = String(rest[slash.upperBound...])
                        }
                    }
                }
                return GitHubTarget(owner: owner, repo: repoName, ref: ref, path: filePath)
            }
        }

        var ownerRepo = text
        var ref = branchOverride
        if let at = text.lastIndex(of: "@") {
            ownerRepo = String(text[..<at])
            if ref == nil {
                ref = String(text[text.index(after: at)...])
            }
        }
        let bits = ownerRepo.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard bits.count >= 2 else { return nil }
        return GitHubTarget(owner: bits[bits.count - 2], repo: bits[bits.count - 1], ref: ref, path: pathDefault)
    }

    private func startWatching(_ folder: URL) {
        stopWatching()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<KeymapSource>.fromOpaque(info).takeUnretainedValue().scheduleReload()
        }
        let paths = [folder.path] as CFArray
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.35,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func stopWatching() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    // MARK: - Parser

    private static func parse(text: String?, folder: URL?, source: String? = nil) -> OverlayPayload? {
        let raw: String
        var label = source ?? "キーマップ"
        if let text {
            raw = text
        } else if let folder, let file = keymapURL(in: folder),
                  let contents = try? String(contentsOf: file, encoding: .utf8) {
            raw = contents
            label = file.path.replacingOccurrences(of: folder.path + "/", with: "")
        } else {
            return nil
        }
        let processed = preprocess(raw)
        let parsed = layers(in: processed)
        guard parsed["base"] != nil else { return nil }

        func merged(_ id: String, overlay: String) -> (mac: [OverlayKey], win: [OverlayKey]) {
            let mac = parsed[id]?.keys ?? Array(repeating: .transKey, count: 43)
            let winLayer = parsed[overlay]?.keys
            let win = winLayer.map { merge(mac, $0) } ?? mac
            return (mac, win)
        }

        let baseKeys = merged("base", overlay: "win")
        let numKeys = merged("num", overlay: "numw")
        let gestKeys = merged("gesture", overlay: "gestw")
        let ordered: [(String, String)] = [
            ("base", parsed["base"]?.name ?? "Base"),
            ("num", parsed["num"]?.name ?? "Num+Nav"),
            ("fn", parsed["fn"]?.name ?? "Fn"),
            ("sym", parsed["sym"]?.name ?? "Sym"),
            ("gesture", parsed["gesture"]?.name ?? "Gesture"),
            ("mouse", parsed["mouse"]?.name ?? "Mouse"),
        ]
        var layersOut: [OverlayLayer] = []
        for (id, fallbackName) in ordered {
            let name = parsed[id]?.name ?? fallbackName
            switch id {
            case "base":
                layersOut.append(OverlayLayer(id: id, name: name, mac: baseKeys.mac, win: baseKeys.win))
            case "num":
                layersOut.append(OverlayLayer(id: id, name: name, mac: numKeys.mac, win: numKeys.win))
            case "gesture":
                layersOut.append(OverlayLayer(id: id, name: name, mac: gestKeys.mac, win: gestKeys.win))
            default:
                let keys = parsed[id]?.keys ?? Array(repeating: .transKey, count: 43)
                layersOut.append(OverlayLayer(id: id, name: name, mac: keys, win: keys))
            }
        }
        return OverlayPayload(layers: layersOut, source: label)
    }

    private static func merge(_ base: [OverlayKey], _ overlay: [OverlayKey]) -> [OverlayKey] {
        // &trans だけが下の層へ抜ける。&none は「そのキーは無効」という指定なので、
        // 上書きしたまま表示する（Windows 側で意図的に潰しているキーがある）。
        zip(base, overlay).map { left, right in right.trans ? left : right }
    }

    private static func preprocess(_ source: String) -> String {
        var defines: [String: String] = [:]
        var taking = true
        var stack: [Bool] = []
        var out: [String] = []
        let stripped = stripComments(source)
        for rawLine in stripped.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#include") { continue }
            if trimmed.hasPrefix("#if") || trimmed.hasPrefix("#ifdef") {
                stack.append(taking)
                let cond = trimmed
                    .replacingOccurrences(of: "#ifdef", with: "")
                    .replacingOccurrences(of: "#if", with: "")
                    .trimmingCharacters(in: .whitespaces)
                taking = taking && evaluateIf(cond, defines: defines)
                continue
            }
            if trimmed.hasPrefix("#else") {
                if let parent = stack.last {
                    taking = parent && !taking
                }
                continue
            }
            if trimmed.hasPrefix("#endif") {
                taking = stack.popLast() ?? true
                continue
            }
            if !taking { continue }
            if trimmed.hasPrefix("#define") {
                let rest = trimmed.dropFirst("#define".count).trimmingCharacters(in: .whitespaces)
                let parts = rest.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                if parts.count == 2 {
                    defines[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces)
                } else if parts.count == 1 {
                    defines[String(parts[0])] = "1"
                }
                continue
            }
            out.append(applyDefines(line, defines: defines))
        }
        return out.joined(separator: "\n")
    }

    private static func evaluateIf(_ cond: String, defines: [String: String]) -> Bool {
        let token = cond.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? cond
        if token == "LAYER_INDICATOR" {
            return (defines["LAYER_INDICATOR"] ?? "1") != "0"
        }
        if token == "0" { return false }
        if token == "1" { return true }
        return defines[token] != nil && defines[token] != "0"
    }

    private static func applyDefines(_ line: String, defines: [String: String]) -> String {
        var result = line
        for key in defines.keys.sorted(by: { $0.count > $1.count }) {
            guard let value = defines[key] else { continue }
            result = replaceWord(result, word: key, with: value)
        }
        return result
    }

    private static func replaceWord(_ text: String, word: String, with value: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let regex = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_])\(escaped)(?![A-Za-z0-9_])")
        let range = NSRange(text.startIndex..., in: text)
        return regex?.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: value)) ?? text
    }

    private static func stripComments(_ source: String) -> String {
        var result = ""
        var i = source.startIndex
        var inBlock = false
        while i < source.endIndex {
            let next = source.index(after: i)
            if inBlock {
                if source[i] == "*", next < source.endIndex, source[next] == "/" {
                    inBlock = false
                    i = source.index(after: next)
                    result.append(" ")
                    continue
                }
                result.append(source[i].isNewline ? "\n" : " ")
                i = next
                continue
            }
            if source[i] == "/", next < source.endIndex, source[next] == "*" {
                inBlock = true
                i = source.index(after: next)
                continue
            }
            if source[i] == "/", next < source.endIndex, source[next] == "/" {
                while i < source.endIndex, !source[i].isNewline { i = source.index(after: i) }
                continue
            }
            result.append(source[i])
            i = next
        }
        return result
    }

    private struct ParsedLayer {
        var name: String
        var keys: [OverlayKey]
    }

    private static func layers(in text: String) -> [String: ParsedLayer] {
        guard let keymapRange = text.range(of: "keymap") else { return [:] }
        let body = String(text[keymapRange.lowerBound...])
        let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z0-9_-]+)\s*\{[^{}]*?display-name\s*=\s*"([^"]+)"[^{}]*?bindings\s*=\s*<([\s\S]*?)>\s*;"#,
            options: []
        )
        let ns = body as NSString
        var result: [String: ParsedLayer] = [:]
        regex?.enumerateMatches(in: body, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 4 else { return }
            let node = ns.substring(with: match.range(at: 1))
            let name = ns.substring(with: match.range(at: 2))
            let bindings = ns.substring(with: match.range(at: 3))
            let id = layerId(node: node, name: name)
            result[id] = ParsedLayer(name: name, keys: pad(parseBindings(bindings)))
        }
        return result
    }

    private static func layerId(node: String, name: String) -> String {
        switch node {
        case "base_layer": return "base"
        case "mouse_layer": return "mouse"
        case "scroll_layer": return "scroll"
        case "win_layer": return "win"
        case "num_layer": return "num"
        case "sym_layer": return "sym"
        case "gest_layer": return "gesture"
        case "numw_layer": return "numw"
        case "gestw_layer": return "gestw"
        case "fn_layer": return "fn"
        default:
            let lower = name.lowercased()
            if lower.contains("num") { return "num" }
            if lower.contains("sym") { return "sym" }
            if lower.contains("gest") { return "gesture" }
            if lower.contains("fn") { return "fn" }
            if lower.contains("mouse") { return "mouse" }
            if lower.contains("base") { return "base" }
            return node.replacingOccurrences(of: "_layer", with: "")
        }
    }

    private static func pad(_ keys: [OverlayKey]) -> [OverlayKey] {
        var out = keys
        if out.count < 43 {
            out.append(contentsOf: Array(repeating: OverlayKey.noneKey, count: 43 - out.count))
        }
        if out.count > 43 { out = Array(out.prefix(43)) }
        if out.indices.contains(15) { out[15] = .noneKey }
        return out
    }

    private static func parseBindings(_ text: String) -> [OverlayKey] {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var keys: [OverlayKey] = []
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token.hasPrefix("&") {
                let name = String(token.dropFirst())
                var n = arity(name)
                if name == "bt" {
                    n = (i + 1 < tokens.count && tokens[i + 1] == "BT_SEL") ? 2 : 1
                }
                var args: [String] = []
                var j = i + 1
                while args.count < n, j < tokens.count, !tokens[j].hasPrefix("&") {
                    args.append(tokens[j])
                    j += 1
                }
                keys.append(overlayKey(behavior: name, args: args))
                i = j
                continue
            }
            keys.append(overlayKey(behavior: token, args: []))
            i += 1
        }
        return keys
    }

    private static func arity(_ behavior: String) -> Int {
        switch behavior {
        case "trans", "none", "caps_word", "bootloader", "key_repeat",
             "ind_fn", "ind_gest", "ind_num", "ind_sym", "ind_scrl",
             "bri_dn", "bri_up", "num_lock", "os_mac", "os_win":
            return 0
        case "kp", "mkp", "mo", "to", "tog", "out", "msc", "mmv", "bt":
            return 1
        case "hml", "hmr", "lt_num", "lt_sym", "lt_fn", "lt_gest", "lt_scrl", "ime_mod":
            return 2
        default:
            return 0
        }
    }

    private static func overlayKey(behavior: String, args: [String]) -> OverlayKey {
        switch behavior {
        case "trans":
            return .transKey
        case "none":
            return .noneKey
        case "kp":
            return .tap(label(args.first ?? ""), kind: kindForKey(args.first ?? ""))
        case "mkp":
            return .tap(label(args.first ?? ""), kind: "")
        case "hml", "hmr":
            return .hold(label(args.last ?? ""), label(args.first ?? ""), kind: "mod")
        case "lt_num":
            return .hold(label(args.last ?? "Space"), "Num", kind: "layer", goto: "num")
        case "lt_sym":
            return .hold(label(args.last ?? "Enter"), "Sym", kind: "layer", goto: "sym")
        case "lt_fn":
            return .hold(label(args.last ?? "?"), "Fn", kind: "layer", goto: "fn")
        case "lt_gest":
            return .hold(label(args.last ?? ""), "Gesture", kind: "layer", goto: "gesture")
        case "lt_scrl":
            return .hold(label(args.last ?? "中クリック"), "Scroll", kind: "layer", goto: "scroll")
        case "ime_mod":
            return .hold(label(args.last ?? ""), label(args.first ?? ""), kind: "ime")
        case "ind_fn":
            return .hold("", "Fn", kind: "layer", goto: "fn")
        case "mo":
            if args.first == "FN" || args.first == "9" {
                return .hold("", "Fn", kind: "layer", goto: "fn")
            }
            return .tap(label(args.first ?? ""))
        case "ind_gest":
            return .hold("", "Gesture", kind: "layer", goto: "gesture")
        case "ind_num":
            return .hold("", "Num", kind: "layer", goto: "num")
        case "ind_sym":
            return .hold("", "Sym", kind: "layer", goto: "sym")
        case "ind_scrl":
            return .hold("", "Scroll", kind: "layer", goto: "scroll")
        case "bt":
            switch args.first {
            case "BT_SEL":
                return .tap("BT\(args.last ?? "")")
            case "BT_CLR":
                return .tap("BT削除")
            case "BT_CLR_ALL":
                return .tap("BT全消")
            default:
                return .tap("BT")
            }
        case "out":
            return .tap("出力切替")
        case "caps_word":
            return .tap("CapsW")
        case "bootloader":
            return .tap("ブート")
        case "bri_dn":
            return .tap("輝度−")
        case "bri_up":
            return .tap("輝度＋")
        case "os_mac":
            return .tap("Mac")
        case "os_win":
            return .tap("Win")
        case "num_lock":
            return .tap("NumLk")
        default:
            if args.isEmpty { return .tap(label(behavior)) }
            return .tap(args.map(label).joined(separator: " "))
        }
    }

    private static func kindForKey(_ code: String) -> String {
        if ["N0", "N1", "N2", "N3", "N4", "N5", "N6", "N7", "N8", "N9", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"].contains(code) {
            return "num"
        }
        if ["LCTRL", "LGUI", "LALT", "LSHFT", "RCTRL", "RGUI", "RALT", "RSHFT"].contains(code) {
            return "mod"
        }
        return ""
    }

    private static func label(_ code: String) -> String {
        let table: [String: String] = [
            "Q": "Q", "W": "W", "E": "E", "R": "R", "T": "T", "Y": "Y", "U": "U", "I": "I", "O": "O", "P": "P",
            "A": "A", "S": "S", "D": "D", "F": "F", "G": "G", "H": "H", "J": "J", "K": "K", "L": "L",
            "Z": "Z", "X": "X", "C": "C", "V": "V", "B": "B", "N": "N", "M": "M",
            "SEMI": ";", "QMARK": "?", "SLASH": "/", "DOT": ".", "COMMA": ",",
            "ESC": "Esc", "BSPC": "⌫", "TAB": "Tab", "SPACE": "Space", "ENTER": "Enter", "DEL": "Del",
            "LANG1": "かな", "LANG2": "英数",
            "LGUI": "⌘", "RGUI": "⌘", "LALT": "⌥", "RALT": "⌥",
            "LCTRL": "⌃", "RCTRL": "⌃", "LSHFT": "⇧", "RSHFT": "⇧",
            "EXCL": "!", "AT": "@", "HASH": "#", "DLLR": "$", "PRCNT": "%",
            "CARET": "^", "AMPS": "&", "ASTRK": "*", "TILDE": "~",
            "SQT": "'", "DQT": "\"", "GRAVE": "`", "PIPE": "|", "UNDER": "_",
            "COLON": ":", "LT": "<", "GT": ">", "PLUS": "+", "MINUS": "-", "EQUAL": "=",
            "LPAR": "(", "RPAR": ")", "LBRC": "{", "RBRC": "}", "LBKT": "[", "RBKT": "]", "BSLH": "\\",
            "UP": "↑", "DOWN": "↓", "LEFT": "←", "RIGHT": "→",
            "N0": "0", "N1": "1", "N2": "2", "N3": "3", "N4": "4", "N5": "5", "N6": "6", "N7": "7", "N8": "8", "N9": "9",
            "F1": "F1", "F2": "F2", "F3": "F3", "F4": "F4", "F5": "F5", "F6": "F6",
            "F7": "F7", "F8": "F8", "F9": "F9", "F10": "F10", "F11": "F11", "F12": "F12",
            "HOME": "行頭", "END": "行末",
            "MB1": "左クリック", "MB2": "右クリック", "MB3": "中クリック", "MB4": "戻る", "MB5": "進む",
            "C_MUTE": "ミュート", "C_VOL_DN": "音量−", "C_VOL_UP": "音量＋",
            "C_PREV": "前曲", "C_PP": "再生", "C_NEXT": "次曲", "PSCRN": "PrtSc",
            "LG(LEFT)": "行頭", "LG(RIGHT)": "行末",
            "LA(LEFT)": "単語←", "LA(RIGHT)": "単語→",
            "LC(LEFT)": "Desk←", "LC(RIGHT)": "Desk→", "LC(UP)": "Mission", "LC(DOWN)": "Exposé",
            "LG(LS(N4))": "範囲SS", "LG(LS(N5))": "SS", "LG(LS(S))": "範囲SS",
            "LG(LBKT)": "戻る", "LG(RBKT)": "進む",
            "LG(GRAVE)": "窓切替", "LG(TAB)": "アプリ", "LG(H)": "隠す", "LG(M)": "最小化",
            "LC(LG(F))": "フルスク", "LG(DOWN)": "最小化", "LG(UP)": "最大化",
            "LC(LG(LEFT))": "Desk←", "LC(LG(RIGHT))": "Desk→", "LG(D)": "デスクトップ",
            "LA(TAB)": "Alt+Tab",
        ]
        return table[code] ?? code
    }
}


// MARK: - 表示するレイヤーを選ぶ

/// KeyboardState の layerId（base / num / fn / sym / gesture / scroll）から
/// 実際に描く 43 キーを取り出す。
enum KeymapLayers {
    /// スクロール中はマウス層の配列を出す。専用のレイヤー定義は無い。
    private static func payloadId(for layerId: String) -> String {
        layerId == "scroll" ? "mouse" : layerId
    }

    static func layer(id: String) -> OverlayLayer? {
        let wanted = payloadId(for: id)
        guard let layers = KeymapSource.shared.payload?.layers else { return nil }
        return layers.first { $0.id == wanted } ?? layers.first { $0.id == "base" }
    }

    static func keys(layerId: String, os: String) -> [OverlayKey] {
        guard let found = layer(id: layerId) else {
            return Array(repeating: OverlayKey.noneKey, count: KeymapGeometry.keyCount)
        }
        let keys = os == "Windows" ? found.win : found.mac
        if keys.count == KeymapGeometry.keyCount { return keys }
        var padded = keys
        while padded.count < KeymapGeometry.keyCount { padded.append(.noneKey) }
        return Array(padded.prefix(KeymapGeometry.keyCount))
    }

    static func title(layerId: String) -> String {
        layer(id: layerId)?.name ?? "Base"
    }
}
