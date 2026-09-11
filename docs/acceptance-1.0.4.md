# 1.0.4 本地手动验收

这是未发布候选。不要先覆盖正式模块、Profile 或真实配置。自动测试使用模拟模型；你的实际模型仍需以下验收。

## 打开隔离终端

分别打开 Windows PowerShell 5.1 和 PowerShell 7。为避免加载已安装旧模块，启动时使用 `-NoProfile`，然后粘贴：

```powershell
$testRoot = Join-Path $env:TEMP ('PSAI.Manual.' + [guid]::NewGuid().ToString('N'))
$env:PSAI_CONFIG_HOME = Join-Path $testRoot 'config'
$env:PSAI_DATA_HOME = Join-Path $testRoot 'data'
Import-Module 'C:\Users\LXT\Desktop\PSAITerminal\out\PSAITerminal-1.0.4\PSAITerminal.psd1'
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
| `$x = )` | 先解释语法错误，再提议修复并审批；未闭合输入仍允许 PowerShell 续行 |
| 在菜单选编辑，将只读命令改为 `Get-Location` | 四项说明重新生成，旧说明不残留，需重新批准 |
| 编辑说明请求时让测试模型不可用 | 显示“无法评估”，选批准也不能执行；可重新编辑或拒绝 |
| 拒绝任一提议 | Run 显示 Cancelled，没有执行该命令 |
| F7 | 仅这时请求最近实际执行命令及输出的解释 |
| F2、F3、F6 | AI、Shell、模式快捷键仍可用；菜单无持续刷屏 |
| `Remove-Module PSAITerminal` | 原有输入读取和快捷键恢复 |
| 输入 `ai`，选择 `7. 卸载 PSAITerminal` | 出现二次确认与清除数据选项；取消可安全退回，确认后剥离 Profile 并排队清理 |

## 失败恢复（仅测试工作目录）

要求模型在当前测试目录演示“写入临时文件后报错，再恢复并重试”。审批前检查原操作、清理与重试都只针对测试文件。观察：

1. 部分成功后报错必须显示失败，诊断保存真实输出。
2. 如模型提出清理，清理命令单独审批；清理成功不显示整个任务完成，而是回到原步骤。
3. 如清理也失败，任务暂停，不自动继续。用 `Get-PSAIRun` 找到 ID，再输入 `ai resume <ID>` 才继续。
4. 重试成功且满足末步完成条件后，才显示“命令已完成”。
5. 执行期间中断的任务禁止自动重放：先核实文件等实际状态，再用 `Resolve-PSAIRun -Id <ID> -Outcome NotExecuted|Succeeded|Failed -Output '核实结果'` 明确确认（Outcome 只能选一个）。

恢复方案依赖模型判断，并不保证发现全部副作用或恢复成功。不要用真实数据制造故障。

记录每个宿主的版本、模型协议、输入、审批内容和实际结果。发现问题时保留脱敏后的输出与 Run ID；不要发布密钥。关闭窗口后隔离配置不会影响正常终端，但测试目录会保留，确认无用后可自行删除该精确目录。
