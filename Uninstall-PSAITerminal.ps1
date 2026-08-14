#requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Current','WindowsPowerShell','PowerShell','Both')]
    [string]$TargetHost = 'Current',
    [string]$ModuleRoot,
    [string]$ProfilePath,
    [switch]$NoProfileIntegration
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'PSAITerminal 0.6.0 仅支持 Windows。' }
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
if ($TargetHost -eq 'Both') {
    $results = foreach ($hostTarget in @('WindowsPowerShell','PowerShell')) {
        $arguments = @{ TargetHost=$hostTarget; NoProfileIntegration=$NoProfileIntegration; Confirm=$false }
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

function ConvertTo-PSAINormalizedPath([string]$Path) {
    [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
}

function Test-PSAIPathFullyQualified([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    [IO.Path]::GetFullPath($Path) -eq $Path -or $Path -match '^[A-Za-z]:[\\/]'
}

function Read-PSAITextFile([Parameter(Mandatory)][string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return '' }

    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) {
        return (New-Object Text.UTF32Encoding($false, $false, $true)).GetString($bytes, 4, $bytes.Length - 4)
    }
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
        return (New-Object Text.UTF32Encoding($true, $false, $true)).GetString($bytes, 4, $bytes.Length - 4)
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return $strictUtf8.GetString($bytes, 3, $bytes.Length - 3)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }

    try { return $strictUtf8.GetString($bytes) }
    catch [Text.DecoderFallbackException] {
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            return [Text.Encoding]::Default.GetString($bytes)
        }
        try {
            $providerType = [Type]::GetType('System.Text.CodePagesEncodingProvider, System.Text.Encoding.CodePages', $false)
            if ($providerType) {
                $provider = $providerType.GetProperty('Instance').GetValue($null, $null)
                [Text.Encoding]::RegisterProvider($provider)
            }
            $codePage = [Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
            return [Text.Encoding]::GetEncoding($codePage).GetString($bytes)
        } catch {
            throw "文件不是有效 UTF-8，且无法按系统代码页读取：$Path。$($_.Exception.Message)"
        }
    }
}

function Resolve-PSAIInstalledModuleRoot([string]$RequestedRoot) {
    $candidate = if ($RequestedRoot) { $RequestedRoot } else { Join-Path $script:DocumentsRoot "$script:ResolvedTargetHost\Modules" }
    if (-not (Test-PSAIPathFullyQualified $candidate)) { throw "模块根目录必须是完整路径：$candidate" }
    $fullPath = ConvertTo-PSAINormalizedPath $candidate
    $rootPath = [IO.Path]::GetPathRoot($fullPath).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if ($fullPath.Equals($rootPath, $script:PathComparison)) { throw "拒绝使用磁盘根目录作为模块根：$fullPath" }
    foreach ($protectedPath in @($PSHOME,$env:ProgramFiles,[Environment]::GetEnvironmentVariable('ProgramFiles(x86)'),$env:windir)) {
        if (-not $protectedPath) { continue }
        $protectedRoot = (ConvertTo-PSAINormalizedPath $protectedPath) + $script:DirectorySeparator
        if (($fullPath + $script:DirectorySeparator).StartsWith($protectedRoot, $script:PathComparison)) {
            throw "拒绝使用系统目录作为模块根：$fullPath"
        }
    }
    $fullPath
}

function Write-PSAIUtf8FileAtomically([string]$Path, [string]$Content) {
    $temporaryPath = "$Path.tmp.$([guid]::NewGuid().ToString('N'))"
    $replacementBackup = "$Path.replace-backup.$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($temporaryPath, $Content, (New-Object Text.UTF8Encoding($true)))
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temporaryPath, $Path, $replacementBackup)
            Remove-Item -LiteralPath $replacementBackup -Force
        }
        else { [IO.File]::Move($temporaryPath, $Path) }
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
        if (Test-Path -LiteralPath $replacementBackup) { Remove-Item -LiteralPath $replacementBackup -Force }
    }
}

