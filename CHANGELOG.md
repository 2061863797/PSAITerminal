# 更新日志

## 0.6.0 - 2026-08-14

- 正式支持 Windows PowerShell 5.1 x64/x86 与 PowerShell 7.4+，发布验收固定使用 7.6.4。
- 拆分 AnyCPU `netstandard2.0` 共享核心和仅由 PowerShell 7 加载的预测/反馈程序集。
- 两个宿主共享配置、凭据引用、会话与运行记录；5.1 明确显示官方预测/反馈“宿主不支持”。
- 安装器和卸载器新增 `Current / WindowsPowerShell / PowerShell / Both` 目标选择。
- 修复 5.1 读取 PowerShell 7 写入的无 BOM UTF-8 中文配置、会话、Run 和 Profile 时乱码或解析失败。
- 修复 Agent 执行包含 `Format-Table` 等格式化命令时破坏格式记录序列并误报失败。
- 修复流式响应在渲染前被 PowerShell 括号完整缓冲的问题，首段文本会在完成事件到达前显示。
- 将模型 Token 用量与对应会话 Turn 合并为一次加锁、一次原子写入，减少重复读取和修订冲突。
- 取消 HTTP 读取后继续观察底层任务，释放迟到的响应流并消费迟到异常。
- 修复 5.1 中重试等待泄漏内部对象、审批摘要调用新 .NET API，以及原生命令非零退出漏判的问题。
- 兼容无本机持久凭据集的受限登录会话：Credential Manager 返回 1312 时安全降级为当前登录会话凭据，不把 API Key 写入配置或明文。
- 将 PowerShell 7 构建链中的 `System.Formats.Asn1` 固定到已修复版本，并增加 NuGet 漏洞 CI 门禁。
- 修复预览构建回归测试读取稳定版目录的问题，并拒绝非法发布标签路径。
- 将执行门禁绑定到即将实际执行的命令文本，避免批准后内存命令与磁盘 Run 状态不一致。
- 推送 `main` 后由 Actions 自动完成打包和门禁验证；同版本首次通过时自动创建 GitHub Release。
- 将自动发布工作流迁移到新路径，解除旧工作流的手动禁用状态对 `main` 推送构建的阻断。
- 修正 Gallery 预览版安装命令，补充未签名包和 AI 回滚建议的安全边界说明。
- 更新 GitHub 官方 Actions 到当前 Node 运行时主版本，移除旧运行时弃用警告。
- 移除 Linux/macOS 实现、工具和测试，发布范围保持 Windows-only。

## 0.5.2 - 2026-08-14

- 修复移除 PSReadLine 快捷键时使用错误参数导致的清理失败。
- 明确 Windows 已知文件夹重定向后的安装、配置路径解析方式。
- 明确 AI 给出的回滚内容只是建议，模块不会自动备份或恢复系统状态。
- 增加 Windows 发布构建、完整回归、真实 ConPTY 交互和包内容校验。
- 当前发布范围收口为 Windows。
- 增加 PSScriptAnalyzer 门禁，并修复静态检查发现的可靠性问题。
