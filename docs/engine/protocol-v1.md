# Engine Protocol v1

`Engine Protocol v1` 定义 shell 与 `island-hostd` 之间的稳定 wire contract。目标不是直接替代 `codex app-server` 协议，而是在 host daemon 与各平台 shell 之间提供一层更薄、更稳定、可鉴权的 websocket/json 消息面。

## 设计边界

- hostd 对上游 `codex app-server` 仍走 stdio JSON-RPC。
- shell 只需要理解 engine protocol，不直接理解 host 侧进程监督、token 校验或 app-server 生命周期细节。
- 所有消息都允许包在 `ProtocolEnvelope<T>` 中，通过上层 websocket message id 做 request/response 关联。
- 协议版本字段固定为 `v1`；未来破坏性变更通过 `v2` 新增，不在 `v1` 上做 silent drift。

## v1 覆盖的契约

### Host health

`HostHealthSnapshot` 负责冻结 host 的对外健康视图，至少包含：

- daemon 协议版本、daemon 自身版本、host identity、平台信息
- 当前 `app-server` 生命周期状态
- 最近错误、最近退出码、restart 次数
- shell 可以依赖的 capability mask

### Pairing

`PairingSession` 与 `PairedDeviceRecord` 分离：

- `PairingSession` 表示短生命周期的配对窗口，例如 pairing code、过期时间、当前状态
- `PairedDeviceRecord` 表示已经持久化的被授权设备
- `AuthToken` 表示配对完成后下发给 shell 的 bearer token 元数据

### Websocket command/event

v1 的 client command 最小集合：

- `hello`
- `get_snapshot`
- `pair_start`
- `pair_confirm`
- `pair_revoke`
- `app_server_request`
- `app_server_interrupt`

v1 的 server event 最小集合：

- `hello_ack`
- `snapshot`
- `host_health_changed`
- `pairing_started`
- `pairing_completed`
- `pairing_revoked`
- `app_server_event`
- `app_server_response`
- `error`

### Error contract

`ProtocolError` 统一承载：

- 稳定错误码 `ErrorCode`
- 人类可读 message
- 可选 `retryable`
- 可选 JSON `details`

这样 shell 可以用稳定 code 做状态机处理，同时仍保留足够的诊断上下文。

## 与 `codex app-server` 的关系

`app_server_request` / `app_server_response` / `app_server_event` 故意保留原始 JSON payload，而不是在 v1 里重新建模整个 app-server 面。这让 hostd 可以先稳定 bridge 行为，再逐步把 shell 真正需要的高层状态收敛到更窄的 engine snapshot 上。

## 当前落地位置

- Rust 类型定义：`engine/crates/island-proto/src/lib.rs`
- 这份文档：`docs/engine/protocol-v1.md`

## 已锁住的兼容性

`island-proto` 当前单测覆盖了：

- command 的稳定 `type` tag
- snapshot event 的 round-trip
- 任意 app-server JSON 参数透传
- error 可选字段省略行为
- envelope 对 payload 形状不做额外改写

## 后续实现顺序

1. `codex-island-27h.4.2` 让 `island-hostd` 真正实现 app-server bridge，并发出这里定义的 `ServerEvent`
2. `codex-island-27h.4.3` 基于 `PairingSession` / `PairedDeviceRecord` / `AuthToken` 做持久化与 token 校验
3. `codex-island-27h.5.1` 在 `island-core` 上消费这些 snapshot / event，形成统一客户端状态机
