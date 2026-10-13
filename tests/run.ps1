[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'module', Justification = '由点源的 tests/suites 使用。')]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# 用例按主题位于 tests/suites，按文件名顺序在本作用域内点源执行，共享模块与临时目录状态。
$root = Split-Path -Parent $PSScriptRoot
$releaseVersion = ([version](Import-PowerShellDataFile -LiteralPath (Join-Path $root 'module/PSAITerminal.psd1')).ModuleVersion).ToString()
$releaseLabel = if ([string]::IsNullOrWhiteSpace($env:PSAI_RELEASE_LABEL)) {
    $releaseVersion
} else {
    [string]$env:PSAI_RELEASE_LABEL
}
if ($releaseLabel -ne $releaseVersion -and
    $releaseLabel -notmatch ('^' + [regex]::Escape($releaseVersion) + '-[0-9A-Za-z]+(?:-[0-9A-Za-z]+)*$')) {
    throw "测试发布标签无效：$releaseLabel"
}
$moduleOutput = Join-Path $root "out/PSAITerminal-$releaseLabel"
$modulePath = Join-Path $moduleOutput 'PSAITerminal.psd1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("PSAITerminal.Tests." + [guid]::NewGuid().ToString('N'))
$env:PSAI_CONFIG_HOME = Join-Path $testRoot 'config'
$env:PSAI_DATA_HOME = Join-Path $testRoot 'data'
$isWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if ($isWindowsHost -and $env:ProgramW6432) {
    $x64Modules = Join-Path $env:ProgramW6432 'WindowsPowerShell\Modules'
    if (Test-Path -LiteralPath $x64Modules) {
        $modulePaths = @($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { $_ })
        if ($modulePaths -notcontains $x64Modules) {
            $env:PSModulePath = "$x64Modules;$env:PSModulePath"
        }
    }
}
[void][IO.Directory]::CreateDirectory($testRoot)
$testsRoot = $PSScriptRoot
. (Join-Path $testsRoot 'common.ps1')

try {
    if (-not (Test-Path -LiteralPath $modulePath)) { throw "测试模块不存在：$modulePath" }
    Import-Module $modulePath -Force
    $module = Get-Module PSAITerminal
    foreach ($suite in @(Get-ChildItem -LiteralPath (Join-Path $testsRoot 'suites') -Filter '*.Tests.ps1' -File | Sort-Object Name)) {
        . $suite.FullName
    }
    Write-Host 'PSAITerminal 完整回归测试通过。' -ForegroundColor Green
} finally {
    Remove-Item Function:\Read-Host,Function:\Start-PSAIToolExecution,Function:\Complete-PSAIToolExecution -ErrorAction SilentlyContinue
    Remove-Module PSAITerminal -ErrorAction SilentlyContinue
    Remove-Item Env:PSAI_CONFIG_HOME,Env:PSAI_DATA_HOME -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
