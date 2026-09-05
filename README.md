# PSAITerminal

[![CI](https://github.com/2061863797/PSAITerminal/actions/workflows/windows-release.yml/badge.svg)](https://github.com/2061863797/PSAITerminal/actions/workflows/windows-release.yml)

> AI-powered terminal assistant for Windows PowerShell.

PSAITerminal 是一个原生运行在 PowerShell 中的智能终端助手。

它将大语言模型深度嵌入终端交互管线，提供**自然语言二分类路由**、**最简原生命令生成**、**执行前六要素安全审批**、**错误先诊断后自愈**以及**单步完结防发散保护**，让 PowerShell 终端既具备强大的 AI 协作能力，又保持原生命令行的轻快与安全。

---

## ✨ Features

### 🤖 智能终端路由与自然语言二分类

- **自由沟通流（纯文本无工具）**：
  - 精准识别日常问候（如“你好”）、概念咨询（如“什么是 Docker”）、开发原理探讨及纯文本疑问。
  - 直接输出自然流畅的文本回答，**严禁调用工具，绝不创建 Agent 状态机，零菜单打扰**。
- **本地操作指令流（最简原生命令提议）**：
  - 用户发出操作诉求（如“查本机内网IP”、“列出占用8080端口的进程”、“清理临时文件”）。
  - AI 提议最简原生 PowerShell 命令，执行前严格呈现**六要素安全契约**。
- **单步完结保护机制（Anti-Overreach）**：
  - 单步查询或单一操作执行成功后，**立即标记任务完成并结束**，终端输出 `◆ ✓ 命令已完成 · F7 解释`。
  - **严禁大模型擅自再次调度，彻底杜绝无意义发散去搜索任务文件的异常行为**。
- **执行完成静默策略与 F7 深度解读**：
  - 命令正常执行成功后不再自动输出长篇冗长文本，避免刷屏；需要深入理解时，随时按下 **F7** 获取专业剖析。
- **新终端自动上下文隔离**：
  - 每次打开新终端自动清除历史上下文记忆，消除旧会话包袱。

### 🛡️ 严格安全审计（六要素与统一三项批准菜单）

执行任何生成的命令前，AI 必须完整呈现**六要素安全契约**：

1. **目的 (Purpose)**：明确该命令意图
2. **命令 (Command)**：待执行的完整原生命令
3. **预期 (Expected Outcome)**：执行后的预期结果
4. **副作用 (Side Effects)**：可能带来的状态变更或资源影响
5. **回滚 (Rollback)**：失败或撤销时的操作建议
6. **风险 (Risk)**：`Low` / `Medium` / `High` 明确风险等级

> **重要说明**：这不是自动回滚功能：界面显示的回滚内容是 AI 生成的操作建议；模块不会自动备份、撤销或恢复系统状态。

随后弹出统一精简的**三项批准菜单**：
```text
1. 批准执行
2. 编辑命令
3. 拒绝执行
```
- 按 `1` 立即执行命令；按 `2` 调起编辑器微调命令；按 `3` 干净拒绝并终止。

### 🔧 语法错误与执行失败闭环自愈

- **先诊断根因，再提议修复**：
  - 当检测到输入代码存在语法错误，或者执行的命令抛出异常、以非零状态码失败退出时：
  - **AI 首先输出明确解释**：剖析为什么执行不成功、语法错误或参数不匹配的根本原因；
  - **随后完整输出修复命令的六要素**，并弹出统一三项批准菜单供一键批准执行。
- **回滚优先机制 (Rollback First)**：
  - 若出错的命令产生了副作用（如创建了残缺临时文件、锁定了目录），AI **必须优先申请执行回滚与清理修复命令**，回滚完成后再继续执行正规命令。

### 🧠 目标驱动自主规划 (Agent Mode)

- **复合长任务规划**：面对用户提出的目标诉求（如“先备份，再压缩，最后校验哈希”），AI 自动规划清晰的分步执行序列，每一步均严格遵循六要素与三项批准。
- **不可行性与障碍主动说明**：当用户目标在当前环境下不可行或存在依赖障碍时，AI 主动向用户说明原因与前置解决条件，严禁盲目猜命令试错。

### 🌐 多模型与本地安全存储

- 原生结构化 Messages 协议支持：
  - OpenAI Chat / OpenAI Compatible API
  - OpenAI Responses
  - Anthropic Messages
  - Gemini Native
  - Ollama 本地模型
- **凭据安全**：API Key 通过 Windows Credential Manager 安全加密存储，禁止明文落盘。
- **本地访问控制 (DACL)**：运行数据与配置目录采用 Win32 DACL 限制仅当前用户和管理员访问。

---

## 📦 Installation

### PowerShell Gallery

当前正式版本为 [`1.0.3`](https://www.powershellgallery.com/packages/PSAITerminal/1.0.3)。

Windows PowerShell 5.1 与 PowerShell 7.4+ 均可直接安装：

```powershell
Install-Module -Name PSAITerminal -Repository PSGallery -Scope CurrentUser
```

PowerShell 7 推荐使用 `PSResourceGet`：

```powershell
Install-PSResource -Name PSAITerminal -Repository PSGallery -Scope CurrentUser
```

使用本地 GitHub Release 安装包：

```powershell
.\Install-PSAITerminal.ps1 -TargetHost Current
```

> **安全提示**：当前发布包未作 Authenticode 代码签名。手动安装时请核对发布压缩包附带的 `SHA256SUMS-Windows.txt`。

---

## 🚀 Quick Start

### 1. 初始化与模型配置

在 PowerShell 中输入 `ai` 打开交互式终端菜单：

```powershell
ai
```
选择 `1. Models` -> 添加你的模型 API Key（支持 OpenAI / Claude / Gemini / Ollama 等）。

### 2. 交互使用

```powershell
# 自由沟通（直接输出解答，零菜单、不调工具）
ai 你好
ai 什么是递归函数？请举例说明

# 操作指令（生成原生命令，附带六要素与批准菜单）
ai 帮我查找当前目录下大于 100MB 的文件
ai 查看本机内网 IP 地址

# 一键清空当前会话上下文
ai clear

# 创建并切换到全新会话
ai new "项目排障会话"

# 切换工作模式
ai mode Auto     # 智能双轨模式（推荐）
ai mode AI       # 纯 AI 对话模式
ai mode Off      # 原生 PowerShell 模式

# 查看命令行帮助
ai help
```

### 3. 全局快捷键

| 快捷键 | 功能说明 | 使用方式 |
| :--- | :--- | :--- |
| **F2** | **强制 AI 请求** | 输入内容后不按回车，直接按 F2，强制交给 AI 解答/生成 |
| **F3** | **强制 Shell 执行** | 输入内容后不按回车，直接按 F3，强制按原生 PowerShell 执行 |
| **F6** | **轮询切换模式** | 在 `Off` / `AI` / `Auto` 模式间循环切换 |
| **F7** | **解释最近命令** | 深度解读最近一次执行的命令或其输出结果 |

> 部分笔记本需配合 `Fn + F2`、`Fn + F7` 使用。

---

## ⚙️ Operating Modes

### 1. Auto 模式（推荐，默认智能双轨）

- **PowerShell 命令**：语法正确时直接以原生零延迟执行。
- **命令执行失败 / 语法错误**：AI 自动介入，**先诊断为什么执行不成功**，随后给出六要素修复命令与 `1-3` 批准菜单，支持一键修复。
- **自然语言输入**：
  - 问候 / 概念咨询 / 纯文本疑问 → 直接自然语言解答（零菜单、不调工具）。
  - 系统操作指令 → 生成极简原生命令，输出六要素与三项批准菜单。
- **单步完结保护**：操作成功后立即结束并提示 `◆ ✓ 命令已完成 · F7 解释`，严禁擅自发散搜索。

### 2. AI 模式

- 无论输入什么内容，均先提交给 AI 处理。

### 3. Off 模式

- 纯原生 PowerShell 终端模式，所有输入均直接按原生 PowerShell 执行。

---

## 🖥️ Compatibility

当前版本支持：

- Windows PowerShell 5.1 (x64/x86)
- PowerShell 7.4+

当前 `1.0.3` 发布仅支持 Windows PowerShell 5.1（x64/x86）和 PowerShell 7.4 及以上。

当前发布版本：

- Windows only

Linux/macOS 实现暂不属于当前发布范围。

---

## 🔧 Storage & Configuration

Windows PowerShell 5.1 与 PowerShell 7 共用以下配置和运行数据：

| 平台 | 配置目录 | 数据目录 |
| --- | --- | --- |
| Windows | `<Documents>/PowerShell/PSAITerminal` | `%LOCALAPPDATA%/PowerShell/PSAITerminal` |

> 敏感凭据（API Keys）由 Windows 凭据管理器（Credential Manager）统一加密托管，不会写入 JSON 配置文件。

---

## 📚 Common Commands

```powershell
# 模型管理
Get-PSAIModel                  # 列出已配置的模型
Set-PSAIDefaultModel           # 设置默认模型

# 会话与任务管理
Get-PSAISession                # 查看持久化会话列表
Clear-PSAISession              # 清空当前激活会话的上下文
New-PSAISession                # 创建并激活新会话
Get-PSAIRun                    # 查看运行记录与检查点
ai resume <RunId>              # 恢复执行中断的 Run

# 配置检测
Test-PSAIConfiguration         # 诊断当前配置与环境状态
```

---

## 🛠 Development

```powershell
# 编译并打包 Release
./build.ps1 -Restore -Configuration Release -Package

# 运行自动化全量回归测试套件（支持跨版本双验）
powershell -NoProfile -File ./tests/run.ps1   # Windows PowerShell 5.1
pwsh -NoProfile -File ./tests/run.ps1         # PowerShell 7.x
```

---

## 📄 License

本项目采用 [MIT License](LICENSE) 许可证。
