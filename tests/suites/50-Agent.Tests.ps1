# 上下文压缩，以及 Agent 循环：工具调用、审批菜单、顶层执行、结果回传与结束条件。
# 由 tests/run.ps1 在同一作用域内按文件名顺序点源执行，依赖其中的 $module、$testRoot 等状态，不能单独运行。
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = '模块内审批与顶层执行的命令需要共享测试桩状态。')]
param()

# 上下文超出模型窗口预算时丢弃最早的轮次，保留最近内容；不调用模型做摘要。
New-PSAISession -Title '上下文测试' | Out-Null
& $module { 1..40 | ForEach-Object { Add-AISessionTurn 'user' ("第 $_ 轮 " + ('x' * 900)) 'message' | Out-Null } }
$context = & $module {
    $messages = @(Get-AISessionMessages @{contextWindow=1024} '最新要求')
    [pscustomobject]@{Count=$messages.Count;Characters=($messages | ForEach-Object { ([string]$_.content).Length } | Measure-Object -Sum).Sum;Last=[string]$messages[-1].content;First=[string]$messages[0].content}
}
Assert-True ($context.Characters -le 16384) '上下文必须限制在窗口预算内。'
Assert-Equal '最新要求' $context.Last '当前要求必须保留在上下文末尾。'
Assert-True ($context.First -notmatch '^第 1 轮') '超出预算时必须先丢弃最早的轮次。'
Assert-True ($context.Count -gt 10) '预算内的最近轮次必须保留。'

