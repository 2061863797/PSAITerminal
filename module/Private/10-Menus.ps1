# 交互式终端菜单、设置 UI 与模式/选项命令。

function Read-AIChoice([string]$Prompt, [int[]]$Allowed, [Nullable[int]]$Default) {
    while ($true) {
        $suffix = if ($null -ne $Default) { Get-AIText 'DefaultPrompt' @($Default) } else { '' }
        $raw = (Read-Host "$Prompt$suffix").Trim()
        if (-not $raw -and $null -ne $Default) { return [int]$Default }
        $value = 0
        if ([int]::TryParse($raw, [ref]$value) -and $Allowed -contains $value) { return $value }
        Write-Warning (Get-AIText 'InvalidNumber')
    }
}

function Read-AIYesNo([string]$Prompt, [bool]$Default = $false) {
    $label = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $raw = (Read-Host "$Prompt $label").Trim()
        if (-not $raw) { return $Default }
        if ($raw -match '^(?i:y|yes)$') { return $true }
        if ($raw -match '^(?i:n|no)$') { return $false }
        Write-Warning $(if ((Get-AILanguage) -eq 'en-US') { 'Enter y or n.' } else { '请输入 y 或 n。' })
    }
}

function Select-AIRemoteModel([string]$Protocol, [uri]$Endpoint, [AllowNull()][string]$Secret) {
    Write-Host (Get-AIText 'LoadingModels')
    try { $models = @(Get-AIRemoteModels -Protocol $Protocol -Endpoint $Endpoint -Secret $Secret) }
    catch {
        Write-Warning (Get-AIText 'RemoteModelsFailed' @($_.Exception.Message))
        if (-not (Read-AIYesNo (Get-AIText 'EnterModelManually') $true)) { return }
        $manual = (Read-Host (Get-AIText 'ModelId')).Trim()
        if ($manual) { return [pscustomobject]@{Id=$manual;DisplayName=$manual;ContextWindow=0} }
        return
    }
    if ($models.Count -eq 0) {
        Write-Warning (Get-AIText 'NoRemoteModels')
        $manual = (Read-Host (Get-AIText 'ManualModelId')).Trim()
        if ($manual) { return [pscustomobject]@{Id=$manual;DisplayName=$manual;ContextWindow=0} }
        return
    }

    $visible = @($models | Select-Object -First 100)
    Write-Host ''
    for ($index = 0; $index -lt $visible.Count; $index++) {
        $label = if ($visible[$index].DisplayName -and $visible[$index].DisplayName -ne $visible[$index].Id) {
            "$($visible[$index].Id)  ($($visible[$index].DisplayName))"
        } else { [string]$visible[$index].Id }
        Write-Host ('{0,3}. {1}' -f ($index + 1), $label)
    }
    Write-Host ('{0,3}. {1}' -f ($visible.Count + 1), $(if ((Get-AILanguage) -eq 'en-US') { 'Enter model ID manually' } else { '手动输入模型 ID' }))
    Write-Host "  0. $(Get-AIText 'Cancel')"
    $allowed = @(0..($visible.Count + 1))
    $choice = Read-AIChoice (Get-AIText 'SelectNumber') $allowed $null
    if ($choice -eq 0) { return }
    if ($choice -eq ($visible.Count + 1)) {
        $manual = (Read-Host (Get-AIText 'ModelId')).Trim()
        if ($manual) { return [pscustomobject]@{Id=$manual;DisplayName=$manual;ContextWindow=0} }
        return
    }
    $visible[$choice - 1]
}

function Read-AIProtocol([string]$Current) {
    Write-Host ''
    Write-Host '1. OpenAI Responses'
    Write-Host '2. OpenAI Chat / Compatible'
    Write-Host '3. Anthropic'
    Write-Host '4. Gemini Native'
    Write-Host '5. Ollama'
    Write-Host "0. $(Get-AIText 'Cancel')"
    $choice = Read-AIChoice (Get-AIText 'SelectProtocol') @(0,1,2,3,4,5) $null
    switch ($choice) {
        1 { 'OpenAIResponses' }
        2 { 'OpenAIChat' }
        3 { 'Anthropic' }
        4 { 'GeminiNative' }
        5 { 'Ollama' }
        default { $null }
    }
}

