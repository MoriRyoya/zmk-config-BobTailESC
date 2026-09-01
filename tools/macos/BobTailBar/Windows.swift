import AppKit
import WebKit

enum KeymapHTML {
    static var url: URL? {
        let candidates = [
            Bundle.main.url(forResource: "keymap", withExtension: "html"),
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("docs/keymap.html"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

final class KeymapPane: NSObject, WKNavigationDelegate {
    enum Mode: String {
        case embed
        case hud
    }

    let webView: WKWebView
    var onReady: (() -> Void)?
    private let mode: Mode
    private var ready = false
    private var readyPoll: Timer?
    private var pendingPush = false

    var isReady: Bool { ready }

    init(mode: Mode) {
        self.mode = mode
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let boot = WKUserScript(
            source: "document.documentElement.classList.add('\(mode.rawValue)');",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(boot)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 820, height: 488), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        webView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        webView.setContentHuggingPriority(.defaultLow, for: .vertical)
        webView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        webView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
        NotificationCenter.default.addObserver(
            forName: KeymapSource.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pushKeymapData()
            self?.pushState()
        }
        load()
        startReadyPoll()
    }

    func pushState() {
        pendingPush = true
        guard ready else { return }
        flushState()
    }

    func pushKeymapData() {
        guard ready else { return }
        if let json = KeymapSource.shared.jsonString() {
            webView.evaluateJavaScript("window.setBobTailKeymap && window.setBobTailKeymap(\(json));", completionHandler: nil)
        } else {
            webView.evaluateJavaScript("window.setBobTailKeymap && window.setBobTailKeymap(null);", completionHandler: nil)
        }
    }

    func pushPressed() {
        guard ready else { return }
        webView.evaluateJavaScript(
            "window.setBobTailPressed && window.setBobTailPressed(\(Self.pressedJS));",
            completionHandler: nil
        )
    }

    /// 設定を開かなくても JS が動くように、明示的に起床させる
    func wake() {
        if !ready {
            load()
        }
        startReadyPoll()
        _ = webView.window
        webView.needsLayout = true
        webView.layoutSubtreeIfNeeded()
        probeReady()
    }

    private func flushState() {
        let state = KeyboardState.shared
        let script = """
        window.setBobTailAppearance && window.setBobTailAppearance('\(mode.rawValue)');
        window.setBobTailState && window.setBobTailState('\(state.layerId)', '\(state.effectiveOS)', \(Self.pressedJS));
        """
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let self else { return }
            if error == nil {
                self.pendingPush = false
            } else {
                self.ready = false
                self.startReadyPoll()
            }
        }
    }

    private static var pressedJS: String {
        guard Preferences.shared.keymapHighlightPressed else { return "[]" }
        let ids = KeyboardState.shared.pressedIndices.map(String.init).joined(separator: ",")
        return "[\(ids)]"
    }

    private func load() {
        ready = false
        guard let file = KeymapHTML.url else { return }
        // loadFileURL は accessory アプリで完了しないことがあるので、文字列読み込みを優先する
        if let html = try? String(contentsOf: file, encoding: .utf8) {
            webView.loadHTMLString(html, baseURL: file.deletingLastPathComponent())
        } else {
            var url = file
            if var parts = URLComponents(url: file, resolvingAgainstBaseURL: false) {
                parts.fragment = mode.rawValue
                url = parts.url ?? file
            }
            webView.loadFileURL(url, allowingReadAccessTo: file.deletingLastPathComponent())
        }
    }

    private func startReadyPoll() {
        readyPoll?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.probeReady()
            if self.ready {
                timer.invalidate()
                self.readyPoll = nil
            }
        }
        readyPoll = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func probeReady() {
        webView.evaluateJavaScript("typeof window.setBobTailState === 'function'") { [weak self] result, _ in
            guard let self else { return }
            let ok = (result as? Bool) == true || (result as? NSNumber)?.boolValue == true
            guard ok else { return }
            let wasReady = self.ready
            self.ready = true
            if !wasReady {
                self.pushKeymapData()
                self.flushState()
                self.onReady?()
            } else if self.pendingPush {
                self.flushState()
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        probeReady()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.load()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.load()
        }
    }
}

private final class HUDPanel: NSPanel {
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
}

private final class OverlayDragHandle: NSView {
    var title = "キーマップ" {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = bounds.insetBy(dx: 12, dy: 4)
        NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10).fill()
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let stroke = NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10)
        stroke.lineWidth = 1
        stroke.stroke()
        let grip = NSRect(x: bounds.midX - 14, y: bounds.maxY - 8, width: 28, height: 2.5)
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
        let text = title as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2 - 1),
            withAttributes: attrs
        )
    }
}

/// WebView を載せつつ、角ドラッグでリサイズ・中央はクリック透過できるホスト。
private final class OverlayChromeView: NSView {
    enum Edge: CaseIterable {
        case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight

        var isCorner: Bool {
            switch self {
            case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
            default: return false
            }
        }
    }