function Resolve-PSAIProfilePath([string]$RequestedPath) {
    $path = if ([string]::IsNullOrWhiteSpace($RequestedPath)) { Join-Path $script:DocumentsRoot "$script:ResolvedTargetHost\Microsoft.PowerShell_profile.ps1" } else { $RequestedPath }
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-PSAIPathFullyQualified $path) -or
        [IO.Path]::GetExtension($path) -ne '.ps1') {
        throw 'Profile 路径必须是完整的 .ps1 文件路径。'
    }
    $resolved = [IO.Path]::GetFullPath($path)
    if (Test-Path -LiteralPath $resolved -PathType Container) { throw "Profile 路径指向目录：$resolved" }
    $resolved
}

function Get-PSAIProfileUpdate([string]$Content) {
    $startText = '# PSAITerminal 自动加载（开始）'; $endText = '# PSAITerminal 自动加载（结束）'
    $startMatches = @([regex]::Matches($Content, [regex]::Escape($startText)))
    if ($startMatches.Count -gt 1) {
        $innerStart = $startMatches[$startMatches.Count - 1].Index
        $openText = 'PSAITerminal 自动加载失败：$('; $suffixText = '.Exception.Message)" }'
        $openIndex = $Content.LastIndexOf($openText, $innerStart, [StringComparison]::Ordinal)
        $innerEnd = $Content.IndexOf($endText, $innerStart, [StringComparison]::Ordinal)
        if ($openIndex -ge 0 -and $innerEnd -ge 0) {
            $suffixIndex = $Content.IndexOf($suffixText, $innerEnd + $endText.Length, [StringComparison]::Ordinal)
            if ($suffixIndex -ge 0) {
                $candidateStart = $openIndex + $openText.Length
                $candidate = $Content.Substring($candidateStart, $suffixIndex - $candidateStart)
                if ([regex]::Matches($candidate, [regex]::Escape($startText)).Count -eq 1 -and
                    [regex]::Matches($candidate, [regex]::Escape($endText)).Count -eq 1) { $Content = $candidate }
            }
        }
    }
    $markerPattern = '(?m)(?:^|(?<=\$\())# PSAITerminal 自动加载（(?<Kind>开始|结束)）\r?$(?:\n)?'
    $markers = @([regex]::Matches($Content, $markerPattern))
    if ($markers.Count -eq 0) { return [pscustomobject]@{ Content = $Content; HasBlock = $false } }
    $depth = 0; $rangeStart = -1
    $ranges = [Collections.Generic.List[object]]::new()
    foreach ($marker in $markers) {
        if ($marker.Groups['Kind'].Value -eq '开始') {
            if ($depth -eq 0) { $rangeStart = $marker.Index }
            $depth++
        } else {
            if ($depth -eq 0) { throw 'Profile 中的 PSAITerminal 自动加载结束标记没有对应的开始标记。' }
            $depth--
            if ($depth -eq 0) { $ranges.Add([pscustomobject]@{ Start = $rangeStart; Length = $marker.Index + $marker.Length - $rangeStart }) }
        }
    }
    if ($depth -ne 0) { throw 'Profile 中的 PSAITerminal 自动加载开始标记没有对应的结束标记。' }
    $updated = $Content
    for ($index = $ranges.Count - 1; $index -ge 0; $index--) {
        $updated = $updated.Remove($ranges[$index].Start, $ranges[$index].Length)
    }
    [pscustomobject]@{ Content = $updated; HasBlock = $true }
}

$resolvedModuleRoot = Resolve-PSAIInstalledModuleRoot $ModuleRoot
$resolvedProfilePath = if ($NoProfileIntegration) { $null } else { Resolve-PSAIProfilePath $ProfilePath }
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

if ($PSCmdlet.ShouldProcess($moduleBase, '卸载 PSAITerminal 模块')) {
    $profilePath = $resolvedProfilePath
    $profileIntegrationRemoved = $false
    if ($profilePath -and (Test-Path -LiteralPath $profilePath)) {
        $content = Read-PSAITextFile $profilePath
        $updated = (Get-PSAIProfileUpdate $content).Content
        if ($updated -ne $content) {
            Write-PSAIUtf8FileAtomically $profilePath $updated
            $profileIntegrationRemoved = $true
        }
    }
    if (Test-Path -LiteralPath $moduleBase -PathType Container) { Remove-Item -LiteralPath $moduleBase -Recurse -Force }
    [pscustomobject]@{
        RemovedPath = $moduleBase
        ProfilePath = $resolvedProfilePath
        ProfileIntegrationRemoved = $profileIntegrationRemoved
        UserDataPreserved = $true
    }
}
