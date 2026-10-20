# 验证结果

验证日期：2026-10-17，Asia/Taipei。

此仓库已经完成实际验证，结果不是全部通过。最终分层报告：

- `functionalPassed: true`
- `nativeCapturePassed: false`
- `passed: false`，`verify` 正确返回退出码 1。

报告：run-20261017-180134/report.json（历史路径：`artifacts/run-20261017-180134/report.json`）。
本次生成的原始证据已按用户要求清理。此文保留历史测量与失败记录，所列路径仅供追溯命名，文件已不存在。

## 环境与执行方式

- Flutter 3.47.6 stable，Dart 3.13.5。
- Windows x64 Debug runner；最终运行使用默认渲染器，日志报告 Impeller。
- Flutter Driver 通过应用自己的本机 VM Service 连接。
- Python 3 标准库；Windows SDK/C++20 原生工具；本机 FFmpeg/FFprobe。
- 没有使用 Computer Use、SendInput、鼠标移动或全局键盘注入。
- 最终运行实际 Windows 前台 HWND 保持为另一个窗口；测试应用激活次数为 0。

## 实际结果

| 能力 | 结果 | 证据 |
| --- | --- | --- |
| 组件点击、导航 | 通过 | 图库点击及按钮回调累计 2 次，切换三个页面 |
| 滚动 | 通过 | 列表实际偏移 450 logical pixels |
| 文本输入 | 通过 | `Agent input / 测试输入` 原样进入输入控件 |
| Flutter 内部键盘事件 | 通过 | F6 处理计数增加 1；未发送系统键盘输入 |
| App 内容截图 | 通过 | 三个页面与恢复状态的 RepaintBoundary PNG，1266×683 |
| App 内容录屏 | 通过 | H.264，8 秒，5 fps，40 帧；实际耗时 8.006 秒 |
| Windows 原生窗口截图 | 部分成功，未稳定验收 | 启动后前三页捕获为空白；后续恢复页捕获到完整内容 |
| Windows 原生窗口录屏 | 最终这轮通过 | PrintWindow，1920×1080，12 秒，12 fps，144 帧；画面包含页面变化 |
| 前台模拟开关 | 通过 | 开启为 `resumed/focused`，关闭恢复 `inactive/unfocused` |
| 前台专属逻辑 | 通过 | 关闭时计数停止；开启在后台推进；关闭后再次停止 |
| 实际 Windows 前台/焦点 | 通过 | 最终激活次数 0；原生焦点 false；录屏 144 次前台采样均非目标窗口 |

App 视频的中心内容区最大平均像素变化为 25.70，原生视频为 22.95，
超过验收阈值 3。这个检查会排除只因 H.264 编码噪声或标题栏产生的帧哈希变化。

## 原证据文件记录（已清理）

- App 录屏（历史路径：`artifacts/run-20261017-180134/app-recording.mp4`）
- App 录屏抽帧（历史路径：`artifacts/run-20261017-180134/app-video-contact-sheet.png`）
- 原生窗口录屏（历史路径：`artifacts/run-20261017-180134/window-recording.mp4`）
- 原生窗口录屏抽帧（历史路径：`artifacts/run-20261017-180134/video-contact-sheet.png`）
- 成功的恢复状态窗口截图（历史路径：`artifacts/run-20261017-180134/restored-window.png`）
- 启动早期空白窗口截图（历史路径：`artifacts/run-20261017-180134/overview-window.png`）
- 对应的正常 App 截图（历史路径：`artifacts/run-20261017-180134/overview-app.png`）

已经人工查看 App 截图、成功的窗口截图、两段视频的抽帧，以及失败的空白窗口截图。
正常画面没有看到布局溢出或渲染错误；空白图当时记录为失败证据，现已随测试数据清理。

## 原生捕获的具体边界

WGC 和 PrintWindow 均尝试过。两者都出现过 API 成功但内容区为空白或停留在旧画面的
情况；这不是“窗口截到了标题栏”就可以接受的结果。默认 GPU、Skia/软件渲染的
对照没有建立可靠的启动截图方案。最后一轮中，较晚进行的 PrintWindow 录屏和截图
获得了正确内容，但前三页启动截图仍失败，原因尚未确认。因此没有将原生捕获整体
标为通过，也没有将某次成功推广成稳定保证。

原生 helper 目前提供真实 API 调用和可复现的验证入口，不包含隐藏的激活、提到最前、
移动窗口或鼠标键盘回退。不会用 App 截图拼接一个标题栏来冒充原生截图。
最小化、隐藏、销毁或录制中改变尺寸会报错；锁屏和安全桌面未验证。

## 前台模拟的含义

它改变的是测试入口中 Flutter 接收的生命周期、视图焦点通知和框架焦点遍历许可。
正常入口不安装这个 binding。开关关闭时恢复最新平台事件，不硬编码恢复到某个状态。
实际 Windows `GetForegroundWindow` 和原生焦点单独观测，未被伪造。

这可以验证依赖 `resumed`、Flutter 焦点和内部输入事件的行为；不能证明真实 IME、
系统快捷键、系统对话框或直接查询 Windows 前台状态的原生插件路径同样有效。

## 低成本检查

- `dart format`，最终格式检查无变化。
- `flutter analyze`：No issues found。
- `flutter test`：4 项通过，覆盖最新平台状态恢复、框架焦点保护、真实视图焦点恢复和组件交互。
- Python 编译检查。
- Python unittest：4 项通过，覆盖无效 HWND、PID 不匹配、无效首帧协议和首帧超时的进程清理。
- `skill-creator/scripts/quick_validate.py`：Skill is valid。
- Debug Windows 构建和独立原生 helper 构建成功。

早期存在自动断言错误接受空白图的情况：原先像素检查包含窗口边框，帧哈希检查也
可能接受编码噪声。相关报告保留了人工否决记录。当前检查仅取中心内容区，并同时
检查有意义的页面变化，最终报告如实保留三项失败。
