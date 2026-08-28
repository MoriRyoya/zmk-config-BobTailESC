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
        let webView = WKWebView(frame: .zero, configuration: config)
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
        load()
    }

    func pushState() {
        guard ready else { return }
        let state = KeyboardState.shared
        let script = """
        window.setBobTailAppearance && window.setBobTailAppearance('\(mode.rawValue)');
        window.setBobTailState && window.setBobTailState('\(state.layerId)', '\(state.effectiveOS)', \(Self.pressedJS));
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func pushPressed() {
        guard ready else { return }
        webView.evaluateJavaScript(
            "window.setBobTailPressed && window.setBobTailPressed(\(Self.pressedJS));",
            completionHandler: nil
        )
    }

    private static var pressedJS: String {
        guard Preferences.shared.keymapHighlightPressed else { return "[]" }
        let ids = KeyboardState.shared.pressedIndices.map(String.init).joined(separator: ",")
        return "[\(ids)]"
    }

    private func load() {
        guard let file = KeymapHTML.url else { return }
        var url = file
        if var parts = URLComponents(url: file, resolvingAgainstBaseURL: false) {
            parts.fragment = mode.rawValue
            url = parts.url ?? file
        }
        webView.loadFileURL(url, allowingReadAccessTo: file.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        pushState()
        onReady?()
    }
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
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
        let pill = bounds.insetBy(dx: 10, dy: 3)
        NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
        let grip = NSRect(x: bounds.midX - 16, y: bounds.maxY - 9, width: 32, height: 3)
        NSColor.white.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
        let text = title as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88),
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2 - 1),
            withAttributes: attrs
        )
    }
}

final class KeymapOverlayController: NSWindowController {
    static let baseContentSize = NSSize(width: 720, height: 430)
    static let handleHeight: CGFloat = 30

    private let pane = KeymapPane(mode: .hud)
    private let handleView = OverlayDragHandle()
    private let contentPanel: HUDPanel

    private var contentSize: NSSize {
        let scale = CGFloat(Preferences.shared.keymapOverlayScale)
        return NSSize(
            width: (Self.baseContentSize.width * scale).rounded(),
            height: (Self.baseContentSize.height * scale).rounded()
        )
    }

    init() {
        let size = NSSize(
            width: (Self.baseContentSize.width * CGFloat(Preferences.shared.keymapOverlayScale)).rounded(),
            height: (Self.baseContentSize.height * CGFloat(Preferences.shared.keymapOverlayScale)).rounded()
        )
        let handle = Self.makePanel(size: NSSize(width: size.width, height: Self.handleHeight))
        handle.setFrameAutosaveName("BobTailKeymapHandle4")
        handle.isMovableByWindowBackground = true
        handle.ignoresMouseEvents = false
        handle.contentView = handleView

        let content = Self.makePanel(size: size)
        content.ignoresMouseEvents = true
        content.contentView = pane.webView
        self.contentPanel = content

        super.init(window: handle)
        handle.addChildWindow(content, ordered: .below)
        pane.onReady = { [weak self] in self?.sync() }
        hide()
        place(at: Preferences.shared.keymapOverlayCorner)
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: Preferences.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleMoved), name: NSWindow.didMoveNotification, object: handle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func sync() {
        let prefs = Preferences.shared
        let holdingLayer = KeyboardState.shared.layerId != "base"
        let show = prefs.keymapOverlayEnabled && (!prefs.keymapOverlayHideOnBase || holdingLayer)
        guard show else {
            hide()
            return
        }
        applyStyle()
        layoutChild()
        window?.orderFrontRegardless()
        contentPanel.orderFrontRegardless()
        pane.pushState()
        handleView.title = "キーマップ · \(KeyboardState.shared.layerBadge)（ドラッグで移動）"
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
        handleView.title = "キーマップ · \(KeyboardState.shared.layerBadge)（ドラッグで移動）"
    }

    func pushPressed() {
        pane.pushPressed()
    }

    @objc private func prefsChanged() { sync() }

    @objc private func handleMoved() { layoutChild() }

    private func hide() {
        contentPanel.ignoresMouseEvents = true
        contentPanel.alphaValue = 0
        contentPanel.orderOut(nil)
        window?.alphaValue = 0
        window?.orderOut(nil)
    }

    private func applyStyle() {
        let prefs = Preferences.shared
        let alpha = CGFloat(prefs.keymapOverlayOpacity)
        window?.alphaValue = max(alpha, 0.55)
        window?.ignoresMouseEvents = false
        contentPanel.alphaValue = alpha
        contentPanel.ignoresMouseEvents = prefs.keymapOverlayClickThrough
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
    }

    private static func makePanel(size: NSSize) -> HUDPanel {
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true
        panel.hidesOnDeactivate = false
        return panel
    }
}

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
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
    private var tokens: [MenuBarToken] = []
    private var isReloading = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BobTailBar 設定"
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.setFrameAutosaveName("BobTailSettings3")
        super.init(window: window)
        tokens = Preferences.shared.tokens
        window.contentView = build()
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

        let overlayHint = NSTextField(wrappingLabelWithString: "位置はボタンか、画面上の「キーマップ」バーをドラッグして変えられます。バーはクリック透過中でも掴めます。")
        overlayHint.textColor = .secondaryLabelColor

        keymapCaption.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)

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
        prefs.keymapOverlayScale = overlayScale.doubleValue
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

    func pushKeymap() {
        keymapCaption.stringValue = "いまのレイヤー: \(KeyboardState.shared.layerName)（\(KeyboardState.shared.effectiveOS)）"
        overlayBox.state = Preferences.shared.keymapOverlayEnabled ? .on : .off
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
        overlay?.pushPressed()
    }

    private func ensureOverlay() {
        if overlay == nil { overlay = KeymapOverlayController() }
    }
}