    var clickThrough = true
    /// ドラッグ中（Preferences は触らない）
    var onResizeLive: ((NSSize) -> Void)?
    /// マウスアップ時だけ保存
    var onResizeEnd: ((NSSize) -> Void)?
    private(set) var activeResize = false
    /// 角のヒット領域（クリック透過時もここだけ掴める）
    private let corner: CGFloat = 16
    /// 辺（クリック透過オフのときだけ）
    private let edge: CGFloat = 6
    private var activeEdge: Edge?
    private var startMouseScreen = NSPoint.zero
    private var startFrame = NSRect.zero

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        discardCursorRects()
        let b = bounds
        let c = corner
        addCursorRect(NSRect(x: 0, y: b.height - c, width: c, height: c), cursor: .crosshair)
        addCursorRect(NSRect(x: b.width - c, y: b.height - c, width: c, height: c), cursor: .crosshair)
        addCursorRect(NSRect(x: 0, y: 0, width: c, height: c), cursor: .crosshair)
        addCursorRect(NSRect(x: b.width - c, y: 0, width: c, height: c), cursor: .crosshair)
        if !clickThrough {
            addCursorRect(NSRect(x: 0, y: c, width: edge, height: max(0, b.height - 2 * c)), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: b.width - edge, y: c, width: edge, height: max(0, b.height - 2 * c)), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: c, y: b.height - edge, width: max(0, b.width - 2 * c), height: edge), cursor: .resizeUpDown)
            addCursorRect(NSRect(x: c, y: 0, width: max(0, b.width - 2 * c), height: edge), cursor: .resizeUpDown)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let hit = edge(at: local) {
            if clickThrough, !hit.isCorner { return nil }
            return self
        }
        if clickThrough { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let hit = edge(at: local), let window else { return }
        if clickThrough, !hit.isCorner { return }
        activeEdge = hit
        activeResize = true
        // ウィンドウ座標だとリサイズで原点が動いてぷるぷるするので画面座標を使う
        startMouseScreen = NSEvent.mouseLocation
        startFrame = window.frame.integral
        window.ignoresMouseEvents = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let activeEdge, let window else { return }
        activeResize = true
        let now = NSEvent.mouseLocation
        let delta = NSPoint(
            x: now.x - startMouseScreen.x,
            y: now.y - startMouseScreen.y
        )
        var frame = startFrame
        let minSize = NSSize(width: 420, height: 250)
        let maxSize = NSSize(width: 1400, height: 900)

        switch activeEdge {
        case .right:
            frame.size.width = min(maxSize.width, max(minSize.width, startFrame.width + delta.x))
        case .left:
            let width = min(maxSize.width, max(minSize.width, startFrame.width - delta.x))
            frame.origin.x = startFrame.maxX - width
            frame.size.width = width
        case .top:
            frame.size.height = min(maxSize.height, max(minSize.height, startFrame.height + delta.y))
        case .bottom:
            let height = min(maxSize.height, max(minSize.height, startFrame.height - delta.y))
            frame.origin.y = startFrame.maxY - height
            frame.size.height = height
        case .topRight:
            frame.size.width = min(maxSize.width, max(minSize.width, startFrame.width + delta.x))
            frame.size.height = min(maxSize.height, max(minSize.height, startFrame.height + delta.y))
        case .topLeft:
            let width = min(maxSize.width, max(minSize.width, startFrame.width - delta.x))
            frame.origin.x = startFrame.maxX - width
            frame.size.width = width
            frame.size.height = min(maxSize.height, max(minSize.height, startFrame.height + delta.y))
        case .bottomRight:
            frame.size.width = min(maxSize.width, max(minSize.width, startFrame.width + delta.x))
            let height = min(maxSize.height, max(minSize.height, startFrame.height - delta.y))
            frame.origin.y = startFrame.maxY - height
            frame.size.height = height
        case .bottomLeft:
            let width = min(maxSize.width, max(minSize.width, startFrame.width - delta.x))
            frame.origin.x = startFrame.maxX - width
            frame.size.width = width
            let height = min(maxSize.height, max(minSize.height, startFrame.height - delta.y))
            frame.origin.y = startFrame.maxY - height
            frame.size.height = height
        }

        frame = frame.integral
        window.setFrame(frame, display: true, animate: false)
        onResizeLive?(frame.size)
    }

    override func mouseUp(with event: NSEvent) {
        let size = window?.frame.integral.size
        activeEdge = nil
        activeResize = false
        if let size {
            onResizeEnd?(size)
        }
    }

    func isOnResizeHandle(_ pointInView: NSPoint) -> Bool {
        guard let hit = edge(at: pointInView) else { return false }
        if clickThrough { return hit.isCorner }
        return true
    }

    private func edge(at point: NSPoint) -> Edge? {
        let b = bounds
        let c = corner
        let l = point.x <= c
        let r = point.x >= b.width - c
        let bottom = point.y <= c
        let top = point.y >= b.height - c
        // 角を優先（一般的なウィンドウリサイズ）
        if l && top { return .topLeft }
        if r && top { return .topRight }
        if l && bottom { return .bottomLeft }
        if r && bottom { return .bottomRight }
        if clickThrough { return nil }
        let e = edge
        if point.x <= e { return .left }
        if point.x >= b.width - e { return .right }
        if point.y >= b.height - e { return .top }
        if point.y <= e { return .bottom }
        return nil
    }
}

final class KeymapOverlayController: NSWindowController {
    static let baseContentSize = NSSize(width: 820, height: 488)
    static let handleHeight: CGFloat = 28

