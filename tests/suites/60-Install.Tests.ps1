# 配置迁移、安装器、Profile 修复、内置与独立卸载、Both 目标。
# 由 tests/run.ps1 在同一作用域内按文件名顺序点源执行，依赖其中的 $module、$testRoot 等状态，不能单独运行。

# v1 配置迁移以及损坏配置不被导入过程覆盖。
$legacyRoot = Join-Path $testRoot 'legacy'
Remove-Item Env:PSAI_CONFIG_HOME,Env:PSAI_DATA_HOME -ErrorAction SilentlyContinue
$env:PSAI_CONFIG_HOME = Join-Path $legacyRoot 'config'; $env:PSAI_DATA_HOME = Join-Path $legacyRoot 'data'
[void][IO.Directory]::CreateDirectory($env:PSAI_CONFIG_HOME)
$legacy = @{schemaVersion=1;shortcutPresetVersion=3;shortcuts=@{cycleMode='F6';forceAI='Ctrl+Enter';forceShell='Ctrl+Shift+Enter';explainLast='F7'}}
$legacy | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $env:PSAI_CONFIG_HOME 'config.json') -Encoding utf8
Import-Module $modulePath -Force
Assert-Equal 'F2' (Get-PSAITerminalOption).Shortcuts.forceAI '旧快捷键应迁移到 F2。'
Assert-Equal 'F3' (Get-PSAITerminalOption).Shortcuts.forceShell '旧快捷键应迁移到 F3。'
Remove-Module PSAITerminal

$corruptRoot = Join-Path $testRoot 'corrupt'
$env:PSAI_CONFIG_HOME = Join-Path $corruptRoot 'config'; $env:PSAI_DATA_HOME = Join-Path $corruptRoot 'data'
[void][IO.Directory]::CreateDirectory($env:PSAI_CONFIG_HOME)
$corruptPath = Join-Path $env:PSAI_CONFIG_HOME 'config.json'
$corruptText = '{not-json'
Set-Content -LiteralPath $corruptPath -Value $corruptText -NoNewline
Import-Module $modulePath -Force -WarningAction SilentlyContinue
Assert-Equal $corruptText (Get-Content -LiteralPath $corruptPath -Raw) '损坏配置不能在导入期间被覆盖。'
Assert-True (@(Get-ChildItem -LiteralPath $env:PSAI_CONFIG_HOME -Filter 'config.json.corrupt.*.json').Count -eq 1) '损坏配置应创建旁路备份。'

