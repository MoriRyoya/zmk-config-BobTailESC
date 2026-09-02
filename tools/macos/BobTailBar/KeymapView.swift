//
//  KeymapView — キーマップを AppKit で直接描く
//
//  以前は docs/keymap.html を WKWebView に載せていた。見た目は作りやすいが、
//  LSUIElement のアプリでパネルを隠すと WebKit がコンテンツプロセスを止めるため、
//  設定ウィンドウを開いてアプリを前面に出すまで JS が動かず、レイヤーを切り替えても
//  配列が変わらなかった。alpha を 0.02 にする、定期的に activate する、readiness を
//  ポーリングする——といった回避策はどれも症状を薄めるだけで、ついでにユーザーの
//  作業中のアプリからフォーカスを奪っていた。
//
//  自前で描けば止まるプロセスが無い。押した瞬間に setNeedsDisplay で更新でき、
//  ライト / ダークにも素直に追従する。
//

import AppKit

// MARK: - 物理配置

/// config/boards/shields/Test/BobTail.dtsi の key_physical_attrs と同じ並び。
/// 列は 100 単位（0…1200）、行は 0…3。15 番はエンコーダでキーは載っていない。
enum KeymapGeometry {
    struct Slot {
        let column: CGFloat
        let row: CGFloat
    }

    static let columns: CGFloat = 13
    static let rows: CGFloat = 4
    static let encoderIndex = 15

    /// ボールは最下段右、41 と 42 のあいだ
    static let ballColumn: CGFloat = 10
    static let ballRow: CGFloat = 3

    static let slots: [Slot] = {
        var out: [Slot] = []
        func add(_ columns: [CGFloat], row: CGFloat) {
            for column in columns { out.append(Slot(column: column, row: row)) }
        }
        add([0, 1, 2, 3, 4], row: 0)
        add([8, 9, 10, 11, 12], row: 0)
        add([0, 1, 2, 3, 4, 5], row: 1)
        add([7, 8, 9, 10, 11, 12], row: 1)
        add([0, 1, 2, 3, 4, 5], row: 2)
        add([7, 8, 9, 10, 11, 12], row: 2)
        add([0, 1, 2, 3, 4, 5], row: 3)
        add([7, 8], row: 3)
        add([12], row: 3)
        return out
    }()

    static let keyCount = slots.count // 43
}

// MARK: - 配色

/// ライト / ダークで別々に持つ。描画時に effectiveAppearance から選ぶ。
struct KeymapPalette {
    let capFill: NSColor
    let capStroke: NSColor
    let capText: NSColor
    let holdText: NSColor
    let transFill: NSColor
    let transText: NSColor
    let noneStroke: NSColor
    let plateText: NSColor
    let plateFaint: NSColor
    let accent: NSColor
    let onAccent: NSColor

    private let tints: [String: NSColor]

    func tint(for kind: String) -> NSColor? { tints[kind] }

    static func resolve(for view: NSView) -> KeymapPalette {
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? .dark : .light
    }

    static let dark = KeymapPalette(
        capFill: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10),
        capStroke: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14),
        capText: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.96),
        holdText: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.52),
        transFill: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.035),
        transText: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22),
        noneStroke: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07),
        plateText: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92),
        plateFaint: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.46),
        accent: NSColor(srgbRed: 0.36, green: 0.66, blue: 1.00, alpha: 1),
        onAccent: NSColor(srgbRed: 0.04, green: 0.07, blue: 0.12, alpha: 1),
        tints: [
            "num": NSColor(srgbRed: 0.36, green: 0.66, blue: 1.00, alpha: 0.20),
            "mod": NSColor(srgbRed: 0.76, green: 0.55, blue: 1.00, alpha: 0.20),
            "layer": NSColor(srgbRed: 1.00, green: 0.71, blue: 0.36, alpha: 0.20),
            "ime": NSColor(srgbRed: 0.36, green: 0.85, blue: 0.68, alpha: 0.20),
        ]
    )

    static let light = KeymapPalette(
        capFill: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92),
        capStroke: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.12),
        capText: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1),
        holdText: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 0.50),
        transFill: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.34),
        transText: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 0.24),
        noneStroke: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.06),
        plateText: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1),
        plateFaint: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 0.55),
        accent: NSColor(srgbRed: 0.00, green: 0.44, blue: 0.94, alpha: 1),
        onAccent: NSColor.white,
        tints: [
            "num": NSColor(srgbRed: 0.00, green: 0.44, blue: 0.94, alpha: 0.13),
            "mod": NSColor(srgbRed: 0.51, green: 0.24, blue: 0.86, alpha: 0.13),
            "layer": NSColor(srgbRed: 0.87, green: 0.47, blue: 0.05, alpha: 0.15),
            "ime": NSColor(srgbRed: 0.00, green: 0.53, blue: 0.40, alpha: 0.14),
        ]
    )
}

