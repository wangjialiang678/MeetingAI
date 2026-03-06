# ASR Migration Test Plan

## P0: 生存测试（自动化）

编译通过即 PASS。

| # | 测试项 | 命令 | 判定 |
|---|--------|------|------|
| P0-1 | Go asr-bridge 编译 | `cd asr-bridge && go build -o bin/asr-bridge .` | exit code = 0 |
| P0-2 | Swift MeetingAI 编译 | `swift build` | exit code = 0 |

## P1: 核心功能验证（手动）

需用户手动操作 App 验证。

| # | 测试项 | 操作 | 预期结果 |
|---|--------|------|---------|
| P1-1 | ASR 转写 | 启动 App → 开始会议 → 对麦克风说话 | 左侧面板显示实时转写文本 |
| P1-2 | AI 自动分析 | 持续说话 30 秒后静默 | 右侧面板出现 AI 分析建议 |
| P1-3 | 手动分析 | 点击闪电按钮 | 右侧面板出现 AI 分析 |
| P1-4 | 会话保存 | 结束会议 | sessions/ 目录有 txt + mp3 |
| P1-5 | ASR 断线重连 | kill asr-bridge 进程后等待 | 自动重连（最多 3 次） |

## 自动化闭环判定标准

- **PASS**: P0-1 和 P0-2 全部 exit code = 0
- **FAIL**: 任何一项编译失败