# 发布安装器必须尊重调用进程的自定义 PSModulePath，并支持按名称导入和安全卸载。
Remove-Module PSAITerminal
$originalModulePath = $env:PSModulePath
$installRoot = Join-Path $testRoot 'installer/CustomModules'
$testProfile = Join-Path $testRoot 'installer/Microsoft.PowerShell_profile.ps1'
$installResult = & (Join-Path $moduleOutput 'Install-PSAITerminal.ps1') `
    -ModuleRoot $installRoot -ProfilePath $testProfile
Assert-True (Test-Path -LiteralPath $installResult.InstalledPath) '安装器必须创建版本化模块目录。'
Assert-Equal ([IO.Path]::GetFullPath($testProfile)) $installResult.ProfilePath '安装器必须返回实际写入的 Profile 路径。'
$profileContent = Get-Content -LiteralPath $testProfile -Raw
Assert-Match $profileContent ([regex]::Escape("Import-Module PSAITerminal -MinimumVersion '$releaseVersion'")) '安装器必须写入带最低版本的自动加载区块。'
Assert-Match $profileContent ([regex]::Escape("`$__psaiModuleRoot = '$installRoot'")) '安装器必须把实际模块根写入自动加载区块。'
& (Join-Path $moduleOutput 'Install-PSAITerminal.ps1') -ModuleRoot $installRoot -ProfilePath $testProfile | Out-Null
$repeatedProfileContent = Get-Content -LiteralPath $testProfile -Raw
Assert-Equal 1 @([regex]::Matches($repeatedProfileContent, 'PSAITerminal 自动加载（开始）')).Count '重复安装不能重复写入 Profile 区块。'
Assert-True $repeatedProfileContent.Contains('$($_.Exception.Message)') '重复安装必须保留 Profile 区块中的 PowerShell 表达式，不能把它当成正则替换语法。'
# 兼容旧版正则替换已经生成的嵌套区块：修复前保留原文件备份，用户内容只保留一份。
$profilePattern = '(?ms)^# PSAITerminal 自动加载（开始）\r?\n.*?^# PSAITerminal 自动加载（结束）\r?\n?'
$corruptProfileContent = "# 用户内容（前）`n$repeatedProfileContent# 用户内容（后）`n"
for ($corruptionIndex = 0; $corruptionIndex -lt 3; $corruptionIndex++) {
    $corruptProfileContent = [regex]::Replace(
        $corruptProfileContent,
        $profilePattern,
        $repeatedProfileContent + [Environment]::NewLine)
}
Set-Content -LiteralPath $testProfile -Value $corruptProfileContent -NoNewline -Encoding utf8
$repairInstall = & (Join-Path $moduleOutput 'Install-PSAITerminal.ps1') -ModuleRoot $installRoot -ProfilePath $testProfile
$repairedProfileContent = Get-Content -LiteralPath $testProfile -Raw
Assert-Equal 1 @([regex]::Matches($repairedProfileContent, 'PSAITerminal 自动加载（开始）')).Count '安装器必须合并旧版生成的嵌套 Profile 区块。'
Assert-Equal 1 @([regex]::Matches($repairedProfileContent, '# 用户内容（前）')).Count '修复 Profile 时不能重复用户原有内容。'
Assert-Equal 1 @([regex]::Matches($repairedProfileContent, '# 用户内容（后）')).Count '修复 Profile 时不能丢失用户原有内容。'
Assert-True ([string]$repairInstall.ProfileBackupPath -and (Test-Path -LiteralPath $repairInstall.ProfileBackupPath)) '修复损坏 Profile 前必须创建备份。'
Assert-Equal $corruptProfileContent (Get-Content -LiteralPath $repairInstall.ProfileBackupPath -Raw) 'Profile 备份必须保存修复前的原始内容。'
Set-Content -LiteralPath (Join-Path $repairInstall.InstalledPath 'old-stale.txt') -Value 'stale' -NoNewline -Encoding utf8
Assert-Throws { & (Join-Path $moduleOutput 'Install-PSAITerminal.ps1') -ModuleRoot $installRoot -ProfilePath $testProfile } '内容不同' '安装器必须拒绝带有额外残留文件的同版本目录。'
Remove-Item -LiteralPath (Join-Path $repairInstall.InstalledPath 'old-stale.txt') -Force
Assert-Throws { & (Join-Path $moduleOutput 'Install-PSAITerminal.ps1') -ModuleRoot $installRoot -ProfilePath '.\relative.ps1' } '完整的 .ps1' '安装器必须拒绝相对 Profile 路径。'
Assert-Throws { & (Join-Path $moduleOutput 'Install-PSAITerminal.ps1') -ModuleRoot $installRoot -NoProfileIntegration -ProfilePath $testProfile } '不能同时使用' '安装器必须拒绝矛盾的 Profile 参数。'
$env:PSModulePath = $originalModulePath
$env:PSAI_CONFIG_HOME = Join-Path $testRoot 'installer/config'
$env:PSAI_DATA_HOME = Join-Path $testRoot 'installer/data'
. $testProfile
$installedModule = Get-Module PSAITerminal
$installComparison = if ($isWindowsHost) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$installPrefix = [IO.Path]::GetFullPath($installRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
Assert-True ([IO.Path]::GetFullPath($installedModule.Path).StartsWith($installPrefix, $installComparison)) '安装后必须能从自定义 PSModulePath 按名称导入。'
Assert-True (@($env:PSModulePath -split [IO.Path]::PathSeparator) -contains [IO.Path]::GetFullPath($installRoot)) 'Profile 必须在宿主缺少用户模块路径时补回实际模块根。'
Assert-True (Test-Path -LiteralPath (Join-Path $installedModule.ModuleBase 'Uninstall-PSAITerminal.ps1')) '发布目录必须包含卸载脚本。'
Assert-True (Test-Path -LiteralPath (Join-Path $installedModule.ModuleBase 'zh-CN/about_PSAITerminal.help.txt')) '发布目录必须包含简体中文帮助主题。'
Assert-True (Test-Path -LiteralPath (Join-Path $installedModule.ModuleBase 'en-US/about_PSAITerminal.help.txt')) '发布目录必须包含英文帮助主题。'
Set-Content -LiteralPath (Join-Path $installedModule.ModuleBase 'loaded-stale.txt') -Value 'stale' -NoNewline -Encoding utf8
$loadedForceInstall = & (Join-Path $moduleOutput 'Install-PSAITerminal.ps1') `
    -ModuleRoot $installRoot -ProfilePath $testProfile -Force
Assert-Equal $null (Get-Module PSAITerminal) '带 -Force 升级时必须先从当前会话移除正在使用的目标版本。'
Assert-Equal $true $loadedForceInstall.RestartRequired '替换已加载模块后必须明确要求重启 PowerShell。'
Assert-True ([string]$loadedForceInstall.BackupPath -and (Test-Path -LiteralPath $loadedForceInstall.BackupPath)) '替换已加载版本前必须保留原目录备份。'
Assert-Equal $false (Test-Path -LiteralPath (Join-Path $loadedForceInstall.InstalledPath 'loaded-stale.txt')) '强制升级后的目标目录不能保留旧文件。'
& (Join-Path $moduleOutput 'Uninstall-PSAITerminal.ps1') -ModuleRoot $installRoot -ProfilePath $testProfile | Out-Null
Assert-Equal $false (Test-Path -LiteralPath (Join-Path $installRoot 'PSAITerminal')) '卸载器必须只删除指定模块目录。'
Assert-True (Test-Path -LiteralPath $env:PSAI_CONFIG_HOME) '卸载器默认必须保留用户配置。'
Assert-Equal $false ((Get-Content -LiteralPath $testProfile -Raw) -match 'PSAITerminal 自动加载') '卸载器必须移除自己的 Profile 区块。'
$env:PSModulePath = $originalModulePath

# 测试模块内置 Uninstall-PSAITerminal 与清单导出
$manifest = Import-PowerShellDataFile (Join-Path $moduleOutput 'PSAITerminal.psd1')
Assert-True ($manifest.FunctionsToExport -contains 'Uninstall-PSAITerminal') '模块清单必须导出 Uninstall-PSAITerminal。'

# 在隔离子进程中测试模块内置 Uninstall-PSAITerminal 的 Profile 清理与用户数据清除
$sandboxModuleDir = Join-Path $testRoot 'installer/sandbox-module/PSAITerminal'
Copy-Item -LiteralPath $moduleOutput -Destination $sandboxModuleDir -Recurse -Force
$testBuiltinProfile = Join-Path $testRoot 'builtin-uninstall-profile.ps1'
$testBuiltinConfig = Join-Path $testRoot 'builtin-uninstall-config'
$testBuiltinData = Join-Path $testRoot 'builtin-uninstall-data'
$escapedSandboxPsd1 = [IO.Path]::GetFullPath((Join-Path $sandboxModuleDir 'PSAITerminal.psd1')).Replace("'", "''")
$escapedProfile = [IO.Path]::GetFullPath($testBuiltinProfile).Replace("'", "''")
$escapedConfig = [IO.Path]::GetFullPath($testBuiltinConfig).Replace("'", "''")
$escapedData = [IO.Path]::GetFullPath($testBuiltinData).Replace("'", "''")

$testBuiltinScript = Join-Path $testRoot 'builtin-uninstall-test.ps1'
$builtinTestScript = @"
`$ErrorActionPreference = 'Stop'
`$testProfile = '$escapedProfile'
`$testConfig = '$escapedConfig'
`$testData = '$escapedData'
[IO.File]::WriteAllText(`$testProfile, "# User Profile Content`r`n# PSAITerminal 自动加载（开始）`r`nImport-Module PSAITerminal`r`n# PSAITerminal 自动加载（结束）`r`n", [Text.Encoding]::UTF8)
[void][IO.Directory]::CreateDirectory(`$testConfig)
[void][IO.Directory]::CreateDirectory(`$testData)
[IO.File]::WriteAllText((Join-Path `$testData 'cache.dat'), '123', [Text.Encoding]::UTF8)

`$env:PSAI_CONFIG_HOME = `$testConfig
`$env:PSAI_DATA_HOME = `$testData
`$PROFILE.CurrentUserCurrentHost = `$testProfile

Import-Module '$escapedSandboxPsd1' -Force
Set-PSAITerminalOption -Language zh-CN | Out-Null
try { Uninstall-PSAITerminal -PurgeUserData -Force | Out-Null }
catch {
    # Windows 宿主可能保持已加载 DLL 的文件锁；必须明确失败，由独立脚本完成。
    if (`$_.Exception.Message -notmatch '模块文件删除失败') { throw }
}
`$profileAfter = [IO.File]::ReadAllText(`$testProfile, [Text.Encoding]::UTF8)
if (`$profileAfter -match 'PSAITerminal 自动加载') { exit 10 }
if (-not (`$profileAfter -match '# User Profile Content')) { exit 11 }
if (Test-Path -LiteralPath `$testConfig) { exit 12 }
if (-not (Test-Path -LiteralPath (Join-Path `$testData 'cache.dat'))) { exit 13 }
exit 0
"@
[IO.File]::WriteAllText($testBuiltinScript, $builtinTestScript, (New-Object Text.UTF8Encoding($true)))
$hostExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
& $hostExe -NoProfile -ExecutionPolicy Bypass -File $testBuiltinScript
Assert-Equal 0 $LASTEXITCODE '模块内置 Uninstall-PSAITerminal 必须安全清理 Profile 自动加载并清除指定用户数据。'
& (Join-Path $moduleOutput 'Uninstall-PSAITerminal.ps1') -ModuleRoot (Split-Path -Parent $sandboxModuleDir) -NoProfileIntegration -Force | Out-Null
Assert-Equal $false (Test-Path -LiteralPath $sandboxModuleDir) '子进程退出后，独立卸载器必须完成被占用模块文件的删除。'