// MARK: - テキスト描画

private enum CapText {
    /// 枠に収まるまで少しずつ縮める。「デスクトップ」「左クリック」のような
    /// 長いラベルがはみ出さないようにする。
    static func draw(
        _ text: String,
        in rect: NSRect,
        maxSize: CGFloat,
        minSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) {
        guard !text.isEmpty, rect.width > 1, rect.height > 1 else { return }
        var size = maxSize
        var attributes: [NSAttributedString.Key: Any] = [:]
        var measured = NSSize.zero
        while true {
            attributes = [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color,
            ]
            measured = (text as NSString).size(withAttributes: attributes)
            if measured.width <= rect.width || size <= minSize { break }
            size -= 0.5
        }
        let origin = NSPoint(
            x: rect.midX - measured.width / 2,
            y: rect.midY - measured.height / 2
        )
        (text as NSString).draw(
            in: NSRect(x: origin.x, y: origin.y, width: measured.width, height: measured.height),
            withAttributes: attributes
        )
    }
}

// MARK: - キーマップ本体

/// 43 キーを描く。レイヤーと押下状態を渡すだけで、あとは自前で描画する。
final class KeymapBoardView: NSView {
    var keys: [OverlayKey] = [] {
        didSet { if keys != oldValue { needsDisplay = true } }
    }

    var pressed: Set<Int> = [] {
        didSet { if pressed != oldValue { needsDisplay = true } }
    }

    var showsBall = true

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// 配列の縦横比。パネルのサイズ決めに使う。
    static let aspectRatio: CGFloat = KeymapGeometry.columns / KeymapGeometry.rows

    override func draw(_ dirtyRect: NSRect) {
        let palette = KeymapPalette.resolve(for: self)
        let inset: CGFloat = 4
        let area = bounds.insetBy(dx: inset, dy: inset)
        guard area.width > 8, area.height > 8 else { return }

        // 13 列 4 行がちょうど収まる 1 キーの大きさ
        let unit = min(area.width / KeymapGeometry.columns, area.height / KeymapGeometry.rows)
        let boardWidth = unit * KeymapGeometry.columns
        let boardHeight = unit * KeymapGeometry.rows
        let originX = area.minX + (area.width - boardWidth) / 2
        let originY = area.minY + (area.height - boardHeight) / 2

        let gap = max(1.5, unit * 0.07)
        let radius = max(2, unit * 0.16)

        func capFrame(column: CGFloat, row: CGFloat) -> NSRect {
            NSRect(
                x: originX + column * unit + gap / 2,
                y: originY + row * unit + gap / 2,
                width: unit - gap,
                height: unit - gap
            )
        }

        if showsBall {
            drawBall(in: capFrame(column: KeymapGeometry.ballColumn, row: KeymapGeometry.ballRow),
                     palette: palette)
        }

        for (index, slot) in KeymapGeometry.slots.enumerated() {
            let rect = capFrame(column: slot.column, row: slot.row)
            if index == KeymapGeometry.encoderIndex {
                drawEncoder(in: rect, palette: palette)
                continue
            }
            let key = index < keys.count ? keys[index] : OverlayKey.noneKey
            drawCap(key, in: rect, radius: radius, unit: unit,
                    isPressed: pressed.contains(index), palette: palette)
        }
    }

