#requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Current','WindowsPowerShell','PowerShell','Both')]
    [string]$TargetHost = 'Current',
    [string]$ModuleRoot,
    [string]$ProfilePath,
    [switch]$NoProfileIntegration,
    [switch]$PurgeUserData,
    [switch]$Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$safetyScript = Join-Path $PSScriptRoot 'PSAIStorageSafety.ps1'
if (-not (Test-Path -LiteralPath $safetyScript -PathType Leaf)) {
    $safetyScript = Join-Path $PSScriptRoot 'module\PSAIStorageSafety.ps1'
}
. $safetyScript
if ($env:OS -ne 'Windows_NT') { throw 'PSAITerminal 仅支持 Windows。' }
if ($NoProfileIntegration -and -not [string]::IsNullOrWhiteSpace($ProfilePath)) {
    throw '-NoProfileIntegration 与 -ProfilePath 不能同时使用。'
}
if ($TargetHost -eq 'Both' -and (-not [string]::IsNullOrWhiteSpace($ModuleRoot) -or -not [string]::IsNullOrWhiteSpace($ProfilePath))) {
    throw '-TargetHost Both 不能与 -ModuleRoot 或 -ProfilePath 同时使用。'
}
if ($env:PSAI_TEST_DOCUMENTS_HOME -and $env:PSAI_TEST_MODE -ne '1') {
    throw 'PSAI_TEST_DOCUMENTS_HOME 只能在 PSAI_TEST_MODE=1 的隔离测试中使用。'
}
$script:DocumentsRoot = if ($env:PSAI_TEST_DOCUMENTS_HOME) { [IO.Path]::GetFullPath($env:PSAI_TEST_DOCUMENTS_HOME) }
    else { [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments) }
$configHome = if ($env:PSAI_CONFIG_HOME) { $env:PSAI_CONFIG_HOME } else { Join-Path $script:DocumentsRoot 'PowerShell\PSAITerminal' }
$dataHome = if ($env:PSAI_DATA_HOME) { $env:PSAI_DATA_HOME }
    elseif ($env:PSAI_TEST_LOCALAPPDATA) { $env:PSAI_TEST_LOCALAPPDATA }
    else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PowerShell\PSAITerminal' }
if ($TargetHost -eq 'Both') {
    foreach ($hostTarget in @('WindowsPowerShell','PowerShell')) {
        $hostModule = Join-Path $script:DocumentsRoot "$hostTarget\Modules\PSAITerminal"
        Assert-PSAIModuleRemoval $hostModule
        Assert-PSAIStorageOutsideModule $hostModule @($configHome,$dataHome)
    }
    $results = foreach ($hostTarget in @('WindowsPowerShell','PowerShell')) {
        $arguments = @{ TargetHost=$hostTarget; NoProfileIntegration=$NoProfileIntegration; PurgeUserData=$PurgeUserData; Force=$Force }
        if ($PSBoundParameters.ContainsKey('Confirm')) { $arguments.Confirm = $PSBoundParameters['Confirm'] }
        if ($WhatIfPreference) { $arguments.WhatIf = $true }
        & $PSCommandPath @arguments
    }
    return $results
}
$script:ResolvedTargetHost = if ($TargetHost -eq 'Current') {
    if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' }
} else { $TargetHost }
$script:PathComparison = [StringComparison]::OrdinalIgnoreCase
$script:DirectorySeparator = [IO.Path]::DirectorySeparatorChar

$resolvedModuleRoot = Resolve-PSAIModuleRoot $ModuleRoot $script:DocumentsRoot $script:ResolvedTargetHost
$resolvedProfilePath = if ($NoProfileIntegration) { $null } else { Resolve-PSAIProfilePath $ProfilePath $script:DocumentsRoot $script:ResolvedTargetHost }
$moduleBase = ConvertTo-PSAINormalizedPath (Join-Path $resolvedModuleRoot 'PSAITerminal')
if ((Split-Path $moduleBase -Leaf) -ne 'PSAITerminal' -or
    -not (ConvertTo-PSAINormalizedPath (Split-Path $moduleBase -Parent)).Equals($resolvedModuleRoot, $script:PathComparison)) {
    throw '拒绝删除无法确认的模块目录。'
}

