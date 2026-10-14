# AI 对话与 Agent：模型自行决定直接回答还是提议命令；命令经本地风险分级和用户批准后在调用者顶层作用域执行。
# 任务状态只保存在内存中，会话轮次照常持久化，供后续对话使用。

function ConvertFrom-AIToolCall($Call) {
    if ([string](Get-AIProperty $Call 'name') -ne 'powershell') { throw '模型请求了未注册的工具。' }
    $arguments = Get-AIProperty $Call 'arguments'
    if ($arguments -isnot [Collections.IDictionary]) {
        try { $arguments = ConvertFrom-AIJson ([string]$arguments) }
        catch { throw 'powershell 工具参数不是有效 JSON。' }
    }
    if ($arguments -isnot [Collections.IDictionary]) { throw 'powershell 工具参数必须是对象。' }
    $command = $arguments['command']
    if ($command -isnot [string] -or [string]::IsNullOrWhiteSpace($command) -or $command.Length -gt 16384) {
        throw 'command 必须是非空字符串且不能超过 16384 个字符。'
    }
    if ((Protect-AIText $command -1) -cne $command) {
        throw '命令包含需要脱敏的敏感值或控制字符，不能改写后执行；请使用变量或凭据引用。'
    }
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($command, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count) { throw "命令存在语法错误：$($parseErrors[0].Message)" }
    $forbidden = $ast.Find({ param($node) $node -is [Management.Automation.Language.ExitStatementAst] -or
        $node -is [Management.Automation.Language.ReturnStatementAst] -or
        $node -is [Management.Automation.Language.BreakStatementAst] -or
        $node -is [Management.Automation.Language.ContinueStatementAst] }, $true)
    if ($forbidden) { throw '命令不能包含 exit、return、break 或 continue。' }
    $purpose = if ($arguments['purpose'] -is [string]) { Protect-AIText ([string]$arguments['purpose']).Trim() 1024 } else { '' }
    $id = [string](Get-AIProperty $Call 'id')
    [ordered]@{ id = $(if ($id) { $id } else { [guid]::NewGuid().ToString('N') }); command = $command; purpose = $purpose }
}

# 返回命令中每个调用的免审批键：普通命令为命令名；子命令决定读写的工具为“工具 子命令”，
# 允许 git status 不等于允许 git checkout。
function Get-AICommandApprovalKeys([string]$Command) {
    $subcommandTools = @('git','npm','pnpm','yarn','dotnet','cargo','docker','kubectl','pip','winget','choco','scoop','gh','az','wsl')
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$parseErrors)
    $keys = foreach ($commandAst in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)) {
        $rawName = $commandAst.GetCommandName()
        if (-not $rawName) { continue }
        $tool = [PSAITerminal.AITerminalSecurity]::NormalizeCommandName($rawName)
        if ($tool -notin $subcommandTools) { $rawName; continue }
        $subcommand = $null
        $elements = @($commandAst.CommandElements | Select-Object -Skip 1)
        for ($index = 0; $index -lt $elements.Count; $index++) {
            $text = $elements[$index].Extent.Text
            if ($text -cin @('-C','-c')) { $index++; continue }
            if ($text.StartsWith('-')) { continue }
            $subcommand = $text; break
        }
        if ($subcommand) { "$($tool.ToLowerInvariant()) $subcommand" } else { $tool.ToLowerInvariant() }
    }
    @($keys | Sort-Object -Unique)
}

# 只有中低风险、不含重定向/赋值/.NET 调用等无法按命令名约束的写操作，
# 且每个命令都在会话允许列表或 execution.autoApprove 中时才免审批。
function Test-AIAutoApproved([string]$Command, [string]$Risk) {
    if ($Risk -eq 'High') { return $false }
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$parseErrors)
    $unboundWrite = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FileRedirectionAst] -or
        $node -is [Management.Automation.Language.AssignmentStatementAst] -or
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -or
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -or
        $node -is [Management.Automation.Language.TypeDefinitionAst] }, $true)
    if ($unboundWrite) { return $false }
    $keys = @(Get-AICommandApprovalKeys $Command)
    if ($keys.Count -eq 0) { return $false }
    $patterns = @(@($script:Config.execution.autoApprove) + @($script:SessionAllowedCommands) | Where-Object { $_ })
    foreach ($key in $keys) {
        if (-not @($patterns | Where-Object { $key -like $_ }).Count) { return $false }
    }
    $true
}

