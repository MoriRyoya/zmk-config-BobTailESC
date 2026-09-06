# zmk-config-BobTailESC

BobTail / BobTailESC 用の ZMK ファームウェアリポジトリです。
[nakano さんの公式リポジトリ](https://github.com/na-ka-no) を fork して使ってください。

このリポジトリは、**macOS をメインに使いながら Windows も併用する研究者**向けに
キーマップと周辺ツールを組み直したものです。

---

## 中身

| パス | 内容 |
| --- | --- |
| `config/BobTail.keymap` | キーマップ本体 |
| `config/BobTail.json` | Keymap Editor 用の実機配置（エンコーダ空席を含む 43 位置） |
| `config/boards/shields/Test/` | シールド定義（トラックボール・バッテリー等の設定） |
| `docs/keymap.md` | **キーマップの説明書。まずはここを読んでください** |
| `tools/macos/BobTailBar/` | メニューバー常駐アプリ（レイヤー表示・左右バッテリー） |
| `tools/check_keymap.py` | キーマップ編集後の自己チェック |

---

## キーマップの要点

- **英字・Enter・? は単機能**。ホーム列の Mod-tap を廃止し、Shift / Ctrl / Command は専用キー
- **英数 / かなは親指キー**。英数は長押し L⌥、かなは長押し Sym。その左隣が Gesture
- **Tab は Gesture + A**。旧 Tab の位置は Shift。Fn は右下の専用キー
- 数字は左手テンキー。右手はトラックボールに置いたまま数値を打てる
- Space は文字入力を優先し、少し間を置いて 220 ms 保持すると Num。Gesture + Space で Num 固定も可能
- F キーは数字と同一位置（7→F7）
- 左エンコーダは全層で拡大 / 縮小。macOS は Command、Windows は Ctrl のズームショートカット
- AMLは10秒維持し、マウス用5キー以外の押下で解除。BobTailBarにもAMLを表示
- BobTailBarで慣性・速度・応答を調整。四隅リサイズとShift/Commandによる縦横比保持に対応
- **右手だけでカーソル操作が完結する層**。単語移動・行頭行末・文頭文末は専用キー
- **Mac / Windows の切り替え**。⌘ と Ctrl の位置が入れ替わり、
  「行頭」「単語移動」などの意味キーも OS ごとに実体が差し替わる
- **左右のバッテリー残量**を個別に % で確認できる
- **トラックボール + Gesture** で Mission Control やデスクトップ切り替え（変換は本体。アプリ不要）

詳細は [docs/keymap.md](docs/keymap.md) を参照してください。

---

## ファームウェアの焼き方

1. このリポジトリに push すると GitHub Actions がビルドします
2. Actions の成果物（`firmware.zip`）をダウンロードして展開します
3. キーボードの背面のリセットスイッチを 2 回押して `XIAO SENSE` を表示させます
4. `BobTail_L-…uf2` / `BobTail_R-…uf2` をそれぞれ投下します

> **キーマップ・電池測定・AML・スクロールの変更を反映するには、左右とも焼き直してください。**
> うまく動かない場合は先に `settings_reset-…uf2` を投下してからやり直します。

---

## メニューバーアプリ

```bash
cd tools/macos/BobTailBar
./build.sh install
```

インストール後、システム設定で「アクセシビリティ」と「Bluetooth」を許可してください。
詳細は [tools/macos/README.md](tools/macos/README.md) を参照。

---

## キーマップを編集したら

```bash
python3 tools/check_keymap.py
```

キー数の過不足・独自 behavior を含む引数不足・未定義の参照・レイヤー名の衝突を、通知の ON/OFF 両構成で検出します。
安全性の回帰確認は `python3 -m unittest discover -s tools -p 'test_keymap*.py'` で実行できます。

---

## OS 側の推奨設定

| OS | 設定 |
| --- | --- |
| macOS | 入力ソースを **US（ABC）** にする |
| Windows | キーボードレイアウトを **英語キーボード（101/102）** にする。Windows 11 推奨 |

Windows を日本語キーボード（106/109）に設定すると記号の位置がずれます。