$moduleBaseWithSeparator = $moduleBase + $script:DirectorySeparator
$loaded = Get-Module PSAITerminal | Where-Object {
    $_.Path -and (ConvertTo-PSAINormalizedPath $_.Path).StartsWith($moduleBaseWithSeparator, $script:PathComparison)
}
if ($loaded) { throw '当前进程正在使用 PSAITerminal。请运行 pwsh -NoProfile 后再执行卸载脚本。' }

Assert-PSAIModuleRemoval $moduleBase
Assert-PSAIStorageOutsideModule $moduleBase @($configHome,$dataHome)
$profileContent = $null; $profileUpdate = $null
if ($resolvedProfilePath -and (Test-Path -LiteralPath $resolvedProfilePath)) {
    [void](Assert-PSAISafeRemovalDirectory (Split-Path -Parent $resolvedProfilePath))
    if ((Get-Item -LiteralPath $resolvedProfilePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw '拒绝修改重解析点 Profile。'
    }
    $profileContent = Read-PSAITextFile $resolvedProfilePath
    $profileUpdate = (Get-PSAIProfileUpdate $profileContent).Content
}
$purgePlan = $null; $coreAssembly = $null
if ($PurgeUserData) {
    $purgePlan = Get-PSAIStoragePurgePlan $configHome $dataHome
    $assemblyCandidates = @((Join-Path $moduleBase 'bin\PSAITerminal.dll'), (Join-Path $PSScriptRoot 'bin\PSAITerminal.dll'))
    if (Test-Path -LiteralPath $moduleBase -PathType Container) {
        $assemblyCandidates += @(Get-ChildItem -LiteralPath $moduleBase -Directory |
            Where-Object Name -Match '^\d+\.\d+\.\d+(?:\.\d+)?$' |
            Sort-Object { [version]$_.Name } -Descending | ForEach-Object { Join-Path $_.FullName 'bin\PSAITerminal.dll' })
    }
    $coreAssembly = $assemblyCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ($purgePlan.CredentialTargets.Count -and -not $coreAssembly) { throw '无法定位凭据清理所需的核心程序集，原文件未删除。' }
}
if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'None' }
if ($PSCmdlet.ShouldProcess($moduleBase, '卸载 PSAITerminal 模块')) {
    $credentialsPurged = $false; $userDataPurged = $false
    if ($PurgeUserData) {
        Assert-PSAIStoragePurgePlan $purgePlan
        Invoke-PSAICredentialPurge $purgePlan.CredentialTargets $coreAssembly
        $credentialsPurged = $true
        Remove-PSAIStorageData $purgePlan
        $userDataPurged = $true
    }
    $profileIntegrationRemoved = $false
    if ($null -ne $profileUpdate -and $profileUpdate -ne $profileContent) {
        if ((Read-PSAITextFile $resolvedProfilePath) -cne $profileContent) { throw 'Profile 在预检后已变化，停止卸载。' }
        Write-PSAIUtf8FileAtomically $resolvedProfilePath $profileUpdate
        $profileIntegrationRemoved = $true
    }
    Assert-PSAIModuleRemoval $moduleBase
    if (Test-Path -LiteralPath $moduleBase -PathType Container) { Remove-Item -LiteralPath $moduleBase -Recurse -Force -ErrorAction Stop }
    [Environment]::SetEnvironmentVariable("__PSAI_SESSION_PID_$PID", $null, 'Process')
    [pscustomobject]@{
        RemovedPath = $moduleBase
        ProfilePath = $resolvedProfilePath
        ProfileIntegrationRemoved = $profileIntegrationRemoved
        UserDataPreserved = (-not $userDataPurged)
        UserDataPurged = $userDataPurged
        CredentialsPurged = $credentialsPurged
        ModuleRemoved = (-not (Test-Path -LiteralPath $moduleBase))
    }
}
