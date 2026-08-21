# PSAITerminal

[![CI](https://github.com/2061863797/PSAITerminal/actions/workflows/ci.yml/badge.svg)](https://github.com/2061863797/PSAITerminal/actions/workflows/ci.yml)

> AI-powered terminal assistant for Windows PowerShell.

PSAITerminal 是一个运行在 PowerShell 中的本地 AI 终端助手。

它将 AI Agent、命令分析、安全审批和多模型支持结合到传统终端中，让
PowerShell 具备智能化交互能力。

------------------------------------------------------------------------

## ✨ Features

## 🤖 AI Terminal Assistant

使用自然语言与终端交互：

-   自动生成 PowerShell 命令
-   解释已有命令
-   分析错误信息
-   辅助完成日常开发任务

## 🧠 Agent Mode

支持：

-   多步骤任务执行
-   执行 → 观察 → 调整循环
-   持久会话
-   Run 检查点恢复
-   上下文管理

## 🔐 Security First

执行命令前展示：

-   完整命令
-   执行目的
-   预期结果
-   潜在风险

高风险操作需要明确确认。

这不是自动回滚功能：界面显示的回滚内容是 AI 生成的操作建议；模块不会自动备份、撤销或恢复系统状态。

安全机制包括：

-   命令 SHA-256 审批绑定
-   API Key 安全存储
-   Windows Credential Manager 支持
-   风险等级检测

## 🌐 Multi Model Support

支持：

-   OpenAI Chat
-   OpenAI Responses
-   Anthropic Messages
-   Gemini Native
-   Ollama

兼容：

-   云端 API
-   OpenAI Compatible API
-   本地模型服务

------------------------------------------------------------------------

# 📦 Installation

## PowerShell Gallery

当前 Gallery 候选版为 [`0.6.0-preview1`](https://www.powershellgallery.com/packages/PSAITerminal/0.6.0-preview1)。

PowerShell 7.4 及以上：

``` powershell
Install-PSResource -Name PSAITerminal -Prerelease -Repository PSGallery -Scope CurrentUser
```

Windows PowerShell 5.1 自带的 PowerShellGet 1.0.0.1 不支持预览版。先升级
PowerShellGet，关闭并重新打开 Windows PowerShell，再安装：

``` powershell
Install-Module -Name PowerShellGet -MinimumVersion 2.2.5 -Scope CurrentUser -Force -AllowClobber
# 关闭并重新打开 Windows PowerShell
Install-Module -Name PSAITerminal -AllowPrerelease -Repository PSGallery -Scope CurrentUser
```

正式版 `0.6.0` 发布后，两个宿主都可直接运行：

``` powershell
Install-Module -Name PSAITerminal -Repository PSGallery -Scope CurrentUser
```

或者使用 GitHub Release 安装包：

``` powershell
.\Install-PSAITerminal.ps1 -TargetHost Current
```

当前包未做 Authenticode 代码签名。手动安装时请从官方 Release 下载，并核对
`SHA256SUMS-Windows.txt`。

------------------------------------------------------------------------

# 🚀 Quick Start

启动配置：

``` powershell
ai
```

询问 AI：

``` powershell
ai explain this command
```

快捷操作：

  功能             快捷键
  ---------------- --------
  强制 AI 请求     F2
  强制执行 Shell   F3
  切换模式         F6
  解释最近命令     F7

部分笔记本可能需要：

``` text
Fn + F2
Fn + F3
```

------------------------------------------------------------------------

# ⚙️ Modes

## Off

普通 PowerShell 模式。

所有输入按照 PowerShell 原方式执行。

## AI

所有输入交给 AI 处理。

## Auto

智能判断输入：

-   PowerShell 命令 → 直接执行
-   自然语言 → 交给 AI

------------------------------------------------------------------------

# 🖥️ Compatibility

当前版本支持：

-   Windows PowerShell 5.1 (x64/x86)
-   PowerShell 7.4+

当前 `0.6.0` 发布仅支持 Windows PowerShell 5.1（x64/x86）和 PowerShell 7.4 及以上。

当前发布版本：

-   Windows only

Linux/macOS 实现暂不属于当前发布范围。

------------------------------------------------------------------------

# 🔧 Configuration

支持模型：

-   OpenAI
-   Anthropic
-   Gemini
-   Ollama

首次使用：

1.  输入：

``` powershell
ai
```

2.  进入 Models
3.  添加模型配置

API Key 不会保存到普通 JSON 配置文件。

Windows 默认使用 Credential Manager 保存凭据。

Windows PowerShell 5.1 与 PowerShell 7 共用以下配置和运行数据：

| 平台 | 配置目录 | 数据目录 |
| --- | --- | --- |
| Windows | `<Documents>/PowerShell/PSAITerminal` | `%LOCALAPPDATA%/PowerShell/PSAITerminal` |

------------------------------------------------------------------------

# 📚 Commands

常用管理命令：

``` powershell
Get-PSAIModel
Get-PSAISession
Get-PSAIRun
```

恢复会话：

``` powershell
ai resume <RunId>
```

检查配置：

``` powershell
Test-PSAIConfiguration
```

------------------------------------------------------------------------

# 🛠 Development

构建：

``` powershell
./build.ps1 -Restore -Configuration Release -Package
```

预览版本：

``` powershell
./build.ps1 -Configuration Release -Package -Prerelease preview1
```

运行测试：

``` powershell
./tests/run.ps1
```

------------------------------------------------------------------------

# 📄 License

See repository license for details.
