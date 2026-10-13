# 上下文压缩、工具调用、计划纠偏与顶层 Agent 包装。
# 由 tests/run.ps1 在同一作用域内按文件名顺序点源执行，依赖其中的 $module、$testRoot 等状态，不能单独运行。

# 上下文达到预算后应自动摘要，并保留最近轮次。
New-PSAISession -Title '压缩测试' | Out-Null
& $module { 1..10 | ForEach-Object { Add-AISessionTurn 'user' ("第 $_ 轮 " + ('x' * 900)) 'message' | Out-Null } }
Set-PSAITerminalOption -ContextBudgetPercent 50 -RecentTurns 2 | Out-Null
$summaryResponse = ConvertTo-AIMockSse '保留目标与关键结果的压缩摘要。'
$server = Start-AIMockServer @($summaryResponse)
try {
    Set-PSAIModel -Name local -Endpoint ([uri]"http://127.0.0.1:$($server.Port)") -ContextWindow 1024 | Out-Null
    & $module { $model=Get-AIActiveModel; Compress-AISessionIfNeeded $model ([Threading.CancellationToken]::None) }
    $compression = & $module { [pscustomobject]@{Count=[int]$script:CurrentSession.compactedTurnCount;Summary=[string]$script:CurrentSession.summary} }
    Assert-Equal 8 $compression.Count '压缩后应保留最近 2 个 Turn。'
    Assert-Match $compression.Summary '压缩摘要' '压缩摘要必须持久化。'
} finally { Stop-AIMockServer $server }

# 原生工具调用、多步骤观察和 Run 检查点。
$toolArguments = [ordered]@{purpose='读取日期';command='Get-Date';expectedOutcome='显示当前日期';sideEffects='无';rollbackHint='无需回滚';plan=$singlePlan;stepIndex=1;stepRole='Operation';afterSuccess='Complete'}
$invalidToolArguments = [ordered]@{purpose='读取日期';command='Get-Date';expectedOutcome='显示当前日期';sideEffects='无'}
$invalidToolResponse = ConvertTo-AIMockSse -ToolArguments $invalidToolArguments -ToolCallId 'call-invalid'
$toolResponse = ConvertTo-AIMockSse -ToolArguments $toolArguments -ToolCallId 'call-1'
$finalResponse = ConvertTo-AIMockSse '任务已完成。'
$proposalServer = Start-AIMockServer @($invalidToolResponse,$toolResponse)
$finalServer = Start-AIMockServer @($finalResponse)
try {
    Set-PSAIModel -Name local -Endpoint ([uri]"http://127.0.0.1:$($proposalServer.Port)") -Capabilities @{streaming=$true;toolCalling=$true;usage=$false} | Out-Null
    New-PSAIModel -Name alternate -Protocol OpenAIChat -Endpoint ([uri]"http://127.0.0.1:$($finalServer.Port)") -ModelId qwen3 `
        -Capabilities @{streaming=$true;toolCalling=$true;usage=$false} | Out-Null
    function global:Read-Host { param([Parameter(ValueFromRemainingArguments)]$Arguments) [void]$Arguments; '' }
    try { $step = Start-PSAIRun -Task '告诉我当前日期' }
    finally { Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue }
    Assert-True ($null -ne $step) '模型工具调用应产生待执行步骤。'
    Assert-Match ([string]$step.ApprovalDigest) '^[a-f0-9]{64}$' '待执行步骤必须绑定已批准命令的 SHA-256 摘要。'
    Assert-True ([long]$step.ApprovalRevision -gt 0) '待执行步骤必须绑定批准时的 Run 修订号。'
    Select-PSAIModel alternate | Out-Null
    Start-PSAIToolExecution -RunId $step.RunId -StepId $step.StepId `
        -Command $step.Command -ApprovalDigest $step.ApprovalDigest -ApprovalRevision $step.ApprovalRevision
    $next = Complete-PSAIToolExecution -RunId $step.RunId -StepId $step.StepId -Succeeded $true -Output '2026-08-11'
    Assert-Equal $null $next '单步成功后不应继续请求模型或工具步骤。'
    Assert-Equal 'Completed' (Get-PSAIRun -Id $step.RunId).State '单步成功必须直接完成。'
    Assert-Equal 'alternate' (Get-PSAIModel | Where-Object Active).Name '模型切换应在下一步骤生效且保持同一 Run。'
    Remove-PSAIModel -Name alternate -ReplacementModel local -Confirm:$false
} finally {
    Stop-AIMockServer $proposalServer; Stop-AIMockServer $finalServer
    Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
}

