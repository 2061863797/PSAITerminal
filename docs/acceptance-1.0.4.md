# 本地手动验收

这是未发布候选。不要覆盖正式安装、Profile 或真实配置。自动测试使用模拟模型，真实模型和真实终端体验仍需按下面的清单验收。

## 打开隔离终端

分别打开 Windows PowerShell 5.1 和 PowerShell 7。为避免加载已安装的旧模块，启动时使用 `-NoProfile`，然后粘贴：

```powershell
$testRoot = Join-Path $env:TEMP ('PSAI.Manual.' + [guid]::NewGuid().ToString('N'))
$env:PSAI_CONFIG_HOME = Join-Path $testRoot 'config'
$env:PSAI_DATA_HOME = Join-Path $testRoot 'data'
$package = 'C:\Users\LXT\Desktop\PSAITerminal\out\PSAITerminal-1.0.4'
$moduleRoot = Join-Path $testRoot 'modules'
New-Item -ItemType Directory -Path $moduleRoot,(Join-Path $testRoot 'profile') -Force | Out-Null
Copy-Item -LiteralPath $package -Destination (Join-Path $moduleRoot 'PSAITerminal') -Recurse
$PROFILE.CurrentUserCurrentHost = Join-Path $testRoot 'profile/current.ps1'
$PROFILE.CurrentUserAllHosts = Join-Path $testRoot 'profile/all.ps1'
Import-Module (Join-Path $moduleRoot 'PSAITerminal/PSAITerminal.psd1')
New-Item -ItemType Directory -Path (Join-Path $testRoot 'work') -Force | Out-Null
Set-Location (Join-Path $testRoot 'work')
ai
```

在设置里添加测试模型；密钥选择“仅当前会话”，不要在聊天或测试记录中粘贴密钥。然后输入 `ai mode Auto`。确认菜单不是沙箱，仍须检查命令：文件操作只能针对刚创建的测试工作目录，拒绝任何真实目录、系统或网络设置的修改。

## 验收清单

| 输入或操作 | 预期 |
|---|---|
| `你好`、`解释一下进程和线程的区别` | 模型直接用文字回答，不出现确认菜单 |
| `磁盘空间还剩多少`、`这个文件夹有多大` | 交给模型；模型提议查询命令，风险为 Low，回车即执行，随后用一两句话给出结论 |
| `查本机 IP` | 提议 `Get-NetIPAddress` 或 `ipconfig`，风险为 Low，不要求二次确认 |
| `gti status` | 交给模型，模型指出拼写错误并提议 `git status` |
| `$x = )` | 模型说明语法错误并提议修正 |
| 让模型删除测试目录中的某个文件 | 风险为 High，菜单没有 `[A]`，回车不执行，选 Y 后要求二次确认 |
| 对一条中风险命令选 `A`，再让模型做类似操作 | 同名命令不再询问，显示“已自动允许” |
| 对一条命令选 `E` | 命令出现在下一次输入行，可编辑；回车按当前模式处理（AI 模式下用 F3 执行） |
| 对一条命令选 `N` 并输入“换一种方法” | 模型根据反馈重新提议，原命令没有执行 |
| 对一条命令选 `N` 直接回车 | 任务取消，没有执行 |
| Auto 模式执行 `Get-Item 不存在的文件` | 出现“命令失败 · 按 F7 诊断修复”；按 F7 后模型解释原因并提议修复 |
| Auto 模式执行 `robocopy` 成功复制（退出码 1） | 不会自动请求 AI |
| Auto 模式执行 `using namespace System.IO` | 原样执行，不报内部错误 |
| 成功执行一条命令后按 F7 | 模型解释该命令，不调用工具 |
| AI 模式输入 `Get-Date` 回车 | 交给 AI；F3 才直接执行 |
| Auto/Off/F3 输入未闭合代码；Shift+Enter | 原生续行和多行编辑可用 |
| `Set-PSAITerminalOption -AutoApprove 'Get-*'` 后让模型查询进程 | `Get-*` 命令不再询问；高风险命令仍然询问 |
| 使用 oh-my-posh 或 starship 等提示符，执行一条失败命令 | 提示符正确显示失败状态 |
| F2、F3、F6 | 快捷键可用，菜单不持续刷屏 |
| `Remove-Module PSAITerminal` | 原有输入读取、Prompt 和快捷键恢复 |
| 在临时安装副本中输入 `ai`，选择卸载 | 可以取消；确认后清理指定数据和 Profile；DLL 被占用时明确报错，关闭终端后用独立脚本重试 |
| 用 1.0.4 的配置（含 Gemini 或 Ollama 模型）启动 | 提示模型已迁移到 OpenAI 兼容接口，迁移后可以正常对话 |

## 自动门禁与外部验收边界

`tests/run.ps1` 在 Windows PowerShell 5.1 x64/x86 和 PowerShell 7 上运行全部回归：
- 风险分级表；
- 路由；
- 配置迁移；
- 端到端 Agent 场景：执行、拒绝与反馈、本会话允许、放入命令行、步数上限、无效提议修复；
- 卸载安全；
- 资源释放。

ConPTY 冒烟在真实伪终端中验证：
- Enter/F2/F3/F7；
- 放入命令行；
- 失败提示；
- Auto 模式下的自然语言；
- 原生续行与历史。

真实模型、真实凭据、已安装模块、真实 Profile 和人工终端体验需要按上面的清单单独验收，不能由自动回归代替。

记录每个宿主的版本、模型服务商、输入、确认菜单内容和实际结果。发现问题时保留脱敏后的输出，不要发布密钥。关闭窗口后隔离配置不会影响正常终端；测试目录会保留，确认无用后可自行删除该目录。
