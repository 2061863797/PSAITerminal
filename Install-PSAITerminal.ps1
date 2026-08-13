#requires -Version 7.4

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ModuleRoot,
    [string]$ProfilePath,
    [switch]$NoProfileIntegration,
    [switch]$Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
if ($NoProfileIntegration -and -not [string]::IsNullOrWhiteSpace($ProfilePath)) {
    throw '-NoProfileIntegration 与 -ProfilePath 不能同时使用。'
}

$script:PathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$script:DirectorySeparator = [IO.Path]::DirectorySeparatorChar

function ConvertTo-PSAINormalizedPath([string]$Path) {
    [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
}

function Resolve-PSAIUserModuleRoot([string]$RequestedRoot) {
    $candidates = if ($RequestedRoot) { @($RequestedRoot) }
        else { @($env:PSModulePath -split [IO.Path]::PathSeparator) }
    $systemCandidates = @($PSHOME, $env:ProgramFiles, $env:windir)
    if (-not $IsWindows) { $systemCandidates += @('/usr/local/share/powershell/Modules','/usr/share/powershell/Modules') }
    $systemRoots = $systemCandidates |
        Where-Object { $_ } |
        ForEach-Object { (ConvertTo-PSAINormalizedPath $_) + $script:DirectorySeparator }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not [IO.Path]::IsPathFullyQualified($candidate)) { continue }
        $fullPath = ConvertTo-PSAINormalizedPath $candidate
        $systemPath = $false
        foreach ($root in $systemRoots) {
            if (($fullPath + $script:DirectorySeparator).StartsWith($root, $script:PathComparison)) {
                $systemPath = $true
                break
            }
        }
        if (-not $systemPath) { return $fullPath }
    }

    throw '没有找到当前用户可用的 PowerShell 模块目录。请通过 -ModuleRoot 指定用户模块目录。'
}

