#!/bin/bash
# BobTailBar 用の codesign 識別名を返す。
# 安定したローカル証明書があればそれを、なければ ad-hoc (-) にフォールバックする。
# （自己署名の信頼設定はユーザー操作が必要なので、ここでは強制しない）
set -euo pipefail

CERT_NAME="BobTailBar Local"
KEYCHAIN="${HOME}/Library/Keychains/bobtail-codesign.keychain-db"

if [[ -f "$KEYCHAIN" ]] && security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "$CERT_NAME"
    exit 0
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "$CERT_NAME"
    exit 0
fi

# Apple Development などがあればそれを使う（Team ID 付きで TCC が安定しやすい）
if identity="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)" \
    && [[ -n "$identity" ]]; then
    echo "$identity"
    exit 0
fi

echo "==> no stable codesign identity; using ad-hoc (-)" >&2
echo "-"