    private func drawCap(
        _ key: OverlayKey,
        in rect: NSRect,
        radius: CGFloat,
        unit: CGFloat,
        isPressed: Bool,
        palette: KeymapPalette
    ) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        if key.none && key.tap.isEmpty && key.hold.isEmpty {
            palette.noneStroke.setStroke()
            path.lineWidth = 1
            path.stroke()
            return
        }

        if isPressed {
            palette.accent.setFill()
            path.fill()
        } else if key.trans {
            palette.transFill.setFill()
            path.fill()
            palette.noneStroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            palette.capFill.setFill()
            path.fill()
            if let tint = palette.tint(for: key.kind) {
                tint.setFill()
                path.fill()
            }
            palette.capStroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let hasHold = !key.hold.isEmpty
        let tapColor: NSColor
        let holdColor: NSColor
        if isPressed {
            tapColor = palette.onAccent
            holdColor = palette.onAccent.withAlphaComponent(0.72)
        } else if key.trans {
            tapColor = palette.transText
            holdColor = palette.transText
        } else {
            tapColor = palette.capText
            holdColor = palette.holdText
        }

        let padding = unit * 0.08
        let inner = rect.insetBy(dx: padding, dy: padding)

        if hasHold {
            // 上 2/3 がタップ、下 1/3 が長押し
            let tapRect = NSRect(x: inner.minX, y: inner.minY,
                                 width: inner.width, height: inner.height * 0.62)
            let holdRect = NSRect(x: inner.minX, y: inner.minY + inner.height * 0.60,
                                  width: inner.width, height: inner.height * 0.40)
            CapText.draw(key.tap, in: tapRect, maxSize: unit * 0.30, minSize: 6,
                         weight: .semibold, color: tapColor)
            CapText.draw(key.hold, in: holdRect, maxSize: unit * 0.20, minSize: 5.5,
                         weight: .medium, color: holdColor)
        } else {
            CapText.draw(key.tap, in: inner, maxSize: unit * 0.32, minSize: 6,
                         weight: .semibold, color: tapColor)
        }
    }

    private func drawEncoder(in rect: NSRect, palette: KeymapPalette) {
        let side = min(rect.width, rect.height) * 0.72
        let box = NSRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )
        let ring = NSBezierPath(ovalIn: box)
        ring.lineWidth = max(1, side * 0.10)
        palette.noneStroke.setStroke()
        ring.stroke()
    }

    private func drawBall(in rect: NSRect, palette: KeymapPalette) {
        let side = min(rect.width, rect.height) * 1.5
        let box = NSRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )
        let circle = NSBezierPath(ovalIn: box)
        circle.lineWidth = 1
        palette.noneStroke.setStroke()
        let dashes: [CGFloat] = [3, 3]
        circle.setLineDash(dashes, count: 2, phase: 0)
        circle.stroke()
    }
}

// MARK: - HUD の中身（見出し + 配列）

/// パネルに載せる中身。見出しにレイヤー名・OS・電池を出すので、
/// メニューを開かなくても状態が読める。
final class KeymapHUDView: NSView {
    let board = KeymapBoardView()

    /// つかんで動かせる帯の高さ
    static let headerHeight: CGFloat = 30
    /// 右下のサイズ変更グリップ
    static let gripSize: CGFloat = 18

