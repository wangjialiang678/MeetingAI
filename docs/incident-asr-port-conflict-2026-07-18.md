---
title: ASR 端口冲突事故复盘与预防（与 SpeakLow 撞 18089）
date: 2026-07-18
status: active
audience: ai
tags: [incident, asr-bridge, port-conflict, troubleshooting]
---

# ASR 端口冲突事故复盘与预防（2026-07-18）

> 现象：App 启动后无限循环 `[系统] ASR 连接中断，1 秒后重连（1/3）… ASR 正在重新连接…`，
> 但 bridge 日志无报错、健康检查全部通过。根因是和隔壁 SpeakLow 应用抢 18089 端口。
> 本文档给后续接手的 AI/协作者：先读硬规则，再按 checklist 排查，不要一上来就改代码。

## 硬规则（改任何 ASR 相关代码/配置前必读)

1. **端口所有权：MeetingAI 用 18090，SpeakLow 用 18089，永久错开。**
   MeetingAI 的端口配置在 `~/Library/Application Support/MeetingAI/config.json`：
   ```json
   { "asr": { "serverPort": 18090 } }
   ```
   不要删除这个文件，不要把端口改回 18089，不要在示例/文档/脚本里复制 18089 给 MeetingAI 用。
2. **"健康检查通过" ≠ "我们的 bridge 在服务"。** 同端口可能有别人的进程在应答（见下文机制）。
   判断流量打到谁身上的唯一可靠证据：看**本项目** bridge 日志（`~/Library/Logs/MeetingAI-bridge.log`）
   里有没有对应时间的 `GET /v1/stream` 记录。App 在"重连"而 bridge 日志一条 stream 请求都没有 → 流量去了别人家。
3. **清理进程禁止裸 `pkill asr-bridge`**，会误杀 SpeakLow 的同名进程。用路径过滤：
   `pkill -f '会议中AI给建议.*asr-bridge'`。
4. **"bind 没报错"不能证明端口没冲突。** macOS 允许"具体地址绑定"（`127.0.0.1:PORT`）与
   "通配地址绑定"（`*:PORT`）共存。后启动的一方绑通配照样成功，但发往 `127.0.0.1` 的连接
   会路由给绑具体地址的那个进程。
5. 排查 ASR 断连问题时，先跑完下面的 checklist 并把结论写进对话/日志，再考虑动代码。

## 复发排查 checklist（命令可直接复制）

```bash
# 1. 谁在监听 MeetingAI 的端口？（期望：只有一个、路径在本项目内的 asr-bridge）
lsof -nP -iTCP:18090 -sTCP:LISTEN

# 2. 有没有别的 asr-bridge 进程？（SpeakLow 的在 speaklow-macvoiceinput 路径下，属正常，别杀）
pgrep -fl asr-bridge

# 3. 健康检查响应来自谁？对比 IPv4 / IPv6 两个回答，若 JSON 结构不同 = 两个不同进程在应答
curl -s http://127.0.0.1:18090/health   # IPv4，具体地址绑定者优先应答
curl -s "http://[::1]:18090/health"     # IPv6，通配绑定者应答
#    识别特征：本项目 bridge 的响应含 "service":"meetingai-asr-bridge"（2026-07-18 加固后新增的
#    身份字段，ASRServerManager 也会校验它）；SpeakLow 的响应含 "build_identity"/"protocol_version"。
#    字段特征可能随版本变化，重点是"两边不一致"本身。

# 4. 决定性证据：App 重连期间，本项目 bridge 日志有没有 stream 请求？
tail -20 ~/Library/Logs/MeetingAI-bridge.log
#    有 "GET /v1/stream" → 流量到位，问题在上游（看第 5 条）
#    只有启动行、没有任何请求 → 端口被别人截胡，回到第 1-3 条

# 5. 上游断连（流量到位但几分钟后断）：看是否走了本机代理
#    日志特征：write tcp 127.0.0.1:xxxxx->127.0.0.1:7897: i/o timeout
#    7897 是本机 Clash 类代理端口。长连接被代理闲置超时属已知次级问题（见下文），
#    重连 1 次即恢复的偶发断连可接受；频繁复发再考虑 NO_PROXY 直连。
```

## 事故经过（2026-07-18）

| 时间 | 事件 |
|---|---|
| 15:11:30 | 用户侧 SpeakLow 应用启动，其自带 asr-bridge 绑定 `127.0.0.1:18089`（IPv4 具体地址） |
| 15:11:57 | MeetingAI 启动，自己的 asr-bridge 绑定 `*:18089`（IPv6 通配）——**bind 成功，无任何报错** |
| 15:12 起 | App 的 WebSocket 连 `ws://127.0.0.1:18089/v1/stream`，全部路由到 SpeakLow 的 bridge，协议不匹配被断开，UI 无限显示"重连（1/3）" |
| 15:17 | 排查确认：MeetingAI bridge 日志当天零条 stream 请求；`lsof` 显示两个进程同时 LISTEN 18089 |
| 15:22 | 修复：写入 config.json 指定 18090，重启 MeetingAI（SpeakLow 未动） |
| 15:25 | 新会话正常，转写恢复 |