# Both 只能使用两个标准用户目录；测试通过专用文档根隔离，绝不触碰真实安装目录。
$env:PSAI_TEST_DOCUMENTS_HOME = Join-Path $testRoot 'installer/both-documents'
$env:PSAI_TEST_MODE = '1'
try {
    Assert-Throws {
        & (Join-Path $moduleOutput 'Install-PSAITerminal.ps1') -TargetHost Both `
            -ModuleRoot (Join-Path $testRoot 'invalid-root') -NoProfileIntegration
    } '不能与' 'Both 必须拒绝自定义模块根，避免安装目标歧义。'
    $providerType = [Type]::GetType('System.Text.CodePagesEncodingProvider, System.Text.Encoding.CodePages', $false)
    if ($providerType) {
        $provider = $providerType.GetProperty('Instance').GetValue($null, $null)
        [Text.Encoding]::RegisterProvider($provider)
    }
    $ansiEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
    foreach ($hostDirectory in @('WindowsPowerShell','PowerShell')) {
        $profilePath = Join-Path $env:PSAI_TEST_DOCUMENTS_HOME "$hostDirectory/Microsoft.PowerShell_profile.ps1"
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $profilePath))
        $profileEncoding = if ($hostDirectory -eq 'WindowsPowerShell') { $ansiEncoding } else { New-Object Text.UTF8Encoding($false) }
        [IO.File]::WriteAllText($profilePath, "legacy café - $hostDirectory`r`n", $profileEncoding)
    }
    & (Join-Path $moduleOutput 'Install-PSAITerminal.ps1') -TargetHost Both | Out-Null
    foreach ($hostDirectory in @('WindowsPowerShell','PowerShell')) {
        $bothPath = Join-Path $env:PSAI_TEST_DOCUMENTS_HOME "$hostDirectory/Modules/PSAITerminal/$releaseVersion"
        Assert-True (Test-Path -LiteralPath $bothPath -PathType Container) "Both 未安装到隔离的 $hostDirectory 标准目录。"
        $profilePath = Join-Path $env:PSAI_TEST_DOCUMENTS_HOME "$hostDirectory/Microsoft.PowerShell_profile.ps1"
        $profileText = [IO.File]::ReadAllText($profilePath, [Text.Encoding]::UTF8)
        Assert-Match $profileText ([regex]::Escape("legacy café - $hostDirectory")) "Both 安装不能破坏 $hostDirectory Profile 的原始编码内容。"
        Assert-Equal 1 @([regex]::Matches($profileText, 'PSAITerminal 自动加载（开始）')).Count "Both 安装必须只写入一个 $hostDirectory Profile 区块。"
        $expectedModuleRoot = Join-Path $env:PSAI_TEST_DOCUMENTS_HOME "$hostDirectory/Modules"
        Assert-Match $profileText ([regex]::Escape("`$__psaiModuleRoot = '$expectedModuleRoot'")) "Both 必须把 $hostDirectory 的实际模块根写入对应 Profile。"
    }
    & (Join-Path $moduleOutput 'Uninstall-PSAITerminal.ps1') -TargetHost Both | Out-Null
    foreach ($hostDirectory in @('WindowsPowerShell','PowerShell')) {
        $bothBase = Join-Path $env:PSAI_TEST_DOCUMENTS_HOME "$hostDirectory/Modules/PSAITerminal"
        Assert-Equal $false (Test-Path -LiteralPath $bothBase) "Both 卸载未清理隔离的 $hostDirectory 模块目录。"
        $profilePath = Join-Path $env:PSAI_TEST_DOCUMENTS_HOME "$hostDirectory/Microsoft.PowerShell_profile.ps1"
        $profileText = [IO.File]::ReadAllText($profilePath, [Text.Encoding]::UTF8)
        Assert-Match $profileText ([regex]::Escape("legacy café - $hostDirectory")) "Both 卸载不能删除 $hostDirectory Profile 的用户内容。"
        Assert-Equal $false ($profileText -match 'PSAITerminal 自动加载') "Both 卸载必须移除 $hostDirectory Profile 区块。"
    }
} finally {
    Remove-Item Env:PSAI_TEST_DOCUMENTS_HOME -ErrorAction SilentlyContinue
    Remove-Item Env:PSAI_TEST_MODE -ErrorAction SilentlyContinue
}
