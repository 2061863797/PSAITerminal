# 终端提示符（Prompt）安全包装与防重入。

function Get-AIPromptPrefix {
    switch ([string]$script:Config.mode) {
        'AI' { '[AI] ' }
        'Auto' { '[AUTO] ' }
        default { '' }
    }
}

function Get-AIDefaultPromptText {
    $location = [string]$ExecutionContext.SessionState.Path.CurrentLocation
    if ([string]::IsNullOrWhiteSpace($location)) { $location = [Environment]::CurrentDirectory }
    "PS $location> "
}

function Get-AIPromptIntegrationState {
    [AppDomain]::CurrentDomain.GetData($script:PromptStateVariableName)
}

function Test-AISamePromptScriptBlock([AllowNull()][scriptblock]$Left, [AllowNull()][scriptblock]$Right) {
    if (-not $Left -or -not $Right) { return $false }
    if ([object]::ReferenceEquals($Left, $Right)) { return $true }
    [string]::Equals($Left.ToString(), $Right.ToString(), [StringComparison]::Ordinal)
}

function Test-AILegacyPromptWrapper([AllowNull()][scriptblock]$ScriptBlock) {
    if (-not $ScriptBlock) { return $false }
    $text = $ScriptBlock.ToString()
    $text.Contains('Get-Module PSAITerminal') -and $text.Contains('Invoke-AIWrappedPrompt')
}

function Find-AILegacyOriginalPrompt {
    foreach ($loadedModule in @(Get-Module PSAITerminal)) {
        try {
            $candidate = & $loadedModule {
                [pscustomobject]@{
                    OriginalPrompt = $script:OriginalPrompt
                    PromptWrapper = $script:PSAIPromptWrapper
                }
            }
            if ($candidate.OriginalPrompt -and -not (Test-AILegacyPromptWrapper $candidate.OriginalPrompt)) {
                return $candidate.OriginalPrompt
            }
        } catch {
            Write-Debug "无法读取旧 PSAITerminal 实例的 Prompt 状态：$($_.Exception.Message)"
        }
    }
    $null
}

# 记录上一条交互命令的结果；失败时提示 F7。AI 调度行和模块内部命令不记录。
function Update-AILastCommandStatus([bool]$LastSuccess) {
    $errorCount = $global:Error.Count
    $newErrors = $errorCount -gt [int]$script:LastErrorCount
    $script:LastErrorCount = $errorCount
    $entry = Get-History -Count 1
    if (-not $entry -or $entry.Id -eq $script:LastHistoryId) { return }
    $script:LastHistoryId = $entry.Id
    $line = [string]$entry.CommandLine
    if ($line -match '^(?:\. \(Invoke-PSAI\)|# PSAI F7|(?:Set|Get)-PSAITerminalMode\b|Open-PSAI|Show-AICliHelp|Clear-PSAISession|New-PSAISession)') { return }
    # Test-Path 不会向 $Error 写入记录，避免覆盖要诊断的真实错误。
    $exitCode = if (Test-Path Variable:global:LASTEXITCODE) { [int]$global:LASTEXITCODE } else { 0 }
    if ([string]$entry.ExecutionStatus -eq 'Stopped') { return }
    $failed = -not $LastSuccess -or [string]$entry.ExecutionStatus -eq 'Failed'
    $detail = if (-not $failed) { $null }
        elseif ($newErrors -and $global:Error.Count) { Protect-AIText ($global:Error[0] | Out-String).Trim() 8192 }
        elseif ($exitCode) { Get-AIText 'StepFailedExit' @($exitCode) }
        else { Get-AIText 'StepFailed' }
    $script:LastCommand = [pscustomobject]@{ Command = Protect-AIText $line 16384; Succeeded = -not $failed; Error = $detail
        ExitCode = $exitCode; Source = 'Shell' }
    if ($failed -and [string]$script:Config.mode -in @('AI','Auto') -and $script:Config.activeModel) {
        Write-AIColoredHost "✗ $(Get-AIText 'CommandFailedHint')" DarkGray
    }
}

