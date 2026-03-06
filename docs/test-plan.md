# ASR Migration Test Plan

## P0: 生存测试（自动化）

编译通过即 PASS。任一失败则 BLOCK。

| # | 测试项 | 命令 | 判定 |
|---|--------|------|------|
| P0-1 | Go asr-bridge 编译 | `cd asr-bridge && go build -o bin/asr-bridge .` | exit code = 0 |
| P0-2 | Swift MeetingAI 编译 | `swift build` | exit code = 0 |

## P1: 代码正确性检查（自动化）

P0 通过后执行，验证关键代码变更符合设计文档。

| # | 测试项 | 验证方式 | 判定 |
|---|--------|----------|------|
| P1-1 | asr-bridge 不含 refine 路由 | `! grep -q 'refine' asr-bridge/main.go` | 无匹配 |
| P1-2 | asr-bridge 不含 transcribe-sync 路由 | `! grep -q 'transcribe-sync' asr-bridge/main.go` | 无匹配 |
| P1-3 | env.go 使用 api-vault.env | `grep -q 'api-vault.env' asr-bridge/env.go` | 有匹配 |
| P1-4 | go.mod 模块名正确 | `grep -q 'meetingai/asr-bridge' asr-bridge/go.mod` | 有匹配 |
| P1-5 | ASRServerManager 指向 asr-bridge | `grep -q 'asr-bridge' Sources/ASRServerManager.swift` | 有匹配 |
| P1-6 | ASRServerManager 健康检查 /health | `grep -q '/health' Sources/ASRServerManager.swift` | 有匹配 |
| P1-7 | ASRClient 连接 /v1/stream | `grep -q '/v1/stream' Sources/ASRClient.swift` | 有匹配 |
| P1-8 | ASRClient base64 音频发送 | `grep -q 'base64EncodedString' Sources/ASRClient.swift` | 有匹配 |
| P1-9 | Config 默认端口 18089 | `grep -q '18089' Sources/Config.swift` | 有匹配 |

## P2: 功能验证（手动）

auto-dev 不覆盖，需用户手动操作。

- [ ] 启动 App → 开始会议 → 对麦说话 → 左侧转写面板有输出
- [ ] 等待 30 秒沉默 → AI 自动分析触发
- [ ] 点击闪电按钮 → 手动触发分析
- [ ] 结束会议 → sessions/ 目录有 txt + mp3
- [ ] kill asr-bridge 进程 → 自动重连（最多 3 次）

## 自动化闭环判定标准

- **PASS**: P0 全部 exit code = 0 且 P1 全部通过
- **FAIL**: 任何一项失败
- **测试脚本**: `tests/run-p0-p1.sh`
