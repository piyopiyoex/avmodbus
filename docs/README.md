# ドキュメント

AVModbus core の資料は、目的別に次の3つへ分けています。

## 利用者向け

- [Modbus の基礎](modbus-basics.md) — Modbus と RS485 の関係、基本用語
- [はじめ方](getting-started.md) — AVModbus の追加、UART の設定、最初の読み書き
- [実機チュートリアル](../examples/hello_atomvm_modbus/README.md) — XIAO ESP32-C5 と HW-519 を使った通信

## 設計と仕様

- [アーキテクチャ](architecture.md) — コンポーネントの責務と境界
- [開発者ガイド](development.md) — 高度な設定、テスト、相互運用確認
- [動作確認済みの構成](compatibility.md) — 検証した runtime、機器、外部実装
- [既知の制約](limitations.md) — AtomVM と AVModbus の制約
- [ロードマップ](roadmap.md) — 今後の優先事項と対象外
- [設計判断記録](adr/README.md) — 長期的に維持する設計判断

## 検証と保守

- [開発資料一覧](development/README.md) — 実機試験、リソース計測、障害調査、リリース確認

現在の利用方法は利用者向け資料、設計方針はアーキテクチャと ADR、実測値は検証資料を正とします。
日々の細かな変更履歴は文書へ複製せず、Git の履歴で確認します。

## 実験

- [Modbus RTU 上の distributed Erlang](https://github.com/piyopiyoex/avmodbus/tree/v0.1.0/examples/hello_atomvm_modbus_disterl) — custom Function Code `100` を carrier とする実験
- [distributed Erlang 仮想ロボット](https://github.com/piyopiyoex/avmodbus/tree/v0.1.0/examples/hello_atomvm_modbus_robot) — 3台の ESP32-C5 を使う分散 application の実験

実験の設計、ロードマップ、worklog は各 example 内で管理します。これらは AVModbus の public API や
production support の対象ではなく、Hex package にも含めません。

## 更新方針

- 本文は日本語を基本とし、API 名、プロトコル名、正式な技術用語は必要以上に翻訳しません。
- トップレベルの `README.md` は、初めて訪れた利用者向けの簡潔な入口とします。実験の経緯、詳細な測定値、内部設計は正となる資料へ分離し、README からリンクします。
- ファイル名は小文字の kebab-case とします。ディレクトリの入口となる `README.md` は例外です。
- 同じ説明を複数のページへ複製せず、正となるページへリンクします。
- 実測値には日付、環境、設定、結果を添え、確認済みの範囲と一般的な保証を区別します。
- ファイルを移動した場合は、リポジトリ内のリンクと `mix.exs` の ExDoc 設定を更新します。
- 長期的な設計判断を変更する場合は、[ADR の更新方針](adr/README.md#追加と更新)に従います。
