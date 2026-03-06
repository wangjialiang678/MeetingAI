# Changelog

## [Unreleased]

## [0.1.0] - 2026-02-27

### Added

- 麦克风实时录音采集（AVAudioEngine, 16kHz PCM16）
- ASR 实时转写（通过 asr-server Go 子进程 + DashScope WebSocket）
- AI 智能触发分析：内容积累（8条）、静默检测（30s）、上限计时器（600s）
- 手动一键分析按钮
- 对话式 AI 交互（用户输入 prompt 与 AI 对话）
- 双面板 UI：左侧转写面板 + 右侧 AI 对话面板
- 录音状态控制（开始/暂停）
- 会话转写自动保存（.txt）
- 会议录音保存（.mp3）
- ASR WebSocket 断线自动重连（最多 3 次）
- 自定义 AI System Prompt 支持
- 历史转写文件导入功能
- JSON 配置文件支持（AI 模型、分析间隔等）
