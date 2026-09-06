# 左右のバッテリー表示と測定

BobTailBar は接続中の BobTail の Battery Service を読み、右の中央側と左の子機を別々に表示します。取得前・切断後・読み取り失敗時は `—` です。マウスなど他の Bluetooth 機器の残量で補完しません。

左右の Battery Level はどちらも UUID `2A19` です。UUID を辞書キーにすると両者が上書きされるため、アプリでは characteristic インスタンス単位で保持します。左右は取得順で推測せず、Presentation Format (`2904`) の `main` を右、`auxiliary` を左と識別します。ZMK の User Description (`2901`) の `Peripheral 0` でも左を識別します。値と記述子のどちらが先に届いても表示先は変わりません。

## ファームウェアで修正した点

- 左も `CONFIG_ZMK_BATTERY_REPORTING_FETCH_MODE_STATE_OF_CHARGE=y` を使います。従来の `LITHIUM_VOLTAGE` は `SENSOR_CHAN_VOLTAGE` を要求しますが、XIAO のドライバーは `SENSOR_CHAN_GAUGE_VOLTAGE` / `SENSOR_CHAN_GAUGE_STATE_OF_CHARGE` に対応しており、従来設定では測定が `-ENOTSUP` になっていました。
- 使用中の ZMK fork は、電圧分圧を補正した**電池そのものの電圧**に対して 1.95–2.35 V を 0–100% とする換算を使っています。通常の LiPo の電圧範囲と合わず、残量が満充電へ偏ります。本リポジトリの `pmw3610/src/battery_percentage.c` で標準 ZMK と同じ 3.45–4.20 V の近似に置き換えています。
- `pmw3610/CMakeLists.txt` が `--wrap=lithium_ion_mv_to_pct` をリンクに追加し、ADC ドライバーからの呼び出しだけを独立した換算関数へ向けます。ダウンロードした ZMK のファイルは変更しません。この設定は電池報告と State of Charge 取得が有効なビルドに適用されます。

左右ともファームウェアをビルドして書き換える必要があります。アプリの更新だけでは電圧の換算式は変わりません。

残量は電圧からの推定で、充電中・負荷・電池の劣化によって変わります。ZMK の Battery Level には測定時刻や左子機の接続状態が含まれないため、BobTailBar だけで中継された左の値の鮮度や実容量を保証することはできません。

## 確認方法

```sh
python3 -m unittest discover -s tools -p 'test_battery_percentage.py' -v
```

換算の代表点・全 `int16_t` 範囲での単調性・0–100% 範囲をネイティブ C で確認します。Linux では旧関数を残した別コンパイル単位からの呼び出しが GNU `--wrap` で新関数に向くことも実行検証します。macOS の Apple linker にはこのオプションがないため、リンク検証だけを明示的にスキップします。

BobTailBar の `BatteryReadingsTests.swift` は、同一 UUID の左右・48 通りのコールバック順・切断時の破棄・不正値と失敗した読み取り・無関係な機器の除外を確認します。

## 実装の一次資料

- [使用 fork の XIAO BLE 電池ノード](https://github.com/na-ka-no/zmk/blob/for-cool642tb_mini/app/boards/seeeduino_xiao_ble.overlay): ADC 7、分圧比 `1510000 / 510000`。
- [使用 fork の ADC ドライバー](https://github.com/na-ka-no/zmk/blob/for-cool642tb_mini/app/module/drivers/sensor/battery/battery_voltage_divider.c): 分圧補正後の電圧と対応する sensor channel。
- [使用 fork のバッテリー取得](https://github.com/na-ka-no/zmk/blob/for-cool642tb_mini/app/src/battery.c): 取得モード別の sensor channel。
- [使用 fork の旧換算](https://github.com/na-ka-no/zmk/blob/for-cool642tb_mini/app/module/drivers/sensor/battery/battery_common.c)、[標準 ZMK の換算](https://github.com/zmkfirmware/zmk/blob/main/app/module/drivers/sensor/battery/battery_common.c)。
- [ZMK の左右中継サービス](https://github.com/na-ka-no/zmk/blob/for-cool642tb_mini/app/src/split/bluetooth/central_bas_proxy.c)、[Zephyr の標準 Battery Service](https://github.com/zmkfirmware/zephyr/blob/v3.5.0%2Bzmk-fixes/subsys/bluetooth/services/bas.c): 左右の記述子。
- [GNU ld の `--wrap` 仕様](https://sourceware.org/binutils/docs/ld/Options.html): 別コンパイル単位の未解決参照を `__wrap_` 関数に置き換える。
