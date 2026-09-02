#!/bin/bash
# BobTailBar.app をビルドする。
#   使い方:  ./build.sh          → ./build/BobTailBar.app を作る
#            ./build.sh install  → さらに /Applications へコピーして起動する
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="BobTailBar"
BUILD_DIR="build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"

echo "==> compiling"
RESOURCES="${APP_DIR}/Contents/Resources"
mkdir -p "${RESOURCES}"
# 配列表示はこの .keymap を読んで描く。読み込み先が設定されていないときの
# 内蔵ぶんもこれ。表を別に持たないので、キーマップを直せば表示も必ず追随する。
cp "../../../config/BobTail.keymap" "${RESOURCES}/BobTail.keymap"
# ブラウザで見る用の説明書きも同梱しておく（アプリからは使わない）
cp "../../../docs/keymap.html" "${RESOURCES}/keymap.html"

# アプリアイコン
if [[ -f AppIcon.icns ]]; then
    cp AppIcon.icns "${RESOURCES}/AppIcon.icns"
elif [[ -d AppIcon.iconset ]]; then
    iconutil -c icns AppIcon.iconset -o "${RESOURCES}/AppIcon.icns"
fi
if [[ -f AppIcon.png ]]; then
    cp AppIcon.png "${RESOURCES}/AppIcon.png"
fi

swiftc -O \
    -framework AppKit \
    -framework CoreBluetooth \
    -framework CoreGraphics \
    -framework ServiceManagement \
    -framework IOKit \
    -framework CoreServices \
    -framework Security \
    -o "${MACOS_DIR}/${APP_NAME}" \
    main.swift Preferences.swift KeymapView.swift Windows.swift Gesture.swift KeymapSource.swift

cat > "${APP_DIR}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>BobTailBar</string>
    <key>CFBundleDisplayName</key>     <string>BobTailBar</string>
    <key>CFBundleIdentifier</key>      <string>local.bobtail.menubar</string>
    <key>CFBundleExecutable</key>      <string>BobTailBar</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>12.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>キーボード左右のバッテリー残量を読み取るために使用します。</string>
</dict>
</plist>
PLIST

# 署名が変わると macOS はアクセシビリティと入力監視の許可を捨てる。
# ad-hoc (-) は毎回別の署名になるので、ビルドのたびに許可し直しになり、
# 「BobTailBar を選んでいるときしかレイヤーが切り替わらない」状態に戻る。
# 安定した識別名があるならそちらを使う。
IDENTITY="$(./ensure-signing-identity.sh || echo -)"
echo "==> signing (${IDENTITY})"
codesign --force --deep --sign "${IDENTITY}" "${APP_DIR}"

if [[ "${IDENTITY}" == "-" ]]; then
    cat >&2 <<'WARN'
==> 注意: ad-hoc 署名です。ビルドのたびに署名が変わるため、
    「アクセシビリティ」と「入力監視」の許可が毎回外れます。
    外れている間はレイヤー表示が他アプリで追従しません
    （メニューの「キー監視」が赤くなります）。
    GitHub トークンを Keychain に保存している場合も、同じ理由で
    ビルドのたびに読めなくなり、設定画面には毎回入力し直しになります。

    毎回やり直したくない場合は、キーチェーンアクセスで
    「BobTailBar Local」という名前のコード署名用の自己署名証明書を作ってください。
    ensure-signing-identity.sh がそれを自動で拾います。
WARN
fi

echo "==> built: ${APP_DIR}"

if [[ "${1:-}" == "install" ]]; then
    echo "==> installing to /Applications"
    osascript -e 'quit app "BobTailBar"' 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP_DIR}" /Applications/
    open "/Applications/${APP_NAME}.app"
    echo "==> 「システム設定 → プライバシーとセキュリティ」で次の 2 つを許可してください"
    echo "      ・アクセシビリティ … 通知キーを他アプリに漏らさず受け取る"
    echo "      ・入力監視         … キーボードから直接読む"
    echo "    どちらも無いと、BobTailBar を選んでいるときしかレイヤーが切り替わりません" 
fi
