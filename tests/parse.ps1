#requires -Version 5.1

[CmdletBinding()]
param([string]$Root)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$files = @(
    'build.ps1',
    'Install-PSAITerminal.ps1',
    'Uninstall-PSAITerminal.ps1',
    'module/PSAITerminal.psd1',
    'module/PSAITerminal.psm1',
    'tests/host-probe.ps1'
)

foreach ($relativePath in $files) {
    $path = Join-Path $Root $relativePath
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) {
        throw "PowerShell 语法检查失败：$relativePath`n$($errors | Out-String)"
    }
}

"语法检查通过：$($PSVersionTable.PSVersion)，64 位进程=$([Environment]::Is64BitProcess)"
