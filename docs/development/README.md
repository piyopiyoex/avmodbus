# 開発資料

再現可能な検証手順と、今後の判断に必要な結果を置きます。利用方法は
[はじめ方](../getting-started.md)、設計方針は [アーキテクチャ](../architecture.md) と
[ADR](../adr/README.md) を正とします。

## 検証する

- [実機での追加検証](hardware-tests.md) — RS485、workflow、memory probe、firmware download
- [リソース計測](resource-measurements.md) — artifact size と実機 memory の基準値
- [TCP リソース上限の調査](atomvm-tcp-investigation.md) — 確認済み範囲と再評価条件

## リリースする

- [リリース前チェックリスト](release-checklist.md) — 実施状況を含む公開判定
- [リリース手順](../../RELEASE.md) — Hex、tag、GitHub Release の手動操作

## 経緯を確認する

- [開発記録](worklog.md) — 主な milestone と release candidate の検証結果
- [互換性表](../compatibility.md) — 実際に確認した機器、runtime、外部実装

細かな実装履歴や一時的なログは Git の履歴で確認します。同じ結果を複数の資料へ転載せず、
設計判断は ADR、現在の制約は [既知の制約](../limitations.md)、測定値は該当する検証資料へ残します。
