# Flutter UI Automation

[English](README.md) | 简体中文

[![CI](https://github.com/normalllll/flutter-ui-automation/actions/workflows/ci.yml/badge.svg)](https://github.com/normalllll/flutter-ui-automation/actions/workflows/ci.yml)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)

让 AI 智能体测试并目视检查真实运行的 Flutter 应用：点击、输入、滚动、热重载、截图和录屏，**全程不碰你的鼠标、键盘和窗口焦点**。它运行时，你可以照常在同一台电脑上工作。

它由两部分组成：一个智能体技能（Claude Code、Codex 可用），以及一个常驻的 Dart MCP 服务。服务通过 Flutter Driver 驱动应用，支持 Windows、Android、Linux X11、macOS 和 iOS 模拟器。

<p align="center">
  <img src="docs/images/architecture.svg" alt="AI 智能体与一个常驻的 Dart MCP 进程通信；该进程通过 Flutter Driver 驱动 Flutter 应用，并把应用自身的 PNG 和系统实际显示的像素作为两路独立证据收集。" width="900">
</p>

## 有什么不同

- **天生在后台运行。** 不发送系统级的模拟输入，也不激活窗口。输入走 Flutter 自己的指针、文本和按键通道；截图只针对指定的那个窗口或设备。
- **两路证据。** 每次截图同时保留应用自己导出的 PNG 和系统实际显示出来的像素。两者会比对，但从不混在一起。
- **证明拍到的是新画面。** 截取系统画面前，应用会显示一个 8×4 的小点阵标记，里面编码了本次请求独有的编号。只有在截到的像素里解出这个编号，截图才会被接受，空白或过期的画面都会被拒绝。
- **会话一直在线。** 改代码后热重载或热重启，继续测试同一个原生进程。耗时操作以可取消的任务方式运行。
- **如实交代媒体质量。** 平台允许时，录像会保留原始帧和经过校验的无损母版；Android 的 screenrecord 会如实标注为有损。

## 支持的平台

| 平台 | 应用控制 | 系统截图 | 说明 |
| --- | --- | --- | --- |
| Windows | Flutter Driver | WGC / PrintWindow，限定单个 HWND | 需要可交互的桌面 |
| Android | Flutter Driver | ADB 截图与 screenrecord，需显式指定设备 | 保留真实生命周期和输入法 |
| Linux | Flutter Driver | X11 窗口截图 | 尚未实现 Wayland 截图 |
| macOS | Flutter Driver | ScreenCaptureKit 窗口辅助程序 | 需要屏幕录制权限 |
| iOS 模拟器 | Flutter Driver | `simctl`，需显式指定 UDID | 不支持真机 |

当前的验证结果和限制见 [验证状态](docs/validation-status.md)（英文）。

## 快速开始

1. 安装依赖和技能：[安装说明](docs/installation.md)。
2. 编译一次服务，并把它注册为 MCP 服务。
3. 启动参考示例应用，操作它并同时截取两路画面：[快速开始](docs/quickstart.md)。

要自动化你自己的应用，给它加一个 Debug 测试入口并附加上去，见 [接入应用](references/mcp.md#integrating-an-app)。

以上文档目前均为英文。

## 文档

| 主题 | 文档 |
| --- | --- |
| 工作流程、工具、会话和命令行 | [MCP 工作流程](references/mcp.md) |
| Windows · Android | [Windows](references/windows.md) · [Android](references/android.md) |
| Linux · macOS/iOS · 远程主机 | [Linux](references/linux.md) · [Apple](references/apple.md) · [远程](references/remote.md) |
| 呈现标记与截图保真度 | [截图](references/capture.md) |
| 前台模拟的边界 | [前台](references/foreground.md) |
| 独立的 Windows 窗口截图工具 | [用法](references/usage.md) |
| 实测数据与复现方法 | [MCP 验证](docs/mcp-validation.md) |
| 智能体指令 | [SKILL.md](SKILL.md) |

## 目录结构

```text
tools/automation/      常驻 Dart MCP、命令行和回归测试
tools/window_capture/  Windows WGC/PrintWindow 截图辅助程序（C++20）
tools/linux_capture/   X11 截图辅助程序
tools/macos_capture/   ScreenCaptureKit 截图辅助程序
examples/capture_lab/  覆盖所有平台的 Flutter 参考示例应用
references/  docs/     工作流程、平台指南和验证记录
scripts/               仓库检查和独立的 Windows 截图工具
```

## 参与贡献与许可

开发时需要跑的检查见 [CONTRIBUTING.md](CONTRIBUTING.md)，变更记录见 [CHANGELOG.md](CHANGELOG.md)。安全问题请按 [SECURITY.md](SECURITY.md) 报告。

Copyright (C) 2026 [normalllll](https://github.com/normalllll)。以 **GPL-3.0-or-later** 授权，见 [LICENSE](LICENSE)、[COPYRIGHT](COPYRIGHT) 和 [第三方声明](THIRD_PARTY_NOTICES.md)。