    private let pane = KeymapPane(mode: .hud)
    private let handleView = OverlayDragHandle()
    private let chrome = OverlayChromeView()
    private let contentPanel: HUDPanel
    private var resizing = false
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?

    private var contentSize: NSSize {
        Preferences.shared.keymapOverlayPixelSize
    }

    init() {
        let size = Preferences.shared.keymapOverlayPixelSize
        let handle = Self.makePanel(size: NSSize(width: size.width, height: Self.handleHeight), activating: false)
        handle.setFrameAutosaveName("BobTailKeymapHandle6")
        handle.isMovableByWindowBackground = true
        handle.ignoresMouseEvents = false
        handle.contentView = handleView

        let content = Self.makePanel(size: size, activating: true)
        content.allowKey = true
        content.ignoresMouseEvents = false
        chrome.translatesAutoresizingMaskIntoConstraints = false
        pane.webView.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(pane.webView)
        NSLayoutConstraint.activate([
            pane.webView.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            pane.webView.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            pane.webView.topAnchor.constraint(equalTo: chrome.topAnchor),
            pane.webView.bottomAnchor.constraint(equalTo: chrome.bottomAnchor),
        ])
        content.contentView = chrome
        self.contentPanel = content

        super.init(window: handle)
        handle.addChildWindow(content, ordered: .below)
        chrome.onResizeLive = { [weak self] size in
            self?.followHandle(toContentSize: size)
        }
        chrome.onResizeEnd = { [weak self] size in
            self?.finishContentResize(size)
        }
        pane.onReady = { [weak self] in self?.sync() }
        place(at: Preferences.shared.keymapOverlayCorner)
        warmUp()
        startMouseMonitor()
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: Preferences.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(layerChanged), name: KeyboardState.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pressedChanged), name: KeyboardState.pressedDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleMoved), name: NSWindow.didMoveNotification, object: handle)
    }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func sync() {
        let prefs = Preferences.shared
        let holdingLayer = KeyboardState.shared.layerId != "base"
        let show = prefs.keymapOverlayEnabled && (!prefs.keymapOverlayHideOnBase || holdingLayer)
        pane.pushState()
        handleView.title = "キーマップ · \(KeyboardState.shared.layerBadge)（上バーで移動 / 角でサイズ変更）"
        guard show else {
            hide()
            return
        }
        applyStyle()
        if !resizing {
            layoutChild()
        }
        window?.orderFrontRegardless()
        contentPanel.orderFrontRegardless()
    }

    func place(at corner: String) {
        guard let screen = NSScreen.main, let handle = window else { return }
        let visible = screen.visibleFrame
        let size = contentSize
        let combined = NSSize(
            width: size.width,
            height: size.height + Self.handleHeight
        )
        let margin: CGFloat = 16
        let origin: NSPoint
        switch corner {
        case "bottomLeft":
            origin = NSPoint(x: visible.minX + margin, y: visible.minY + margin)
        case "topLeft":
            origin = NSPoint(x: visible.minX + margin, y: visible.maxY - combined.height - margin)
        case "topRight":
            origin = NSPoint(x: visible.maxX - combined.width - margin, y: visible.maxY - combined.height - margin)
        default:
            origin = NSPoint(x: visible.maxX - combined.width - margin, y: visible.minY + margin)
        }
        handle.setFrame(
            NSRect(x: origin.x, y: origin.y + size.height, width: combined.width, height: Self.handleHeight),
            display: true
        )
        layoutChild()
    }

    func pushState() {
        pane.pushState()
        handleView.title = "キーマップ · \(KeyboardState.shared.layerBadge)（上バーで移動 / 角でサイズ変更）"
    }

    func pushPressed() {
        pane.pushPressed()
    }

    @objc private func prefsChanged() {
        if resizing { return }
        sync()
    }

    @objc private func layerChanged() {
        if resizing || chrome.activeResize { return }
        sync()
    }

    @objc private func pressedChanged() {
        if resizing || chrome.activeResize { return }
        pushPressed()
    }

    @objc private func handleMoved() {
        if resizing || chrome.activeResize { return }
        layoutChild()
    }

    /// ドラッグ中: 上バーだけ追従。Preferences は書かない。
    private func followHandle(toContentSize size: NSSize) {
        resizing = true
        guard let handle = window else { return }
        var hf = handle.frame
        hf.size.width = size.width.rounded()
        hf.size.height = Self.handleHeight
        hf.origin.x = contentPanel.frame.origin.x.rounded()
        hf.origin.y = contentPanel.frame.maxY.rounded()
        handle.setFrame(hf.integral, display: true, animate: false)
    }

    /// マウスアップ: サイズを一度だけ保存
    private func finishContentResize(_ size: NSSize) {
        resizing = true
        Preferences.shared.keymapOverlayPixelSize = size
        followHandle(toContentSize: size)
        resizing = false
        updateClickThrough(for: NSEvent.mouseLocation)
    }

    func wake() {
        contentPanel.allowKey = true
        contentPanel.alphaValue = 0.02
        window?.alphaValue = 0.02
        contentPanel.orderFrontRegardless()
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        contentPanel.makeKeyAndOrderFront(nil)
        pane.wake()
        pushState()
        DispatchQueue.main.async { [weak self] in
            self?.sync()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.pane.wake()
            self?.sync()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.pane.wake()
            self?.sync()
        }
    }

    private func warmUp() {
        layoutChild()
        window?.alphaValue = 0.02
        contentPanel.alphaValue = 0.02
        window?.ignoresMouseEvents = true
        contentPanel.ignoresMouseEvents = false
        window?.orderFrontRegardless()
        contentPanel.orderFrontRegardless()
        pane.wake()
        pane.pushState()
        DispatchQueue.main.async { [weak self] in
            self?.sync()
        }
    }

    private func hide() {
        contentPanel.ignoresMouseEvents = false
        window?.ignoresMouseEvents = true
        contentPanel.alphaValue = 0
        window?.alphaValue = 0
        window?.orderFrontRegardless()
        contentPanel.orderFrontRegardless()
    }

    private func applyStyle() {
        let prefs = Preferences.shared
        let alpha = CGFloat(prefs.keymapOverlayOpacity)
        window?.alphaValue = max(alpha, 0.55)
        window?.ignoresMouseEvents = false
        contentPanel.alphaValue = alpha
        chrome.clickThrough = prefs.keymapOverlayClickThrough
        updateClickThrough(for: NSEvent.mouseLocation)
        chrome.window?.invalidateCursorRects(for: chrome)
    }

    private func startMouseMonitor() {
        let handler: (NSEvent) -> Void = { [weak self] _ in
            guard let self else { return }
            // リサイズ中は ignoresMouseEvents をいじるとイベントが途切れて揺れる
            if self.resizing || self.chrome.activeResize { return }
            self.updateClickThrough(for: NSEvent.mouseLocation)
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: handler)
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            handler(event)
            return event
        }
    }

    private func updateClickThrough(for screenPoint: NSPoint) {
        guard Preferences.shared.keymapOverlayClickThrough else {
            contentPanel.ignoresMouseEvents = false
            return
        }
        if resizing || chrome.activeResize {
            contentPanel.ignoresMouseEvents = false
            return
        }
        let frame = contentPanel.frame
        guard frame.contains(screenPoint) else {
            contentPanel.ignoresMouseEvents = true
            return
        }
        let local = NSPoint(x: screenPoint.x - frame.minX, y: screenPoint.y - frame.minY)
        // クリック透過オン時は四隅だけアプリ側が受け取る
        contentPanel.ignoresMouseEvents = !chrome.isOnResizeHandle(local)
    }

    private func layoutChild() {
        guard let handle = window else { return }
        let size = contentSize
        var hf = handle.frame
        hf.size = NSSize(width: size.width, height: Self.handleHeight)
        handle.setFrame(hf, display: true)
        contentPanel.setFrame(
            NSRect(
                x: hf.minX,
                y: hf.minY - size.height,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        chrome.needsDisplay = true
    }

    private static func makePanel(size: NSSize, activating: Bool) -> HUDPanel {
        var mask: NSWindow.StyleMask = [.borderless]
        if !activating {
            mask.insert(.nonactivatingPanel)
        }
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: mask,
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = !activating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true
        panel.hidesOnDeactivate = false
        return panel
    }
}

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let tabs = NSTabView()
    private let table = NSTableView()
    private let preview = NSTextField(labelWithString: "")
    private let sep = NSPopUpButton()
    private let prefixBox = NSButton(checkboxWithTitle: "バッテリーに L / R を付ける", target: nil, action: nil)
    private let fontSize = NSSlider()
    private let follow = NSButton(radioButtonWithTitle: "キーボードに追従（Fn 層の Mac / Win）", target: nil, action: nil)
    private let forceMac = NSButton(radioButtonWithTitle: "このアプリで macOS 表示に固定", target: nil, action: nil)
    private let forceWin = NSButton(radioButtonWithTitle: "このアプリで Windows 表示に固定", target: nil, action: nil)
    private let gestureBox = NSButton(checkboxWithTitle: "トラックボールジェスチャを使う", target: nil, action: nil)
    private let threshold = NSSlider()
    private let cooldown = NSSlider()
    private let thresholdLabel = NSTextField(labelWithString: "")
    private let cooldownLabel = NSTextField(labelWithString: "")
    private let loginBox = NSButton(checkboxWithTitle: "ログイン時に起動する", target: nil, action: nil)
    private let keymapCaption = NSTextField(labelWithString: "")
    private let overlayBox = NSButton(checkboxWithTitle: "レイヤーキーを押している間、キーマップを画面に重ねる", target: nil, action: nil)
    private let clickThroughBox = NSButton(checkboxWithTitle: "配列の上のクリックは下のアプリへ通す", target: nil, action: nil)
    private let hideOnBaseBox = NSButton(checkboxWithTitle: "ベース（ABC）では隠す", target: nil, action: nil)
    private let highlightBox = NSButton(checkboxWithTitle: "押しているキーを強調表示する", target: nil, action: nil)
    private let opacity = NSSlider()
    private let opacityLabel = NSTextField(labelWithString: "")
    private let overlayScale = NSSlider()
    private let overlayScaleLabel = NSTextField(labelWithString: "")
    private let sourcePopup = NSPopUpButton()
    private let keymapFolderLabel = NSTextField(labelWithString: "")
    private let keymapSourceStatus = NSTextField(wrappingLabelWithString: "")
    private let githubRepoField = NSTextField()
    private let githubBranchField = NSTextField()
    private let githubPathField = NSTextField()
    private let githubTokenField = NSSecureTextField()
    private let folderBox = NSStackView()
    private let githubBox = NSStackView()
    private var tokens: [MenuBarToken] = []
    private var isReloading = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BobTailBar 設定"
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.setFrameAutosaveName("BobTailSettings4")
        super.init(window: window)
        tokens = Preferences.shared.tokens
        window.contentView = build()
        NotificationCenter.default.addObserver(
            forName: KeymapSource.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshKeymapSource()
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        reload()
    }

    private func build() -> NSView {
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(tab("メニューバー", view: displayTab()))
        tabs.addTabViewItem(tab("キーボード", view: keyboardTab()))
        tabs.addTabViewItem(tab("キーマップ", view: keymapTab()))
        tabs.addTabViewItem(tab("ジェスチャ", view: gestureTab()))
        tabs.addTabViewItem(tab("一般", view: generalTab()))
        return tabs
    }

    private func tab(_ title: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        return item
    }

    private func displayTab() -> NSView {
        let wrap = inset()
        preview.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        preview.stringValue = "プレビュー"

        let hint = NSTextField(wrappingLabelWithString: "CodexBar と同じく、メニューバーに出す項目を選んで並べ替えます。チェックを外すと非表示になります。")
        hint.textColor = .secondaryLabelColor

        table.headerView = nil
        table.rowHeight = 28
        table.delegate = self
        table.dataSource = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        col.width = 520
        table.addTableColumn(col)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 210).isActive = true

        let up = NSButton(title: "上へ", target: self, action: #selector(moveTokenUp))
        let down = NSButton(title: "下へ", target: self, action: #selector(moveTokenDown))
        let buttons = NSStackView(views: [up, down])
        buttons.orientation = NSUserInterfaceLayoutOrientation.horizontal

        sep.removeAllItems()
        sep.addItems(withTitles: ["スペース", "中点  ·", "縦線  |", "スラッシュ  /"])
        sep.target = self
        sep.action = #selector(changed)
        let sepRow = labeled("区切り", sep)

        prefixBox.target = self
        prefixBox.action = #selector(changed)

        fontSize.minValue = 10
        fontSize.maxValue = 14
        fontSize.numberOfTickMarks = 5
        fontSize.target = self
        fontSize.action = #selector(changed)
        let fontRow = labeled("文字サイズ", fontSize)

        let stack = NSStackView(views: [hint, preview, scroll, buttons, sepRow, prefixBox, fontRow])
        stack.orientation = NSUserInterfaceLayoutOrientation.vertical
        stack.alignment = NSLayoutConstraint.Attribute.leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fontSize.widthAnchor.constraint(equalToConstant: 180),
        ])
        return wrap
    }

    private func keyboardTab() -> NSView {
        let wrap = inset()
        let hint = NSTextField(wrappingLabelWithString: "本体の Win 層はキーボード Fn → Win で切り替わり、F19 / F20 でこのアプリに通知されます。表示とキーマップ確認だけアプリ側で固定することもできます。HID 経由でファームウェアのレイヤーそのものを書き換えることはできません。")
        hint.textColor = .secondaryLabelColor

        for button in [follow, forceMac, forceWin] {
            button.target = self
            button.action = #selector(osChanged)
        }

        let stack = NSStackView(views: [hint, follow, forceMac, forceWin])
        stack.orientation = NSUserInterfaceLayoutOrientation.vertical
        stack.alignment = NSLayoutConstraint.Attribute.leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 16),
        ])
        return wrap
    }

    private func keymapTab() -> NSView {
        let hint = NSTextField(wrappingLabelWithString: "Num / Sym / Fn などを押している間、そのレイヤーの配列が画面に重なります。離すと消えます。")
        hint.textColor = .secondaryLabelColor

        overlayBox.target = self
        overlayBox.action = #selector(overlayChanged)
        clickThroughBox.target = self
        clickThroughBox.action = #selector(overlayChanged)
        hideOnBaseBox.target = self
        hideOnBaseBox.action = #selector(overlayChanged)
        highlightBox.target = self
        highlightBox.action = #selector(overlayChanged)

        opacity.minValue = 0
        opacity.maxValue = 0.75
        opacity.target = self
        opacity.action = #selector(overlayChanged)
        let opacityRow = labeled("透明度", opacity)

        overlayScale.minValue = 0.55
        overlayScale.maxValue = 1.7
        overlayScale.target = self
        overlayScale.action = #selector(overlayChanged)
        let scaleRow = labeled("大きさ", overlayScale)

        let titles = ["左下", "右下", "左上", "右上"]
        var placeButtons: [NSView] = []
        for (index, title) in titles.enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(placeOverlay(_:)))
            button.tag = index
            placeButtons.append(button)
        }
        let placeRow = NSStackView(views: [NSTextField(labelWithString: "位置")] + placeButtons)
        placeRow.orientation = NSUserInterfaceLayoutOrientation.horizontal
        placeRow.spacing = 8

        let overlayHint = NSTextField(wrappingLabelWithString: "位置はボタンか上バーのドラッグ、大きさは四隅をドラッグして変えられます。クリック透過中でも角と上バーだけ掴めます。")
        overlayHint.textColor = .secondaryLabelColor

        keymapCaption.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)

        sourcePopup.removeAllItems()
        sourcePopup.addItems(withTitles: ["自動（ローカルフォルダ）", "フォルダ", "GitHub", "アプリ内蔵"])
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceKindChanged)
        let sourceRow = labeled("読み込み先", sourcePopup)

        keymapFolderLabel.lineBreakMode = .byTruncatingMiddle
        keymapSourceStatus.textColor = .secondaryLabelColor
        let choose = NSButton(title: "フォルダを選択…", target: self, action: #selector(chooseKeymapFolder))
        let reloadFolder = NSButton(title: "再読み込み", target: self, action: #selector(reloadKeymapSource))
        let clear = NSButton(title: "解除", target: self, action: #selector(clearKeymapFolder))
        let folderRow = NSStackView(views: [choose, reloadFolder, clear])
        folderRow.orientation = NSUserInterfaceLayoutOrientation.horizontal
        folderRow.spacing = 8
        let folderHint = NSTextField(wrappingLabelWithString: "zmk-config リポジトリ直下を指定します。Keymap Editor で config/*.keymap を保存するとすぐ反映します。")
        folderHint.textColor = .secondaryLabelColor
        folderBox.setViews([
            NSTextField(labelWithString: "キーマップフォルダ"),
            keymapFolderLabel,
            folderRow,
            folderHint,
        ], in: .leading)
        folderBox.orientation = NSUserInterfaceLayoutOrientation.vertical
        folderBox.spacing = 8

        githubRepoField.placeholderString = "MoriRyoya/zmk-config-BobTailESC または GitHub URL"
        githubBranchField.placeholderString = "feature/researcher-keymap"
        githubPathField.placeholderString = "config/BobTail.keymap"
        githubTokenField.placeholderString = "ghp_… / github_pat_…（非公開用）"
        for field in [githubRepoField, githubBranchField, githubPathField, githubTokenField] {
            field.delegate = self
            field.cell?.sendsActionOnEndEditing = true
            field.isEditable = true
            field.isSelectable = true
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.focusRingType = .default
            field.menu = AppMenu.textEditMenu()
        }
        let fetch = NSButton(title: "GitHub から読み込む", target: self, action: #selector(applyGitHubSource))
        let githubHint = NSTextField(wrappingLabelWithString: "公開リポジトリはトークン不要です。非公開は GitHub の Fine-grained token（Contents: Read）を入れて API で読みます。ブランチの初期値は feature/researcher-keymap です。約 20 秒ごとに取り込みます。")
        githubHint.textColor = .secondaryLabelColor
        githubBox.setViews([
            labeled("リポジトリ", githubRepoField),
            labeled("ブランチ", githubBranchField),
            labeled("ファイル", githubPathField),
            labeled("トークン", githubTokenField),
            fetch,
            githubHint,
        ], in: .leading)
        githubBox.orientation = NSUserInterfaceLayoutOrientation.vertical
        githubBox.spacing = 8
        githubRepoField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        githubBranchField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        githubPathField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        githubTokenField.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let stack = NSStackView(views: [
            hint,
            overlayBox,
            hideOnBaseBox,
            highlightBox,
            opacityRow,
            opacityLabel,
            scaleRow,
            overlayScaleLabel,
            clickThroughBox,
            placeRow,
            overlayHint,
            keymapCaption,
            sourceRow,
            folderBox,
            githubBox,
            keymapSourceStatus,
        ])
        stack.orientation = NSUserInterfaceLayoutOrientation.vertical
        stack.alignment = NSLayoutConstraint.Attribute.leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.autoresizingMask = [.width, .height]
        opacity.widthAnchor.constraint(equalToConstant: 220).isActive = true
        overlayScale.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return stack
    }

    private func gestureTab() -> NSView {
        let wrap = inset()
        gestureBox.target = self
        gestureBox.action = #selector(changed)
        threshold.minValue = 20
        threshold.maxValue = 90
        threshold.target = self
        threshold.action = #selector(changed)
        cooldown.minValue = 0.15
        cooldown.maxValue = 1.0
        cooldown.target = self
        cooldown.action = #selector(changed)
        let stack = NSStackView(views: [
            gestureBox,
            labeled("フルスワイプに必要な移動量", threshold),
            thresholdLabel,
            labeled("Windows 時の連打間隔", cooldown),
            cooldownLabel,
        ])
        stack.orientation = NSUserInterfaceLayoutOrientation.vertical
        stack.alignment = NSLayoutConstraint.Attribute.leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 16),
            threshold.widthAnchor.constraint(equalToConstant: 240),
            cooldown.widthAnchor.constraint(equalToConstant: 240),
        ])
        return wrap
    }

    private func generalTab() -> NSView {
        let wrap = inset()
        loginBox.target = self
        loginBox.action = #selector(changed)
        let note = NSTextField(wrappingLabelWithString: "ログイン時起動は /Applications に入れた BobTailBar.app に対して有効です。")
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [loginBox, note])
        stack.orientation = NSUserInterfaceLayoutOrientation.vertical
        stack.alignment = NSLayoutConstraint.Attribute.leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 16),
        ])
        return wrap
    }

    private func inset() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private func labeled(_ title: String, _ view: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        let row = NSStackView(views: [label, view])
        row.orientation = NSUserInterfaceLayoutOrientation.horizontal
        row.spacing = 12
        return row
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tokens.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let token = tokens[row]
        let box = NSButton(checkboxWithTitle: Preferences.shared.title(for: token.id), target: self, action: #selector(toggleToken(_:)))
        box.state = token.enabled ? .on : .off
        box.tag = row
        if let hint = Preferences.catalog.first(where: { $0.id == token.id })?.hint {
            box.toolTip = hint
        }
        return box
    }

    @objc private func toggleToken(_ sender: NSButton) {
        guard tokens.indices.contains(sender.tag) else { return }
        tokens[sender.tag].enabled = sender.state == .on
        saveTokens()
    }

    @objc private func moveTokenUp() {
        let row = table.selectedRow
        guard row > 0 else { return }
        tokens.swapAt(row, row - 1)
        saveTokens()
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: row - 1), byExtendingSelection: false)
    }

    @objc private func moveTokenDown() {
        let row = table.selectedRow
        guard row >= 0, row < tokens.count - 1 else { return }
        tokens.swapAt(row, row + 1)
        saveTokens()
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
    }

    @objc private func changed() {
        guard !isReloading else { return }
        let prefs = Preferences.shared
        prefs.showBatteryPrefix = prefixBox.state == .on
        prefs.menubarFontSize = fontSize.doubleValue
        prefs.gestureEnabled = gestureBox.state == .on
        prefs.gestureThreshold = threshold.doubleValue
        prefs.gestureCooldown = cooldown.doubleValue
        prefs.launchAtLogin = loginBox.state == .on
        switch sep.indexOfSelectedItem {
        case 1: prefs.separator = " · "
        case 2: prefs.separator = " | "
        case 3: prefs.separator = " / "
        default: prefs.separator = "  "
        }
        refreshLabels()
        KeyboardState.shared.onChange?()
    }

    @objc private func overlayChanged() {
        guard !isReloading else { return }
        let prefs = Preferences.shared
        prefs.keymapOverlayEnabled = overlayBox.state == .on
        prefs.keymapOverlayClickThrough = clickThroughBox.state == .on
        prefs.keymapOverlayHideOnBase = hideOnBaseBox.state == .on
        prefs.keymapHighlightPressed = highlightBox.state == .on
        prefs.keymapOverlayOpacity = 1 - opacity.doubleValue
        let scale = overlayScale.doubleValue
        prefs.keymapOverlayScale = scale
        prefs.keymapOverlayPixelSize = NSSize(
            width: (820 * scale).rounded(),
            height: (488 * scale).rounded()
        )
        refreshLabels()
        AppWindows.shared.syncKeymap()
    }

    @objc private func placeOverlay(_ sender: NSButton) {
        let corners = ["bottomLeft", "bottomRight", "topLeft", "topRight"]
        guard corners.indices.contains(sender.tag) else { return }
        Preferences.shared.keymapOverlayCorner = corners[sender.tag]
        Preferences.shared.keymapOverlayEnabled = true
        overlayBox.state = .on
        AppWindows.shared.placeKeymapOverlay(at: corners[sender.tag])
    }

    @objc private func osChanged(_ sender: NSButton) {
        if sender == follow { Preferences.shared.osSource = "keyboard" }
        if sender == forceMac { Preferences.shared.osSource = "mac" }
        if sender == forceWin { Preferences.shared.osSource = "win" }
        KeyboardState.shared.onChange?()
    }

    @objc private func sourceKindChanged() {
        let kinds = ["auto", "folder", "github", "bundled"]
        let index = sourcePopup.indexOfSelectedItem
        guard kinds.indices.contains(index) else { return }
        Preferences.shared.keymapSourceKind = kinds[index]
        saveGitHubFields()
        KeymapSource.shared.restart()
        refreshKeymapSource()
    }

    @objc private func chooseKeymapFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "選択"
        panel.message = "zmk-config リポジトリ（config/BobTail.keymap がある場所）を選んでください"
        if let current = KeymapSource.shared.folderURL {
            panel.directoryURL = current
        }
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Preferences.shared.keymapFolderPath = url.path
            if Preferences.shared.keymapSourceKind == "auto" || Preferences.shared.keymapSourceKind == "bundled" {
                Preferences.shared.keymapSourceKind = "folder"
            }
            KeymapSource.shared.restart()
            self?.refreshKeymapSource()
        }
    }

    @objc private func clearKeymapFolder() {
        Preferences.shared.keymapFolderPath = nil
        KeymapSource.shared.restart()
        refreshKeymapSource()
    }

    @objc private func reloadKeymapSource() {
        saveGitHubFields()
        KeymapSource.shared.reload()
        refreshKeymapSource()
    }

    @objc private func applyGitHubSource() {
        Preferences.shared.keymapSourceKind = "github"
        saveGitHubFields()
        KeymapSource.shared.restart()
        refreshKeymapSource()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        saveGitHubFields()
        if Preferences.shared.keymapSourceKind == "github" {
            KeymapSource.shared.restart()
        }
    }

    private func saveGitHubFields() {
        Preferences.shared.keymapGitHubRepo = githubRepoField.stringValue
        Preferences.shared.keymapGitHubBranch = githubBranchField.stringValue
        Preferences.shared.keymapGitHubPath = githubPathField.stringValue
        Preferences.shared.keymapGitHubToken = githubTokenField.stringValue
    }

    private func refreshKeymapSource() {
        let kind = Preferences.shared.keymapSourceKind
        let kinds = ["auto", "folder", "github", "bundled"]
        sourcePopup.selectItem(at: kinds.firstIndex(of: kind) ?? 0)
        folderBox.isHidden = kind == "github" || kind == "bundled"
        githubBox.isHidden = kind != "github"
        keymapFolderLabel.stringValue = KeymapSource.shared.folderURL?.path ?? "（自動検出なし）"
        keymapSourceStatus.stringValue = "読み込み中: \(KeymapSource.shared.statusText)"
    }

    func pushKeymap() {
        keymapCaption.stringValue = "いまのレイヤー: \(KeyboardState.shared.layerName)（\(KeyboardState.shared.effectiveOS)）"
        overlayBox.state = Preferences.shared.keymapOverlayEnabled ? .on : .off
        refreshKeymapSource()
    }

    private func saveTokens() {
        Preferences.shared.tokens = tokens
        refreshLabels()
        KeyboardState.shared.onChange?()
    }

    private func reload() {
        isReloading = true
        let prefs = Preferences.shared
        tokens = prefs.tokens
        table.reloadData()
        prefixBox.state = prefs.showBatteryPrefix ? .on : .off
        fontSize.doubleValue = prefs.menubarFontSize
        gestureBox.state = prefs.gestureEnabled ? .on : .off
        threshold.doubleValue = prefs.gestureThreshold
        cooldown.doubleValue = prefs.gestureCooldown
        loginBox.state = prefs.launchAtLogin ? .on : .off
        overlayBox.state = prefs.keymapOverlayEnabled ? .on : .off
        clickThroughBox.state = prefs.keymapOverlayClickThrough ? .on : .off
        hideOnBaseBox.state = prefs.keymapOverlayHideOnBase ? .on : .off
        highlightBox.state = prefs.keymapHighlightPressed ? .on : .off
        opacity.doubleValue = 1 - prefs.keymapOverlayOpacity
        overlayScale.doubleValue = prefs.keymapOverlayScale
        follow.state = prefs.osSource == "keyboard" ? .on : .off
        forceMac.state = prefs.osSource == "mac" ? .on : .off
        forceWin.state = prefs.osSource == "win" ? .on : .off
        githubRepoField.stringValue = prefs.keymapGitHubRepo
        githubBranchField.stringValue = prefs.keymapGitHubBranch
        githubPathField.stringValue = prefs.keymapGitHubPath
        githubTokenField.stringValue = prefs.keymapGitHubToken
        switch prefs.separator {
        case " · ": sep.selectItem(at: 1)
        case " | ": sep.selectItem(at: 2)
        case " / ": sep.selectItem(at: 3)
        default: sep.selectItem(at: 0)
        }
        refreshLabels()
        pushKeymap()
        isReloading = false
    }

    private func refreshLabels() {
        preview.stringValue = "プレビュー　" + Preferences.shared.composeMenubar(state: KeyboardState.shared)
        thresholdLabel.stringValue = String(format: "%.0f px", threshold.doubleValue)
        cooldownLabel.stringValue = String(format: "%.2f 秒", cooldown.doubleValue)
        opacityLabel.stringValue = "\(Int((opacity.doubleValue * 100).rounded()))%"
        overlayScaleLabel.stringValue = "\(Int((overlayScale.doubleValue * 100).rounded()))%"
    }
}

