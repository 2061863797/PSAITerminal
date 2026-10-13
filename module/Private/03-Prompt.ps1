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

function Invoke-AIWrappedPrompt {
    $lastSuccess = $?
    $state = Get-AIPromptIntegrationState
    if ($script:PromptInvocationActive -or ($state -and [bool]$state.InvocationActive)) {
        return Get-AIDefaultPromptText
    }

    $script:PromptInvocationActive = $true
    if ($state) { $state.InvocationActive = $true }
    try {
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
        $state = [AppDomain]::CurrentDomain.GetData('__PSAITerminalPromptIntegrationState')
        if ($state -and [bool]$state.InvocationActive) {
            $location = [string]$ExecutionContext.SessionState.Path.CurrentLocation
            if ([string]::IsNullOrWhiteSpace($location)) { $location = [Environment]::CurrentDirectory }
            "PS $location> "
        } elseif ($state -and $state.Owner) {
            & $state.Owner { Invoke-AIWrappedPrompt }
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