function Get-AIInteractiveSessionOnlyChoice([string]$Protocol) {
    if ($Protocol -eq 'Ollama' -or [PSAITerminal.PlatformCredentialStore]::IsAvailable) { return $false }
    Write-Warning $(if ((Get-AILanguage) -eq 'en-US') { 'The system credential store is unavailable; the API key cannot be persisted securely.' } else { '系统密钥库当前不可用，API Key 无法安全持久化。' })
    if (Read-AIYesNo $(if ((Get-AILanguage) -eq 'en-US') { 'Use this API key only for the current PowerShell session? You will need to enter it again after closing the terminal.' } else { '是否仅在当前 PowerShell 会话中使用此 API Key？关闭终端后需要重新输入。' }) $true) {
        return $true
    }
    $null
}

function Test-AISecretStoreException([Exception]$Exception) {
    $Exception.Message -match '(?i)credential|密钥库|凭据|登录会话'
}

function Add-AIModelInteractive {
    $name = (Read-Host (Get-AIText 'AddModelName')).Trim()
    try { Assert-AIModelName $name } catch { Write-Warning $_.Exception.Message; return }
    if (Test-AIMapContains $script:Config.models $name) { Write-Warning (Get-AIText 'DuplicateModel' @($name)); return }
    $protocol = Read-AIProtocol
    if (-not $protocol) { return }
    $defaultEndpoint = Get-AIDefaultEndpoint $protocol
    $endpointText = (Read-Host $(if ((Get-AILanguage) -eq 'en-US') { "Base endpoint (press Enter to use $defaultEndpoint)" } else { "接口基础地址（留空使用 $defaultEndpoint）" })).Trim()
    if (-not $endpointText) { $endpointText = $defaultEndpoint }
    try { $endpoint = [uri](ConvertTo-AIEndpoint $protocol ([uri]$endpointText)) }
    catch { Write-Warning $_.Exception.Message; return }

    $secure = $null
    $plain = $null
    if ($protocol -ne 'Ollama') {
        $secure = Read-Host (Get-AIText 'ApiKey') -AsSecureString
        if (-not $secure -or $secure.Length -eq 0) { Write-Warning $(if ((Get-AILanguage) -eq 'en-US') { 'API key cannot be empty.' } else { 'API Key 不能为空。' }); return }
        $plain = ConvertFrom-AISecureString $secure
    }
    $sessionOnly = Get-AIInteractiveSessionOnlyChoice $protocol
    if ($protocol -ne 'Ollama' -and $null -eq $sessionOnly) { return }
    try { $selection = Select-AIRemoteModel $protocol $endpoint $plain }
    finally { $plain = $null }
    if (-not $selection) { return }
    $window = if ([int]$selection.ContextWindow -ge 1024) { [int]$selection.ContextWindow } else { 32768 }
    $parameters = @{
        Name=$name;Protocol=$protocol;Endpoint=$endpoint;ModelId=[string]$selection.Id
        ApiKey=$secure;ContextWindow=$window;SessionOnly=[bool]$sessionOnly;SetActive=$true
    }
    try {
        New-PSAIModel @parameters | Out-Host
        Write-AIColoredHost (Get-AIText 'ModelAdded') Green
    } catch {
        $failure = $_
        if (-not $sessionOnly -and $protocol -ne 'Ollama' -and (Test-AISecretStoreException $failure.Exception) -and
            (Read-AIYesNo (Get-AIText 'CredentialFallback') $true)) {
            try {
                $parameters.SessionOnly = $true
                New-PSAIModel @parameters | Out-Host
                Write-AIColoredHost (Get-AIText 'ModelAddedSession') Yellow
                return
            } catch { Write-Warning $_.Exception.Message; return }
        }
        Write-Warning $failure.Exception.Message
    }
}

