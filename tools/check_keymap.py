#!/usr/bin/env python3
"""BobTail.keymap の静的チェック。

ZMK のビルドを回さずに、よくある事故を先に潰すためのスクリプト。
  - 各レイヤーのバインディング数が物理キー数 (43) と一致しているか
  - 波括弧 / 山括弧の対応が取れているか
  - キーマップ内で参照している behavior や macro が定義済みか
"""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

KEY_COUNT = 43
REPO = Path(__file__).resolve().parent.parent
KEYMAP = REPO / "config" / "BobTail.keymap"


def preprocess(source: str) -> str:
    """自前の #define / #if だけを展開する (#include は落とす)。"""
    stripped = "\n".join(
        line for line in source.splitlines() if not line.lstrip().startswith("#include")
    )
    with tempfile.NamedTemporaryFile("w", suffix=".dts", delete=False) as handle:
        handle.write(stripped)
        temp_path = handle.name

    # Zephyr と同じく assembler-with-cpp で処理する。
    # そうしないと #binding-cells が未知のプリプロセッサ指令として弾かれる。
    try:
        result = subprocess.run(
            ["clang", "-E", "-P", "-x", "assembler-with-cpp", temp_path],
            capture_output=True,
            text=True,
        )
    finally:
        Path(temp_path).unlink(missing_ok=True)

    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        raise SystemExit("プリプロセスに失敗しました")
    return result.stdout


def layer_blocks(text: str) -> list[tuple[str, str]]:
    """keymap ノード内の 各レイヤー名と bindings 本文を取り出す。

    [^{}] を挟むことで、直近に開いたノード名 (= レイヤー名) だけを拾う。
    """
    body = text[text.index("keymap {"):]
    pattern = r"([\w-]+)\s*\{[^{}]*?bindings\s*=\s*<(.*?)>\s*;"
    return [match.groups() for match in re.finditer(pattern, body, re.S)]


def main() -> int:
    source = KEYMAP.read_text()
    text = preprocess(source)

    problems: list[str] = []

    if text.count("{") != text.count("}"):
        problems.append(f"波括弧の数が合いません: {{ = {text.count('{')} / }} = {text.count('}')}")

    blocks = layer_blocks(text)
    if not blocks:
        problems.append("レイヤーを 1 つも検出できませんでした")

    print(f"検出したレイヤー: {len(blocks)}")
    for index, (name, bindings) in enumerate(blocks):
        count = len(re.findall(r"&\w+", bindings))
        flag = "ok " if count == KEY_COUNT else "NG "
        print(f"  [{index:2}] {flag}{name:<12} bindings={count}")
        if count != KEY_COUNT:
            problems.append(f"レイヤー {name} のキー数が {count} 個 (期待値 {KEY_COUNT})")
        # レイヤー名を #define と同じ綴りにすると数値へ置換されて DTS が壊れる
        if name.isdigit():
            problems.append(
                f"レイヤー名が数値 ({name}) に展開されています。"
                "#define したレイヤー名をノード名に使わないでください"
            )

    # 参照しているラベルがすべて定義されているか
    defined = set(re.findall(r"^\s*(\w+)\s*:\s*\w+\s*\{", text, re.M))
    builtin = {
        "kp", "mo", "to", "tog", "kt", "trans", "none", "bt", "out", "mkp", "msc", "mmv",
        "bootloader", "sys_reset", "caps_word", "key_repeat", "sk", "sl", "mt", "lt",
        "inc_dec_kp", "studio_unlock", "soft_off",
        "macro_press", "macro_release", "macro_tap", "macro_pause_for_release",
        "macro_param_1to1", "macro_param_1to2", "macro_param_2to1", "macro_param_2to2",
        "macro_wait_time", "macro_tap_time",
    }
    for label in sorted(set(re.findall(r"&(\w+)", text))):
        if label not in defined and label not in builtin:
            problems.append(f"未定義の behavior を参照しています: &{label}")

    print()
    if problems:
        for problem in problems:
            print(f"NG: {problem}")
        return 1

    print("問題は見つかりませんでした")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
