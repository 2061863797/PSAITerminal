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
$moduleSource = [IO.File]::ReadAllText((Join-Path $module.ModuleBase 'PSAITerminal.psm1'), [Text.Encoding]::UTF8)

function Assert-Probe([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-ProbeThrows([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    try { & $Action; throw $Message }
    catch { if ($_.Exception.Message -eq $Message -or $_.Exception.Message -notmatch $Pattern) { throw } }
}

Assert-Probe ($moduleSource -notmatch '\$client\.Send\s*\(') '模块不能调用 Windows PowerShell 5.1 缺失的 HttpClient.Send。'
Assert-Probe ($moduleSource -notmatch 'ReadLineAsync\s*\(\s*\$CancellationToken') '模块不能调用 Windows PowerShell 5.1 缺失的可取消 ReadLineAsync 重载。'
Assert-Probe ($moduleSource -notmatch '\.Content\.ReadAsStream\s*\(') '模块不能调用 Windows PowerShell 5.1 缺失的 HttpContent.ReadAsStream。'
Assert-Probe ($moduleSource -match '\$PSVersionTable\.PSVersion\s*-ge\s*\[version\]\x27?7\.3') 'Agent Harness 必须在 5.1 中跳过 PowerShell 7 专属原生命令错误偏好变量。'

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

$lineBytes = [Text.Encoding]::UTF8.GetBytes("alpha`nbeta")
$lineStream = [IO.MemoryStream]::new($lineBytes)
$lineReader = [IO.StreamReader]::new($lineStream)
try {
    Assert-Probe (([PSAITerminal.AITerminalHttpContent]::ReadLine($lineReader, [Threading.CancellationToken]::None)) -eq 'alpha') '兼容流读取未返回第一行。'
    Assert-Probe (([PSAITerminal.AITerminalHttpContent]::ReadLine($lineReader, [Threading.CancellationToken]::None)) -eq 'beta') '兼容流读取未返回末行。'
    $lineCancellation = [Threading.CancellationTokenSource]::new()
    try {
        $lineCancellation.Cancel()
        Assert-ProbeThrows { [PSAITerminal.AITerminalHttpContent]::ReadLine($lineReader, $lineCancellation.Token) } 'cancel|取消|canceled' '兼容流读取必须响应取消令牌。'
    } finally { $lineCancellation.Dispose() }
} finally { $lineReader.Dispose(); $lineStream.Dispose() }

$streamContent = [Net.Http.StringContent]::new('stream-ok')
$contentStream = $null
$contentReader = $null
try {
    $contentStream = [PSAITerminal.AITerminalHttpContent]::ReadStream($streamContent, [Threading.CancellationToken]::None)
    $contentReader = [IO.StreamReader]::new($contentStream)
    Assert-Probe ($contentReader.ReadToEnd() -eq 'stream-ok') '兼容 HTTP 流入口未返回完整内容。'
} finally {
    if ($contentReader) { $contentReader.Dispose() }
    elseif ($contentStream) { $contentStream.Dispose() }
    $streamContent.Dispose()
}

$harnessScript = & $module {
    New-AITopLevelHarnessScript "[pscustomobject]@{RunId='host-probe';StepId='host-probe';ApprovalDigest=('a'*64);ApprovalRevision=1;Command='Get-Date | Out-Null'}"
}
function global:Start-PSAIToolExecution {
    param($RunId,$StepId,$Command,$ApprovalDigest,[long]$ApprovalRevision)
    [void]$RunId; [void]$StepId; [void]$Command; [void]$ApprovalDigest; [void]$ApprovalRevision
}
function global:Complete-PSAIToolExecution {
    param($RunId,$StepId,[bool]$Succeeded,$Output)
    [void]$RunId; [void]$StepId
    $global:HostProbeHarnessSuccess = $Succeeded
    $global:HostProbeHarnessOutput = $Output
}
try {
    . ([scriptblock]::Create($harnessScript))
    Assert-Probe ($global:HostProbeHarnessSuccess -eq $true) 'Agent Harness 在当前宿主中未能完成无副作用命令。'
} finally {
    Remove-Item Function:\Start-PSAIToolExecution,Function:\Complete-PSAIToolExecution -ErrorAction SilentlyContinue
    Remove-Variable HostProbeHarnessSuccess,HostProbeHarnessOutput -Scope Global -ErrorAction SilentlyContinue
}

$sendClient = [Net.Http.HttpClient]::new()
$sendRequest = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, 'http://127.0.0.1:1/')
$sendCancellation = [Threading.CancellationTokenSource]::new()
try {
    $sendCancellation.Cancel()
    Assert-ProbeThrows {
        [void][PSAITerminal.AITerminalHttpTransport]::Send(
            $sendClient, $sendRequest, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $sendCancellation.Token)
    } 'cancel|取消|canceled' '兼容 HTTP 发送入口必须在当前宿主中可调用并响应取消令牌。'
} finally { $sendCancellation.Dispose(); $sendRequest.Dispose(); $sendClient.Dispose() }

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