function Edit-AIModelInteractive([string]$Name) {
    $current = $script:Config.models[$Name]
    if (-not $current) { Write-Warning (Get-AIText 'ModelMissing'); return }
    Write-Host "$(Get-AIText 'CurrentProtocol'): $($current.protocol)"
    $changeProtocol = Read-AIYesNo (Get-AIText 'ChangeProtocol') $false
    $protocol = if ($changeProtocol) { Read-AIProtocol } else { [string]$current.protocol }
    if (-not $protocol) { return }
    $endpointText = (Read-Host "$(Get-AIText 'Endpoint') [$($current.endpoint)]").Trim()
    if (-not $endpointText) { $endpointText = [string]$current.endpoint }
    try { $endpoint = [uri](ConvertTo-AIEndpoint $protocol ([uri]$endpointText)) }
    catch { Write-Warning $_.Exception.Message; return }

    $secure = $null
    $plain = $null
    $sessionOnly = $false
    if ($protocol -ne 'Ollama') {
        $replaceKey = $changeProtocol -or (Read-AIYesNo (Get-AIText 'UpdateApiKey') $false)
        if ($replaceKey) {
            $secure = Read-Host (Get-AIText 'NewApiKey') -AsSecureString
            if (-not $secure -or $secure.Length -eq 0) { Write-Warning $(if ((Get-AILanguage) -eq 'en-US') { 'API key cannot be empty.' } else { 'API Key 不能为空。' }); return }
            $plain = ConvertFrom-AISecureString $secure
            $sessionOnly = Get-AIInteractiveSessionOnlyChoice $protocol
            if ($null -eq $sessionOnly) { return }
        } else { $plain = Get-AISecret $Name }
    }
    try { $selection = Select-AIRemoteModel $protocol $endpoint $plain }
    finally { $plain = $null }
    if (-not $selection) { return }
    $parameters = @{Name=$Name;Protocol=$protocol;Endpoint=$endpoint;ModelId=[string]$selection.Id}
    if ($secure) { $parameters.ApiKey = $secure; $parameters.SessionOnly = [bool]$sessionOnly }
    if ([int]$selection.ContextWindow -ge 1024) { $parameters.ContextWindow = [int]$selection.ContextWindow }
    try { Set-PSAIModel @parameters | Out-Host; Write-AIColoredHost (Get-AIText 'ModelUpdated') Green }
    catch {
        $failure = $_
        if ($secure -and -not $sessionOnly -and (Test-AISecretStoreException $failure.Exception) -and
            (Read-AIYesNo (Get-AIText 'CredentialFallback') $true)) {
            try {
                $parameters.SessionOnly = $true
                Set-PSAIModel @parameters | Out-Host
                Write-AIColoredHost (Get-AIText 'ModelUpdatedSession') Yellow
                return
            } catch { Write-Warning $_.Exception.Message; return }
        }
        Write-Warning $failure.Exception.Message
    }
}

function Select-AIReplacementModel([string]$ExcludedName) {
    $models = @($script:Config.models.Values | Where-Object name -ne $ExcludedName)
    if ($models.Count -eq 0) { return $null }
    Write-Host (Get-AIText 'ChooseReplacement')
    for ($index=0; $index -lt $models.Count; $index++) { Write-Host ('{0}. {1}' -f ($index+1), $models[$index].name) }
    $choice = Read-AIChoice (Get-AIText 'SelectNumber') @(1..$models.Count) $null
    [string]$models[$choice-1].name
}