# 正文 Markdown / 裸 JSON 工具调用容错提取与计划自适应纠偏测试
$markdownToolText = @'
发现变量赋值存在语法错误，未闭合的括号导致异常。

```json
{
  "purpose": "检查并恢复变量环境",
  "command": "Get-Variable -Name x -ErrorAction SilentlyContinue",
  "expectedOutcome": "安全检查变量 x 的状态",
  "sideEffects": "无",
  "rollbackHint": "无需回滚",
  "plan": {
    "mode": "Single",
    "steps": [
      "检查变量 x 状态",
      "验证输出与环境正常"
    ],
    "completionCondition": "命令正常完成"
  },
  "stepIndex": 1,
  "stepRole": "Operation",
  "afterSuccess": "Observe"
}
```
'@
$extracted = & $module { param($txt) Find-AITextToolCall $txt } $markdownToolText
Assert-True ($null -ne $extracted) '必须能从 Markdown 代码块中提取工具调用。'
Assert-Equal 'powershell' $extracted.ToolCall.name '提取的工具名称必须为 powershell。'
Assert-Match $extracted.CleanedText '未闭合的括号导致异常' '提取后必须保留正文中的自然语言说明。'
Assert-Equal $false ($extracted.CleanedText.Contains('```')) '提取后正文不能残留 Markdown 代码块标记。'
Assert-Equal 'Get-Variable -Name x -ErrorAction SilentlyContinue' $extracted.ToolCall.arguments.command '提取的命令必须完全一致。'

# ConvertTo-AIValidatedPlan 容错纠偏：steps > 1 即使 mode 误标 Single 也自适应纠正为 Multi
$validatedPlan = & $module { param($p) ConvertTo-AIValidatedPlan $p } $extracted.ToolCall.arguments.plan
Assert-Equal 'Multi' $validatedPlan.mode '多步骤计划被误标为 Single 时必须自适应纠正为 Multi。'
Assert-Equal 2 @($validatedPlan.steps).Count '步骤数量必须完整保留。'

# Find-AITextToolCall 容错提取：支持 YAML/键值列表格式工具提议
$yamlToolText = @"
根因说明：查询系统密钥。
计划：
- mode: Single
- steps: ["读取注册表存储的产品密钥"]
- completionCondition: 成功输出产品密钥
- stepIndex: 1
- stepRole: Operation
- afterSuccess: Complete
- sideEffects: 无
- rollbackHint: 无需回滚
- purpose: 查询系统产品密钥
- command: `Get-ItemProperty -Path 'HKLM:\Software'`
- expectedOutcome: 返回产品密钥
"@
$extractedYaml = & $module { param($txt) Find-AITextToolCall $txt } $yamlToolText
Assert-True ($null -ne $extractedYaml) '必须能从 YAML/列表文本中提取工具调用。'
Assert-Equal 'Get-ItemProperty -Path ''HKLM:\Software''' $extractedYaml.ToolCall.arguments.command '提取的 YAML 命令必须一致。'
Assert-Equal '查询系统产品密钥' $extractedYaml.ToolCall.arguments.purpose '提取的 YAML 目的必须一致。'
Assert-Match $extractedYaml.CleanedText '根因说明：查询系统密钥。' '提取后必须保留说明文字。'
Assert-Equal $false ($extractedYaml.CleanedText.Contains('- command:')) '提取后不能残留命令键值列表。'

