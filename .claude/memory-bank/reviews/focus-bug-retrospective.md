# 复盘：输入框焦点失效

**日期**：2026-02-27
**严重度**：P1（核心交互功能不可用）

## 错误描述

App 的输入框（TextField）完全无法获得键盘焦点，用户无法输入任何文字。焦点始终跳到其他应用的输入框。

## 根因分析

`swift run` 启动的进程不是标准 macOS .app bundle。macOS 将其视为后台进程，不会：
- 赋予前台激活状态
- 在 Dock 和 Cmd+Tab 中显示
- 将键盘事件路由到该进程

## 修复过程

| 尝试 | 修复层 | 结果 |
|------|--------|------|
| 1. 添加 `@FocusState` | SwiftUI 控件层 | 无效 |
| 2. `setActivationPolicy(.regular)` + `activate()` + `makeKeyAndOrderFront` | OS 进程层 + 窗口层 | 成功 |

## 关键代码

```swift
// App init 中
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.activate(ignoringOtherApps: true)

// 窗口出现后
NSApp.windows.first?.makeKeyAndOrderFront(nil)
```

## 教训

1. **分层思考**：UI 问题先确定属于哪一层（OS → 窗口 → 控件），不要在错误层级修复
2. **SPM 应用缺陷**：SPM executable 缺少 .app bundle 的运行时行为，需手动补全
3. **第一次修复的反思**：看到"焦点问题"就直觉用 `@FocusState`，没有先验证进程是否具备前台身份