function Open-AIModelDetail([string]$Name) {
    while (Test-AIMapContains $script:Config.models $Name) {
        $model = $script:Config.models[$Name]
        $isActive = [string]$script:Config.activeModel -eq $Name
        Write-Host ''
        Write-AIColoredHost $Name Magenta
        Write-Host "$(Get-AIText 'Protocol'): $($model.protocol)"
        Write-Host "$(Get-AIText 'Model'): $($model.modelId)"
        Write-Host "$(Get-AIText 'EndpointLabel'): $($model.endpoint)"
        Write-Host "$(Get-AIText 'ModelStatus'): $(if($isActive){(Get-AIText 'ActiveStatus')}else{(Get-AIText 'InactiveStatus')})"
        if ($model.protocol -ne 'Ollama') {
            Write-Host "$(Get-AIText 'ApiKeyStatus'): $(if(Get-AISecret $Name){(Get-AIText 'ApiKeySaved')}else{(Get-AIText 'ApiKeyMissing')})"
        }
        Write-Host ''
        $actions = [Collections.Generic.List[string]]::new()
        if (-not $isActive) { $actions.Add((Get-AIText 'SetActive')) }
        $actions.Add((Get-AIText 'EditConfig'));$actions.Add((Get-AIText 'TestConnection'));$actions.Add((Get-AIText 'DeleteConfig'));$actions.Add((Get-AIText 'Back'))
        for ($index=0;$index -lt $actions.Count;$index++) { Write-Host ('{0}. {1}' -f ($index+1),$actions[$index]) }
        $choice = Read-AIChoice (Get-AIText 'SelectNumber') @(1..$actions.Count) $null
        $action = $actions[$choice-1]
        switch ($action) {
            { $_ -eq (Get-AIText 'SetActive') } { Select-PSAIModel $Name | Out-Host }
            { $_ -eq (Get-AIText 'EditConfig') } { Edit-AIModelInteractive $Name }
            { $_ -eq (Get-AIText 'TestConnection') } {
                try { Test-PSAIModel -Name $Name | Format-List | Out-Host }
                catch { Write-Warning $_.Exception.Message }
            }
            { $_ -eq (Get-AIText 'DeleteConfig') } {
                if (-not (Read-AIYesNo (Get-AIText 'ConfirmDeleteModel' @($Name)) $false)) { continue }
                $replacement = if ($isActive) { Select-AIReplacementModel $Name } else { $null }
                try {
                    Remove-PSAIModel -Name $Name -ReplacementModel $replacement -Confirm:$false
                    Write-AIColoredHost (Get-AIText 'ModelDeleted') Green
                    return
                } catch { Write-Warning $_.Exception.Message }
            }
            { $_ -eq (Get-AIText 'Back') } { return }
        }
    }
}

function Open-PSAIModelSelector {
    [CmdletBinding()] param()
    $models = @($script:Config.models.Values)
    if ($models.Count -eq 0) { Write-Warning (Get-AIText 'NoModelsWarning'); return }
    for ($index=0;$index -lt $models.Count;$index++) {
        $mark = if ($models[$index].name -eq $script:Config.activeModel) { " $(Get-AIText 'Current')" } else { '' }
        Write-Host ('{0}. {1} [{2} / {3}]{4}' -f ($index+1),$models[$index].name,$models[$index].protocol,$models[$index].modelId,$mark)
    }
    Write-Host "0. $(Get-AIText 'Back')"
    $choice = Read-AIChoice (Get-AIText 'SelectNumber') @(0..$models.Count) $null
    if ($choice -gt 0) { Select-PSAIModel ([string]$models[$choice-1].name) | Out-Host }
}

function Open-AIModelsMenu {
    while ($true) {
        $models = @($script:Config.models.Values)
        Write-Host ''
        Write-AIColoredHost (Get-AIText 'Models') Magenta
        Write-Host ''
        for ($index=0;$index -lt $models.Count;$index++) {
            $mark = if ($models[$index].name -eq $script:Config.activeModel) { " $(Get-AIText 'Current')" } else { '' }
            Write-Host ('{0}. {1} [{2} / {3}]{4}' -f ($index+1),$models[$index].name,$models[$index].protocol,$models[$index].modelId,$mark)
        }
        $addNumber = $models.Count + 1
        Write-Host "$addNumber. $(Get-AIText 'AddModel')"
        Write-Host "0. $(Get-AIText 'Back')"
        $choice = Read-AIChoice (Get-AIText 'SelectNumber') @(0..$addNumber) $null
        if ($choice -eq 0) { return }
        if ($choice -eq $addNumber) { Add-AIModelInteractive; continue }
        Open-AIModelDetail ([string]$models[$choice-1].name)
    }
}

