#!/usr/bin/env python3
"""BobTail.keymap の静的チェック。

ZMK のビルドを回さずに、よくある事故を先に潰すためのスクリプト。
  - 各レイヤーのバインディング数が物理キー数 (43) と一致しているか
  - 行ごとのキー数が物理配置 (10 / 12 / 12 / 9) と一致しているか
  - 波括弧 / 山括弧の対応が取れているか
  - キーマップ内で参照している behavior や macro が定義済みか
  - 引数が要る behavior を引数なしで置いていないか

行ごとのチェックが要る理由:
合計だけ見ていると、ある行が 1 個多く隣の行が 1 個少ないケースを見逃す。
実際 Fn 層が [10, 13, 14, 6] のまま合計 43 で通ってしまい、F7 が 7 ではなく
8 の位置に載っていた。行の形まで見ればこの種のズレを push 前に潰せる。

引数チェックが要る理由:
LAYER_INDICATOR を 0 にすると HOLD_GEST が &mo へ展開される。これは
hold-tap の bindings に渡す形で、キーに直接置くとレイヤー番号が抜けた
&mo になり、DTS が次のキーを引数として食う。数だけ見ても気付けない。
"""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

# 物理配置。15 番はエンコーダで、キーマップ上は &none を 1 個置く
ROW_SHAPE = (10, 12, 12, 9)
KEY_COUNT = sum(ROW_SHAPE)
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
    # -P を付けても行の区切りは残るので、行ごとのキー数を数えられる。
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


def split_bindings(line: str) -> list[str]:
    """1 行を & 区切りのバインディングに割る。&kp LC(LEFT) のような引数付きも 1 個。"""
    return [token.strip() for token in re.split(r"(?=&)", line) if token.strip()]


# キーに直接置くとき最低限必要な引数の数。0 のものはここに載せない
MIN_PARAMS = {
    "kp": 1, "mo": 1, "to": 1, "tog": 1, "kt": 1, "sk": 1, "sl": 1,
    "mkp": 1, "msc": 1, "mmv": 1, "bt": 1, "out": 1,
    "mt": 2, "lt": 2,
}


def rows_of(bindings: str) -> list[list[str]]:
    return [
        split_bindings(line)
        for line in (raw.strip() for raw in bindings.splitlines())
        if line
    ]


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
    print(f"物理配置: {' / '.join(str(n) for n in ROW_SHAPE)} = {KEY_COUNT} キー")
    print()

    for index, (name, bindings) in enumerate(blocks):
        rows = rows_of(bindings)
        shape = tuple(len(row) for row in rows)
        count = sum(shape)

        shape_ok = shape == ROW_SHAPE
        flag = "ok " if shape_ok and count == KEY_COUNT else "NG "
        print(f"  [{index:2}] {flag}{name:<12} 計 {count:2} 行 {list(shape)}")

        if count != KEY_COUNT:
            problems.append(f"レイヤー {name} のキー数が {count} 個 (期待値 {KEY_COUNT})")
        elif not shape_ok:
            # 合計が合っていて行の形だけ違う = 隣の行へキーがはみ出している
            problems.append(
                f"レイヤー {name} の行ごとのキー数が {list(shape)} です "
                f"(期待値 {list(ROW_SHAPE)})。合計は合っているので、"
                "どこかの行がはみ出して以降のキー位置がずれています"
            )

        # 引数が足りない behavior を置いていないか
        for position, binding in enumerate(token for row in rows for token in row):
            parts = binding.split()
            need = MIN_PARAMS.get(parts[0].lstrip("&"))
            if need is not None and len(parts) - 1 < need:
                problems.append(
                    f"レイヤー {name} のキー {position} が引数不足です: "
                    f"'{binding}' には引数が {need} 個要ります"
                )

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