# 经过真实流解析再进入 Harness：缺字段必须有限修复；显示清洗不能改写正文命令。
$bodyCases=@(
    (@{name='powershell';arguments=@{command='Get-Date';expectedOutcome='e';sideEffects='s';rollbackHint='r';plan=$singlePlan;stepIndex=1;stepRole='Operation';afterSuccess='Complete'}} | ConvertTo-Json -Depth 10 -Compress),
    (@{name='powershell';arguments='invalid-json'} | ConvertTo-Json -Compress),
    $yamlToolText.Replace("Get-ItemProperty -Path 'HKLM:\Software'", "Write-Output '$([char]27)[31mfixture-value'")
)
foreach($bodyCase in $bodyCases){
    $payload=ConvertTo-AIMockSse $bodyCase
    $bodyServer=Start-AIMockServer @($payload,$payload)
    try {
        Set-PSAIModel -Name local -Endpoint ([uri]"http://127.0.0.1:$($bodyServer.Port)") -Capabilities @{streaming=$true;toolCalling=$true;usage=$false} | Out-Null
        Assert-Throws { Start-PSAIRun -Task '拒绝无效正文提议' } '连续两次返回无效工具调用' '正文提议必须按原文校验、仅修复一次且不能执行改写后的命令。'
    }finally{Stop-AIMockServer $bodyServer}
}


# 模拟真实模型仅返回 Markdown JSON 块时的端到端容错执行
$fallbackResponse = ConvertTo-AIMockSse $markdownToolText
$fallbackServer = Start-AIMockServer @($fallbackResponse)
try {
    Set-PSAIModel -Name local -Endpoint ([uri]"http://127.0.0.1:$($fallbackServer.Port)") -Capabilities @{streaming=$true;toolCalling=$true;usage=$false} | Out-Null
    function global:Read-Host { param([Parameter(ValueFromRemainingArguments)]$Arguments) [void]$Arguments; '' }
    try {
        $fallbackRun = Start-PSAIRun -Task '修复语法错误' -Failure ([ordered]@{task='修复';command='$x = )';output='语法错误';succeeded=$false;exitCode=$null})
    } finally {
        Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
    }
    Assert-True ($null -ne $fallbackRun) '正文 JSON 工具调用必须被成功转换为待执行步骤。'
    Assert-Equal 'Get-Variable -Name x -ErrorAction SilentlyContinue' $fallbackRun.Command '待执行步骤命令必须是提取出的修复命令。'
    Assert-Match ([string]$fallbackRun.ApprovalDigest) '^[a-f0-9]{64}$' '待执行步骤必须具备合法的批准摘要。'
    Stop-PSAIRun -Id $fallbackRun.RunId | Out-Null
} finally {
    Stop-AIMockServer $fallbackServer
}

# 验证 EnableTools 时的专属智能体系统提示词及历史会话中的 JSON 块净化
$agentPromptChecks = & $module {
    $model = @{protocol='OpenAIChat';modelId='model';parameters=@{}}
    $agentBody = New-AIRequestBody $model 'test' -EnableTools
    $agentSystem = [string]$agentBody.messages[0].content
    $prevSession = $script:CurrentSession
    try {
        $script:CurrentSession = [ordered]@{
            id = [guid]::NewGuid().ToString('N')
            summary = ''
            turns = @(
                [ordered]@{ role = 'user'; kind = 'task'; content = '查 IP' },
                [ordered]@{ role = 'assistant'; kind = 'message'; content = "分析说明`n" + '```json' + "`n" + '{"purpose":"查IP","command":"ipconfig"}' + "`n" + '```' }
            )
        }
        $sanitizedMessages = Get-AISessionMessages -Instruction '后续任务'
        $assistantMsg = ($sanitizedMessages | Where-Object role -eq 'assistant').content
        [pscustomobject]@{
            AgentSystem = $agentSystem
            AssistantContent = $assistantMsg
        }
    } finally {
        $script:CurrentSession = $prevSession
    }
}
Assert-Match $agentPromptChecks.AgentSystem 'Agent Operating Rules' '英文智能体提示词必须包含智能体操作准则。'
Assert-Equal $false ($agentPromptChecks.AgentSystem.Contains('strictly do NOT call tools')) '智能体模式下严禁包含禁止调用工具的冲突规则。'
Assert-Equal $false ($agentPromptChecks.AssistantContent.Contains('```json')) '历史会话中残留的 JSON 代码块必须在装配给模型前被净化。'
Assert-Match $agentPromptChecks.AssistantContent 'Proposed Command: ipconfig' '净化后的内容必须保留可读的操作描述。'