function Request-AICommandApproval([Collections.IDictionary]$Proposal) {
    $command = [string]$Proposal.command
    $risk = [string](Get-AICommandRisk $command)
    $riskColor = switch ($risk) { 'High' { 'Red' } 'Medium' { 'Yellow' } default { 'Green' } }
    if (Test-AIAutoApproved $command $risk) {
        Write-AIColoredHost "› $(Get-AIText 'AutoApproved')：$command" DarkGray
        return [pscustomobject]@{ Action = 'Run'; Feedback = $null }
    }
    $names = @(Get-AICommandApprovalKeys $command)
    Write-Host ''
    if ($Proposal.purpose) { Write-Host "$(Get-AIText 'ApprovalPurpose')：$($Proposal.purpose)" }
    Write-AIColoredHost "  $command" $riskColor
    Write-AIColoredHost "$(Get-AIText 'ApprovalRisk')：$risk" $riskColor
    $canAllow = $risk -ne 'High' -and $names.Count -gt 0
    $menu = if ($canAllow) { Get-AIText 'ApprovalChoices' @($names -join ', ') } else { Get-AIText 'ApprovalChoicesHigh' }
    while ($true) {
        $answer = ([string](Read-Host $menu)).Trim()
        if (-not $answer) {
            if ($risk -eq 'High') { Write-Warning (Get-AIText 'HighRiskNoDefault'); continue }
            $answer = 'y'
        }
        if ($answer -match '^(?i:y|yes|1)$') {
            if ($risk -eq 'High' -and -not (Read-AIYesNo (Get-AIText 'HighRiskConfirm') $false)) { continue }
            return [pscustomobject]@{ Action = 'Run'; Feedback = $null }
        }
        if ($canAllow -and $answer -match '^(?i:a|always)$') {
            foreach ($name in $names) { [void]$script:SessionAllowedCommands.Add($name) }
            return [pscustomobject]@{ Action = 'Run'; Feedback = $null }
        }
        if ($answer -match '^(?i:e|edit)$') { return [pscustomobject]@{ Action = 'Edit'; Feedback = $null } }
        if ($answer -match '^(?i:n|no)$') {
            $feedback = ([string](Read-Host (Get-AIText 'RejectReason'))).Trim()
            return [pscustomobject]@{ Action = 'Reject'; Feedback = $feedback }
        }
        Write-Warning (Get-AIText 'InvalidChoice')
    }
}

function Start-AIAgent([string]$Task) {
    try { $model = Assert-AIActiveModelReady }
    catch { Write-Warning $_.Exception.Message; return $null }
    Add-AISessionTurn 'user' (Protect-AIText $Task 16384) 'task' | Out-Null
    $script:Agent = [ordered]@{ Model = $model; Steps = 0; Repairs = 0; Pending = $null
        MaxSteps = [int]$script:Config.execution.maxAgentSteps }
    Invoke-AIAgentTurn
}

function Submit-AIAgentResult([bool]$Succeeded, [AllowNull()][string]$Output, [int]$ExitCode) {
    $agent = $script:Agent
    if (-not $agent -or -not $agent.Pending) { return $null }
    $command = [string]$agent.Pending.command
    $agent.Pending = $null
    $safeOutput = Protect-AIText $Output ([int]$script:Config.execution.outputCaptureCharacters)
    $script:LastCommand = [pscustomobject]@{ Command = $command; Succeeded = $Succeeded
        Error = $(if ($Succeeded) { $null } else { $safeOutput }); ExitCode = $ExitCode; Source = 'AI' }
    $status = if ($Succeeded) { Get-AIText 'StepSucceeded' } elseif ($ExitCode) { Get-AIText 'StepFailedExit' @($ExitCode) } else { Get-AIText 'StepFailed' }
    $body = if ([string]::IsNullOrWhiteSpace($safeOutput)) { Get-AIText 'NoOutput' } else { $safeOutput }
    Add-AISessionTurn 'tool' "$(Get-AIText 'ToolResultCommand')：$command`n$(Get-AIText 'ToolResultStatus')：$status`n$(Get-AIText 'ToolResultOutput')：`n$body" 'tool_result' @{
        command = $command; succeeded = $Succeeded; exitCode = $ExitCode } | Out-Null
    Write-AIColoredHost "◆ $(if ($Succeeded) { '✓' } else { '✗' }) $status" DarkGray
    Invoke-AIAgentTurn
}

