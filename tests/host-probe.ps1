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
$module = Get-Module PSAITerminal

function Assert-Probe([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$status = Get-PSAIIntegrationStatus
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    Assert-Probe (-not $status.OfficialIntegrationSupported) 'Windows PowerShell 不应声明支持官方预测/反馈集成。'
    Assert-Probe ($status.Prediction -eq '宿主不支持') 'Windows PowerShell 的预测状态必须明确为宿主不支持。'
    $before = [IO.File]::ReadAllText((Join-Path $ConfigPath 'config.json'), [Text.Encoding]::UTF8)
    try { Enable-PSAIPredictor; throw 'Windows PowerShell 中 Enable-PSAIPredictor 应失败。' }
    catch { if ($_.Exception.Message -notmatch '宿主不支持') { throw } }
    $after = [IO.File]::ReadAllText((Join-Path $ConfigPath 'config.json'), [Text.Encoding]::UTF8)
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

function Read-ProbeText([string]$Path) {
    & $module { param($probePath) Read-AITextFile $probePath } $Path
}

$utf8ProbePath = Join-Path $DataPath 'utf8-no-bom.txt'
$utf16ProbePath = Join-Path $DataPath 'utf16.txt'
$ansiProbePath = Join-Path $DataPath 'legacy-ansi.txt'

switch ($Phase) {
    'Create' {
        Set-PSAITerminalOption -Language zh-CN -MaxAgentSteps 9 | Out-Null
        [IO.File]::WriteAllText($utf8ProbePath, '五一点一写入中文', (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($utf16ProbePath, 'UTF16 中文内容', [Text.Encoding]::Unicode)
        [IO.File]::WriteAllText($ansiProbePath, 'legacy café', [Text.Encoding]::Default)
        Assert-Probe ((Read-ProbeText $utf8ProbePath) -eq '五一点一写入中文') 'Windows PowerShell 未正确读取无 BOM UTF-8。'
        Assert-Probe ((Read-ProbeText $utf16ProbePath) -eq 'UTF16 中文内容') 'Windows PowerShell 未正确读取 UTF-16 BOM 文件。'
        Assert-Probe ((Read-ProbeText $ansiProbePath) -eq 'legacy café') 'Windows PowerShell 未正确读取系统代码页文件。'
        New-PSAISession -Title '五一点一中文会话' | Out-Null
        if ($StoreEntryTarget) {
            Assert-Probe ([PSAITerminal.PlatformCredentialStore]::IsAvailable) 'Windows Credential Manager 不可用。'
            [PSAITerminal.PlatformCredentialStore]::Set($StoreEntryTarget, 'psai-host-probe-51')
        }
    }
    'Update' {
        $option = Get-PSAITerminalOption
        Assert-Probe ($option.Language -eq 'zh-CN' -and $option.Execution.maxAgentSteps -eq 9) 'PowerShell 7 未读取到 5.1 写入的共享配置。'
        Assert-Probe ((Read-ProbeText $utf8ProbePath) -eq '五一点一写入中文') 'PowerShell 7 未读取到 5.1 写入的无 BOM UTF-8。'
        Assert-Probe ((Read-ProbeText $utf16ProbePath) -eq 'UTF16 中文内容') 'PowerShell 7 未正确读取 UTF-16 BOM 文件。'
        Assert-Probe ((Read-ProbeText $ansiProbePath) -eq 'legacy café') 'PowerShell 7 未正确读取 Windows 系统代码页文件。'
        Assert-Probe (@(Get-PSAISession | Where-Object Title -eq '五一点一中文会话').Count -eq 1) 'PowerShell 7 未读取到 5.1 写入的中文会话。'
        Set-PSAITerminalOption -Language en-US -MaxAgentSteps 10 | Out-Null
        [IO.File]::WriteAllText($utf8ProbePath, '七点六写回中文', (New-Object Text.UTF8Encoding($false)))
        New-PSAISession -Title '七点六中文会话' | Out-Null
        if ($StoreEntryTarget) {
            Assert-Probe ([PSAITerminal.PlatformCredentialStore]::Get($StoreEntryTarget) -eq 'psai-host-probe-51') 'PowerShell 7 未读取到 5.1 写入的凭据。'
            [PSAITerminal.PlatformCredentialStore]::Set($StoreEntryTarget, 'psai-host-probe-7')
        }
    }
    'Verify' {
        $option = Get-PSAITerminalOption
        Assert-Probe ($option.Language -eq 'en-US' -and $option.Execution.maxAgentSteps -eq 10) 'Windows PowerShell 未读取到 PowerShell 7 写回的共享配置。'
        Assert-Probe ((Read-ProbeText $utf8ProbePath) -eq '七点六写回中文') 'Windows PowerShell x86 未读取到 PowerShell 7 写回的无 BOM UTF-8。'
        Assert-Probe (@(Get-PSAISession | Where-Object Title -eq '五一点一中文会话').Count -eq 1) 'Windows PowerShell x86 未读取到 5.1 中文会话。'
        Assert-Probe (@(Get-PSAISession | Where-Object Title -eq '七点六中文会话').Count -eq 1) 'Windows PowerShell x86 未读取到 PowerShell 7 中文会话。'
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