# Agent 场景：模拟服务按顺序返回模型响应；Read-Host 按队列回答审批菜单；调度脚本在本测试的顶层作用域执行。
function Start-AgentScenario([string[]]$Responses, [string[]]$Answers = @()) {
    $server = Start-AIMockServer $Responses
    Set-PSAIModel -Name local -Endpoint ([uri]"http://127.0.0.1:$($server.Port)") -Capabilities @{streaming=$true;toolCalling=$true;usage=$false} | Out-Null
    $global:AgentAnswers = [Collections.Generic.Queue[string]]::new()
    foreach ($answer in $Answers) { $global:AgentAnswers.Enqueue($answer) }
    $global:AgentPrompts = [Collections.Generic.List[string]]::new()
    function global:Read-Host {
        param([Parameter(Position=0)]$Prompt, [switch]$AsSecureString)
        [void]$AsSecureString
        $global:AgentPrompts.Add([string]$Prompt)
        if ($global:AgentAnswers.Count) { $global:AgentAnswers.Dequeue() } else { '' }
    }
    $server
}
function Stop-AgentScenario($Server) {
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    while ($Server.Job.State -eq 'Running' -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
    $consumedAll = $Server.Job.State -eq 'Completed'
    Stop-AIMockServer $Server
    Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
    $consumedAll
}
function Get-AgentTurns([int]$Last = 6) { @(& $module { param($n) @($script:CurrentSession.turns | Select-Object -Last $n) } $Last) }
function New-AgentTool([string]$Command, [string]$Purpose = '测试目的') { ConvertTo-AIMockSse -ToolArguments ([ordered]@{command=$Command;purpose=$Purpose}) }

# 1. 工具调用 → 回车默认执行 → 结果回传 → 文字结束；命令在调用者顶层作用域执行。
$server = Start-AgentScenario @((New-AgentTool '$AgentScopeProbe=42; function Invoke-AgentProbe { 99 }; Get-Date | Out-Null'), (ConvertTo-AIMockSse '任务已完成。')) @('')
try {
    . ([scriptblock]::Create((& $module { New-AIAgentHarnessScript '记录一个变量' }))) 6>$null
} finally { $consumed = Stop-AgentScenario $server }
Assert-True $consumed '执行成功后必须把结果回传给模型。'
Assert-Equal 42 $AgentScopeProbe 'Agent 命令必须在调用者顶层作用域执行。'
Assert-Equal 99 (Invoke-AgentProbe) 'Agent 命令定义的函数必须保留在调用者作用域。'
$turns = Get-AgentTurns 3
Assert-Equal 'tool_result' $turns[1].kind '执行结果必须写入会话。'
Assert-Equal $true ([bool]$turns[1].metadata.succeeded) '成功命令必须记录为成功。'
Assert-Equal '任务已完成。' $turns[2].content '模型的结束文字必须写入会话。'
Assert-Equal $null (& $module { $script:Agent }) '任务结束后不能残留 Agent 状态。'
Assert-Equal $false (Test-Path Variable:\__psai_*) '调度脚本结束后不能残留内部变量。'

# 1b. 新终端的第一次请求：会话里只有一条消息，请求体 messages 仍必须是数组（模拟服务会校验）。
New-PSAISession -Title '首次请求' | Out-Null
$server = Start-AgentScenario @((ConvertTo-AIMockSse '首次回答。')) @()
try { . ([scriptblock]::Create((& $module { New-AIAgentHarnessScript '第一句话' }))) 3>$null 6>$null }
finally { $consumed = Stop-AgentScenario $server }
Assert-True $consumed '全新会话的第一次请求必须成功。'
Assert-Equal '首次回答。' @(Get-AgentTurns 1)[0].content '全新会话的第一次回答必须写入会话。'

# 1c. Anthropic：任务与工具结果都是 user 角色，合并后只剩一条消息，执行命令后的下一轮请求仍必须成功。
New-PSAISession -Title 'Anthropic' | Out-Null
$global:AnthropicProbe = $null
$server = Start-AgentScenario @((ConvertTo-AIMockAnthropicSse -ToolArguments ([ordered]@{command='$global:AnthropicProbe = 1';purpose='测试'})), (ConvertTo-AIMockAnthropicSse '完成。')) @('')
try {
    $mockEndpoint = [uri]"http://127.0.0.1:$($server.Port)"
    Set-PSAIModel -Name local -Protocol Anthropic -Endpoint $mockEndpoint | Out-Null
    . ([scriptblock]::Create((& $module { New-AIAgentHarnessScript '设置变量' }))) 3>$null 6>$null
} finally {
    $consumed = Stop-AgentScenario $server
    Set-PSAIModel -Name local -Protocol OpenAIChat -Endpoint $mockEndpoint | Out-Null
}
Assert-Equal 1 $global:AnthropicProbe 'Anthropic 工具调用必须被执行。'
Assert-True $consumed 'Anthropic 执行命令后的下一轮请求必须成功。'
Assert-Equal '完成。' @(Get-AgentTurns 1)[0].content 'Anthropic 的结束文字必须写入会话。'

# 1d. 中文引号不能截断任务或注入代码：任务文本必须原样交给 Agent。
$quotedTask = "把‘test’文件夹删掉’; Write-Host INJECTED; ‘"
$harnessAst = [Management.Automation.Language.Parser]::ParseInput((& $module { param($t) New-AIAgentHarnessScript $t } $quotedTask), [ref]$null, [ref]$null)
$taskLiteral = $harnessAst.Find({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -eq $quotedTask }, $true)
Assert-True ($null -ne $taskLiteral) '含中文引号的任务必须作为一个完整字符串传入。'
Assert-Equal $null ($harnessAst.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-Host' }, $true)) '任务文本不能被解析成命令。'

# 2. 非终止错误与原生非零退出都必须判为失败；高风险命令需要 Y 加二次确认。
$nativeExit = 'cmd /c exit 7'
$server = Start-AgentScenario @((New-AgentTool "Write-Error 'agent-probe' -ErrorAction Continue; Get-Date | Out-Null"), (New-AgentTool $nativeExit), (ConvertTo-AIMockSse '已结束。')) @('', 'y', 'y')
try { . ([scriptblock]::Create((& $module { New-AIAgentHarnessScript '失败场景' }))) 2>$null 6>$null }
finally { $consumed = Stop-AgentScenario $server }
Assert-True $consumed '失败结果也必须回传模型。'
$turns = @(Get-AgentTurns 4 | Where-Object kind -eq 'tool_result')
Assert-Equal $false ([bool]$turns[0].metadata.succeeded) '前面的非终止错误不能被后续成功语句覆盖。'
Assert-Equal $false ([bool]$turns[1].metadata.succeeded) '原生命令非零退出必须判为失败。'
Assert-Equal 7 ([int]$turns[1].metadata.exitCode) '必须记录原生命令的退出码。'
Assert-Match ($global:AgentPrompts -join '|') '(?i)high-risk|高风险' '高风险命令必须经过二次确认。'
Assert-Equal $false (($global:AgentPrompts[1]) -match '\[A\]') '高风险命令不能提供“本会话总是允许”。'

# 3. 拒绝并附反馈：反馈回传模型，模型改提议；被拒绝的命令不执行。
$global:RejectedProbe = $null
$server = Start-AgentScenario @((New-AgentTool '$global:RejectedProbe = 1'), (New-AgentTool '$global:RejectedProbe = 2'), (ConvertTo-AIMockSse '好的。')) @('n', '改成 2', '')
try { . ([scriptblock]::Create((& $module { New-AIAgentHarnessScript '拒绝反馈' }))) 6>$null }
finally { $consumed = Stop-AgentScenario $server }
Assert-True $consumed '附反馈的拒绝必须继续请求模型。'
Assert-Equal 2 $global:RejectedProbe '只能执行用户最终接受的命令。'
Assert-Match (@(Get-AgentTurns 4 | Where-Object kind -eq 'tool_result')[0]).content '改成 2' '拒绝反馈必须写入会话供模型参考。'

# 4. 拒绝且不附反馈：任务取消，不再请求模型。
$global:RejectedProbe = $null
$server = Start-AgentScenario @((New-AgentTool '$global:RejectedProbe = 3')) @('n', '')
try { . ([scriptblock]::Create((& $module { New-AIAgentHarnessScript '直接拒绝' }))) 6>$null }
finally { $consumed = Stop-AgentScenario $server }
Assert-Equal $null $global:RejectedProbe '拒绝的命令不能执行。'
Assert-Equal $null (& $module { $script:Agent }) '直接拒绝后必须结束任务。'

# 5. [A] 本会话允许：之后同名命令免审批。
$server = Start-AgentScenario @((New-AgentTool 'Get-Date | Out-Null'), (New-AgentTool 'Get-Date | Out-Null'), (ConvertTo-AIMockSse '完成。')) @('a')
try { . ([scriptblock]::Create((& $module { New-AIAgentHarnessScript '允许同名命令' }))) 6>$null }
finally { $consumed = Stop-AgentScenario $server }
Assert-True $consumed '允许后必须继续执行后续步骤。'
Assert-Equal 1 $global:AgentPrompts.Count '同名命令在本会话允许后不能再次询问。'
Assert-True (& $module { $script:SessionAllowedCommands.Contains('Get-Date') -and $script:SessionAllowedCommands.Contains('Out-Null') }) '允许的命令名必须记入会话允许列表。'

# 6. 高风险命令不受允许列表影响；E 把命令放入下一次输入，不执行。
$highRisk = & $module {
    $previous = @($script:Config.execution.autoApprove)
    $script:Config.execution.autoApprove = @('*')
    [void]$script:SessionAllowedCommands.Add('Remove-Item')
    $global:AgentAnswers = [Collections.Generic.Queue[string]]::new(); foreach ($a in @('a', 'e')) { $global:AgentAnswers.Enqueue($a) }
    $global:AgentPrompts = [Collections.Generic.List[string]]::new()
    function script:Read-Host { param([Parameter(Position=0)]$Prompt) $global:AgentPrompts.Add([string]$Prompt); $global:AgentAnswers.Dequeue() }
    try {
        $decision = Request-AICommandApproval ([ordered]@{command='Remove-Item fixture.txt';purpose='删除'}) 3>$null 6>$null
        $lowAuto = Test-AIAutoApproved 'Get-ChildItem' 'Low'
        [pscustomobject]@{Action=$decision.Action;Prompts=$global:AgentPrompts.Count;Menu=$global:AgentPrompts[0];LowAuto=$lowAuto}
    } finally {
        Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
        $script:Config.execution.autoApprove = $previous
        [void]$script:SessionAllowedCommands.Remove('Remove-Item')
    }
}
Assert-Equal 'Edit' $highRisk.Action '高风险命令输入 A 无效，随后 E 必须放入命令行。'
Assert-Equal 2 $highRisk.Prompts '高风险命令即使匹配允许列表也必须询问。'
Assert-Equal $false ($highRisk.Menu -match '\[A\]') '高风险菜单不能出现 [A]。'
Assert-Equal $true $highRisk.LowAuto 'autoApprove 通配必须对中低风险命令生效。'
# 免审批只按命令名约束不了写操作；子命令工具按“工具 子命令”匹配。
$autoApproveCases = & $module {
    $previous = @($script:Config.execution.autoApprove)
    $script:Config.execution.autoApprove = @('Get-*', 'git status')
    try {
        [ordered]@{
            'Get-Date' = Test-AIAutoApproved 'Get-Date' 'Low'
            'Get-Date; [IO.File]::WriteAllText(''x'', ''y'')' = Test-AIAutoApproved 'Get-Date; [IO.File]::WriteAllText(''x'', ''y'')' 'Medium'
            'Get-ChildItem > out.txt' = Test-AIAutoApproved 'Get-ChildItem > out.txt' 'Medium'
            '$x = Get-Date' = Test-AIAutoApproved '$x = Get-Date' 'Medium'
            'git status' = Test-AIAutoApproved 'git status' 'Low'
            'git -C . status' = Test-AIAutoApproved 'git -C . status' 'Medium'
            'git checkout -- .' = Test-AIAutoApproved 'git checkout -- .' 'Medium'
            'git.exe checkout -- .' = Test-AIAutoApproved 'git.exe checkout -- .' 'Medium'
        }
    } finally { $script:Config.execution.autoApprove = $previous }
}
$expectedAutoApprove = [ordered]@{
    'Get-Date' = $true; 'Get-Date; [IO.File]::WriteAllText(''x'', ''y'')' = $false; 'Get-ChildItem > out.txt' = $false
    '$x = Get-Date' = $false; 'git status' = $true; 'git -C . status' = $true; 'git checkout -- .' = $false; 'git.exe checkout -- .' = $false
}
foreach ($case in $expectedAutoApprove.GetEnumerator()) {
    Assert-Equal $case.Value $autoApproveCases[$case.Key] "免审批判断错误：$($case.Key)"
}
$global:EditProbe = $null
$server = Start-AgentScenario @((New-AgentTool '$global:EditProbe = 1')) @('e')
try { . ([scriptblock]::Create((& $module { New-AIAgentHarnessScript '放入命令行' }))) 6>$null }
finally { $consumed = Stop-AgentScenario $server }
Assert-Equal $null $global:EditProbe '选择放入命令行时不能执行命令。'
Assert-Equal '$global:EditProbe = 1' (& $module { $value = $script:NextInputBuffer; $script:NextInputBuffer = $null; $value }) '命令必须留给下一次输入预填。'

# 7. 无效工具调用最多修复一次；单任务命令数受 maxAgentSteps 限制。
$global:RepairProbe = $null
$server = Start-AgentScenario @((New-AgentTool 'exit'), (New-AgentTool '$global:RepairProbe = 1'), (ConvertTo-AIMockSse '完成。')) @('')
try { . ([scriptblock]::Create((& $module { New-AIAgentHarnessScript '修复一次' }))) 6>$null }
finally { $consumed = Stop-AgentScenario $server }
Assert-Equal 1 $global:RepairProbe '第一次无效提议后必须允许模型修正一次。'
$server = Start-AgentScenario @((New-AgentTool 'exit'), (New-AgentTool 'return')) @()
try { . ([scriptblock]::Create((& $module { New-AIAgentHarnessScript '连续无效' }))) 3>$null 6>$null }
finally { $consumed = Stop-AgentScenario $server }
Assert-True $consumed '连续两次无效提议后必须停止，不再请求模型。'
& $module { $script:Config.execution.maxAgentSteps = 1 }
$global:StepLimitProbe = 0
$server = Start-AgentScenario @((New-AgentTool '$global:StepLimitProbe++'), (New-AgentTool '$global:StepLimitProbe++')) @('', '')
try { . ([scriptblock]::Create((& $module { New-AIAgentHarnessScript '步数上限' }))) 3>$null 6>$null }
finally { $consumed = Stop-AgentScenario $server; & $module { $script:Config.execution.maxAgentSteps = 12 } }
Assert-Equal 1 $global:StepLimitProbe '达到步数上限后不能再执行命令。'

# 8. 不支持工具调用的模型只做问答。
$server = Start-AgentScenario @((ConvertTo-AIMockSse '纯文本回答。')) @()
try {
    Set-PSAIModel -Name local -Capabilities @{streaming=$true;toolCalling=$false;usage=$false} | Out-Null
    . ([scriptblock]::Create((& $module { New-AIAgentHarnessScript '问答' }))) 6>$null
} finally { $consumed = Stop-AgentScenario $server }
Assert-Equal '纯文本回答。' @(Get-AgentTurns 1)[0].content '不支持工具的模型必须退化为问答。'
Set-PSAIModel -Name local -Capabilities @{streaming=$true;toolCalling=$true;usage=$false} | Out-Null

# 9. 工具参数校验与系统提示词。
Assert-Throws { & $module { ConvertFrom-AIToolCall @{name='powershell';arguments=@{command='Get-Date; exit'}} } } '不能包含 exit' '控制流命令必须被拒绝。'
Assert-Throws { & $module { ConvertFrom-AIToolCall @{name='powershell';arguments=@{command='$x = )'}} } } '语法错误' '语法错误命令必须被拒绝。'
Assert-Throws { & $module { ConvertFrom-AIToolCall @{name='powershell';arguments=@{command='$env:API_KEY="sk-live-fixture"'}} } } '脱敏' '会被脱敏改写的命令必须被拒绝。'
Assert-Equal '' (& $module { ConvertFrom-AIToolCall @{name='powershell';arguments='{"command":"Get-Date"}'} }).purpose 'purpose 缺失时不能阻止合法命令。'
$agentSystem = & $module { [string](New-AIRequestBody @{protocol='OpenAIChat';modelId='m';parameters=@{}} 'x' -EnableTools).messages[0].content }
Assert-Match $agentSystem 'powershell tool' 'Agent 系统提示词必须说明工具用法。'
Remove-Variable AgentAnswers,AgentPrompts,RejectedProbe,EditProbe,RepairProbe,StepLimitProbe,AnthropicProbe -Scope Global -ErrorAction SilentlyContinue
Remove-Item Function:\Invoke-AgentProbe -ErrorAction SilentlyContinue
