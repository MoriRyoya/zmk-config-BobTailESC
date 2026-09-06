#!/bin/bash
# BobTailBar 用の codesign 識別子を返す。
# 安定したローカル証明書があればその SHA-1 を、なければ ad-hoc (-) にフォールバックする。
#
# 名前ではなく指紋で指す。同じ common name の証明書が複数のキーチェーンにあると
# codesign は名前を "ambiguous" として拒み、ビルドがそこで止まるため。
# （自己署名の信頼設定はユーザー操作が必要なので、ここでは強制しない）
set -euo pipefail

CERT_NAME="BobTailBar Local"

# find-identity -v の行は `  1) <SHA-1> "<name>"`。信頼されていない証明書は
# -v の時点で落ちるので、ここに出てきたものはそのまま署名に使える。
pick() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n "s/^ *[0-9]*) \([0-9A-F]*\) \"$1.*\"\$/\1/p" | head -1
}

for pattern in "$CERT_NAME" "Apple Development:"; do
    hash="$(pick "$pattern" || true)"
    if [[ -n "$hash" ]]; then
        echo "==> code signing identity: ${pattern} (${hash})" >&2
        echo "$hash"
        exit 0
    fi
done

echo "==> no stable codesign identity; using ad-hoc (-)" >&2
echo "-"
