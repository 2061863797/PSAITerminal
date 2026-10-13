# Profile 自动加载注入、配置自检与卸载清理。

function Test-AIProfileIntegration {
    try {
        if (-not (Test-Path -LiteralPath $PROFILE.CurrentUserCurrentHost)) { return $false }
        (Read-PSAITextFile $PROFILE.CurrentUserCurrentHost) -match '(?m)^# PSAITerminal 自动加载（开始）$'
    } catch { $false }
}

function Get-PSAIIntegrationStatus {
    $module = $ExecutionContext.SessionState.Module
    $shortcuts = @(Get-AIShortcutStatus)
    $shortcutText = ($shortcuts | ForEach-Object { '{0} {1}' -f $_.Key,$(if($_.Active){'✓'}else{'未启用'}) }) -join '；'
    $inputRouting = if (-not [bool]$script:Config.integrations.enterRouting) { '关闭' }
        elseif ($script:BoundKeys.Contains('Enter')) { '已启用' } else { '未启用' }
    $prediction = if (-not $script:OfficialIntegrationAvailable) { '宿主不支持' }
        elseif (-not [bool]$script:Config.integrations.predictor) { '关闭' }
        elseif (Test-AIOfficialPredictorRegistered) { '已启用' } else { '注册失败' }
    [pscustomobject]@{
        Version = $module.Version.ToString()
        HostEdition = $script:HostEdition
        HostVersion = $script:HostVersion.ToString()
        OfficialIntegrationSupported = $script:OfficialIntegrationAvailable
        Mode = [string]$script:Config.mode
        Model = if ($script:Config.activeModel) { [string]$script:Config.activeModel } else { '未配置' }
        InputRouting = $inputRouting
        Shortcuts = $shortcutText
        Prediction = $prediction
        FailureFeedback = if (-not $script:OfficialIntegrationAvailable) { '宿主不支持' }
            elseif (Test-AIOfficialFeedbackRegistered) { '已启用' } else { '未启用' }
        ProfileAutoLoad = if (Test-AIProfileIntegration) { '已启用' } else { '未启用' }
        ModulePath = $module.Path
    }
}