$interruptedId = & $module {
    $id=[guid]::NewGuid().ToString('N')
    $run=[ordered]@{schemaVersion=1;id=$id;sessionId=$script:CurrentSession.id;task='中断测试';state='ExecutingTool';stepCount=1;maxSteps=2
        pendingProposal=[ordered]@{id='call-interrupted';stepId=[guid]::NewGuid().ToString('N');purpose='读取日期';command='Get-Date';expectedOutcome='显示日期';sideEffects='无';rollbackHint='无需回滚';risk='Low'}
        events=@();createdUtc=[DateTime]::UtcNow.ToString('O');updatedUtc=[DateTime]::UtcNow.ToString('O')}
    Save-AIRun $run; $id
}
Assert-Throws { Resume-PSAIRun -Id $interruptedId } '避免重复执行' '执行中断的 Run 不能自动重放命令。'
Stop-PSAIRun -Id $interruptedId | Out-Null

$invalidRunId = & $module {
    $id=[guid]::NewGuid().ToString('N')
    $run=[ordered]@{schemaVersion=1;id=$id;sessionId=$script:CurrentSession.id;task='损坏测试';state='UnknownState';stepCount=0;maxSteps=2
        pendingProposal=$null;events=@();createdUtc=[DateTime]::UtcNow.ToString('O');updatedUtc=[DateTime]::UtcNow.ToString('O')}
    Save-AIRun $run; $id
}
Assert-Throws { Get-PSAIRun -Id $invalidRunId } 'Run 状态无效' '损坏的 Run 状态必须在恢复前被拒绝。'

$runConcurrency = & $module {
    $id = [guid]::NewGuid().ToString('N')
    $run = [ordered]@{
        schemaVersion=1;revision=0L;id=$id;sessionId=$script:CurrentSession.id;task='并发状态测试'
        state='AwaitingApproval';stepCount=1;maxSteps=2
        pendingProposal=[ordered]@{id='call-concurrent';stepId=[guid]::NewGuid().ToString('N');purpose='读取日期';command='Get-Date';expectedOutcome='显示日期';sideEffects='无';rollbackHint='无需回滚';risk='Low'}
        events=@();createdUtc=[DateTime]::UtcNow.ToString('O');updatedUtc=[DateTime]::UtcNow.ToString('O')
    }
    Save-AIRun $run
    $first = Import-AIRun $id
    $stale = Import-AIRun $id
    Set-AIRunState $first 'ExecutingTool' @{stepId=$first.pendingProposal.stepId}
    $message = try { Set-AIRunState $stale 'ExecutingTool' @{stepId=$stale.pendingProposal.stepId}; '' }
        catch { $_.Exception.Message }
    $reloaded = Import-AIRun $id
    [pscustomobject]@{Message=$message;State=$reloaded.state;EventCount=@($reloaded.events).Count}
}
Assert-Match $runConcurrency.Message '另一个 PowerShell 进程修改' '旧 Run 快照不能重复领取同一工具步骤。'
Assert-Equal 'ExecutingTool' $runConcurrency.State '第一个成功领取者必须保留 ExecutingTool 状态。'
Assert-Equal 1 $runConcurrency.EventCount '并发冲突不能重复写入状态事件。'