function Show-AICliHelp {
    [CmdletBinding()] param()
    Write-Host ''
    Write-AIColoredHost $(if ((Get-AILanguage) -eq 'en-US') { 'PSAITerminal Command-Line Help' } else { 'PSAITerminal 命令行使用帮助' }) Magenta
    Write-Host ''
    if ((Get-AILanguage) -eq 'en-US') {
        Write-Host '  ai                         Open interactive settings menu'
        Write-Host '  ai <question/task>         Ask AI explicitly / execute local task'
        Write-Host '  ai clear                   Clear current session context'
        Write-Host '  ai new [title]             Create and switch to a new session'
        Write-Host '  ai mode [Off|AI|Auto]      View or switch operating mode'
        Write-Host '  ai help                    Show this command-line help'
        Write-Host '  ai resume <RunId>          Resume an unfinished run'
        Write-Host '  Get-PSAIModel              List configured models'
        Write-Host '  Get-PSAISession            List persistent sessions'
        Write-Host '  Clear-PSAISession          Clear active session context'
        Write-Host '  New-PSAISession            Create a new session'
        Write-Host ''
        Write-Host '  Shortcuts: F2 (Force AI) | F3 (Force Shell) | F6 (Cycle Mode) | F7 (Explain Last)'
    } else {
        Write-Host '  ai                         打开交互配置菜单'
        Write-Host '  ai <内容>                  显式询问 AI 或提出本地任务'
        Write-Host '  ai clear                   一键清空当前会话上下文'
        Write-Host '  ai new [名称]              创建并切换到全新独立会话'
        Write-Host '  ai mode [Off|AI|Auto]      查看或切换工作模式'
        Write-Host '  ai help                    显示本命令行帮助'
        Write-Host '  ai resume <RunId>          在顶层恢复未完成 Run'
        Write-Host '  Get-PSAIModel              查看已配置模型'
        Write-Host '  Get-PSAISession            查看持久会话列表'
        Write-Host '  Clear-PSAISession          清空当前激活会话'
        Write-Host '  New-PSAISession            新建会话'
        Write-Host ''
        Write-Host '  快捷键提示: F2 (强制 AI) | F3 (强制 Shell) | F6 (切换模式) | F7 (解释最近命令)'
    }
    Write-Host ''
}

function Show-AIHelp {
    Show-AICliHelp
}

function Show-AIShortcuts {
    Write-Host ''
    Write-AIColoredHost (Get-AIText 'Shortcuts') Magenta
    Write-Host ''
    if ((Get-AILanguage) -eq 'en-US') {
        Write-Host '  Type a command without pressing Enter, then press the function key.'
        Write-Host '  On some laptops, press Fn together with the function key.'
    } else {
        Write-Host '  使用方法：先输入内容，不按 Enter，直接按对应功能键。'
        Write-Host '  笔记本若把功能键用于亮度或音量，请同时按 Fn。'
    }
    Write-Host ''
    $shortcutText = if ((Get-AILanguage) -eq 'en-US') {
        @('Send current input to AI','Run current input as PowerShell','Cycle Off / AI / Auto mode','Explain the most recent command','Submit using the current mode','Open settings')
    } else {
        @('把当前输入交给 AI，并立即提交','把当前输入按 PowerShell 执行，并立即提交','切换 Off / AI / Auto 模式','解释最近一次命令','按照当前 Off / AI / Auto 模式提交输入','打开设置')
    }
    Write-Host ('  {0,-16} {1}' -f $script:Config.shortcuts.forceAI, $shortcutText[0])
    Write-Host ('  {0,-16} {1}' -f $script:Config.shortcuts.forceShell, $shortcutText[1])
    Write-Host ('  {0,-16} {1}' -f $script:Config.shortcuts.cycleMode, $shortcutText[2])
    Write-Host ('  {0,-16} {1}' -f $script:Config.shortcuts.explainLast, $shortcutText[3])
    Write-Host ('  {0,-16} {1}' -f 'Enter', $shortcutText[4])
    Write-Host ('  {0,-16} {1}' -f 'ai', $shortcutText[5])
    Write-Host ''
    [void](Read-Host (Get-AIText 'ReturnPrompt'))
}

function Open-AIHelpMenu {
    while ($true) {
        Write-Host ''
        Write-AIColoredHost (Get-AIText 'UsageHelp') Magenta
        Write-Host ''
        Write-Host "1. $(Get-AIText 'CommonCommands')"
        Write-Host "2. $(Get-AIText 'Shortcuts')"
        Write-Host "0. $(Get-AIText 'Back')"
        $choice = Read-AIChoice (Get-AIText 'SelectNumber') @(0,1,2) $null
        switch ($choice) {
            0 { return }
            1 { Show-AIHelp; [void](Read-Host (Get-AIText 'ReturnPrompt')) }
            2 { Show-AIShortcuts }
        }
    }
}