    private var layerTitle = ""
    private var layerBadge = ""
    private var osTitle = ""
    private var batteryText = ""
    private var sourceText = ""

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 300))
        board.translatesAutoresizingMaskIntoConstraints = false
        addSubview(board)
        NSLayoutConstraint.activate([
            board.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            board.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            board.topAnchor.constraint(equalTo: topAnchor, constant: Self.headerHeight),
            board.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(layerTitle: String, badge: String, os: String, left: Int?, right: Int?, source: String) {
        let battery = "L " + (left.map { "\($0)%" } ?? "—") + "   R " + (right.map { "\($0)%" } ?? "—")
        guard layerTitle != self.layerTitle || badge != layerBadge || os != osTitle
            || battery != batteryText || source != sourceText else { return }
        self.layerTitle = layerTitle
        self.layerBadge = badge
        self.osTitle = os
        self.batteryText = battery
        self.sourceText = source
        needsDisplay = true
    }

    /// 帯の上か（クリック透過中でもここだけは掴めるようにする）
    func isInHeader(_ point: NSPoint) -> Bool {
        point.y <= Self.headerHeight
    }

    /// 右下のサイズ変更グリップの上か
    func isInGrip(_ point: NSPoint) -> Bool {
        point.x >= bounds.maxX - Self.gripSize && point.y >= bounds.maxY - Self.gripSize
    }

    // MARK: マウス

    var onDragBegin: ((NSPoint) -> Void)?
    var onDragMove: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var onResizeBegin: ((NSPoint) -> Void)?
    var onResizeMove: ((NSPoint) -> Void)?
    var onResizeEnd: (() -> Void)?

    private enum Grab { case idle, move, resize }
    private var grab = Grab.idle

    /// パネルは非アクティブのままなので、最初のクリックから受け取れるようにする
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight),
                      cursor: .openHand)
        addCursorRect(NSRect(x: bounds.maxX - Self.gripSize, y: bounds.maxY - Self.gripSize,
                             width: Self.gripSize, height: Self.gripSize),
                      cursor: .crosshair)
    }

    private func screenPoint(_ event: NSEvent) -> NSPoint {
        guard let window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if isInGrip(local) {
            grab = .resize
            onResizeBegin?(screenPoint(event))
        } else if isInHeader(local) {
            grab = .move
            onDragBegin?(screenPoint(event))
        } else {
            grab = .idle
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        switch grab {
        case .move: onDragMove?(screenPoint(event))
        case .resize: onResizeMove?(screenPoint(event))
        case .idle: super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch grab {
        case .move: onDragEnd?()
        case .resize: onResizeEnd?()
        case .idle: super.mouseUp(with: event)
        }
        grab = .idle
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = KeymapPalette.resolve(for: self)

        // 見出しの帯
        let header = NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
        let badgeSide: CGFloat = 18
        let badgeRect = NSRect(x: 12, y: (Self.headerHeight - badgeSide) / 2,
                               width: max(badgeSide, 30), height: badgeSide)
        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 5, yRadius: 5)
        palette.accent.withAlphaComponent(0.22).setFill()
        badgePath.fill()
        CapText.draw(layerBadge, in: badgeRect, maxSize: 10, minSize: 7,
                     weight: .bold, color: palette.accent)

        let titleRect = NSRect(x: badgeRect.maxX + 8, y: 0,
                               width: 180, height: Self.headerHeight)
        drawLeft(layerTitle, in: titleRect, size: 12, weight: .semibold, color: palette.plateText)

        let rightText = osTitle + "   " + batteryText
        drawRight(rightText, in: NSRect(x: header.width - 250, y: 0, width: 238, height: Self.headerHeight),
                  size: 11, weight: .medium, color: palette.plateFaint)

        // 帯と配列のあいだの細い区切り
        let line = NSBezierPath(rect: NSRect(x: 10, y: Self.headerHeight - 1,
                                             width: bounds.width - 20, height: 1))
        palette.noneStroke.setFill()
        line.fill()

        drawGrip(palette: palette)
    }

    private func drawGrip(palette: KeymapPalette) {
        let corner = NSPoint(x: bounds.maxX - 6, y: bounds.maxY - 6)
        palette.plateFaint.withAlphaComponent(0.45).setStroke()
        for offset in stride(from: CGFloat(3), through: CGFloat(9), by: 3) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: corner.x - offset, y: corner.y))
            path.line(to: NSPoint(x: corner.x, y: corner.y - offset))
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawLeft(_ text: String, in rect: NSRect, size: CGFloat,
                          weight: NSFont.Weight, color: NSColor) {
        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        let measured = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            in: NSRect(x: rect.minX, y: rect.midY - measured.height / 2,
                       width: min(measured.width, rect.width), height: measured.height),
            withAttributes: attributes
        )
    }

    private func drawRight(_ text: String, in rect: NSRect, size: CGFloat,
                           weight: NSFont.Weight, color: NSColor) {
        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        let measured = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            in: NSRect(x: rect.maxX - measured.width, y: rect.midY - measured.height / 2,
                       width: measured.width, height: measured.height),
            withAttributes: attributes
        )
    }
}
