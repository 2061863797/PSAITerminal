#requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Current','WindowsPowerShell','PowerShell','Both')]
    [string]$TargetHost = 'Current',
    [string]$ModuleRoot,
    [string]$ProfilePath,
    [switch]$NoProfileIntegration,
    [switch]$Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$safetyScript = Join-Path $PSScriptRoot 'PSAIStorageSafety.ps1'
if (-not (Test-Path -LiteralPath $safetyScript -PathType Leaf)) {
    $safetyScript = Join-Path $PSScriptRoot 'module\PSAIStorageSafety.ps1'
}
. $safetyScript
if ($NoProfileIntegration -and -not [string]::IsNullOrWhiteSpace($ProfilePath)) {
    throw '-NoProfileIntegration 与 -ProfilePath 不能同时使用。'
}
if ($env:OS -ne 'Windows_NT') { throw 'PSAITerminal 仅支持 Windows。' }
if ($TargetHost -eq 'Both' -and (-not [string]::IsNullOrWhiteSpace($ModuleRoot) -or -not [string]::IsNullOrWhiteSpace($ProfilePath))) {
    throw '-TargetHost Both 不能与 -ModuleRoot 或 -ProfilePath 同时使用。'
}

if ($env:PSAI_TEST_DOCUMENTS_HOME -and $env:PSAI_TEST_MODE -ne '1') {
    throw 'PSAI_TEST_DOCUMENTS_HOME 只能在 PSAI_TEST_MODE=1 的隔离测试中使用。'
}
$script:DocumentsRoot = if ($env:PSAI_TEST_DOCUMENTS_HOME) {
    [IO.Path]::GetFullPath($env:PSAI_TEST_DOCUMENTS_HOME)
} else { [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments) }

if ($TargetHost -eq 'Both') {
    $results = foreach ($hostTarget in @('WindowsPowerShell','PowerShell')) {
        $arguments = @{ TargetHost=$hostTarget; NoProfileIntegration=$NoProfileIntegration; Force=$Force; Confirm=$false }
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

function Test-PSAIPackageMatch([string]$Left, [string]$Right) {
    $expectedFiles = @(
        'PSAITerminal.psd1', 'PSAITerminal.psm1', 'PSAIStorageSafety.ps1', 'bin/PSAITerminal.dll',
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
    (Join-Path $PSScriptRoot 'PSAIStorageSafety.ps1'),
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
$resolvedModuleRoot = Resolve-PSAIModuleRoot $ModuleRoot $script:DocumentsRoot $script:ResolvedTargetHost
$resolvedProfilePath = if ($NoProfileIntegration) { $null } else { Resolve-PSAIProfilePath $ProfilePath $script:DocumentsRoot $script:ResolvedTargetHost }
$moduleBase = Join-Path $resolvedModuleRoot 'PSAITerminal'
$destination = Join-Path $moduleBase $moduleVersion
$stage = Join-Path $moduleBase ('.install-' + [guid]::NewGuid().ToString('N'))
$backup = $null
$profileBackup = $null
$restartRequired = [bool](Get-Module PSAITerminal)

if (-not $PSCmdlet.ShouldProcess($destination, "安装 PSAITerminal $moduleVersion")) { return }

[IO.Directory]::CreateDirectory((Join-Path $stage 'bin')) | Out-Null
try {
    foreach ($name in @('PSAITerminal.psd1', 'PSAITerminal.psm1', 'PSAIStorageSafety.ps1', 'README.md', 'CHANGELOG.md', 'LICENSE',
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
        [IO.File]::WriteAllText($verifyScript, $verifyScriptContent, (New-Object Text.UTF8Encoding($true)))
        $pwshPath = if ($script:ResolvedTargetHost -eq 'WindowsPowerShell') {
            Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
        } else { (Get-Command pwsh.exe -ErrorAction Stop).Source }
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
        $profileContent = if (Test-Path -LiteralPath $profilePath) { Read-PSAITextFile $profilePath } else { '' }
        $block = @'
# PSAITerminal 自动加载（开始）
$__psaiModuleRoot = '{MODULE_ROOT}'
if (@($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $__psaiModuleRoot) {
    $env:PSModulePath = $__psaiModuleRoot + [IO.Path]::PathSeparator + $env:PSModulePath
}
try { Import-Module PSAITerminal -MinimumVersion '{VERSION}' -ErrorAction Stop }
catch { Write-Warning "PSAITerminal 自动加载失败：$($_.Exception.Message)" }
Remove-Variable __psaiModuleRoot -ErrorAction SilentlyContinue
# PSAITerminal 自动加载（结束）
'@
        $escapedModuleRoot = $resolvedModuleRoot.Replace("'", "''")
        $block = $block.Replace('{MODULE_ROOT}', $escapedModuleRoot).Replace('{VERSION}', $moduleVersion)
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