$approvalBinding = & $module {
    $id = [guid]::NewGuid().ToString('N')
    $run = [ordered]@{
        schemaVersion=2;revision=0L;id=$id;sessionId=$script:CurrentSession.id;task='批准绑定测试'
        plan=[ordered]@{mode='Single';steps=@('读取日期');completionCondition='显示日期'};nextStep=1;phase='Normal';lastFailure=$null;lastResult=$null
        state='AwaitingApproval';stepCount=1;maxSteps=2
        pendingProposal=[ordered]@{id='call-binding';stepId=[guid]::NewGuid().ToString('N');purpose='读取日期';command='Get-Date';expectedOutcome='显示日期';sideEffects='无';rollbackHint='无需回滚';risk='Low'}
        events=@();createdUtc=[DateTime]::UtcNow.ToString('O');updatedUtc=[DateTime]::UtcNow.ToString('O')
    }
    $run.pendingProposal.plan=$run.plan; $run.pendingProposal.stepIndex=1
    $run.pendingProposal.stepRole='Operation'; $run.pendingProposal.afterSuccess='Complete'
    Save-AIRun $run
    $oldApproval = Set-AIProposalApproval $run $run.pendingProposal (Get-AICommandRisk $run.pendingProposal.command)
    $oldStep = [pscustomobject]@{
        RunId=$id;StepId=$run.pendingProposal.stepId;Command=$run.pendingProposal.command
        ApprovalDigest=$oldApproval.Digest;ApprovalRevision=$oldApproval.Revision
    }
    $edited = Import-AIRun $id
    Remove-AIProposalApproval $edited.pendingProposal
    $edited.pendingProposal.command = 'Get-Location'
    $edited.pendingProposal.purpose = '读取当前位置'
    Add-AIRunEvent $edited 'ProposalEdited' @{stepId=$edited.pendingProposal.stepId}
    $newApproval = Set-AIProposalApproval $edited $edited.pendingProposal (Get-AICommandRisk $edited.pendingProposal.command)
    [pscustomobject]@{
        Old=$oldStep
        New=[pscustomobject]@{RunId=$id;StepId=$edited.pendingProposal.stepId;Command=$edited.pendingProposal.command;ApprovalDigest=$newApproval.Digest;ApprovalRevision=$newApproval.Revision}
    }
}
$expiredApprovalMessage = try {
    Start-PSAIToolExecution -RunId $approvalBinding.Old.RunId -StepId $approvalBinding.Old.StepId `
        -Command $approvalBinding.Old.Command -ApprovalDigest $approvalBinding.Old.ApprovalDigest `
        -ApprovalRevision $approvalBinding.Old.ApprovalRevision
    ''
} catch { $_.Exception.Message }
Assert-Match $expiredApprovalMessage '批准已过期' '命令在批准后发生变化时必须拒绝旧执行票据。'
Assert-Equal 'AwaitingApproval' (Get-PSAIRun -Id $approvalBinding.New.RunId).State '拒绝旧执行票据后不能改变 Run 状态。'
$tamperedCommandMessage = try {
    Start-PSAIToolExecution -RunId $approvalBinding.New.RunId -StepId $approvalBinding.New.StepId `
        -Command 'Remove-Item test.txt' -ApprovalDigest $approvalBinding.New.ApprovalDigest `
        -ApprovalRevision $approvalBinding.New.ApprovalRevision
    ''
} catch { $_.Exception.Message }
Assert-Match $tamperedCommandMessage '批准已过期' '实际执行命令与批准命令不一致时必须拒绝执行。'
Assert-Equal 'AwaitingApproval' (Get-PSAIRun -Id $approvalBinding.New.RunId).State '拒绝内存命令篡改后不能改变 Run 状态。'
Start-PSAIToolExecution -RunId $approvalBinding.New.RunId -StepId $approvalBinding.New.StepId `
    -Command $approvalBinding.New.Command -ApprovalDigest $approvalBinding.New.ApprovalDigest `
    -ApprovalRevision $approvalBinding.New.ApprovalRevision
