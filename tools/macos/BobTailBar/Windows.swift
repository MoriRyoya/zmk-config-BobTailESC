import AppKit

// MARK: - オーバーレイのパネル

/// フォーカスを奪わないパネル。.nonactivatingPanel なので、前面に出しても
/// ユーザーが打っているアプリはアクティブなままになる。
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 角丸とすりガラスの下地。中身は KeymapHUDView が描く。
private final class HUDBackgroundView: NSVisualEffectView {
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        if #available(macOS 10.15, *) {
            layer?.cornerCurve = .continuous
        }
    }
}

// MARK: - キーマップ重ね表示

/// レイヤーを押しているあいだ、その配列を画面に重ねる。
///
/// 描画は KeymapHUDView（AppKit）。WKWebView をやめたので、
/// 設定ウィンドウを開かなくても押した瞬間に更新される。
final class KeymapOverlayController: NSWindowController {
    private let hud = KeymapHUDView()
    private let panel: HUDPanel
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var dragOrigin: NSPoint?
    private var dragStartFrame: NSRect?
    private var resizeOrigin: NSPoint?
    private var resizeStartSize: NSSize?

    private var contentSize: NSSize { Preferences.shared.keymapOverlayPixelSize }

    init() {
        let size = Preferences.shared.keymapOverlayPixelSize
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isExcludedFromWindowsMenu = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true

        let background = HUDBackgroundView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        hud.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hud.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hud.topAnchor.constraint(equalTo: background.topAnchor),
            hud.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        self.panel = panel

        super.init(window: panel)

        place(at: Preferences.shared.keymapOverlayCorner)
        applyStyle()
        startMouseMonitor()

        hud.onDragBegin = { [weak self] point in self?.beginDrag(at: point) }
        hud.onDragMove = { [weak self] point in self?.continueDrag(to: point) }
        hud.onDragEnd = { [weak self] in self?.endDrag() }
        hud.onResizeBegin = { [weak self] point in self?.beginResize(at: point) }
        hud.onResizeMove = { [weak self] point in self?.continueResize(to: point) }
        hud.onResizeEnd = { [weak self] in self?.endResize() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(prefsChanged), name: Preferences.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateChanged), name: KeyboardState.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(pressedChanged), name: KeyboardState.pressedDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sourceChanged), name: KeymapSource.didChange, object: nil)

        sync()
    }

    deinit {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 状態の反映

    func sync() {
        let prefs = Preferences.shared
        let state = KeyboardState.shared
        let holdingLayer = state.layerId != "base"
        let show = prefs.keymapOverlayEnabled && (!prefs.keymapOverlayHideOnBase || holdingLayer)

        pushState()
        applyStyle()

        guard show else {
            panel.orderOut(nil)
            return
        }
        panel.orderFrontRegardless()
    }

    /// レイヤーと配列を描画側へ渡す
    func pushState() {
        let state = KeyboardState.shared
        hud.board.keys = KeymapLayers.keys(layerId: state.layerId, os: state.effectiveOS)
        hud.update(
            layerTitle: KeymapLayers.title(layerId: state.layerId),
            badge: state.layerBadge,
            os: state.effectiveOS,
            left: state.leftBattery,
            right: state.rightBattery,
            source: KeymapSource.shared.statusText,
            warning: state.globalTracking ? "" : "⚠︎ 他アプリでは追従しません — メニューから許可してください"
        )
        pushPressed()
    }

    func pushPressed() {
        guard Preferences.shared.keymapHighlightPressed else {
            hud.board.pressed = []
            return
        }
        hud.board.pressed = Set(KeyboardState.shared.pressedIndices)
    }

    /// WKWebView 時代の名残。ネイティブ描画なので起こす必要はない。
    func wake() {
        sync()
    }

    // MARK: 見た目と配置

    private func applyStyle() {
        panel.alphaValue = CGFloat(Preferences.shared.keymapOverlayOpacity)
    }

    func place(at corner: String) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = contentSize
        let margin: CGFloat = 16
        let origin: NSPoint
        switch corner {
        case "bottomLeft":
            origin = NSPoint(x: visible.minX + margin, y: visible.minY + margin)
        case "topLeft":
            origin = NSPoint(x: visible.minX + margin, y: visible.maxY - size.height - margin)
        case "topRight":
            origin = NSPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin)
        default:
            origin = NSPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func applyStoredSize() {
        var frame = panel.frame
        let size = contentSize
        guard frame.size != size else { return }
        // 左上を固定したまま大きさだけ変える
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    // MARK: 通知

    @objc private func prefsChanged() {
        applyStoredSize()
        sync()
    }

    @objc private func stateChanged() {
        sync()
    }

    @objc private func pressedChanged() {
        pushPressed()
    }

    @objc private func sourceChanged() {
        pushState()
    }

    // MARK: マウス（クリック透過と、帯 / グリップの掴み）

    /// クリック透過を入れていると、そのままでは動かすことも大きさを変えることも
    /// できない。ポインタが帯かグリップの上にあるときだけ透過を切る。
    private func startMouseMonitor() {
        // 透過している間はイベントが下のアプリへ抜けるのでグローバル監視で拾う。
        // 帯の上に来て透過を切ったあとは、こちらにイベントが来るのでローカル監視が要る。
        // 片方だけだと、一度帯に触れたあと透過に戻れなくなる。
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] _ in
            self?.updateClickThrough()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] event in
            self?.updateClickThrough()
            return event
        }
        updateClickThrough()
    }

    private func updateClickThrough() {
        guard Preferences.shared.keymapOverlayClickThrough else {
            panel.ignoresMouseEvents = false
            return
        }
        // 掴んでいる最中に透過へ戻すと、ドラッグが途中で切れる
        if dragOrigin != nil || resizeOrigin != nil {
            panel.ignoresMouseEvents = false
            return
        }
        guard panel.isVisible else {
            panel.ignoresMouseEvents = true
            return
        }
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        guard frame.contains(mouse) else {
            panel.ignoresMouseEvents = true
            return
        }
        // パネル座標（左下原点）→ HUD 座標（左上原点）
        let local = NSPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
        let grabbable = hud.isInHeader(local) || hud.isInGrip(local)
        panel.ignoresMouseEvents = !grabbable
    }

    // MARK: ドラッグで移動 / 右下で大きさ変更

    private func beginDrag(at screenPoint: NSPoint) {
        dragOrigin = screenPoint
        dragStartFrame = panel.frame
    }

    private func continueDrag(to screenPoint: NSPoint) {
        guard let dragOrigin, let dragStartFrame else { return }
        var frame = dragStartFrame
        frame.origin.x += screenPoint.x - dragOrigin.x
        frame.origin.y += screenPoint.y - dragOrigin.y
        panel.setFrameOrigin(frame.origin)
    }

    private func endDrag() {
        dragOrigin = nil
        dragStartFrame = nil
    }

    private func beginResize(at screenPoint: NSPoint) {
        resizeOrigin = screenPoint
        resizeStartSize = panel.frame.size
    }

    private func continueResize(to screenPoint: NSPoint) {
        guard let resizeOrigin, let resizeStartSize else { return }
        let width = resizeStartSize.width + (screenPoint.x - resizeOrigin.x)
        let height = resizeStartSize.height - (screenPoint.y - resizeOrigin.y)
        let clamped = NSSize(
            width: min(1400, max(420, width.rounded())),
            height: min(900, max(180, height.rounded()))
        )
        var frame = panel.frame
        frame.origin.y = frame.maxY - clamped.height
        frame.size = clamped
        panel.setFrame(frame, display: true)
    }

    private func endResize() {
        guard resizeOrigin != nil else { return }
        resizeOrigin = nil
        resizeStartSize = nil
        Preferences.shared.keymapOverlayPixelSize = panel.frame.size
    }
}

