# 256+256 flow-controlled long run — 2026-10-20

## 目的

application ACK / in-flight window 1を維持したまま、既存の64+64 profileを256+256 messagesへ延長する。10分以上の連続trafficで
delivery、fairness、transaction failure、queue high-water、Controller heapの推移を測定する。

## 変更

concurrent traffic probeの明示的上限を64から256 messages / roleへ広げた。上限は残し、payload上限128 bytes、roleごとの
in-flight window 1、ACK timeoutとrun timeoutは維持する。host testでは256 messagesをACKしながら完了する境界を追加し、61 testが
成功した。

## 実機条件

- 3 × Seeed Studio XIAO ESP32-C5
- shared two-wire RS485、115,200 baud
- FC-100 chunk payload 96 bytes、poll interval 20 ms
- AtomVM v0.7.0-beta.0 と既存multi-connection local patch
- Drive / Sensors各256 messages、64-byte application payload
- producer interval 500 ms、application ACK window 1
- run timeout 1,200,000 ms、settled snapshot 30,000 ms
- traffic ACK timeout 90,000 ms、retry 1

firmware sizeはDrive 254,696 bytes、Sensors 254,668 bytes、Controller 257,632 bytesだった。run IDは`1754972612`である。

## Application result

| Metric | Drive | Sensors |
| --- | ---: | ---: |
| expected / received | 256 / 256 | 256 / 256 |
| missing / duplicates | 0 / 0 | 0 / 0 |
| out-of-order / invalid | 0 / 0 | 0 / 0 |
| duration | 624,986 ms | 625,014 ms |
| sample span | 621,205 ms | 621,251 ms |
| throughput | 409 milli-msg/s | 409 milli-msg/s |
| max interarrival | 4,434 ms | 4,427 ms |

run全体は627,792 ms、active overlapは623,957 ms、start skewは1,057 ms、completion skewは1,029 ms、delivery ratio gapは0‰だった。
queue-full、application ACK timeout、carrier session change、distribution reconnectは発生しなかった。

## Transaction、queue、memory

| Phase | Role | Success / failure | Queue | High-water | Free heap | Minimum free heap |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| before | Drive | 0 / 0 | 0 bytes / 0 chunks | 0 bytes / 0 chunks | 89,608 | 86,368 |
| before | Sensors | 0 / 0 | 0 bytes / 0 chunks | 0 bytes / 0 chunks | 89,076 | 86,368 |
| after | Drive | 1,551 / 2 | 131 bytes / 2 chunks | 279 bytes / 4 chunks | 85,084 | 70,736 |
| after | Sensors | 1,551 / 2 | 0 bytes / 0 chunks | 162 bytes / 2 chunks | 84,476 | 70,736 |
| settled | Drive | 1,636 / 2 | 0 bytes / 0 chunks | 279 bytes / 4 chunks | 85,896 | 70,736 |
| settled | Sensors | 1,637 / 2 | 0 bytes / 0 chunks | 162 bytes / 2 chunks | 85,352 | 70,736 |

開始直後にUnit 1 / 2で各2回の約2秒transaction timeoutが発生したが、retry後は増えずapplication deliveryへ影響しなかった。
完了直後にDrive側だけ131 bytes / 2 chunksが残っていたが、30秒後は両queueとも0だった。

free heapは開始時から約4.5 KB低い85 KB台でsettleし、minimum watermarkは70,736 bytesだった。minimumは履歴値のため回復しない。
largest free blockは開始時69,632 bytes、完了後とsettled時は65,536 bytesだった。単一runではOOM、継続的なheap減少、session resetを
観測しなかったが、複数runや数時間の安定性を保証しない。

## 結論

ACK window 1の構成は、同じ500 ms producer設定で256+256 messagesを10分以上完全配送し、queueを既定8,192-byte上限より十分低く
保った。以前のflow-controlなし64+64 runで起きたremote queue saturationは再現しなかった。

この結果は1回のdiagnostic runである。Controllerで取得するmetricsはController側adapterだけを表し、remote VM全体やremote outgoing
queueの周期的snapshotではない。次は物理的なRS485切断・再接続と、異なるfailure中のmemory behaviorを分けて検証する。
