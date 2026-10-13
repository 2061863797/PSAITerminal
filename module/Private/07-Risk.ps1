# 命令 AST 安全分析、风险分级与审批摘要。

# 命令名的静态规则在 C# 中；这里按当前会话解析别名和函数，防止重绑定绕过分级。
function Get-AICommandRisk([string]$Command) {
    $risk = [PSAITerminal.AITerminalSecurity]::ClassifyRisk($Command)
    if ($risk -eq [PSAITerminal.AITerminalRisk]::High) { return $risk }

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$parseErrors)
    foreach ($commandAst in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $commandAst.GetCommandName()
        if (-not $name) { continue }
        $resolvedName = $name
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $commandInfo = $null
        while ($seen.Add($resolvedName) -and $seen.Count -le 8) {
            $commandInfo = Get-Alias -Name ([WildcardPattern]::Escape($resolvedName)) -Scope Global -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $commandInfo) {
                $commandInfo = Get-Item -LiteralPath ("Function:\global:" + $resolvedName) -ErrorAction SilentlyContinue
            }
            if (-not $commandInfo) {
                $commandInfo = Get-Command -Name ([WildcardPattern]::Escape($resolvedName)) -ErrorAction SilentlyContinue |
                    Select-Object -First 1
            }
            if (-not $commandInfo -or $commandInfo.CommandType -ne [Management.Automation.CommandTypes]::Alias) { break }
            $resolvedName = if ($commandInfo.ResolvedCommand) { [string]$commandInfo.ResolvedCommand.Name } else { [string]$commandInfo.Definition }
        }
        if (-not $commandInfo) { continue }

        $commandRisk = [PSAITerminal.AITerminalRisk]::Low
        if ($commandInfo.CommandType -in @([Management.Automation.CommandTypes]::Function, [Management.Automation.CommandTypes]::Filter)) {
            $shadowsCmdlet = [bool](Get-Command -Name ([WildcardPattern]::Escape($resolvedName)) -CommandType Cmdlet -ErrorAction SilentlyContinue)
            if ($shadowsCmdlet) { return [PSAITerminal.AITerminalRisk]::High }
            # 只有随系统安装的模块函数（如 Get-NetIPAddress）按名称分级，会话自定义函数至少为中风险。
            if (-not (Test-AISystemModule $commandInfo.Module)) { $commandRisk = [PSAITerminal.AITerminalRisk]::Medium }
        } elseif ($commandInfo.CommandType -eq [Management.Automation.CommandTypes]::ExternalScript) {
            $commandRisk = [PSAITerminal.AITerminalRisk]::Medium
        }
        if ($resolvedName -ne $name) {
            $nameLength = $commandAst.CommandElements[0].Extent.Text.Length
            $resolvedText = $resolvedName + $commandAst.Extent.Text.Substring($nameLength)
            $aliasRisk = [PSAITerminal.AITerminalSecurity]::ClassifyRisk($resolvedText)
            if ([int]$aliasRisk -gt [int]$commandRisk) { $commandRisk = $aliasRisk }
        }
        if ([int]$commandRisk -gt [int]$risk) { $risk = $commandRisk }
        if ($risk -eq [PSAITerminal.AITerminalRisk]::High) { return $risk }
    }
    $risk
}

function Test-AISystemModule([AllowNull()][Management.Automation.PSModuleInfo]$Module) {
    if (-not $Module -or -not $Module.ModuleBase) { return $false }
    $base = [IO.Path]::GetFullPath($Module.ModuleBase).TrimEnd('\') + '\'
    foreach ($root in @($PSHOME, (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0'), (Join-Path $env:windir 'SysWOW64\WindowsPowerShell\v1.0'))) {
        if ($root -and $base.StartsWith(([IO.Path]::GetFullPath($root).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
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
