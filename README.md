# PSAITerminal

[![CI](https://github.com/2061863797/PSAITerminal/actions/workflows/windows-release.yml/badge.svg)](https://github.com/2061863797/PSAITerminal/actions/workflows/windows-release.yml)

> AI-powered terminal assistant for Windows PowerShell.

PSAITerminal 是直接运行在 PowerShell 里的 AI 助手。你可以用自然语言提问或描述要做的事，模型决定是直接回答，还是提议一条 PowerShell 命令；每条命令都要经过你确认才会执行，执行结果会交回模型继续推进，直到任务完成。

支持 Windows PowerShell 5.1（x64/x86）和 PowerShell 7.4+，仅限 Windows。

---

## 安装

```powershell
Install-Module -Name PSAITerminal -Repository PSGallery -Scope CurrentUser
```

PowerShell 7 也可以用 `Install-PSResource -Name PSAITerminal -Repository PSGallery -Scope CurrentUser`。使用 GitHub Release 安装包时运行 `.\Install-PSAITerminal.ps1 -TargetHost Current`（`-TargetHost Both` 同时安装到 5.1 和 7）。

当前版本为 [`2.0.1`](https://www.powershellgallery.com/packages/PSAITerminal/2.0.1)，变更见 [更新日志](CHANGELOG.md)。从 1.0.x 升级是不兼容升级：请同时升级 Windows PowerShell 5.1 和 PowerShell 7 中的安装（`-TargetHost Both`），旧模型配置会自动迁移。

> 发布包未做 Authenticode 签名。手动安装时请核对 Release 附带的 `SHA256SUMS-Windows.txt`。

## 快速开始

1. 输入 `ai` 打开设置菜单，选择“模型配置”→ 新增模型，选择服务商并填写 API Key。
2. 输入 `ai mode Auto` 切换到推荐的 Auto 模式（新安装默认是 Off）。
3. 直接输入问题或任务：

```powershell
磁盘空间还剩多少
查看本机内网 IP
把当前目录下大于 100MB 的文件列出来
ai 什么是递归函数        # 任何模式下都可以用 ai 前缀显式交给 AI
```

## 工作方式

### 模式

| 模式 | 输入如何处理 |
| --- | --- |
| **Auto**（推荐） | 能直接执行的 PowerShell 命令原样执行；自然语言、拼错的命令、语法错误交给 AI。 |
| **AI** | 所有输入都交给 AI，包括合法命令和未写完的代码。 |
| **Off** | 普通 PowerShell，所有输入直接执行。 |

Auto 只判断“这是不是能执行的命令”，不猜你是想咨询还是想操作；由模型决定直接回答还是提议命令。未写完的代码在 Auto 和 Off 下保持 PowerShell 原生续行。以命令名开头的英文句子（例如 `where is my file`）会被当成命令执行，这时用 F2 交给 AI。

### 执行确认

模型提议命令时显示目的、完整命令和本地计算的风险等级：

```text
目的：查询本机 IPv4 地址
  Get-NetIPAddress -AddressFamily IPv4
风险：Low
[Y] 执行  [A] 本会话总是允许 Get-NetIPAddress  [E] 放入命令行编辑  [N] 拒绝
```

- **Y**：执行。低、中风险直接回车即执行；高风险没有默认项，并要求再确认一次。
- **A**：执行，并在本次 PowerShell 会话内对同名命令免确认。高风险命令不提供此选项。
- **E**：不执行，把命令放进下一次的输入行，你修改后自己回车。
- **N**：拒绝。可以附一句话告诉 AI 怎么改，它会重新提议；直接回车则取消任务。

命令在你当前的 PowerShell 会话里执行（`cd`、变量、函数都会保留），输出交回模型，模型据此继续下一步或用一两句话结束。单个任务最多执行 12 条命令（`Set-PSAITerminalOption -MaxAgentSteps` 可调）。

### 风险等级

风险由本地规则计算，不采信模型的判断：

- **Low**：查询类命令（`Get-*`、`Test-*`、`Select-*` 等）、`cd`，以及 `ipconfig`、`ping`、`whoami`、`git status/log/diff` 等只读工具。
- **High**：删除、停止、卸载、清空（`Remove-*`、`Stop-*`、`rm`、`del`、`taskkill` 等），`Invoke-Expression`、下载后执行、嵌套 `cmd`/`powershell`，注册表、服务、磁盘操作，`git clean`、`git reset --hard`、强制推送等。
- **Medium**：其余命令，包括写文件、新建、安装、启动程序和未知命令。

会话里重新绑定的别名、覆盖了内置命令的函数，按实际目标重新分级。

### 免确认列表

可以让常用的中低风险命令免确认，高风险命令始终需要确认：

```powershell
Set-PSAITerminalOption -AutoApprove 'Get-*', 'git status', 'git log', 'Select-String'
Set-PSAITerminalOption -AutoApprove @()      # 清空
```

`git`、`npm`、`dotnet`、`docker`、`winget` 等工具按“工具 子命令”匹配，允许 `git status` 不会放行 `git checkout`。命令中含有重定向（`>`）、变量赋值或 .NET 方法调用时，总是需要确认。

### 失败时诊断

Auto 和 AI 模式下，命令执行失败后提示 `命令失败 · 按 F7 诊断修复`。按 F7，AI 会先说明原因，再提议修正命令，同样需要你确认。不会自动调用模型。

## 快捷键

| 快捷键 | 作用 |
| --- | --- |
| **F2** | 把当前输入交给 AI |
| **F3** | 把当前输入按 PowerShell 执行 |
| **F6** | 在 Off / AI / Auto 之间切换 |
| **F7** | 上一条命令失败时诊断并修复；成功时解释它做了什么 |

部分笔记本需要配合 Fn 键。

## 模型

新增模型时可选择 OpenAI、Anthropic、Google Gemini、DeepSeek、本机服务（Ollama、LM Studio）或其他 OpenAI 兼容服务。除 Anthropic 外都使用 OpenAI 兼容接口；接口地址已含版本段（如 `/v1`、`/api/v3`）时原样使用，否则自动补 `/v1`。本机地址（`127.0.0.1`、`localhost`）可以不填 API Key。

API Key 保存在 Windows 凭据管理器中，不写入配置文件。

## 常用命令

```powershell
ai                       # 设置菜单
ai help                  # 命令行帮助
ai clear                 # 清空当前会话上下文
ai new "排障"            # 新建会话
ai mode Auto             # 切换模式
Get-PSAIModel            # 查看模型
Select-PSAIModel <名称>  # 切换当前模型
Test-PSAIConfiguration   # 检查配置、凭据和集成状态
Get-PSAIIntegrationStatus
```

## 存储

| 内容 | 位置 |
| --- | --- |
| 配置 | `<Documents>/PowerShell/PSAITerminal` |
| 会话 | `%LOCALAPPDATA%/PowerShell/PSAITerminal` |

Windows PowerShell 5.1 和 PowerShell 7 共用配置和会话。每个新终端使用独立会话；发给模型的上下文按模型窗口截取最近的轮次。

## 卸载

```powershell
Uninstall-PSAITerminal                  # 卸载并移除 Profile 自动加载，保留配置和凭据
Uninstall-PSAITerminal -PurgeUserData   # 同时删除已确认的配置、会话和模型凭据
.\Uninstall-PSAITerminal.ps1 -TargetHost Both
```

也可以在 `ai` 设置菜单中选择“卸载”。卸载前会先做只读检查：拒绝相对路径、磁盘根、系统和用户基础目录、重解析点，只删除能确认属于 PSAITerminal 的文件和 `PSAITerminal/Model/<名称>` 凭据。当前终端已加载的 DLL 可能无法删除，此时关闭终端，在 `pwsh -NoProfile` 中运行独立卸载脚本即可。

## 安全说明

- 命令以当前用户权限在当前 PowerShell 会话中执行，不是沙箱。
- 风险分级和“目的”说明只是辅助，确认前请看完整命令。
- 会被脱敏规则改写的命令（含密钥、密码等字面量）会被拒绝执行，请改用变量或凭据引用。

## 开发

```powershell
./build.ps1 -Restore -Configuration Release -Package
powershell -NoProfile -File ./tests/run.ps1   # Windows PowerShell 5.1
pwsh -NoProfile -File ./tests/run.ps1         # PowerShell 7
```

模块源码按职责拆分在 `module/Private`，构建时按文件名顺序合并为单个 `PSAITerminal.psm1`。

## License

[MIT](LICENSE)