final class AppWindows {
    static let shared = AppWindows()
    private var settings: SettingsWindowController?
    private var overlay: KeymapOverlayController?

    func showSettings() {
        if settings == nil { settings = SettingsWindowController() }
        settings?.show()
    }

    /// 起動直後からオーバーレイを用意し、設定を開かなくてもレイヤー追従できるようにする
    func prepareKeymapOverlay() {
        ensureOverlay()
        wakeKeymapOverlay()
    }

    /// 設定を開いたときと同じ activate で WKWebView を起こす
    func wakeKeymapOverlay() {
        ensureOverlay()
        overlay?.wake()
        // 少し遅らせて再同期（WebKit プロセス起動待ち）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.overlay?.wake()
            self?.overlay?.sync()
        }
    }

    func toggleKeymapOverlay() {
        Preferences.shared.keymapOverlayEnabled.toggle()
        syncKeymap()
    }

    func placeKeymapOverlay(at corner: String) {
        ensureOverlay()
        overlay?.place(at: corner)
        overlay?.sync()
    }

    func syncKeymap() {
        settings?.pushKeymap()
        if Preferences.shared.keymapOverlayEnabled {
            ensureOverlay()
        }
        overlay?.sync()
    }

    func pushKeymapPressed() {
        if overlay == nil, Preferences.shared.keymapOverlayEnabled {
            ensureOverlay()
        }
        overlay?.pushPressed()
    }

    private func ensureOverlay() {
        if overlay == nil { overlay = KeymapOverlayController() }
    }
}
