# 0001: +Xから時計回りに増える方位角を使う

- Status: accepted
- Date: 2026-10-18

## 背景

reference mission は `(0, 0), heading 0°` から 100 mm 前進し、右へ 90° 旋回して 50 mm 前進した結果を
`(100, 50), heading 90°` とします。通常の Cartesian plane の正角は counterclockwise であり、そのままでは
「右旋回」と期待値の符号が一致しません。

## 判断

heading `0°` を `+X`、`90°` を `+Y` とし、右旋回で heading を増やします。left / right を command に明記し、
degree の符号へ方向の意味を持たせません。現在は 90° の倍数だけを受理します。

## 影響

- reference mission の文章、command、期待値が同じ規則で表現できます。
- `{:turn, :right, 90}` と `{:turn, :left, 90}` を wire protocol へ移しても意味が曖昧になりません。
- 地理上の bearing や counterclockwise を正とする座標系と接続する場合は変換が必要です。