function Open-AILanguageMenu {
    while ($true) {
        Write-Host ''
        Write-AIColoredHost (Get-AIText 'Language') Magenta
        Write-Host "1. $(Get-AIText 'English')$(if ((Get-AILanguage) -eq 'en-US') { ' *' })"
        Write-Host "2. $(Get-AIText 'Chinese')$(if ((Get-AILanguage) -eq 'zh-CN') { ' *' })"
        Write-Host "0. $(Get-AIText 'Back')"
        $choice = Read-AIChoice $(if ((Get-AILanguage) -eq 'en-US') { 'Select language' } else { '选择语言' }) @(0,1,2) $null
        if ($choice -eq 0) { return }
        Set-PSAITerminalOption -Language $(if ($choice -eq 1) { 'en-US' } else { 'zh-CN' }) | Out-Null
    }
}

function Open-AIUninstallMenu {
    Write-Host ''
    Write-AIColoredHost (Get-AIText 'Uninstall') Magenta
    Write-Warning (Get-AIText 'UninstallConfirm')
    if (-not (Read-AIYesNo (Get-AIText 'UninstallConfirm') $false)) {
        return $false
    }
    $purge = Read-AIYesNo (Get-AIText 'UninstallPurgeUserDataPrompt') $false

    $result = Uninstall-PSAITerminal -PurgeUserData:$purge -Force
    if (-not $result) { return $false }
    Write-Host ''
    Write-AIColoredHost (Get-AIText 'UninstallComplete') Green
    if ($result.ProfileCleaned) { Write-Host (Get-AIText 'UninstallProfileRemoved') }

    if (Read-AIYesNo (Get-AIText 'UninstallExitPrompt') $true) {
        exit
    }
    return $true
}

function Open-PSAISettings {
    [CmdletBinding()] param()
    while ($true) {
        Write-Host ''
        Write-AIColoredHost (Get-AIText 'Settings') Magenta
        Write-Host (Get-AIText 'CurrentMode' @($script:Config.mode))
        $currentModelText = if ($script:Config.activeModel) { [string]$script:Config.activeModel }
            elseif ((Get-AILanguage) -eq 'en-US') { 'Not configured' } else { '未配置' }
        Write-Host (Get-AIText 'CurrentModel' @($currentModelText))
        Write-Host (Get-AIText 'ConfigPath' @($script:ConfigPath))
        Write-Host ''
        Write-Host "1. $(Get-AIText 'Models')"
        Write-Host "2. $(Get-AIText 'Mode')"
        Write-Host "3. $(Get-AIText 'Appearance')"
        Write-Host "4. $(Get-AIText 'Language')"
        Write-Host "5. $(Get-AIText 'Help')"
        Write-Host "6. $(Get-AIText 'Diagnostics')"
        Write-Host "7. $(Get-AIText 'Uninstall')"
        Write-Host "0. $(Get-AIText 'Back')"
        $choice = Read-AIChoice (Get-AIText 'SelectNumber') @(0,1,2,3,4,5,6,7) $null
        switch ($choice) {
            0 { return }
            1 { Open-AIModelsMenu }
            2 {
                $modeMenu = Get-AIText 'ModeMenu'
                Write-Host "1. $($modeMenu[0])";Write-Host "2. $($modeMenu[1])";Write-Host "3. $($modeMenu[2])";Write-Host "0. $($modeMenu[3])"
                $modeChoice = Read-AIChoice (Get-AIText 'SelectMode') @(0,1,2,3) $null
                if ($modeChoice -gt 0) { Set-PSAITerminalMode -Mode @('Off','AI','Auto')[$modeChoice-1] }
            }
            3 {
                $enabled = Read-AIYesNo (Get-AIText 'ColorPrompt') ([bool]$script:Config.appearance.colorEnabled)
                Set-PSAITerminalOption -ColorEnabled $enabled | Out-Null
            }
            4 { Open-AILanguageMenu }
            5 { Open-AIHelpMenu }
            6 {
                $online = Read-AIYesNo (Get-AIText 'AskOnlineTest') $false
                Test-PSAIConfiguration -Online:$online | Format-Table -AutoSize -Wrap | Out-Host
                [void](Read-Host (Get-AIText 'ReturnPrompt'))
            }
            7 {
                $uninstalled = Open-AIUninstallMenu
                if ($uninstalled) { return }
            }
        }
    }
}

