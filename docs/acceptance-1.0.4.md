# 1.0.4 本地手动验收

这是未发布候选。不要先覆盖正式模块、Profile 或真实配置。自动测试使用模拟模型；你的实际模型仍需以下验收。

## 打开隔离终端

分别打开 Windows PowerShell 5.1 和 PowerShell 7。为避免加载已安装旧模块，启动时使用 `-NoProfile`，然后粘贴：

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

在设置里添加测试模型；密钥选择“仅当前会话”，不要在聊天或测试记录中粘贴密钥。切换 Auto 模式。审批屏不是沙箱，仍须检查命令：文件操作只能针对刚创建的测试工作目录，拒绝任何真实目录、系统或网络设置修改。

## 验收清单

| 输入或操作 | 预期 |
|---|---|
| `你好` | 纯文本回复，无审批菜单 |
| `解释一下进程和线程的区别` | 概念回答，无工具 |
| `这个怎么办？` | 简短澄清，不生成命令；重新输入完整需求 |
| `查本机 IP` | 六项说明；批准后完成，无自动长总结 |
| `创建含说明文件且校验正确的压缩包` | 先展示完整计划；每次只批准当前命令，首步不会提前完成 |
| `$x = )` | 先解释语法错误，再提议修复并审批 |
| AI 模式输入 `Get-Date`，按 Enter | 先交给 AI，每次提交一次；F3 才明确执行原命令 |
| AI 模式输入 `if ($true) {`，分别按 Enter/F2 | 原文一次性提交诊断，不陷入原生续行，历史保留原文 |
| Auto/Off/F3 输入未闭合代码；Shift+Enter | 原生续行和多行编辑仍可用 |
| `请问什么是进程` / `请问进程和线程有什么区别` | 概念回答，无工具、无 Run |
| 在菜单选编辑，将只读命令改为 `Get-Location` | 四项说明重新生成，旧说明不残留，需重新批准 |
| 编辑说明请求时让测试模型不可用 | 显示“无法评估”，选批准也不能执行；可重新编辑或拒绝 |
| 拒绝任一提议 | Run 显示 Cancelled，没有执行该命令 |
| F7 | 仅这时请求最近实际执行命令及输出的解释 |
| F2、F3、F6 | AI、Shell、模式快捷键仍可用；菜单无持续刷屏 |
| `Remove-Module PSAITerminal` | 原有输入读取和快捷键恢复 |
| 在临时安装副本输入 `ai`，选择 `7. 卸载 PSAITerminal` | 可取消；确认后清理指定数据和 Profile；DLL 占用时明确失败，关闭终端后用独立脚本重试 |

## 本轮自动门禁与外部验收边界

使用本次源码新构建的包运行 `tests/run.ps1`，覆盖 Windows PowerShell 5.1 x64/x86 和 CI 固定的 PowerShell 7.6.4。`hardening.ps1` 验证两进程会话/修订号、退出码、提议缺字段、敏感命令、别名重绑定、Win32 错误码与锁释放，以及随机合成凭据的普通卸载/Purge；`resources.ps1` 使用内存 HTTP 响应验证正文失败、超限、等待取消和迟到流释放。ConPTY 覆盖 5.1 x64/7.6.4 的 AI 普通输入、Enter/F2/F3、原文历史、取消、咨询和原生续行。

卸载自动测试只针对随机临时模块副本、Profile、配置和凭据目标，验证 `-Force -WhatIf` 无清理副作用、危险路径/链接被拒绝、无关文件保留及失败报错。普通卸载保留凭据，Purge 仅删除当前配置名称对应的目标；`CredentialsPurged` 按实际结果填写。真实凭据、已安装模块、真实 Profile 和人工终端体验需要单独验收，不能由自动回归代替。在线模型、远程 CI、上传、发布与版本升级不属于本轮本地交付。

## 失败恢复（仅测试工作目录）

要求模型在当前测试目录演示“写入临时文件后报错，再恢复并重试”。审批前检查原操作、清理与重试都只针对测试文件。观察：

1. 部分成功后报错必须显示失败，诊断保存真实输出。
2. 如模型提出清理，清理命令单独审批；清理成功不显示整个任务完成，而是回到原步骤。
3. 如清理也失败，任务暂停，不自动继续。用 `Get-PSAIRun` 找到 ID，再输入 `ai resume <ID>` 才继续。
4. 重试成功且满足末步完成条件后，才显示“命令已完成”。
5. 执行期间中断的任务禁止自动重放：先核实文件等实际状态，再用 `Resolve-PSAIRun -Id <ID> -Outcome NotExecuted|Succeeded|Failed -Output '核实结果'` 明确确认（Outcome 只能选一个）。

恢复方案依赖模型判断，并不保证发现全部副作用或恢复成功。不要用真实数据制造故障。

记录每个宿主的版本、模型协议、输入、审批内容和实际结果。发现问题时保留脱敏后的输出与 Run ID；不要发布密钥。关闭窗口后隔离配置不会影响正常终端，但测试目录会保留，确认无用后可自行删除该精确目录。