$approvedRun = Get-PSAIRun -Id $approvalBinding.New.RunId
$approvedCommand = & $module { param($id) [string](Import-AIRun $id).pendingProposal.command } $approvalBinding.New.RunId
Assert-Equal 'ExecutingTool' $approvedRun.State '只有与当前命令和修订号一致的执行票据才能领取步骤。'
Assert-Equal 'Get-Location' $approvedCommand '领取后记录的命令必须与用户最终批准的命令完全一致。'
Stop-PSAIRun -Id $approvalBinding.New.RunId | Out-Null

$highRiskInteraction = & $module {
    $id = [guid]::NewGuid().ToString('N')
    $run = [ordered]@{
        schemaVersion=1;revision=0L;id=$id;sessionId=$script:CurrentSession.id;task='高风险确认测试'
        state='AwaitingApproval';stepCount=1;maxSteps=2
        pendingProposal=[ordered]@{id='call-high-risk';stepId=[guid]::NewGuid().ToString('N');purpose='删除测试文件';command='Remove-Item test.txt';expectedOutcome='文件消失';sideEffects='删除文件';rollbackHint='从备份恢复';risk='High'}
        events=@();createdUtc=[DateTime]::UtcNow.ToString('O');updatedUtc=[DateTime]::UtcNow.ToString('O')
    }
    Save-AIRun $run
    $responses = [Collections.Generic.Queue[string]]::new()
    foreach ($response in @('1','','3')) { $responses.Enqueue($response) }
    $prompts = [Collections.Generic.List[string]]::new()
    function Read-Host {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets','',Justification='局部审批测试桩，测试结束即移除。')]
        param([Parameter(Position=0)]$Prompt)
        $prompts.Add([string]$Prompt); $responses.Dequeue()
    }
    try { $ticket = Show-AIToolApproval $run $run.pendingProposal ([Threading.CancellationToken]::None) }
    finally { Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue }
    $reloaded = Import-AIRun $id
    [pscustomobject]@{
        TicketIsNull=($null -eq $ticket);State=$reloaded.state
        FirstPrompt=$prompts[0];ConfirmationPrompt=$prompts[1];PromptCount=$prompts.Count
    }
}
Assert-True ($highRiskInteraction.FirstPrompt -notmatch '(?i)default|默认') '高风险菜单不得提供回车默认执行。'
Assert-Match $highRiskInteraction.ConfirmationPrompt '(?i)high-risk|高风险' '高风险执行必须经过第二次明确确认。'
Assert-Equal $true $highRiskInteraction.TicketIsNull '高风险二次确认按回车时必须默认拒绝执行。'
Assert-Equal 'Cancelled' $highRiskInteraction.State '用户随后拒绝高风险命令时 Run 必须取消。'

$runSizeLimit = & $module {
    $id = [guid]::NewGuid().ToString('N')
    $run = [ordered]@{
        schemaVersion=1;revision=0L;id=$id;sessionId=$script:CurrentSession.id;task='大小上限测试'
        state='Created';stepCount=0;maxSteps=2;pendingProposal=$null;events=@()
        createdUtc=[DateTime]::UtcNow.ToString('O');updatedUtc=[DateTime]::UtcNow.ToString('O')
    }
    Save-AIRun $run
    $path = Get-AIRunPath $id
    $previousRevision = Get-AIRevision $run 'Run'
    $previousLimit = $script:MaximumRunBytes
    try {
        $script:MaximumRunBytes = [int](Get-Item -LiteralPath $path).Length + 32
        $run.task = 'x' * 1024
        $message = try { Save-AIRun $run; '' } catch { $_.Exception.Message }
    } finally { $script:MaximumRunBytes = $previousLimit }
    $reloaded = Import-AIRun $id
    [pscustomobject]@{
        Message=$message
        State=$reloaded.state
        Revision=Get-AIRevision $run 'Run'
        PreviousRevision=$previousRevision
    }
}
Assert-Match $runSizeLimit.Message 'Run 检查点超过 \d+ 字节上限' 'Run 写入端必须在替换旧检查点前检查 UTF-8 字节数。'
Assert-Equal 'Created' $runSizeLimit.State 'Run 大小越界后必须保留原有检查点。'
Assert-Equal $runSizeLimit.PreviousRevision $runSizeLimit.Revision 'Run 大小越界后必须回滚内存修订号。'

