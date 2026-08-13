#requires -Version 7.4

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ModuleRoot,
    [string]$ProfilePath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$script:PathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$script:DirectorySeparator = [IO.Path]::DirectorySeparatorChar

function ConvertTo-PSAINormalizedPath([string]$Path) {
    [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
}

function Resolve-PSAIInstalledModuleRoot([string]$RequestedRoot) {
    $candidates = if ($RequestedRoot) { @($RequestedRoot) }
        else { @($env:PSModulePath -split [IO.Path]::PathSeparator) }
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not [IO.Path]::IsPathFullyQualified($candidate)) { continue }
        $fullPath = ConvertTo-PSAINormalizedPath $candidate
        if (Test-Path -LiteralPath (Join-Path $fullPath 'PSAITerminal')) { return $fullPath }
    }
    throw '没有在当前 PSModulePath 中找到 PSAITerminal。可通过 -ModuleRoot 指定安装根目录。'
}

function Write-PSAIUtf8FileAtomically([string]$Path, [string]$Content) {
    $temporaryPath = "$Path.tmp.$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($temporaryPath, $Content, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporaryPath, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
}

function Resolve-PSAIProfilePath([string]$RequestedPath) {
    $path = if ([string]::IsNullOrWhiteSpace($RequestedPath)) { [string]$PROFILE.CurrentUserCurrentHost } else { $RequestedPath }
    if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathFullyQualified($path) -or
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
$resolvedProfilePath = Resolve-PSAIProfilePath $ProfilePath
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
    if (Test-Path -LiteralPath $profilePath) {
        $content = Get-Content -LiteralPath $profilePath -Raw
        $updated = (Get-PSAIProfileUpdate $content).Content
        if ($updated -ne $content) {
            Write-PSAIUtf8FileAtomically $profilePath $updated
            $profileIntegrationRemoved = $true
        }
    }
    Remove-Item -LiteralPath $moduleBase -Recurse -Force
    [pscustomobject]@{
        RemovedPath = $moduleBase
        ProfilePath = $resolvedProfilePath
        ProfileIntegrationRemoved = $profileIntegrationRemoved
        UserDataPreserved = $true
    }
}