function Stop-AIAgent([string]$Message) {
    if ($Message) { Write-Warning $Message }
    $script:Agent = $null
    $null
}

function Invoke-AIAgentTurn {
    $agent = $script:Agent
    while ($agent) {
        if ($agent.Steps -ge $agent.MaxSteps) { return Stop-AIAgent (Get-AIText 'MaxStepsReached' @($agent.MaxSteps)) }
        $useTools = [bool]$agent.Model.capabilities.toolCalling
        try { $response = Invoke-AISessionModel $agent.Model $null -EnableTools:$useTools }
        catch { return Stop-AIAgent "$(Get-AIText 'ModelRequestFailed')：$($_.Exception.Message)" }
        if ($response.Text) {
            Add-AISessionTurn 'assistant' $response.Text 'message' @{} -InputTokens ([long]$response.InputTokens) -OutputTokens ([long]$response.OutputTokens) | Out-Null
        } else {
            Update-AISessionUsage ([long]$response.InputTokens) ([long]$response.OutputTokens)
        }
        $calls = @($response.ToolCalls)
        if ($calls.Count -eq 0) { return Stop-AIAgent $null }

        try { $proposal = ConvertFrom-AIToolCall $calls[0] }
        catch {
            if ($agent.Repairs -ge 1) { return Stop-AIAgent "$(Get-AIText 'InvalidProposalStopped')：$($_.Exception.Message)" }
            $agent.Repairs++
            Add-AISessionTurn 'tool' "$(Get-AIText 'InvalidProposal')：$($_.Exception.Message)" 'tool_result' | Out-Null
            continue
        }
        $agent.Repairs = 0
        $agent.Steps++
        $decision = Request-AICommandApproval $proposal
        if ($decision.Action -eq 'Run') {
            $agent.Pending = $proposal
            return [pscustomobject]@{ Command = [string]$proposal.command; OutputLimit = [int]$script:Config.execution.outputCaptureCharacters }
        }
        if ($decision.Action -eq 'Edit') {
            Add-AISessionTurn 'tool' "$(Get-AIText 'UserEditsCommand')：$($proposal.command)" 'tool_result' | Out-Null
            $script:NextInputBuffer = [string]$proposal.command
            Write-AIColoredHost "◆ $(Get-AIText 'CommandPlacedInInput')" DarkGray
            return Stop-AIAgent $null
        }
        if ($decision.Feedback) {
            Add-AISessionTurn 'tool' "$(Get-AIText 'UserRejectedWithFeedback')：$($proposal.command)`n$($decision.Feedback)" 'tool_result' | Out-Null
            continue
        }
        Add-AISessionTurn 'tool' "$(Get-AIText 'UserRejected')：$($proposal.command)" 'tool_result' | Out-Null
        Write-AIColoredHost "◆ $(Get-AIText 'TaskCancelled')" DarkGray
        return Stop-AIAgent $null
    }
    $null
}

# 生成在调用者顶层作用域运行的调度脚本：Agent 逻辑在模块内，命令本身在用户会话中执行。
function New-AIAgentHarnessScript([string]$Task) {
    $name = '__psai_' + [guid]::NewGuid().ToString('N')
    $template = @'
${V} = @{ Module = (Get-Module PSAITerminal | Select-Object -Last 1); Step = $null }
try {
    ${V}.Step = & ${V}.Module { param($task) Start-AIAgent $task } '{TASK}'
    while ($null -ne ${V}.Step) {
        ${V}.Output = [PSAITerminal.AITerminalBoundedTextCollector]::new([int]${V}.Step.OutputLimit)
        ${V}.Failed = $false
        ${V}.LastSuccess = $false
        $global:LASTEXITCODE = 0
        try {
            . ([scriptblock]::Create([string]${V}.Step.Command + [Environment]::NewLine + '${V}.LastSuccess = $?')) *>&1 | ForEach-Object {
                if ($_ -is [Management.Automation.ErrorRecord] -and $_.FullyQualifiedErrorId -notlike 'NativeCommandError*') { ${V}.Failed = $true }
                $_
            } | Out-String -Stream | ForEach-Object { ${V}.Output.Append($_ + [Environment]::NewLine); $_ | Out-Host }
        } catch {
            ${V}.Failed = $true
            ${V}.Output.Append(($_ | Out-String))
            $_ | Out-Host
        }
        ${V}.ExitCode = [int]$global:LASTEXITCODE
        ${V}.Succeeded = [bool]${V}.LastSuccess -and -not ${V}.Failed -and ${V}.ExitCode -eq 0
        ${V}.Step = & ${V}.Module { param($ok, $text, $code) Submit-AIAgentResult $ok $text $code } ${V}.Succeeded (${V}.Output.GetText()) ${V}.ExitCode
    }
} finally {
    Remove-Variable -Name '{NAME}' -Scope 0 -ErrorAction SilentlyContinue
}
'@
    # 任务文本最后填入，避免其中的占位符被再次替换。
    $template.Replace('${V}', "`$$name").Replace('{NAME}', $name).Replace("'{TASK}'", (ConvertTo-AISingleQuotedLiteral $Task))
}