## 根因机制：为什么三个信号都在"撒谎"

1. **bind 成功**：BSD/macOS 套接字语义下，具体地址（`127.0.0.1:18089`）和通配地址（`*:18089`）
   不算冲突，两个进程都能 LISTEN 成功。本项目 bridge 5 月份日志里出现过的
   `bind: address already in use` 报错，只在"两边都绑通配"时才会出现——所以**没报错不代表没占用**。
2. **健康检查通过**：`ASRServerManager` 检查 `http://127.0.0.1:PORT/health`，走 IPv4，
   由 SpeakLow 的 bridge 应答。它恰好也是从同一份代码衍生的，返回同样的 `"status":"ok"`，
   于是启动流程判定一切正常。这是 `docs/handoff-2026-07-18.md` "已知坑"第 2 条的真实发作。
3. **重连计数永远 1/3**：WebSocket 到 SpeakLow bridge 的**握手能成功**（它也有 `/v1/stream` 路由），
   连接建立会重置重试计数，随后因协议不匹配被断开 → 再握手又成功 → 无限循环，
   永远到不了"3 次失败放弃"的兜底。

三条防线（bind 报错、健康检查、重试上限）恰好被同一个根因全部穿透，这是本次事故最值得记住的形态：
**同源衍生的两个服务跑在同一台机器上时，"长得一样"本身就是故障放大器**——健康检查分不清彼此，
协议又相似到能握手但不能工作。

## 当前防线与剩余风险

已落地（截至 2026-07-18 晚，四重防线，后三条由同日并行开发会话实现并通过 `tests/run-p0-p1.sh` 回归）：
- **config.json 固定 MeetingAI 端口为 18090**（15:22，本次事故的直接修复）。
- **启动预检**：`Sources/ASRBridgePortGuard.swift` + `ASRServerManager`，启动 bridge 前用
  `lsof -ti tcp:PORT -sTCP:LISTEN` 枚举**所有**监听者（含"具体地址 + 通配地址"共存的形态，
  正是本次事故的盲区），自家残留进程自动清理，外来进程占用则中止启动并报错，绝不误杀别人的进程。
- **响亮失败**：`asr-bridge/main.go` 改为显式绑定 `127.0.0.1`（具体地址），端口被占会立刻 bind 失败，
  不再与别人的进程静默共存。
- **健康检查验身份**：`/health` 响应带 `service: meetingai-asr-bridge` 字段，
  `ASRServerManager` 校验该字段，同源衍生服务应答"假绿"时按端口占用快速失败。

**尚未落地**（实施前先按 RIPER-5 走计划审批，不要顺手改）：
- `Sources/Config.swift` 的 serverPort fallback 默认值仍是 18089
  （config.json 不随仓库走，换机器/清配置后会回落到默认值再次撞上 SpeakLow——
  但因上面三重代码防线已在，届时表现为"明确报错"而非"静默重连"，属可接受残留；
  改默认值为 18090 仍是待办决策）。

剩余风险：
- SpeakLow 侧未做任何变更。若未来 SpeakLow 改端口或新增第三个同源衍生服务，需重新确认端口分配表。
- config.json 是用户目录文件，不随仓库走。换机器/清配置后 MeetingAI 会回落到默认 18089。
  默认值改成 18090 需要改代码（`Sources/Config.swift` 的 fallback），属上面的 P2 范畴。

## 次级问题备案：本机代理导致的上游断连

修复端口后观察到一次独立的断连：bridge → DashScope 的 WebSocket 走了本机代理
（`127.0.0.1:7897`，Clash 类），约 2 分钟后代理闲置超时，日志：
`[stream] client loop ended: append audio: write tcp ...->127.0.0.1:7897: i/o timeout`。
重连 1 次即恢复。若此类断连变频繁，候选方案是给 bridge 进程环境加
`NO_PROXY=dashscope.aliyuncs.com` 直连（改 `ASRServerManager` 注入环境变量，同属需走计划的代码变更）。
偶发一次的不必处理。

## 关联文档

- `docs/handoff-2026-07-18.md` — 项目交接总览（已知坑第 2 条即本事故的预警）
- `docs/log-observations-2026-03-06.md` — 更早的 ASR 联调问题观察
- `docs/engineering-lessons-2026-05-23.md` — 工程守则总表