/// スクロールの中身は上から積みたいので反転させる
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
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
    private let keymapPreview = KeymapBoardView()
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
        window.minSize = NSSize(width: 560, height: 420)
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

        // 設定しながら、いまのレイヤーの配列をそのまま確認できるようにする
        keymapPreview.translatesAutoresizingMaskIntoConstraints = false
        keymapPreview.wantsLayer = true
        keymapPreview.layer?.cornerRadius = 10
        keymapPreview.layer?.masksToBounds = true
        NSLayoutConstraint.activate([
            keymapPreview.heightAnchor.constraint(
                equalTo: keymapPreview.widthAnchor,
                multiplier: 1 / KeymapBoardView.aspectRatio),
        ])

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
        folderBox.alignment = NSLayoutConstraint.Attribute.leading
        folderBox.spacing = 8
        stretch([keymapFolderLabel, folderHint], to: folderBox)

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
            field.lineBreakMode = .byTruncatingTail
            // 幅は行に合わせて伸ばす。固定幅だとウィンドウを狭めたときに
            // はみ出して、右へずれたように見える
            field.translatesAutoresizingMaskIntoConstraints = false
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        }
        let fetch = NSButton(title: "GitHub から読み込む", target: self, action: #selector(applyGitHubSource))
        let githubHint = NSTextField(wrappingLabelWithString: "公開リポジトリはトークン不要です。非公開は GitHub の Fine-grained token（Contents: Read）を入れて API で読みます。ブランチの初期値は feature/researcher-keymap です。約 20 秒ごとに取り込みます。")
        githubHint.textColor = .secondaryLabelColor
        let githubRows: [NSView] = [
            labeled("リポジトリ", githubRepoField),
            labeled("ブランチ", githubBranchField),
            labeled("ファイル", githubPathField),
            labeled("トークン", githubTokenField),
        ]
        githubBox.setViews(githubRows + [fetch, githubHint], in: .leading)
        githubBox.orientation = NSUserInterfaceLayoutOrientation.vertical
        githubBox.alignment = NSLayoutConstraint.Attribute.leading
        githubBox.spacing = 8
        stretch(githubRows, to: githubBox)
        stretch([githubHint], to: githubBox)

        let stack = NSStackView(views: [
            hint,
            keymapCaption,
            keymapPreview,
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
            sourceRow,
            folderBox,
            githubBox,
            keymapSourceStatus,
        ])
        stack.orientation = NSUserInterfaceLayoutOrientation.vertical
        stack.alignment = NSLayoutConstraint.Attribute.leading
        stack.spacing = 10
        opacity.widthAnchor.constraint(equalToConstant: 220).isActive = true
        overlayScale.widthAnchor.constraint(equalToConstant: 220).isActive = true
        stretch([hint, keymapPreview, overlayHint, githubBox, folderBox, keymapSourceStatus],
                to: stack)
        return scrollable(stack)
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

    /// ラベルの幅を揃える。これが無いと「リポジトリ」「ブランチ」「ファイル」
    /// でラベル幅が違うぶんだけ入力欄の左端がバラつき、右へずれて見える。
    private static let formLabelWidth: CGFloat = 84

    private func labeled(_ title: String, _ view: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: Self.formLabelWidth).isActive = true

        let row = NSStackView(views: [label, view])
        row.orientation = NSUserInterfaceLayoutOrientation.horizontal
        row.alignment = NSLayoutConstraint.Attribute.centerY
        row.spacing = 10
        return row
    }

    /// 縦スクロールできる台紙。ウィンドウを小さくしても中身が切れず、
    /// 横は常にウィンドウ幅にそろう。
    private func scrollable(_ content: NSView) -> NSView {
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = document
        scroll.autoresizingMask = [.width, .height]
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    /// 行をタブの幅いっぱいに広げる。入力欄が伸びてラベルの位置が固定される。
    private func stretch(_ rows: [NSView], to stack: NSStackView) {
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
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
            width: (Preferences.overlayBaseSize.width * scale).rounded(),
            height: (Preferences.overlayBaseSize.height * scale).rounded()
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
        let state = KeyboardState.shared
        keymapCaption.stringValue = "いまのレイヤー: \(state.layerName)（\(state.effectiveOS)）"
        keymapPreview.keys = KeymapLayers.keys(layerId: state.layerId, os: state.effectiveOS)
        keymapPreview.pressed = Preferences.shared.keymapHighlightPressed
            ? Set(state.pressedIndices) : []
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

    /// 起動直後にオーバーレイを作る。ネイティブ描画なので、これだけで
    /// 設定を開かなくてもレイヤーに追従する。
    func prepareKeymapOverlay() {
        ensureOverlay()
        overlay?.sync()
    }

    func wakeKeymapOverlay() {
        ensureOverlay()
        overlay?.sync()
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
        settings?.pushKeymap()
    }

    private func ensureOverlay() {
        if overlay == nil { overlay = KeymapOverlayController() }
    }
}
