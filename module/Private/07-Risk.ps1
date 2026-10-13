# 命令 AST 安全分析、风险分级与审批摘要。

function Get-AICommandRisk([string]$Command) {
    $risk = [PSAITerminal.AITerminalSecurity]::ClassifyRisk('powershell', $Command)
    if ($risk -eq [PSAITerminal.AITerminalRisk]::High) { return $risk }

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { return [PSAITerminal.AITerminalRisk]::High }

    foreach ($commandAst in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $commandAst.GetCommandName()
        if (-not $name) { return [PSAITerminal.AITerminalRisk]::High }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $resolved = $false
        for ($depth = 0; $depth -lt 8 -and $seen.Add($name); $depth++) {
            # 模块会保留导入时的标准别名；顶层执行以宿主的当前重绑定为准。
            $commandInfo = Get-Alias -Name ([WildcardPattern]::Escape($name)) -Scope Global -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $commandInfo) {
                $commandInfo = Get-Item -LiteralPath ("Function:\global:" + $name) -ErrorAction SilentlyContinue
            }
            if (-not $commandInfo) {
                $commandInfo = Get-Command -Name ([WildcardPattern]::Escape($name)) -ErrorAction SilentlyContinue |
                    Select-Object -First 1
            }
            if (-not $commandInfo) { return [PSAITerminal.AITerminalRisk]::High }
            if ($commandInfo.CommandType -eq [Management.Automation.CommandTypes]::Alias) {
                $resolvedName = if ($commandInfo.ResolvedCommand) {
                    [string]$commandInfo.ResolvedCommand.Name
                } else {
                    [string]$commandInfo.Definition
                }
                if (-not $resolvedName) { return [PSAITerminal.AITerminalRisk]::High }
                $resolvedRisk = [PSAITerminal.AITerminalSecurity]::ClassifyRisk('powershell', "$resolvedName __PSAI_ARGUMENT__")
                if ([int]$resolvedRisk -gt [int]$risk) { $risk = $resolvedRisk }
                if ($risk -eq [PSAITerminal.AITerminalRisk]::High) { return $risk }
                $name = $resolvedName
                continue
            }
            $resolvedRisk = [PSAITerminal.AITerminalSecurity]::ClassifyRisk('powershell', "$($commandInfo.Name) __PSAI_ARGUMENT__")
            if ([int]$resolvedRisk -gt [int]$risk) { $risk = $resolvedRisk }
            if ($risk -eq [PSAITerminal.AITerminalRisk]::High) { return $risk }
            if ($commandInfo.CommandType -ne [Management.Automation.CommandTypes]::Cmdlet) {
                return [PSAITerminal.AITerminalRisk]::High
            }
            $resolved = $true
            break
        }
        if (-not $resolved) { return [PSAITerminal.AITerminalRisk]::High }
    }
    $risk
}

function Get-AIApprovalDigest([string]$RunId, [string]$StepId, [string]$Command,
    [Collections.IDictionary]$Proposal, [Collections.IDictionary]$Run) {
    $payload = "$($RunId.Length):$RunId$($StepId.Length):$StepId$($Command.Length):$Command"
    foreach ($field in @('purpose','expectedOutcome','sideEffects','rollbackHint','explanationReady')) {
        $value = if ($Proposal -and (Test-AIMapContains $Proposal $field)) { [string]$Proposal[$field] } else { '' }
        $payload += "$($value.Length):$value"
    }
    if ($Run -and $Run.schemaVersion -eq 2) {
        $payload += ([ordered]@{plan=$Run.plan;nextStep=$Run.nextStep;phase=$Run.phase;
            stepIndex=$Proposal.stepIndex;stepRole=$Proposal.stepRole;afterSuccess=$Proposal.afterSuccess} | ConvertTo-Json -Depth 10 -Compress)
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $hash = $hasher.ComputeHash($bytes) } finally { $hasher.Dispose() }
    ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}