function Enable-PSAITerminal {
    [CmdletBinding()] param()
    if (-not $script:Config.activeModel) { throw '请先输入 ai 添加模型。' }
    Set-PSAITerminalMode -Mode ([string]$script:Config.lastEnabledMode)
}

function Disable-PSAITerminal { [CmdletBinding()] param() Set-PSAITerminalMode -Mode Off }

function Get-PSAITerminalMode { [string]$script:Config.mode }

function Set-PSAITerminalMode {
    [CmdletBinding()] param([Parameter(Mandatory,Position=0)][ValidateSet('Off','AI','Auto')][string]$Mode)
    if ($Mode -ne 'Off') { [void](Assert-AIActiveModelReady) }
    Invoke-AIConfigMutation {
        $script:Config.mode = $Mode
        if ($Mode -ne 'Off') { $script:Config.lastEnabledMode = $Mode }
    }
    Register-AIPromptIntegration
    Write-Host (Get-AIText 'ModeChanged' @($Mode))
}

function Get-PSAITerminalOption {
    [pscustomobject]@{
        Language = Get-AILanguage
        Mode = $script:Config.mode
        ActiveModel = $script:Config.activeModel
        Shortcuts = [pscustomobject]$script:Config.shortcuts
        Appearance = [pscustomobject]$script:Config.appearance
        Integrations = [pscustomobject]$script:Config.integrations
        Execution = [pscustomobject]$script:Config.execution
        ConfigPath = $script:ConfigPath
    }
}

function Set-PSAITerminalOption {
    [CmdletBinding()] param(
        [ValidateRange(1,100)][int]$MaxAgentSteps,
        [ValidateRange(10,600)][int]$RequestTimeoutSeconds,
        [ValidateRange(50,90)][int]$ContextBudgetPercent,
        [ValidateRange(2,32)][int]$RecentTurns,
        [ValidateRange(1024,65536)][int]$OutputCaptureCharacters,
        [Nullable[bool]]$ColorEnabled,
        [Nullable[bool]]$EnterRouting,
        [ValidateSet('en-US','zh-CN')][string]$Language
    )
    $hasMaxAgentSteps = $PSBoundParameters.ContainsKey('MaxAgentSteps')
    $hasRequestTimeout = $PSBoundParameters.ContainsKey('RequestTimeoutSeconds')
    $hasContextBudget = $PSBoundParameters.ContainsKey('ContextBudgetPercent')
    $hasRecentTurns = $PSBoundParameters.ContainsKey('RecentTurns')
    $hasOutputCapture = $PSBoundParameters.ContainsKey('OutputCaptureCharacters')
    $hasColor = $PSBoundParameters.ContainsKey('ColorEnabled')
    $hasEnterRouting = $PSBoundParameters.ContainsKey('EnterRouting')
    $hasLanguage = $PSBoundParameters.ContainsKey('Language')
    Invoke-AIConfigMutation {
        if ($hasMaxAgentSteps) { $script:Config.execution.maxAgentSteps = $MaxAgentSteps }
        if ($hasRequestTimeout) { $script:Config.execution.requestTimeoutSeconds = $RequestTimeoutSeconds }
        if ($hasContextBudget) { $script:Config.execution.contextBudgetPercent = $ContextBudgetPercent }
        if ($hasRecentTurns) { $script:Config.execution.recentTurns = $RecentTurns }
        if ($hasOutputCapture) { $script:Config.execution.outputCaptureCharacters = $OutputCaptureCharacters }
        if ($hasColor) { $script:Config.appearance.colorEnabled = [bool]$ColorEnabled }
        if ($hasEnterRouting) { $script:Config.integrations.enterRouting = [bool]$EnterRouting }
        if ($hasLanguage) { $script:Config.language = $Language }
    }
    if ($hasEnterRouting) {
        Unregister-AIPSReadLineIntegration
        Register-AIPSReadLineIntegration
    }
    if ($hasLanguage) { Write-Host (Get-AIText 'LanguageChanged') }
    Get-PSAITerminalOption
}
