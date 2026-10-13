# PSAITerminal

[![CI](https://github.com/2061863797/PSAITerminal/actions/workflows/windows-release.yml/badge.svg)](https://github.com/2061863797/PSAITerminal/actions/workflows/windows-release.yml)

> AI-powered terminal assistant for Windows PowerShell.

PSAITerminal 是一个原生运行在 PowerShell 中的智能终端助手。

它提供咨询、操作、待澄清三类自然语言路由、原生命令提议、六要素审批、结构化计划推进和需要审批的失败恢复。AI 说明可能有误，执行前仍需核对命令。

---

## ✨ Features

### 🤖 智能终端路由

- **自由沟通流（纯文本无工具）**：
  - 识别明确的日常问候（如“你好”）和概念咨询（如“解释一下进程和线程的区别”）。
  - 直接输出自然流畅的文本回答，**严禁调用工具，绝不创建 Agent 状态机，零菜单打扰**。
- **本地操作指令流（最简原生命令提议）**：
  - 用户发出操作诉求（如“查本机内网IP”、“列出占用8080端口的进程”、“清理临时文件”）。
  - AI 提议最简原生 PowerShell 命令，执行前严格呈现**六要素安全契约**。
- **单步完结保护机制（Anti-Overreach）**：
  - 已校验计划的末步成功后，立即标记 `Completed`，输出 `◆ ✓ 命令已完成 · F7 解释`，不再追加模型请求。
  - 非末步只显示“步骤完成”，将真实输出交给模型提出下一步；需要验证产物时必须在计划中保留验证步骤。
- **待澄清输入**：无法确定咨询还是操作时，只显示简短问题，请重新输入完整需求；不调用模型、不创建待执行命令。
- **执行完成静默策略与 F7 深度解读**：
  - 命令正常执行成功后不再自动输出长篇冗长文本，避免刷屏；需要深入理解时，随时按下 **F7** 获取专业剖析。
- **新终端自动上下文隔离**：
  - 每次打开新终端创建独立会话，保留已有历史；导入、新建和切换会话不改写共享配置。

### 🛡️ 严格安全审计（六要素与统一三项批准菜单）

执行任何生成的命令前，AI 必须完整呈现**六要素安全契约**：

1. **目的 (Purpose)**：明确该命令意图
2. **命令 (Command)**：待执行的完整原生命令
3. **预期 (Expected Outcome)**：执行后的预期结果
4. **副作用 (Side Effects)**：可能带来的状态变更或资源影响
5. **回滚 (Rollback)**：失败或撤销时的操作建议
6. **风险 (Risk)**：本地确定性规则计算 `Low` / `Medium` / `High`，不采信模型风险评级

> **重要说明**：这不是自动回滚功能：界面显示的回滚内容是 AI 生成的操作建议；模块不会自动备份、撤销或恢复系统状态。

随后弹出统一精简的**三项批准菜单**：
```text
1. 批准执行
2. 编辑命令
3. 拒绝执行
```
- 低、中风险默认批准；高风险没有默认批准，并要求二次确认。按 `2` 重新输入命令，按 `3` 取消任务。
- 编辑后撤销旧批准，禁用工具请求新的目的、预期、副作用和回滚说明；生成失败显示“无法评估”并暂停批准，可继续编辑或拒绝。
- 批准绑定命令、四项说明、计划与推进信息及 Run 修订号；执行前重新读取磁盘记录校验，内容变化必须重新批准。

### 🔧 语法错误与执行失败闭环自愈

- **先诊断根因，再提议修复**：
  - 当检测到输入代码存在语法错误，或者执行的命令抛出异常、以非零状态码失败退出时：
  - **AI 首先输出明确解释**：剖析为什么执行不成功、语法错误或参数不匹配的根本原因；
  - **随后完整输出修复命令的六要素**，并弹出统一三项批准菜单供一键批准执行。
- **回滚优先机制 (Rollback First)**：
  - AI 评估可能副作用并提出清理或重试方案；模块不能检测全部副作用，也不保证恢复成功。
  - 正常执行、清理恢复、重试原步骤分别持久保存。清理成功回到原步骤，清理失败进入 `Paused`，等待显式 `ai resume <RunId>`；清理、回滚、重试都必须审批并计入最大步骤数。
  - 失败显示“命令执行失败”，不会显示成功完成文案；F7 只在主动触发时解释最近实际命令和输出。

### 🧠 目标驱动自主规划 (Agent Mode)

- **复合长任务规划**：面对用户提出的目标诉求（如“先备份，再压缩，最后校验哈希”），AI 自动规划清晰的分步执行序列，每一步均严格遵循六要素与三项批准。
- Run 格式为版本 2，保存计划摘要、完成条件、步骤角色、结果与恢复阶段。旧的已完成 Run 可查看；旧的未完成 Run 恢复时重新规划和批准。执行中断、结果不确定的 Run 必须先用 `Resolve-PSAIRun` 明确确认，不能自动重放。
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

当前版本为 [`1.0.4`](https://www.powershellgallery.com/packages/PSAITerminal/1.0.4)。手动隔离验收参见 [手动验收清单](docs/acceptance-1.0.4.md)。

本轮整改尚未发布，源码版本仍为 `1.0.4`，内容记录在更新日志的“未发布”章节。以下 AI 输入和 Purge 行为适用于本次源码构建的候选包。

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

### 一键卸载

PSAITerminal 提供多种极简卸载方式：

1. **终端设置菜单一键卸载（最推荐）**：
   在终端输入 `ai`（或 `Configure-PSAI`），在主菜单中选择 `7. 卸载 PSAITerminal`，按提示交互式完成 Profile 剥离、数据保留/清除以及文件卸载。

2. **命令行直接调用内置命令**：
   ```powershell
   # 卸载当前模块并清理 Profile（默认保留用户配置与密钥）
   Uninstall-PSAITerminal

   # 同时清理已确认的配置、会话、Run 和配置模型对应的凭据
   Uninstall-PSAITerminal -PurgeUserData
   ```

3. **使用独立卸载脚本**：
   ```powershell
   # 卸载当前宿主模块并自动清理 Profile 自动加载块
   .\Uninstall-PSAITerminal.ps1 -TargetHost Current

   # 同时清理已确认的数据和配置模型对应的凭据
   .\Uninstall-PSAITerminal.ps1 -TargetHost Current -PurgeUserData

   # 同时清理 Windows PowerShell 5.1 与 PowerShell 7 中的安装
   .\Uninstall-PSAITerminal.ps1 -TargetHost Both
   ```

两个入口均先只读预检，再执行 `ShouldProcess`。`-Force -WhatIf` 不修改文件或凭据，`-Force` 仍遵守显式 `-Confirm`。相对路径、磁盘根目录、系统及用户基础目录和重解析点会被拒绝；无法确认归属的数据停止清理。Purge 保留目录中的无关文件，只删除当前配置模型名称对应的 `PSAITerminal/Model/<名称>` 凭据，不枚举或清理其他凭据。凭据删除失败时保留配置以便重试；`CredentialsPurged` 仅在请求 Purge 且全部目标已删除或不存在时为 `true`。

Windows 可能锁定当前宿主加载的 DLL。内置卸载若无法删除程序集会报错，并保留模块清单与独立脚本。关闭占用模块的终端，再打开 `pwsh -NoProfile` 或 `powershell -NoProfile` 运行独立卸载脚本；该脚本在无 Profile 子进程清理凭据，子进程退出后才删除模块文件。

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
- **计划完结保护**：单步或多步计划的末步成功后直接结束并提示 `◆ ✓ 命令已完成 · F7 解释`；清理成功和普通步骤成功不会提前结束任务。

### 2. AI 模式

- 普通输入全部先交给 AI，包括合法 Shell 命令和不完整代码；Enter/F2 每次只提交一次，保留输入原文。
- F3 明确执行 Shell，`ai` 元命令保持控制语义。Auto/Off/F3 保留原生续行，Shift+Enter 保留多行编辑。
- 明确咨询（包括“请问什么是进程”）只回答，不携带工具、不创建 Run；Auto 模式的模糊输入仍在本地澄清。

工具提议的原生调用、正文 JSON 和 YAML 使用同一套必需字段校验。缺失说明、计划或完成条件时最多请求一次修复，第二次无效就停止；首次无效计划不会固定到 Run。命令超过 16384 字符或包含会被脱敏规则改写的内容时直接拒绝，请改用变量或凭据引用。编辑后的四项说明支持纯 JSON 对象或完整包裹于单个 JSON 代码块的对象，额外文字、工具调用或无效字段仍会阻止批准。

### 3. Off 模式

- 纯原生 PowerShell 终端模式，所有输入均直接按原生 PowerShell 执行。

---

## 🖥️ Compatibility

当前版本支持：

- Windows PowerShell 5.1 (x64/x86)
- PowerShell 7.4+

当前 `1.0.4` 发布仅支持 Windows PowerShell 5.1（x64/x86）和 PowerShell 7.4 及以上。

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
