#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ModulePath,
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$DataPath,
    [string]$StoreEntryTarget,
    [ValidateSet('Create','Update','Verify')][string]$Phase
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$env:PSAI_CONFIG_HOME = [IO.Path]::GetFullPath($ConfigPath)
$env:PSAI_DATA_HOME = [IO.Path]::GetFullPath($DataPath)
Import-Module $ModulePath -Force

function Assert-Probe([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$status = Get-PSAIIntegrationStatus
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    Assert-Probe (-not $status.OfficialIntegrationSupported) 'Windows PowerShell 不应声明支持官方预测/反馈集成。'
    Assert-Probe ($status.Prediction -eq '宿主不支持') 'Windows PowerShell 的预测状态必须明确为宿主不支持。'
    $before = Get-Content -LiteralPath (Join-Path $ConfigPath 'config.json') -Raw
    try { Enable-PSAIPredictor; throw 'Windows PowerShell 中 Enable-PSAIPredictor 应失败。' }
    catch { if ($_.Exception.Message -notmatch '宿主不支持') { throw } }
    $after = Get-Content -LiteralPath (Join-Path $ConfigPath 'config.json') -Raw
    Assert-Probe ($before -ceq $after) '拒绝预测器操作时不能修改共享配置。'
} else {
    Assert-Probe $status.OfficialIntegrationSupported 'PowerShell 7.4+ 必须加载官方预测/反馈集成。'
}

$risks = @(
    [PSAITerminal.AITerminalSecurity]::ClassifyRisk('powershell','Get-ChildItem').ToString(),
    [PSAITerminal.AITerminalSecurity]::ClassifyRisk('powershell','Set-Location C:\').ToString(),
    [PSAITerminal.AITerminalSecurity]::ClassifyRisk('powershell','Remove-Item C:\probe.txt').ToString()
)
Assert-Probe (($risks -join ',') -eq 'Low,Medium,High') '低/中/高风险分类与安全约定不一致。'

switch ($Phase) {
    'Create' {
        Set-PSAITerminalOption -Language zh-CN -MaxAgentSteps 9 | Out-Null
        if ($StoreEntryTarget) {
            Assert-Probe ([PSAITerminal.PlatformCredentialStore]::IsAvailable) 'Windows Credential Manager 不可用。'
            [PSAITerminal.PlatformCredentialStore]::Set($StoreEntryTarget, 'psai-host-probe-51')
        }
    }
    'Update' {
        $option = Get-PSAITerminalOption
        Assert-Probe ($option.Language -eq 'zh-CN' -and $option.Execution.maxAgentSteps -eq 9) 'PowerShell 7 未读取到 5.1 写入的共享配置。'
        Set-PSAITerminalOption -Language en-US -MaxAgentSteps 10 | Out-Null
        if ($StoreEntryTarget) {
            Assert-Probe ([PSAITerminal.PlatformCredentialStore]::Get($StoreEntryTarget) -eq 'psai-host-probe-51') 'PowerShell 7 未读取到 5.1 写入的凭据。'
            [PSAITerminal.PlatformCredentialStore]::Set($StoreEntryTarget, 'psai-host-probe-7')
        }
    }
    'Verify' {
        $option = Get-PSAITerminalOption
        Assert-Probe ($option.Language -eq 'en-US' -and $option.Execution.maxAgentSteps -eq 10) 'Windows PowerShell 未读取到 PowerShell 7 写回的共享配置。'
        if ($StoreEntryTarget) {
            try {
                Assert-Probe ([PSAITerminal.PlatformCredentialStore]::Get($StoreEntryTarget) -eq 'psai-host-probe-7') 'Windows PowerShell x86 未读取到 PowerShell 7 写回的凭据。'
            } finally {
                [PSAITerminal.PlatformCredentialStore]::Remove($StoreEntryTarget)
            }
        }
    }
}

[pscustomobject]@{
    Edition = $status.HostEdition
    Version = $status.HostVersion
    Is64Bit = [Environment]::Is64BitProcess
    Phase = $Phase
    Risks = $risks -join ','
    CredentialChecked = [bool]$StoreEntryTarget
} | ConvertTo-Json -Compress

Remove-Module PSAITerminal
