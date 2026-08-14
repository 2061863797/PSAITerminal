# 更新日志

## 0.6.0 - 2026-08-14

- 正式支持 Windows PowerShell 5.1 x64/x86 与 PowerShell 7.4+，发布验收固定使用 7.6.4。
- 拆分 AnyCPU `netstandard2.0` 共享核心和仅由 PowerShell 7 加载的预测/反馈程序集。
- 两个宿主共享配置、凭据引用、会话与运行记录；5.1 明确显示官方预测/反馈“宿主不支持”。
- 安装器和卸载器新增 `Current / WindowsPowerShell / PowerShell / Both` 目标选择。
- 移除 Linux/macOS 实现、工具和测试，发布范围保持 Windows-only。

## 0.5.2 - 2026-08-14

- 修复移除 PSReadLine 快捷键时使用错误参数导致的清理失败。
- 明确 Windows 已知文件夹重定向后的安装、配置路径解析方式。
- 明确 AI 给出的回滚内容只是建议，模块不会自动备份或恢复系统状态。
- 增加 Windows 发布构建、完整回归、真实 ConPTY 交互和包内容校验。
- 当前发布范围收口为 Windows。
- 增加 PSScriptAnalyzer 门禁，并修复静态检查发现的可靠性问题。
