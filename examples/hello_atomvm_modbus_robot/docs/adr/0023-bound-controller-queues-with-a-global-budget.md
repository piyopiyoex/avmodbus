# 0023: Controllerの複数queueをglobal budgetで制限する

## 状態

採用

## 背景

`DisterlProbe.Channel`はstreamごとに8,192 payload bytes / 256 chunksの上限を持つ。Controllerが2個以上の
remote peerへ接続すると上限がpeer数に比例し、32 peersでは262,144 bytes / 8,192 chunksになる。これは事前確保量ではないが、
3台実測のminimum free heap 68,848 bytesより大きく、Controller全体のmemory保護としては不十分である。

peerごとの上限をpeer数で割る方法は、設定変更時に全peer数を事前に知る必要があり、空いている容量を別peerが利用できない。

## 判断

- Controllerの全client adapterが共有する`DisterlProbe.QueueBudget` processを1個起動する。
- 各adapterはwrite全体をqueueする前にpayload bytesとchunk数を原子的に予約する。
- 既定のglobal上限は8,192 bytes / 256 chunksとし、streamごとの同じ上限も維持する。
- ACK、peer session変更、queue-fullによるlocal session reset、adapter終了時に現在量を同期または解放する。
- local adapter processをmonitorし、異常終了時も予約を解放する。
- global上限を超えるwriteはpartial dataを残さず`{:error, :global_queue_full}`を返し、拒否されたstreamだけを新しいsessionへ切り替える。
- `ROBOT_MULTINODE_GLOBAL_MAX_QUEUED_BYTES`と`ROBOT_MULTINODE_GLOBAL_MAX_QUEUED_CHUNKS`をcompile-time設定とする。

## 影響

- peer数を増やしても、Controllerのcarrier queue payload合計は設定したglobal上限を超えない。
- あるpeerのqueueが容量を使用すると、別peerのwriteがglobal上限で拒否されることがある。これはmemoryを保護するfail-fast policyであり、
  peerごとの公平な容量予約ではない。
- 拒否時は該当distribution streamが切り替わり、application retryが必要になる。既存のdurable delivery保証は増えない。
- global budgetはpayload binaryとchunk件数だけを数える。process、mailbox、distribution framing、AVModbus requestを含むVM全体の
  memory上限ではない。
- `QueueBudget`はdistributed Erlang example内の任意機能であり、AVModbus coreとFC-100 wire formatは変更しない。
- host testで32 owner、ACK、session reset、正常終了、異常終了を検証した。3台実機の32+32 trafficではglobal high-water
  906 bytes / 14 chunks、拒否0、settled 0 / 0を確認した。実測条件は
  [検証結果](../worklog/README.md) を正とする。