function Write-PSAIUtf8FileAtomically([string]$Path, [string]$Content) {
    $directory = Split-Path -Parent $Path
    if ($directory) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
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

function Get-PSAIProfileUpdate([string]$Content, [AllowNull()][string]$Block) {
    $knownRepair = $false
    $startText = '# PSAITerminal 自动加载（开始）'
    $endText = '# PSAITerminal 自动加载（结束）'
    $startMatches = @([regex]::Matches($Content, [regex]::Escape($startText)))
    if ($startMatches.Count -gt 1) {
        $innerStart = $startMatches[$startMatches.Count - 1].Index
        $openText = 'PSAITerminal 自动加载失败：$('
        $suffixText = '.Exception.Message)" }'
        $openIndex = $Content.LastIndexOf($openText, $innerStart, [StringComparison]::Ordinal)
        $innerEnd = $Content.IndexOf($endText, $innerStart, [StringComparison]::Ordinal)
        if ($openIndex -ge 0 -and $innerEnd -ge 0) {
            $suffixIndex = $Content.IndexOf($suffixText, $innerEnd + $endText.Length, [StringComparison]::Ordinal)
            if ($suffixIndex -ge 0) {
                $candidateStart = $openIndex + $openText.Length
                $candidate = $Content.Substring($candidateStart, $suffixIndex - $candidateStart)
                if ([regex]::Matches($candidate, [regex]::Escape($startText)).Count -eq 1 -and
                    [regex]::Matches($candidate, [regex]::Escape($endText)).Count -eq 1) {
                    $Content = $candidate
                    $knownRepair = $true
                }
            }
        }
    }
    $markerPattern = '(?m)(?:^|(?<=\$\())# PSAITerminal 自动加载（(?<Kind>开始|结束)）\r?$(?:\n)?'
    $markers = @([regex]::Matches($Content, $markerPattern))
    if ($markers.Count -eq 0) {
        if ($null -eq $Block) {
            return [pscustomobject]@{ Content = $Content; RepairNeeded = $false }
        }
        $separator = if ($Content -and -not $Content.EndsWith("`n")) { [Environment]::NewLine } else { '' }
        return [pscustomobject]@{
            Content = $Content + $separator + $Block.TrimEnd("`r", "`n") + [Environment]::NewLine
            RepairNeeded = $false
        }
    }

    $depth = 0
    $maximumDepth = 0
    $rangeStart = -1
    $ranges = [Collections.Generic.List[object]]::new()
    foreach ($marker in $markers) {
        if ($marker.Groups['Kind'].Value -eq '开始') {
            if ($depth -eq 0) { $rangeStart = $marker.Index }
            $depth++
            $maximumDepth = [Math]::Max($maximumDepth, $depth)
        } else {
            if ($depth -eq 0) { throw 'Profile 中的 PSAITerminal 自动加载结束标记没有对应的开始标记。' }
            $depth--
            if ($depth -eq 0) {
                $ranges.Add([pscustomobject]@{ Start = $rangeStart; Length = $marker.Index + $marker.Length - $rangeStart })
            }
        }
    }
    if ($depth -ne 0) { throw 'Profile 中的 PSAITerminal 自动加载开始标记没有对应的结束标记。' }

    $updated = $Content
    for ($index = $ranges.Count - 1; $index -ge 0; $index--) {
        $updated = $updated.Remove($ranges[$index].Start, $ranges[$index].Length)
    }
    if ($null -ne $Block) {
        $updated = $updated.Insert($ranges[0].Start, $Block.TrimEnd("`r", "`n") + [Environment]::NewLine)
    }
    [pscustomobject]@{
        Content = $updated
        RepairNeeded = $knownRepair -or $markers.Count -ne 2 -or $maximumDepth -ne 1
    }
}

function Test-PSAIPackageMatch([string]$Left, [string]$Right) {
    $expectedFiles = @(
        'PSAITerminal.psd1', 'PSAITerminal.psm1', 'bin/PSAITerminal.dll',
        'README.md', 'CHANGELOG.md', 'LICENSE', 'Install-PSAITerminal.ps1', 'Uninstall-PSAITerminal.ps1',
        'zh-CN/about_PSAITerminal.help.txt', 'en-US/about_PSAITerminal.help.txt')
    foreach ($relativePath in $expectedFiles) {
        $leftPath = Join-Path $Left $relativePath
        $rightPath = Join-Path $Right $relativePath
        if (-not (Test-Path -LiteralPath $rightPath) -or
            (Get-FileHash -LiteralPath $leftPath -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $rightPath -Algorithm SHA256).Hash) {
            return $false
        }
    }
    $expectedNames = @($expectedFiles | ForEach-Object { $_.Replace('\', '/') } | Sort-Object)
    $actualNames = @(Get-ChildItem -LiteralPath $Right -Recurse -File | ForEach-Object {
        $_.FullName.Substring($Right.Length + 1).Replace('\', '/')
    } | Sort-Object)
    if (($expectedNames -join "`n") -ne ($actualNames -join "`n")) { return $false }
    $true
}

$sourceManifest = Join-Path $PSScriptRoot 'PSAITerminal.psd1'
$requiredSourceFiles = @(
    $sourceManifest,
    (Join-Path $PSScriptRoot 'PSAITerminal.psm1'),
    (Join-Path $PSScriptRoot 'bin/PSAITerminal.dll'),
    (Join-Path $PSScriptRoot 'README.md'),
    (Join-Path $PSScriptRoot 'CHANGELOG.md'),
    (Join-Path $PSScriptRoot 'LICENSE'),
    (Join-Path $PSScriptRoot 'Uninstall-PSAITerminal.ps1'),
    (Join-Path $PSScriptRoot 'zh-CN/about_PSAITerminal.help.txt'),
    (Join-Path $PSScriptRoot 'en-US/about_PSAITerminal.help.txt')
)
foreach ($path in $requiredSourceFiles) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "发布包不完整，缺少：$path" }
}

$manifestData = Import-PowerShellDataFile -LiteralPath $sourceManifest
$moduleVersion = ([version]$manifestData.ModuleVersion).ToString()
$resolvedModuleRoot = Resolve-PSAIUserModuleRoot $ModuleRoot
$resolvedProfilePath = if ($NoProfileIntegration) { $null } else { Resolve-PSAIProfilePath $ProfilePath }
$moduleBase = Join-Path $resolvedModuleRoot 'PSAITerminal'
$destination = Join-Path $moduleBase $moduleVersion
$stage = Join-Path $moduleBase ('.install-' + [guid]::NewGuid().ToString('N'))
$backup = $null
$profileBackup = $null
$restartRequired = [bool](Get-Module PSAITerminal)

if (-not $PSCmdlet.ShouldProcess($destination, "安装 PSAITerminal $moduleVersion")) { return }

[IO.Directory]::CreateDirectory((Join-Path $stage 'bin')) | Out-Null
try {
    foreach ($name in @('PSAITerminal.psd1', 'PSAITerminal.psm1', 'README.md', 'CHANGELOG.md', 'LICENSE',
            'Install-PSAITerminal.ps1', 'Uninstall-PSAITerminal.ps1')) {
        $sourcePath = Join-Path $PSScriptRoot $name
        if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
            Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $stage $name) -Force
        }
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'bin/PSAITerminal.dll') -Destination (Join-Path $stage 'bin/PSAITerminal.dll') -Force
    foreach ($helpCulture in @('zh-CN','en-US')) {
        $helpSource = Join-Path $PSScriptRoot $helpCulture
        if (Test-Path -LiteralPath $helpSource -PathType Container) {
            Copy-Item -LiteralPath $helpSource -Destination $stage -Recurse -Force
        }
    }

    $verifyRoot = Join-Path ([IO.Path]::GetTempPath()) ('PSAITerminal.Install.' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($verifyRoot) | Out-Null
        $verifyScript = Join-Path $verifyRoot 'verify.ps1'
        $verifyScriptContent = @'
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$DataPath
)
$ErrorActionPreference = 'Stop'
$env:PSAI_CONFIG_HOME = $ConfigPath
$env:PSAI_DATA_HOME = $DataPath
Import-Module $ManifestPath -Force
if (-not (Get-Command Get-PSAIIntegrationStatus -ErrorAction SilentlyContinue)) {
    throw '发布包未导出必要的诊断命令。'
}
'@
        [IO.File]::WriteAllText($verifyScript, $verifyScriptContent, [Text.UTF8Encoding]::new($false))
        $pwshPath = (Get-Process -Id $PID).Path
        & $pwshPath -NoLogo -NoProfile -NonInteractive -File $verifyScript `
            -ManifestPath (Join-Path $stage 'PSAITerminal.psd1') `
            -ConfigPath (Join-Path $verifyRoot 'config') `
            -DataPath (Join-Path $verifyRoot 'data')
        if ($LASTEXITCODE -ne 0) { throw "发布包验证失败，退出码：$LASTEXITCODE" }
    } finally {
        if (Test-Path -LiteralPath $verifyRoot) { Remove-Item -LiteralPath $verifyRoot -Recurse -Force }
    }

    if (Test-Path -LiteralPath $destination) {
        if (Test-PSAIPackageMatch $stage $destination) {
            Remove-Item -LiteralPath $stage -Recurse -Force
        } else {
            if (-not $Force) {
                throw "目标版本已存在但内容不同：$destination。关闭正在使用该模块的 PowerShell 后使用 -Force 重试。"
            }
            $destinationWithSeparator = $destination + $script:DirectorySeparator
            $loaded = Get-Module PSAITerminal | Where-Object {
                $_.Path -and (ConvertTo-PSAINormalizedPath $_.Path).StartsWith($destinationWithSeparator, $script:PathComparison)
            }
            if ($loaded) {
                Remove-Module -ModuleInfo $loaded -Force -ErrorAction Stop
                $stillLoaded = Get-Module PSAITerminal | Where-Object {
                    $_.Path -and (ConvertTo-PSAINormalizedPath $_.Path).StartsWith($destinationWithSeparator, $script:PathComparison)
                }
                if ($stillLoaded) { throw '无法从当前会话卸载正在使用的目标版本。请关闭该 PowerShell 后重试。' }
            }
            $backup = "$destination.backup.$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
            Move-Item -LiteralPath $destination -Destination $backup
            try { Move-Item -LiteralPath $stage -Destination $destination }
            catch {
                if (-not (Test-Path -LiteralPath $destination) -and (Test-Path -LiteralPath $backup)) {
                    Move-Item -LiteralPath $backup -Destination $destination
                }
                throw
            }
        }
    } else {
        Move-Item -LiteralPath $stage -Destination $destination
    }

    if (-not $NoProfileIntegration) {
        $profilePath = $resolvedProfilePath
        $profileContent = if (Test-Path -LiteralPath $profilePath) { Get-Content -LiteralPath $profilePath -Raw } else { '' }
        $block = @'
# PSAITerminal 自动加载（开始）
try { Import-Module PSAITerminal -MinimumVersion '{VERSION}' -ErrorAction Stop }
catch { Write-Warning "PSAITerminal 自动加载失败：$($_.Exception.Message)" }
# PSAITerminal 自动加载（结束）
'@
        $block = $block.Replace('{VERSION}', $moduleVersion)
        $profileUpdate = Get-PSAIProfileUpdate $profileContent $block
        if ($profileUpdate.RepairNeeded -and (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
            $profileBackup = "$profilePath.psaiterminal-backup.$([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')).$([guid]::NewGuid().ToString('N'))"
            Copy-Item -LiteralPath $profilePath -Destination $profileBackup
            Write-Warning "检测到重复或嵌套的 PSAITerminal Profile 区块，原文件已备份：$profileBackup"
        }
        if ($profileUpdate.Content -ne $profileContent) { Write-PSAIUtf8FileAtomically $profilePath $profileUpdate.Content }
    }

    if (-not [Console]::IsOutputRedirected) {
        Write-Host ''
        Write-Host 'PSAITerminal 安装完成。 / PSAITerminal installation completed.' -ForegroundColor Green
        Write-Host '默认界面语言：English（可在设置中切换为简体中文）。 / Default UI language: English (change it in Settings).'
        Write-Host '重新打开 PowerShell 后输入 ai 开始配置模型。 / Restart PowerShell, then type ai to configure a model.'
    }

    [pscustomobject]@{
        Name = 'PSAITerminal'
        Version = $moduleVersion
        InstalledPath = $destination
        ProfileIntegration = -not $NoProfileIntegration
        ProfilePath = $resolvedProfilePath
        BackupPath = $backup
        ProfileBackupPath = $profileBackup
        RestartRequired = $restartRequired -or [bool](Get-Module PSAITerminal)
    }
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