# PowerShell 把 ‘ ’ ‚ ‛ 也当作单引号，只转义 ' 会让中文引号截断字符串并注入代码。
function ConvertTo-AISingleQuotedLiteral([AllowNull()][string]$Text) {
    "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent([string]$Text) + "'"
}

function New-AIPendingInvocationLine([string]$ScriptText) {
    if ([string]::IsNullOrWhiteSpace($ScriptText)) { throw '内部调度脚本不能为空。' }
    $tokens = $null; $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($ScriptText, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw "内部调度脚本无效：$($parseErrors[0].Message)" }
    if ($script:NextPendingInvocationId) { [void]$script:PendingInvocationScripts.Remove([string]$script:NextPendingInvocationId) }
    if ($script:PendingInvocationScripts.Count -ge 32) { $script:PendingInvocationScripts.Clear() }
    $id = [guid]::NewGuid().ToString('N')
    $script:PendingInvocationScripts[$id] = $ScriptText
    $script:NextPendingInvocationId = $id
    '. (Invoke-PSAI)'
}

function Get-AIPendingInvocationScript([string]$Id) {
    if ([string]$script:NextPendingInvocationId -eq $Id) { $script:NextPendingInvocationId = $null }
    if (-not $script:PendingInvocationScripts.ContainsKey($Id)) { throw '该内部调度请求不存在或已经执行。' }
    $scriptText = $script:PendingInvocationScripts[$Id]
    [void]$script:PendingInvocationScripts.Remove($Id)
    [scriptblock]::Create($scriptText)
}

function ConvertTo-AIAgentLine([string]$Task) {
    New-AIPendingInvocationLine (New-AIAgentHarnessScript $Task)
}

# F7：上一条命令失败时诊断并提议修复（可执行），成功时只解释。
function ConvertTo-AIExplainLine {
    $last = $script:LastCommand
    if (-not $last) { return "Write-Warning $(ConvertTo-AISingleQuotedLiteral (Get-AIText 'NothingToExplain'))" }
    if (-not $last.Succeeded) {
        $detail = if ($last.Error) { $last.Error } elseif ($last.ExitCode) { Get-AIText 'StepFailedExit' @($last.ExitCode) } else { Get-AIText 'StepFailed' }
        return ConvertTo-AIAgentLine (Get-AIText 'FixTask' @($last.Command, $detail))
    }
    New-AIPendingInvocationLine "Invoke-PSAI -Prompt $(ConvertTo-AISingleQuotedLiteral (Get-AIText 'ExplainTask' @($last.Command)))"
}

function Invoke-PSAI {
    [CmdletBinding()] param(
        [Parameter(Position=0,ValueFromRemainingArguments)][string[]]$Prompt,
        [Parameter(DontShow)][ValidatePattern('^[a-f0-9]{32}$')][string]$PendingInvocation
    )
    if ($PendingInvocation) { return Get-AIPendingInvocationScript $PendingInvocation }
    if (-not $PSBoundParameters.ContainsKey('Prompt') -and $script:NextPendingInvocationId) {
        $pendingId = [string]$script:NextPendingInvocationId
        $script:NextPendingInvocationId = $null
        return Get-AIPendingInvocationScript $pendingId
    }
    $text = ($Prompt -join ' ').Trim()
    if (-not $text) { return Open-PSAISettings }
    $model = Assert-AIActiveModelReady
    Add-AISessionTurn 'user' $text 'message' | Out-Null
    $result = Invoke-AISessionModel -Model $model -Instruction $null
    if ($result.Text) {
        Add-AISessionTurn 'assistant' $result.Text 'message' @{} -InputTokens ([long]$result.InputTokens) -OutputTokens ([long]$result.OutputTokens) | Out-Null
    }
}