function Invoke-AIWrappedPrompt([bool]$LastSuccess = $true) {
    $lastSuccess = $LastSuccess
    $state = Get-AIPromptIntegrationState
    if ($script:PromptInvocationActive -or ($state -and [bool]$state.InvocationActive)) {
        return Get-AIDefaultPromptText
    }

    $script:PromptInvocationActive = $true
    if ($state) { $state.InvocationActive = $true }
    try {
        try { Update-AILastCommandStatus $lastSuccess }
        catch { Write-Verbose "无法记录上一条命令状态：$($_.Exception.Message)" }
        $prefix = Get-AIPromptPrefix
        if ($prefix) {
            Write-AIColoredHost $prefix DarkCyan -NoNewline
        }
        if ($script:OriginalPrompt) {
            if ($lastSuccess) { $null = $true }
            else { Write-Error 'PSAITerminal prompt status preservation' -ErrorAction Ignore }
            & $script:OriginalPrompt
        } else {
            Get-AIDefaultPromptText
        }
    } finally {
        if ($state) { $state.InvocationActive = $false }
        $script:PromptInvocationActive = $false
    }
}

function Register-AIPromptIntegration {
    if ($Host.Name -ne 'ConsoleHost' -or [Console]::IsInputRedirected) { return }
    $current = Get-Command prompt -CommandType Function -ErrorAction SilentlyContinue
    if (-not $current) { return }
    if ($script:PSAIPromptWrapper -and [object]::ReferenceEquals($current.ScriptBlock, $script:PSAIPromptWrapper)) { return }

    $state = Get-AIPromptIntegrationState
    if ($state -and (Test-AISamePromptScriptBlock $current.ScriptBlock $state.PromptWrapper)) {
        $script:OriginalPrompt = $state.OriginalPrompt
    } elseif (Test-AILegacyPromptWrapper $current.ScriptBlock) {
        $script:OriginalPrompt = Find-AILegacyOriginalPrompt
    } else {
        $script:OriginalPrompt = $current.ScriptBlock
    }
    if (-not $script:OriginalPrompt) {
        $script:OriginalPrompt = { Get-AIDefaultPromptText }
    }

    $module = $ExecutionContext.SessionState.Module
    $script:PSAIPromptWrapper = {
        # 必须是第一条语句，才能取到用户上一条命令的 $?。
        $lastSuccess = $?
        $state = [AppDomain]::CurrentDomain.GetData('__PSAITerminalPromptIntegrationState')
        if ($state -and [bool]$state.InvocationActive) {
            $location = [string]$ExecutionContext.SessionState.Path.CurrentLocation
            if ([string]::IsNullOrWhiteSpace($location)) { $location = [Environment]::CurrentDirectory }
            "PS $location> "
        } elseif ($state -and $state.Owner) {
            & $state.Owner { param($status) Invoke-AIWrappedPrompt $status } $lastSuccess
        } else {
            $location = [string]$ExecutionContext.SessionState.Path.CurrentLocation
            if ([string]::IsNullOrWhiteSpace($location)) { $location = [Environment]::CurrentDirectory }
            "PS $location> "
        }
    }
    $state = [pscustomobject]@{
        Owner = $module
        OwnerToken = $script:PromptOwnerToken
        OriginalPrompt = $script:OriginalPrompt
        PromptWrapper = $script:PSAIPromptWrapper
        OriginalReadLine = $script:OriginalPSConsoleHostReadLine
        ReadLineWrapper = $script:PSAIHostReadLine
        InvocationActive = $false
    }
    [AppDomain]::CurrentDomain.SetData($script:PromptStateVariableName, $state)
    Set-Item -LiteralPath Function:\global:prompt -Value $script:PSAIPromptWrapper
}

function Unregister-AIPromptIntegration {
    $current = Get-Command prompt -CommandType Function -ErrorAction SilentlyContinue
    $state = Get-AIPromptIntegrationState
    if ($state -and $state.OwnerToken -eq $script:PromptOwnerToken) {
        if ($script:OriginalPrompt -and $current -and (Test-AISamePromptScriptBlock $current.ScriptBlock $state.PromptWrapper)) {
            Set-Item -LiteralPath Function:\global:prompt -Value $script:OriginalPrompt
        }
        [AppDomain]::CurrentDomain.SetData($script:PromptStateVariableName, $null)
    }
    $script:OriginalPrompt = $null
    $script:PSAIPromptWrapper = $null
    $script:PromptInvocationActive = $false
}
