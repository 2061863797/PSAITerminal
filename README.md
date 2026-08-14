# PSAITerminal

[![CI](https://github.com/2061863797/PSAITerminal/actions/workflows/ci.yml/badge.svg)](https://github.com/2061863797/PSAITerminal/actions/workflows/ci.yml)

适用于 Windows PowerShell 5.1（x64/x86）和 PowerShell 7.4 及以上版本的本地 AI 终端模块。

当前 `0.6.0` 发布仅支持 Windows PowerShell 5.1（x64/x86）与 PowerShell 7.4 及以上版本。Linux/macOS 实现已移除，不属于构建、测试或发布范围。

当前发布未做 Authenticode 代码签名。安装前请从 GitHub Release 或 PowerShell Gallery 获取包并核对 SHA256；若本机策略阻止未签名脚本，只对该次安装进程使用 `-ExecutionPolicy Bypass`，不要永久放宽系统策略。

## 安装

在解压后的发布目录中运行：

```powershell
.\Install-PSAITerminal.ps1
```

默认 `-TargetHost Current`，只安装到当前宿主。也可选择 `WindowsPowerShell`、`PowerShell` 或 `Both`；`Both` 分别安装到 `<Documents>\WindowsPowerShell\Modules` 与 `<Documents>\PowerShell\Modules`。它不能与 `-ModuleRoot` 或 `-ProfilePath` 同时使用。

例如，从 PowerShell 7 同时安装两个宿主：

```powershell
pwsh -NoProfile -File .\Install-PSAITerminal.ps1 -TargetHost Both
```

如果不希望自动加载：

```powershell
.\Install-PSAITerminal.ps1 -TargetHost Both -NoProfileIntegration
```

如果系统重定向了用户目录，或要给指定 Host 写入 Profile，可明确指定两条路径。以下是 Windows 示例：

```powershell
.\Install-PSAITerminal.ps1 -ModuleRoot 'D:\PowerShell\Modules' -ProfilePath 'D:\PowerShell\Microsoft.PowerShell_profile.ps1'
```

配置和会话数据默认使用以下目录；设置 `PSAI_CONFIG_HOME` 或 `PSAI_DATA_HOME` 可以分别覆盖它们：

| 平台 | 配置目录 | 会话与 Run 数据目录 |
|---|---|---|
| Windows | `<Documents>/PowerShell/PSAITerminal` | `%LOCALAPPDATA%/PowerShell/PSAITerminal` |

Windows 的 `<Documents>` 以系统“文档”已知文件夹为准，可能被重定向到其他磁盘；可在 PowerShell 中用 `[Environment]::GetFolderPath('MyDocuments')` 查看实际路径。

安装完成后会显示中英文双语引导；模块默认界面语言为 English。首次使用输入 `ai`，选择 `Models` 并新增模型。初始模式为 `Off`，没有预置模型，也不会自动联网。可以在 `ai` → `Language / 语言` 中切换为简体中文，选择会持久化。

## 日常使用

| 操作 | 用法 |
|---|---|
| 打开设置 | 输入 `ai` 后按 Enter |
| 明确询问 AI | 输入 `ai 你的问题` 后按 Enter |
| 强制交给 AI | 先输入内容，**不按 Enter**，直接按 `F2` |
| 强制执行 Shell | 先输入命令，**不按 Enter**，直接按 `F3` |
| 切换模式 | 按 `F6` |
| 解释最近命令 | 按 `F7` |

部分笔记本需要按 `Fn+F2`、`Fn+F3`。是否真的注册成功可运行：

```powershell
Get-PSAIIntegrationStatus
Test-PSAIConfiguration
```

`Off`：Enter 始终按 PowerShell 执行。`AI`：Enter 始终交给 AI。`Auto`：明确的 PowerShell 命令先执行；命令无法运行时，模块会把原始输入交给 AI。

Windows PowerShell 5.1 不提供 PowerShell 7 专属的原生预测器/反馈 API，因此 `Get-PSAIIntegrationStatus` 会显示“宿主不支持”；模型、会话、安全审批、输入路由和快捷键不受影响。`Enable/Disable-PSAIPredictor` 在 5.1 中会明确拒绝且不会改写共享配置。

## 模型

支持 OpenAI Chat、OpenAI Responses、Anthropic Messages、Gemini Native `generateContent` 和 Ollama。OpenAI 兼容地址可以写成包含或不包含 `/v1` 的形式，也可以带反向代理路径前缀。

新增模型时，模块会先尝试读取服务端模型列表供选择；服务不提供列表接口时仍可手动输入模型 ID。API Key 不写入 JSON 配置，Windows 使用 Credential Manager。密钥库不可用时，交互设置会询问是否仅在当前 PowerShell 会话使用 API Key；命令行可显式使用 `New-PSAIModel -SessionOnly`。

连接检查：

```powershell
Test-PSAIConfiguration -Online
```

该命令会发送一次最小模型请求。仅获取模型列表失败不会被误报为模型不可用。

## Agent 与会话

AI 提议命令时会先显示目的、完整命令、预期结果、副作用和确定性风险，再等待确认。目的、预期和副作用仍是 AI 生成的说明，可能不准确；应以屏幕上的完整命令为准。高风险命令没有回车默认执行，并要求第二次明确确认。

批准会绑定到命令 SHA-256 摘要和 Run 修订号；命令、风险或并发状态发生变化后，旧批准自动失效。执行状态会累计整段脚本中的 PowerShell 错误和原生命令非零退出，不会被后续成功语句覆盖。命令仍在当前用户的 PowerShell 会话中执行，不是隔离沙箱。模块同时支持多步骤“执行 → 观察 → 调整”、上下文预算、自动压缩、持久会话和 Run 检查点。

审批界面中的“回滚”是 AI 生成的建议，不是自动回滚功能。模块目前不会自动备份文件、注册表或系统状态，也不会在命令失败后自动执行反向命令。对于删除、覆盖、安装、网络请求等操作，应在批准前自行确认备份和恢复方案。

常用管理命令：

```powershell
Get-PSAIModel
Get-PSAISession
Get-PSAIRun
ai resume <RunId>
```

## 更新与卸载

更新时在新发布包中重新运行安装器，然后重启 PowerShell。版本化安装可避免正在运行的旧 DLL 阻止更新。

卸载请在未加载模块的新进程中运行发布包内的脚本：

```powershell
.\Uninstall-PSAITerminal.ps1 -TargetHost Current
```

卸载默认保留模型配置、凭据和会话数据。

## 故障排查

- `Import-Module PSAITerminal` 找不到模块：请在你日常使用的同一个 `pwsh` 中重新运行安装器。
- 新增的模型看不到：运行 `Test-PSAIConfiguration` 核对“配置文件”路径；不要在不同终端中设置不同的 `PSAI_CONFIG_HOME`。
- F2/F3 没反应：先确认模块已自动加载，再看 `Get-PSAIIntegrationStatus` 中快捷键是否为“已启用”。
- 快捷键冲突：模块不会覆盖用户自定义的 PSReadLine 绑定；移除冲突后重启 PowerShell。
- 查看详细帮助：`Get-Help about_PSAITerminal`。

模块只使用 PowerShell 和 PSReadLine 的公开扩展接口。受官方接口限制，原生程序直接写控制台的内容可能无法保存为步骤结果；`Get-History` 或转录可能看到一条短的内部调度命令，但不会显示 Agent 实现源码。PSReadLine 历史保留用户原始输入。

## 开发构建

```powershell
./build.ps1 -Restore -Configuration Release -Package
./tests/run.ps1
```