$blockedRunDirectory = Join-Path $testRoot 'blocked-run-directory'
Set-Content -LiteralPath $blockedRunDirectory -Value 'not a directory'
$runRollback = & $module {
    param($blockedPath)
    $originalDirectory=$script:RunDirectory
    $run=[ordered]@{schemaVersion=1;id=[guid]::NewGuid().ToString('N');sessionId=$script:CurrentSession.id;task='回滚测试';state='Created';stepCount=0;maxSteps=2
        pendingProposal=$null;events=@();createdUtc=[DateTime]::UtcNow.ToString('O');updatedUtc=[DateTime]::UtcNow.ToString('O')}
    try { $script:RunDirectory=$blockedPath; Set-AIRunState $run 'CallingModel' }
    catch { Write-Verbose "预期的持久化失败：$($_.Exception.Message)" }
    finally { $script:RunDirectory=$originalDirectory }
    [pscustomobject]@{State=$run.state;EventCount=@($run.events).Count}
} $blockedRunDirectory
Assert-Equal 'Created' $runRollback.State 'Run 写盘失败后必须恢复原状态。'
Assert-Equal 0 $runRollback.EventCount 'Run 写盘失败后不能残留未保存事件。'

# 顶层 Agent 包装必须保留调用者作用域并准确记录失败。
$successHarness = & $module { New-AITopLevelHarnessScript "[pscustomobject]@{RunId='r1';StepId='s1';ApprovalDigest=('a'*64);ApprovalRevision=1;Command='`$HarnessScopeProbe=42; function Invoke-HarnessProbe { 99 }; Get-Date | Out-Null'}" }
$nonTerminatingHarness = & $module { New-AITopLevelHarnessScript "[pscustomobject]@{RunId='r2';StepId='s2';ApprovalDigest=('b'*64);ApprovalRevision=2;Command='Write-Error ''harness-probe'' -ErrorAction Continue; Get-Date | Out-Null'}" }
$nativeFailureCommand = if ($isWindowsHost) { 'cmd /c exit 7' } else { "sh -c 'exit 7'" }
$nativeMixedLiteral = "'" + ($nativeFailureCommand + '; Get-Date | Out-Null').Replace("'", "''") + "'"
$nativeMixedHarness = & $module { param($literal) New-AITopLevelHarnessScript ("[pscustomobject]@{RunId='r3';StepId='s3';ApprovalDigest=('c'*64);ApprovalRevision=3;Command=$literal}") } $nativeMixedLiteral
$formatHarness = & $module { New-AITopLevelHarnessScript "[pscustomobject]@{RunId='r4';StepId='s4';ApprovalDigest=('d'*64);ApprovalRevision=4;Command='Get-Date | Select-Object DateTime | Format-Table -AutoSize'}" }
Assert-Match $successHarness 'AITerminalBoundedTextCollector' 'Agent Harness 必须边执行边写入有界输出收集器。'
Assert-Match $successHarness 'PSNativeCommandUseErrorActionPreference = \$true' 'Agent Harness 必须把原生命令非零退出转换为可累计错误。'
Assert-Match $successHarness 'Out-String -Stream' 'Agent Harness 必须整体渲染格式化记录，不能逐对象破坏 Format-Table 序列。'
Assert-Equal $false $successHarness.Contains('@(. ([scriptblock]::Create') 'Agent Harness 不能先把全部命令输出缓存到数组。'
Remove-Module PSAITerminal
function global:Start-PSAIToolExecution {
    param($RunId,$StepId,$Command,$ApprovalDigest,[long]$ApprovalRevision)
    [void]$RunId; [void]$StepId; [void]$Command; [void]$ApprovalDigest; [void]$ApprovalRevision
}
function global:Complete-PSAIToolExecution {
    param($RunId,$StepId,[bool]$Succeeded,$Output,$ExitCode)
    [void]$ExitCode
    [void]$RunId; [void]$StepId
    Set-Variable -Name HarnessObservedSuccess -Scope Global -Value $Succeeded
    Set-Variable -Name HarnessObservedOutput -Scope Global -Value $Output
}
try {
    $nativePreferenceVariable = Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    $nativePreferenceBefore = if ($nativePreferenceVariable) { [bool]$nativePreferenceVariable.Value } else { $null }
    $lastExitCodeVariableBefore = Get-Variable LASTEXITCODE -ErrorAction SilentlyContinue
    $lastExitCodeBefore = if ($lastExitCodeVariableBefore) { [int]$lastExitCodeVariableBefore.Value } else { $null }
    . ([scriptblock]::Create($successHarness))
    Assert-Equal 42 $HarnessScopeProbe 'Agent 顶层包装必须保留普通变量。'
    Assert-Equal 99 (Invoke-HarnessProbe) 'Agent 顶层包装必须保留函数定义。'
    Assert-Equal $true $HarnessObservedSuccess '成功状态必须在 Out-Host 前记录。'
    . ([scriptblock]::Create($nonTerminatingHarness)) 2>$null
    Assert-Equal $false $HarnessObservedSuccess '前面的非终止错误不能被后续成功语句覆盖。'
    . ([scriptblock]::Create($nativeMixedHarness)) 2>$null
    Assert-Equal $false $HarnessObservedSuccess '前面的原生命令非零退出不能被后续成功语句覆盖。'
    . ([scriptblock]::Create($formatHarness))
    Assert-Equal $true $HarnessObservedSuccess 'Format-Table 输出不能导致 Agent 命令被误判为失败。'
    Assert-Match $HarnessObservedOutput 'DateTime' 'Format-Table 的文本输出必须进入有界收集器。'
    if ($nativePreferenceVariable) {
        Assert-Equal $nativePreferenceBefore ([bool](Get-Variable PSNativeCommandUseErrorActionPreference).Value) 'Harness 必须恢复用户原有的原生命令错误偏好。'
    } else {
        Assert-Equal $null (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) '5.1 Harness 不能创建宿主不支持的原生命令错误偏好。'
    }
    if ($PSVersionTable.PSVersion -lt [version]'7.3') {
        $lastExitCodeVariableAfter = Get-Variable LASTEXITCODE -ErrorAction SilentlyContinue
        Assert-Equal ($null -ne $lastExitCodeVariableBefore) ($null -ne $lastExitCodeVariableAfter) '5.1 Harness 必须恢复 LASTEXITCODE 是否存在的原状态。'
        if ($lastExitCodeVariableBefore) {
            Assert-Equal $lastExitCodeBefore ([int]$lastExitCodeVariableAfter.Value) '5.1 Harness 必须恢复用户原有的 LASTEXITCODE。'
        }
    }
} finally {
    Remove-Item Function:\Start-PSAIToolExecution,Function:\Complete-PSAIToolExecution -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-HarnessProbe -ErrorAction SilentlyContinue
    Remove-Variable HarnessObservedSuccess,HarnessObservedOutput,HarnessScopeProbe -Scope Global -ErrorAction SilentlyContinue
}
