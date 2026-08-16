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

``` powershell
Install-Module -Name PSAITerminal -AllowPrerelease
```

或者使用 GitHub Release 安装包：

``` powershell
.\Install-PSAITerminal.ps1
```

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