function Test-PSAIConfiguration {
    [CmdletBinding()] param([switch]$Online)
    $checks = [Collections.Generic.List[object]]::new()
    $add = { param($name,[Nullable[bool]]$success,$details,$action)
        $checks.Add([pscustomobject]@{Check=$name;Success=$success;Details=$details;Action=$action})
    }

    $module = $ExecutionContext.SessionState.Module
    $platform = [Environment]::OSVersion.VersionString
    & $add '操作系统' $script:IsWindowsPlatform $platform $(if($script:IsWindowsPlatform){''}else{'当前发布仅支持 Windows'})
    & $add '官方预测/反馈集成' $(if($script:OfficialIntegrationAvailable){$true}else{$null}) $(if($script:OfficialIntegrationAvailable){'可用'}else{'当前宿主不支持（核心功能不受影响）'}) $(if($script:OfficialIntegrationAvailable){''}else{'如需此功能，请使用 PowerShell 7.4 或更高版本'})
    $secretStoreAvailable = [PSAITerminal.PlatformCredentialStore]::IsAvailable
    $secretStoreName = [PSAITerminal.PlatformCredentialStore]::BackendName
    $secretStoreAction = if ($secretStoreAvailable) { '' } else { '使用 -SessionOnly' }
    & $add '系统密钥库' $secretStoreAvailable $(if($secretStoreAvailable){$secretStoreName}else{"$secretStoreName 不可用，仅支持当前会话密钥"}) $secretStoreAction
    $moduleRoots = @($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { $_ } | ForEach-Object {
        $moduleRoot = $_
        try { [IO.Path]::GetFullPath($moduleRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar }
        catch { Write-Verbose "忽略无效的 PSModulePath 项 '$moduleRoot'：$($_.Exception.Message)" }
    })
    $pathComparison = [StringComparison]::OrdinalIgnoreCase
    $moduleBaseWithSeparator = $module.ModuleBase.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $installed = @($moduleRoots | Where-Object { $moduleBaseWithSeparator.StartsWith($_,$pathComparison) }).Count -gt 0
    & $add '模块安装' $installed $(if($installed){'可按名称发现'}else{'当前是按路径临时导入'}) $(if($installed){''}else{'运行 Install-PSAITerminal.ps1'})

    try { Assert-AIConfigCandidate $script:Config; & $add '配置文件' $true $script:ConfigPath '' }
    catch { & $add '配置文件' $false (Protect-AIText $_.Exception.Message 2048) '修复配置或重新配置模型' }

    $activeModel = $null
    if ($script:Config.activeModel -and (Test-AIMapContains $script:Config.models ([string]$script:Config.activeModel))) {
        $activeModel = $script:Config.models[[string]$script:Config.activeModel]
        & $add '当前模型' $true "$(($activeModel.name)) / $($activeModel.modelId)" ''
        $hasCredential = (Test-AIApiKeyOptional ([string]$activeModel.endpoint)) -or [bool](Get-AISecret ([string]$activeModel.name))
        & $add '模型凭据' $hasCredential $(if($hasCredential){'可用'}else{'缺少 API Key'}) $(if($hasCredential){''}else{'编辑当前模型并更新 API Key'})
        try {
            [void](ConvertTo-AIEndpoint ([string]$activeModel.protocol) ([uri][string]$activeModel.endpoint))
            & $add '接口地址' $true ([string]$activeModel.endpoint) ''
        } catch { & $add '接口地址' $false (Protect-AIText $_.Exception.Message 2048) '编辑当前模型地址' }
    } else {
        $allowedWithoutModel = $script:Config.mode -eq 'Off'
        & $add '当前模型' $allowedWithoutModel '未配置' '输入 ai 后新增模型'
    }

    $psReadLineAvailable = [bool](Get-Module -ListAvailable PSReadLine)
    & $add 'PSReadLine' $psReadLineAvailable $(if($psReadLineAvailable){'可用'}else{'未安装'}) $(if($psReadLineAvailable){''}else{'安装或更新 PSReadLine'})
    foreach ($shortcut in @(Get-AIShortcutStatus)) {
        $success = if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { $null } else { [Nullable[bool]]$shortcut.Active }
        $details = if ($null -eq $success) { "$($shortcut.Key)（非交互环境未检查）" }
            elseif ($shortcut.Active) { "$($shortcut.Key) 已启用" }
            else {
                $actualBinding = if ($shortcut.Actual) { $shortcut.Actual } else { '无' }
                "$($shortcut.Key) 当前绑定：$actualBinding"
            }
        $action = if ($null -eq $success) { '请在交互式终端中检查' }
            elseif ($shortcut.Active) { '' }
            else { '重新导入模块并检查快捷键冲突' }
        & $add "快捷键：$($shortcut.Action)" $success $details $action
    }

    if ($Online) {
        if ($activeModel) {
            $result = Test-PSAIModel -Name ([string]$activeModel.name)
            & $add '模型连接' ([bool]$result.Success) $(if($result.Success){'请求成功'}else{$result.Error}) $(if($result.Success){''}else{'检查地址、模型 ID 和 API Key'})
        } else { & $add '模型连接' $false '没有当前模型' '先新增并选择模型' }
    }
    $checks.ToArray()
}

function Install-PSAIProfileIntegration {
    [CmdletBinding(SupportsShouldProcess)] param()
    $path = $PROFILE.CurrentUserCurrentHost
    $start = '# PSAITerminal 自动加载（开始）'; $end = '# PSAITerminal 自动加载（结束）'
    $content = if (Test-Path -LiteralPath $path) { Read-PSAITextFile $path } else { '' }
    if ($PSCmdlet.ShouldProcess($path, '添加 PSAITerminal 自动加载')) {
        $directory = Split-Path -Parent $path
        if ($directory) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
        $version = $ExecutionContext.SessionState.Module.Version.ToString()
        $moduleBase = $ExecutionContext.SessionState.Module.ModuleBase
        $moduleParent = Split-Path -Parent $moduleBase
        $moduleRoot = if ((Split-Path -Leaf $moduleBase) -eq 'PSAITerminal') {
            $moduleParent
        } elseif ((Split-Path -Leaf $moduleParent) -eq 'PSAITerminal') {
            Split-Path -Parent $moduleParent
        } else {
            $moduleParent
        }
        $escapedModuleRoot = ([IO.Path]::GetFullPath($moduleRoot)).Replace("'", "''")
        $block = @'
{START}
$__psaiModuleRoot = '{MODULE_ROOT}'
if (@($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $__psaiModuleRoot) {
    $env:PSModulePath = $__psaiModuleRoot + [IO.Path]::PathSeparator + $env:PSModulePath
}
try { Import-Module PSAITerminal -MinimumVersion '{VERSION}' -ErrorAction Stop }
catch { Write-Warning "PSAITerminal 自动加载失败：$($_.Exception.Message)" }
Remove-Variable __psaiModuleRoot -ErrorAction SilentlyContinue
{END}
'@
        $block = $block.Replace('{START}', $start)
        $block = $block.Replace('{MODULE_ROOT}', $escapedModuleRoot)
        $block = $block.Replace('{VERSION}', $version)
        $block = $block.Replace('{END}', $end)
        $profileUpdate = Get-PSAIProfileUpdate $content $block
        if ($profileUpdate.RepairNeeded -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            $profileBackup = "$path.psaiterminal-backup.$([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')).$([guid]::NewGuid().ToString('N'))"
            Copy-Item -LiteralPath $path -Destination $profileBackup
            Write-Warning "检测到重复或嵌套的 PSAITerminal Profile 区块，原文件已备份：$profileBackup"
        }
        if ($profileUpdate.Content -ne $content) {
            [PSAITerminal.AITerminalAtomicFile]::WriteAllText($path, $profileUpdate.Content)
        }
    }
}

function Uninstall-PSAIProfileIntegration {
    [CmdletBinding(SupportsShouldProcess)] param()
    $path = $PROFILE.CurrentUserCurrentHost
    if (-not (Test-Path -LiteralPath $path)) { return }
    $content = Read-PSAITextFile $path
    $updated = (Get-PSAIProfileUpdate $content).Content
    if ($updated -ne $content -and $PSCmdlet.ShouldProcess($path, '移除 PSAITerminal 自动加载')) {
        [PSAITerminal.AITerminalAtomicFile]::WriteAllText($path, $updated)
    }
}

function Uninstall-PSAITerminal {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$PurgeUserData,
        [switch]$Force,
        [switch]$ExitTerminal
    )

    $targetModuleBase = if ($script:ModuleRoot) { [IO.Path]::GetFullPath($script:ModuleRoot) }
        else {
            $mod = Get-Module PSAITerminal
            if ($mod -and $mod.ModuleBase) { [IO.Path]::GetFullPath($mod.ModuleBase) } else { $null }
        }

    if (-not $targetModuleBase -or -not (Test-Path -LiteralPath $targetModuleBase)) {
        throw '无法定位 PSAITerminal 模块目录。'
    }

    $normalizedPath = $targetModuleBase.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $rootPath = [IO.Path]::GetPathRoot($normalizedPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($normalizedPath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝使用磁盘根目录作为模块根：$normalizedPath"
    }

    $leafName = Split-Path -Path $normalizedPath -Leaf
    $parentLeafName = Split-Path -Path (Split-Path -Path $normalizedPath -Parent) -Leaf
    if ($leafName -notmatch '^(?i:PSAITerminal)(?:-|\.|\b|$)' -and $parentLeafName -notmatch '^(?i:PSAITerminal)(?:-|\.|\b|$)') {
        throw "拒绝删除无法确认的模块目录：$normalizedPath"
    }

    foreach ($protectedPath in @($PSHOME, $env:ProgramFiles, [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'), $env:windir)) {
        if (-not $protectedPath) { continue }
        $protectedRoot = ([IO.Path]::GetFullPath($protectedPath)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (($normalizedPath + [IO.Path]::DirectorySeparatorChar).StartsWith($protectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "拒绝使用系统目录作为模块根：$normalizedPath"
        }
    }

    Assert-PSAIModuleRemoval $normalizedPath
    $purgeConfig = if ($env:PSAI_CONFIG_HOME) { $env:PSAI_CONFIG_HOME } else { Get-AIConfigDirectory }
    $purgeData = if ($env:PSAI_DATA_HOME) { $env:PSAI_DATA_HOME } else { Get-AIDataDirectory }
    Assert-PSAIStorageOutsideModule $normalizedPath @($purgeConfig,$purgeData)
    $purgePlan = $null
    if ($PurgeUserData) {
        $purgePlan = Get-PSAIStoragePurgePlan $purgeConfig $purgeData
    }
    $profileUpdates = [Collections.Generic.List[object]]::new()
    $profilesToCheck = @($PROFILE.CurrentUserCurrentHost)
    if ($PROFILE.CurrentUserAllHosts -and $PROFILE.CurrentUserAllHosts -ne $PROFILE.CurrentUserCurrentHost) {
        $profilesToCheck += $PROFILE.CurrentUserAllHosts
    }
    foreach ($prof in $profilesToCheck) {
        if ($prof -and (Test-Path -LiteralPath $prof -PathType Leaf)) {
            [void](Assert-PSAISafeRemovalDirectory (Split-Path -Parent $prof))
            if ((Get-Item -LiteralPath $prof -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw '拒绝修改重解析点 Profile。'
            }
            $content = Read-PSAITextFile $prof
            $updated = (Get-PSAIProfileUpdate $content).Content
            if ($updated -ne $content) {
                $profileUpdates.Add([pscustomobject]@{Path=$prof;Original=$content;Updated=$updated})
            }
        }
    }
    if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'None' }
    if (-not $PSCmdlet.ShouldProcess($normalizedPath, '卸载 PSAITerminal 模块')) { return }
    $userDataPurged = $false; $credentialsPurged = $false
    if ($PurgeUserData) {
        Assert-PSAIStoragePurgePlan $purgePlan
        Invoke-PSAICredentialPurge $purgePlan.CredentialTargets (Join-Path $normalizedPath 'bin\PSAITerminal.dll')
        $credentialsPurged = $true
        $script:SessionSecrets.Clear()
        $script:SecretMaskingCache.Clear()
        $script:SecretMaskingCacheInitialized = $true
        Remove-PSAIStorageData $purgePlan
        $userDataPurged = $true
    }
    $profileRemoved = $false
    foreach ($update in $profileUpdates) {
        if ((Read-PSAITextFile $update.Path) -cne $update.Original) { throw 'Profile 在预检后已变化，停止卸载。' }
        [PSAITerminal.AITerminalAtomicFile]::WriteAllText($update.Path, $update.Updated)
        $profileRemoved = $true
    }
    Unregister-AIPSReadLineIntegration
    Unregister-AIPromptIntegration
    if ($script:OfficialIntegrationAvailable) { [PSAITerminal.AITerminalOfficialIntegration]::UnregisterAll() }
    [Environment]::SetEnvironmentVariable("__PSAI_SESSION_PID_$PID", $null, 'Process')
    Assert-PSAIModuleRemoval $normalizedPath
    try {
        # 先尝试程序集，文件仍被当前宿主占用时保留清单与独立卸载脚本供重试。
        Get-ChildItem -LiteralPath $normalizedPath -Filter '*.dll' -Recurse -File -ErrorAction Stop |
            Remove-Item -Force -ErrorAction Stop
        Remove-Item -LiteralPath $normalizedPath -Recurse -Force -ErrorAction Stop
    } catch {
        throw "模块文件删除失败：$($_.Exception.Message) 请关闭使用该模块的终端，再在无 Profile 的终端执行独立卸载脚本。"
    }

    $result = [pscustomobject]@{
        RemovedPath = $normalizedPath
        ProfileCleaned = $profileRemoved
        UserDataPurged = $userDataPurged
        CredentialsPurged = $credentialsPurged
        ModuleRemoved = (-not (Test-Path -LiteralPath $normalizedPath))
    }

    if ($ExitTerminal) {
        exit
    }

    $result
}
