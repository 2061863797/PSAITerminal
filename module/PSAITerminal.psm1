Set-StrictMode -Version 3.0

$script:ModuleName = 'PSAITerminal'
$script:HostEdition = if ($PSVersionTable.PSEdition) { [string]$PSVersionTable.PSEdition } else { 'Desktop' }
$script:HostVersion = [version]$PSVersionTable.PSVersion
$script:IsWindowsPlatform = $env:OS -eq 'Windows_NT'
$script:OfficialIntegrationAvailable = $false
if (-not $script:IsWindowsPlatform) {
    throw 'PSAITerminal 0.6.0 仅支持 Windows。'
}
if ($script:HostEdition -eq 'Core') {
    if ($script:HostVersion -lt [version]'7.4') {
        throw "PSAITerminal 在 PowerShell Core 中要求 7.4 或更高版本；当前为 $script:HostVersion。"
    }
    $integrationAssemblyPath = Join-Path $PSScriptRoot 'bin/PSAITerminal.PowerShell7.dll'
    if (-not (Test-Path -LiteralPath $integrationAssemblyPath -PathType Leaf)) {
        throw "PowerShell 7 集成程序集不存在：$integrationAssemblyPath"
    }
    [void][Reflection.Assembly]::LoadFrom($integrationAssemblyPath)
    $script:OfficialIntegrationAvailable = $true
}
$script:ValidModes = @('Off', 'AI', 'Auto')
$script:ValidProtocols = @('Anthropic', 'OpenAIChat', 'OpenAIResponses', 'GeminiNative', 'Ollama')
$script:SessionSecrets = @{}
$script:LastSubmittedCommand = $null
$script:LastCommandResult = $null
$script:PredictorEnabled = $false
$script:FeedbackEnabled = $false
$script:PSReadLineIntegrated = $false
$script:ShortcutMigrated = $false
$script:OriginalKeyBindings = @{}
$script:BoundKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:InternalHistoryLines = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$script:PendingInvocationScripts = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
$script:NextPendingInvocationId = $null
$script:OriginalAddToHistoryHandler = $null
$script:PSAIAddToHistoryHandler = $null
$script:OriginalPSConsoleHostReadLine = $null
$script:PSAIHostReadLine = $null
$script:NextReadLineAction = $null
$script:OriginalPrompt = $null
$script:PSAIPromptWrapper = $null
$script:PromptInvocationActive = $false
$script:PromptStateVariableName = '__PSAITerminalPromptIntegrationState'
$script:PromptOwnerToken = [guid]::NewGuid().ToString('N')
$script:CurrentSession = $null
$script:ConfigLoadFailed = $false
$script:LastSecretStoreError = $null
$script:Config = $null
$script:MaximumConfigBytes = 1MB
$script:MaximumSessionBytes = 16MB
$script:MaximumRunBytes = 4MB
$script:FileLockTimeoutMilliseconds = 10000

function Invoke-AIOfficialAddPrediction([string]$Command) {
    if ($script:OfficialIntegrationAvailable) {
        [PSAITerminal.AITerminalOfficialIntegration]::AddPrediction($Command)
    }
}

function Get-AIOfficialFeedback {
    if ($script:OfficialIntegrationAvailable) {
        return [PSAITerminal.AITerminalOfficialIntegration]::GetLastFeedback()
    }
    $null
}

function Test-AIOfficialPredictorRegistered {
    if (-not $script:OfficialIntegrationAvailable) { return $false }
    [bool][PSAITerminal.AITerminalOfficialIntegration]::PredictorRegistered
}

function Test-AIOfficialFeedbackRegistered {
    if (-not $script:OfficialIntegrationAvailable) { return $false }
    [bool][PSAITerminal.AITerminalOfficialIntegration]::FeedbackRegistered
}

function Get-AILanguage {
    if ($script:Config -and [string]$script:Config.language -in @('en-US','zh-CN')) {
        return [string]$script:Config.language
    }
    'en-US'
}

function Get-AIText([string]$Key, [object[]]$FormatArguments = @()) {
    $texts = @{
        'Settings' = @{'en-US'='PSAITerminal';'zh-CN'='PSAITerminal'}
        'CurrentMode' = @{'en-US'='Mode: {0}';'zh-CN'='当前模式：{0}'}
        'CurrentModel' = @{'en-US'='Model: {0}';'zh-CN'='当前模型：{0}'}
        'ConfigPath' = @{'en-US'='Config: {0}';'zh-CN'='配置文件：{0}'}
        'Models' = @{'en-US'='Models';'zh-CN'='模型配置'}
        'Mode' = @{'en-US'='Mode';'zh-CN'='切换模式'}
        'Appearance' = @{'en-US'='Appearance';'zh-CN'='外观'}
        'Language' = @{'en-US'='Language / 语言';'zh-CN'='语言 / Language'}
        'Help' = @{'en-US'='Help';'zh-CN'='使用帮助'}
        'Diagnostics' = @{'en-US'='Diagnostics';'zh-CN'='检查配置'}
        'Back' = @{'en-US'='Back';'zh-CN'='返回'}
        'AddModel' = @{'en-US'='Add model';'zh-CN'='新增模型'}
        'Cancel' = @{'en-US'='Cancel';'zh-CN'='取消'}
        'Current' = @{'en-US'='(current)';'zh-CN'='（当前）'}
        'Used' = @{'en-US'='Active';'zh-CN'='当前使用'}
        'Unused' = @{'en-US'='Inactive';'zh-CN'='未使用'}
        'CommonCommands' = @{'en-US'='Common commands';'zh-CN'='常用命令'}
        'Shortcuts' = @{'en-US'='Shortcuts';'zh-CN'='快捷键'}
        'UsageHelp' = @{'en-US'='Usage help';'zh-CN'='使用帮助'}
        'Execute' = @{'en-US'='Execute';'zh-CN'='执行'}
        'Edit' = @{'en-US'='Edit';'zh-CN'='编辑'}
        'Reject' = @{'en-US'='Reject';'zh-CN'='拒绝'}
        'Terminate' = @{'en-US'='Terminate';'zh-CN'='终止'}
        'DefaultPrompt' = @{'en-US'=' (default {0})';'zh-CN'='（默认{0}）'}
        'English' = @{'en-US'='English';'zh-CN'='English'}
        'Chinese' = @{'en-US'='Chinese (简体中文)';'zh-CN'='简体中文 (Chinese)'}
        'LanguageChanged' = @{'en-US'='Language changed to English.';'zh-CN'='语言已切换为中文。'}
        'EnterNumber' = @{'en-US'='Enter a number';'zh-CN'='请输入序号'}
        'InvalidNumber' = @{'en-US'='Invalid number. Please try again.';'zh-CN'='输入的序号无效，请重新输入。'}
        'SelectProtocol' = @{'en-US'='Select protocol';'zh-CN'='选择协议'}
        'NoModels' = @{'en-US'='No models configured.';'zh-CN'='尚未配置模型。'}
        'SelectModel' = @{'en-US'='Select model';'zh-CN'='请选择模型'}
        'ModelId' = @{'en-US'='Model ID';'zh-CN'='模型 ID'}
        'ManualModelId' = @{'en-US'='Enter model ID manually (leave blank to cancel)';'zh-CN'='手动输入模型 ID，留空取消'}
        'LoadingModels' = @{'en-US'='Loading available models...';'zh-CN'='正在获取可用模型...'}
        'AddModelName' = @{'en-US'='Configuration name';'zh-CN'='配置名称'}
        'Endpoint' = @{'en-US'='Base endpoint';'zh-CN'='接口基础地址'}
        'ApiKey' = @{'en-US'='API key (hidden)';'zh-CN'='API Key（隐藏）'}
        'CurrentProtocol' = @{'en-US'='Current protocol';'zh-CN'='当前协议'}
        'CurrentModelLabel' = @{'en-US'='Model';'zh-CN'='模型'}
        'Address' = @{'en-US'='Endpoint';'zh-CN'='地址'}
        'Status' = @{'en-US'='Status';'zh-CN'='状态'}
        'ApiKeyStatus' = @{'en-US'='API key';'zh-CN'='API Key'}
        'ActiveStatus' = @{'en-US'='Active';'zh-CN'='当前使用'}
        'InactiveStatus' = @{'en-US'='Inactive';'zh-CN'='未使用'}
        'SetActive' = @{'en-US'='Set as active';'zh-CN'='设为当前模型'}
        'EditConfig' = @{'en-US'='Edit configuration';'zh-CN'='编辑配置'}
        'TestConnection' = @{'en-US'='Test connection';'zh-CN'='测试连接'}
        'DeleteConfig' = @{'en-US'='Delete configuration';'zh-CN'='删除配置'}
        'ChooseReplacement' = @{'en-US'='Select the active model after deletion:';'zh-CN'='请选择删除后的当前模型：'}
        'AskOnlineTest' = @{'en-US'='Test the active model too? This sends one minimal request.';'zh-CN'='同时测试当前模型？这会发送一次最小请求。'}
        'ReturnPrompt' = @{'en-US'='Press Enter to return';'zh-CN'='按 Enter 返回'}
        'ModeOff' = @{'en-US'='Off';'zh-CN'='Off'}
        'ModeAI' = @{'en-US'='AI';'zh-CN'='AI'}
        'ModeAuto' = @{'en-US'='Auto';'zh-CN'='Auto'}
        'SelectMode' = @{'en-US'='Select mode';'zh-CN'='请选择模式'}
        'ColorPrompt' = @{'en-US'='Use a dedicated color for AI output?';'zh-CN'='启用统一的 AI 输出颜色？'}
        'ApprovalPurpose' = @{'en-US'='Purpose';'zh-CN'='目的'}
        'ApprovalCommand' = @{'en-US'='Command';'zh-CN'='命令'}
        'ApprovalExpected' = @{'en-US'='Expected result';'zh-CN'='预期'}
        'ApprovalSideEffects' = @{'en-US'='Side effects';'zh-CN'='副作用'}
        'ApprovalRollback' = @{'en-US'='Rollback';'zh-CN'='回滚'}
        'ApprovalRisk' = @{'en-US'='Risk';'zh-CN'='风险'}
        'ApprovalNotice' = @{
            'en-US'='AI-generated descriptions may be inaccurate. Verify the complete command before approving.'
            'zh-CN'='目的、预期和副作用由 AI 生成，可能不准确；批准前请核对完整命令。'
        }
        'HighRiskConfirm' = @{
            'en-US'='This is a high-risk command. Execute exactly the command shown above?'
            'zh-CN'='这是高风险命令。确定执行上面显示的完整命令吗？'
        }
        'ApprovalMenu' = @{'en-US'=@('Execute','Edit','Reject','Terminate');'zh-CN'=@('执行','编辑','拒绝','终止')}
        'Protocol' = @{'en-US'='Protocol';'zh-CN'='协议'}
        'Model' = @{'en-US'='Model';'zh-CN'='模型'}
        'EndpointLabel' = @{'en-US'='Endpoint';'zh-CN'='地址'}
        'ModelStatus' = @{'en-US'='Status';'zh-CN'='状态'}
        'ApiKeySaved' = @{'en-US'='saved';'zh-CN'='已保存'}
        'ApiKeyMissing' = @{'en-US'='missing; edit configuration to update';'zh-CN'='缺少，请编辑配置后更新'}
        'NoModelsWarning' = @{'en-US'='No models configured.';'zh-CN'='尚未配置模型。'}
        'SelectNumber' = @{'en-US'='Enter a number';'zh-CN'='请输入序号'}
        'RemoteModelsFailed' = @{'en-US'='Unable to load the model list: {0}';'zh-CN'='自动获取模型列表失败：{0}'}
        'EnterModelManually' = @{'en-US'='Enter a model ID manually?';'zh-CN'='是否手动输入模型 ID？'}
        'NoRemoteModels' = @{'en-US'='The service returned no available generation models.';'zh-CN'='服务没有返回可用生成模型。'}
        'DuplicateModel' = @{'en-US'='A model configuration named {0} already exists.';'zh-CN'='模型配置已存在：{0}'}
        'ModelAdded' = @{'en-US'='Model configuration added and activated.';'zh-CN'='模型配置已添加并立即生效。'}
        'CredentialFallback' = @{'en-US'='Saving to the system credential store failed. Use the API key for this PowerShell session only?';'zh-CN'='系统密钥库保存失败，是否改为仅当前 PowerShell 会话使用？'}
        'ModelAddedSession' = @{'en-US'='Model configuration added; the API key is available only in this session.';'zh-CN'='模型配置已添加；API Key 仅在当前会话有效。'}
        'ModelMissing' = @{'en-US'='Model configuration not found.';'zh-CN'='模型不存在。'}
        'ChangeProtocol' = @{'en-US'='Change the protocol?';'zh-CN'='是否修改协议？'}
        'UpdateApiKey' = @{'en-US'='Update the API key?';'zh-CN'='是否更新 API Key？'}
        'NewApiKey' = @{'en-US'='New API key (hidden)';'zh-CN'='新 API Key（隐藏）'}
        'ModelUpdated' = @{'en-US'='Model configuration updated.';'zh-CN'='模型配置已更新。'}
        'ModelUpdatedSession' = @{'en-US'='Model configuration updated; the API key is available only in this session.';'zh-CN'='模型配置已更新；API Key 仅在当前会话有效。'}
        'ConfirmDeleteModel' = @{'en-US'='Delete ''{0}''?';'zh-CN'='确定删除“{0}”？'}
        'ModelDeleted' = @{'en-US'='Model configuration deleted.';'zh-CN'='模型配置已删除。'}
        'EditedCommand' = @{'en-US'='Enter the complete edited command';'zh-CN'='请输入修改后的完整命令'}
        'ModeChanged' = @{'en-US'='PSAITerminal mode: {0}';'zh-CN'='PSAITerminal 模式：{0}'}
        'ModeMenu' = @{'en-US'=@('Off','AI','Auto','Back');'zh-CN'=@('Off','AI','Auto','返回')}
        'HelpCommands' = @{'en-US'='Common commands';'zh-CN'='常用命令'}
        'HelpShortcuts' = @{'en-US'='Shortcuts';'zh-CN'='快捷键'}
        'HelpBack' = @{'en-US'='Back';'zh-CN'='返回'}
        'LoadedGuide' = @{
            'en-US'="PSAITerminal loaded. / PSAITerminal 已加载。`nType ai to configure a model. / 输入 ai 配置模型。`nF2: AI  F3: PowerShell  F6: mode  F7: explain. / F2：AI  F3：PowerShell  F6：模式  F7：解释。"
            'zh-CN'="PSAITerminal 已加载。/ PSAITerminal loaded.`n输入 ai 配置模型。/ Type ai to configure a model.`nF2：AI  F3：PowerShell  F6：模式  F7：解释。/ F2: AI  F3: PowerShell  F6: mode  F7: explain."
        }
    }
    $value = if ($texts.ContainsKey($Key)) { $texts[$Key][(Get-AILanguage)] } else { $null }
    if ($null -eq $value) { return $Key }
    if ($FormatArguments.Count -gt 0) { return $value -f $FormatArguments }
    $value
}

function Get-AIPromptPrefix {
    switch ([string]$script:Config.mode) {
        'AI' { '[AI] ' }
        'Auto' { '[AUTO] ' }
        default { '' }
    }
}

function Get-AIDefaultPromptText {
    $location = [string]$ExecutionContext.SessionState.Path.CurrentLocation
    if ([string]::IsNullOrWhiteSpace($location)) { $location = [Environment]::CurrentDirectory }
    "PS $location> "
}

function Get-AIPromptIntegrationState {
    [AppDomain]::CurrentDomain.GetData($script:PromptStateVariableName)
}

function Test-AISamePromptScriptBlock([AllowNull()][scriptblock]$Left, [AllowNull()][scriptblock]$Right) {
    if (-not $Left -or -not $Right) { return $false }
    if ([object]::ReferenceEquals($Left, $Right)) { return $true }
    [string]::Equals($Left.ToString(), $Right.ToString(), [StringComparison]::Ordinal)
}

function Test-AILegacyPromptWrapper([AllowNull()][scriptblock]$ScriptBlock) {
    if (-not $ScriptBlock) { return $false }
    $text = $ScriptBlock.ToString()
    $text.Contains('Get-Module PSAITerminal') -and $text.Contains('Invoke-AIWrappedPrompt')
}

function Find-AILegacyOriginalPrompt {
    foreach ($loadedModule in @(Get-Module PSAITerminal)) {
        try {
            $candidate = & $loadedModule {
                [pscustomobject]@{
                    OriginalPrompt = $script:OriginalPrompt
                    PromptWrapper = $script:PSAIPromptWrapper
                }
            }
            if ($candidate.OriginalPrompt -and -not (Test-AILegacyPromptWrapper $candidate.OriginalPrompt)) {
                return $candidate.OriginalPrompt
            }
        } catch {
            Write-Debug "无法读取旧 PSAITerminal 实例的 Prompt 状态：$($_.Exception.Message)"
        }
    }
    $null
}

function Invoke-AIWrappedPrompt {
    $lastSuccess = $?
    $state = Get-AIPromptIntegrationState
    if ($script:PromptInvocationActive -or ($state -and [bool]$state.InvocationActive)) {
        return Get-AIDefaultPromptText
    }

    $script:PromptInvocationActive = $true
    if ($state) { $state.InvocationActive = $true }
    try {
        $prefix = Get-AIPromptPrefix
        if ($prefix) {
            Write-AIColoredHost $prefix DarkCyan -NoNewline
        }
        if ($script:OriginalPrompt) {
            if ($lastSuccess) { $null = $true }
            else { Write-Error 'PSAITerminal prompt status preservation' -ErrorAction Ignore }
            & $script:OriginalPrompt
        } else {
            Get-AIDefaultPromptText
        }
    } finally {
        if ($state) { $state.InvocationActive = $false }
        $script:PromptInvocationActive = $false
    }
}

function Register-AIPromptIntegration {
    if ($Host.Name -ne 'ConsoleHost' -or [Console]::IsInputRedirected) { return }
    $current = Get-Command prompt -CommandType Function -ErrorAction SilentlyContinue
    if (-not $current) { return }
    if ($script:PSAIPromptWrapper -and [object]::ReferenceEquals($current.ScriptBlock, $script:PSAIPromptWrapper)) { return }

    $state = Get-AIPromptIntegrationState
    if ($state -and (Test-AISamePromptScriptBlock $current.ScriptBlock $state.PromptWrapper)) {
        $script:OriginalPrompt = $state.OriginalPrompt
    } elseif (Test-AILegacyPromptWrapper $current.ScriptBlock) {
        $script:OriginalPrompt = Find-AILegacyOriginalPrompt
    } else {
        $script:OriginalPrompt = $current.ScriptBlock
    }
    if (-not $script:OriginalPrompt) {
        $script:OriginalPrompt = { Get-AIDefaultPromptText }
    }

    $module = $ExecutionContext.SessionState.Module
    $script:PSAIPromptWrapper = {
        $state = [AppDomain]::CurrentDomain.GetData('__PSAITerminalPromptIntegrationState')
        if ($state -and [bool]$state.InvocationActive) {
            $location = [string]$ExecutionContext.SessionState.Path.CurrentLocation
            if ([string]::IsNullOrWhiteSpace($location)) { $location = [Environment]::CurrentDirectory }
            "PS $location> "
        } elseif ($state -and $state.Owner) {
            & $state.Owner { Invoke-AIWrappedPrompt }
        } else {
            $location = [string]$ExecutionContext.SessionState.Path.CurrentLocation
            if ([string]::IsNullOrWhiteSpace($location)) { $location = [Environment]::CurrentDirectory }
            "PS $location> "
        }
    }
    $state = [pscustomobject]@{
        Owner = $module
        OwnerToken = $script:PromptOwnerToken
        OriginalPrompt = $script:OriginalPrompt
        PromptWrapper = $script:PSAIPromptWrapper
        OriginalReadLine = $script:OriginalPSConsoleHostReadLine
        ReadLineWrapper = $script:PSAIHostReadLine
        InvocationActive = $false
    }
    [AppDomain]::CurrentDomain.SetData($script:PromptStateVariableName, $state)
    Set-Item -LiteralPath Function:\global:prompt -Value $script:PSAIPromptWrapper
}

function Unregister-AIPromptIntegration {
    $current = Get-Command prompt -CommandType Function -ErrorAction SilentlyContinue
    $state = Get-AIPromptIntegrationState
    if ($state -and $state.OwnerToken -eq $script:PromptOwnerToken) {
        if ($script:OriginalPrompt -and $current -and (Test-AISamePromptScriptBlock $current.ScriptBlock $state.PromptWrapper)) {
            Set-Item -LiteralPath Function:\global:prompt -Value $script:OriginalPrompt
        }
        [AppDomain]::CurrentDomain.SetData($script:PromptStateVariableName, $null)
    }
    $script:OriginalPrompt = $null
    $script:PSAIPromptWrapper = $null
    $script:PromptInvocationActive = $false
}

function Get-AIUserHomeDirectory {
    $path = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($path)) { $path = $HOME }
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-AIPathFullyQualified $path)) {
        throw '无法确定当前用户主目录。'
    }
    [IO.Path]::GetFullPath($path)
}

function Test-AIPathFullyQualified([AllowNull()][string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        if ($Path -match '^[A-Za-z]:[\\/]') { return $true }
        if ($Path -match '^[\\/]{2}[^\\/]+[\\/][^\\/]+(?:[\\/]|$)') { return $true }
        if ($Path -match '^\\\\\?\\(?:[A-Za-z]:\\|UNC\\[^\\]+\\[^\\]+(?:\\|$))') { return $true }
    } catch { return $false }
    $false
}

function ConvertTo-AIJsonMap([AllowNull()]$Value) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [Collections.IDictionary]) {
        $map = [ordered]@{}
        foreach ($key in $Value.Keys) { $map[[string]$key] = ConvertTo-AIJsonMap $Value[$key] }
        return ,$map
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $Value) { $items += ,(ConvertTo-AIJsonMap $item) }
        return ,$items
    }
    $properties = @($Value.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty','Property') })
    if ($Value -is [pscustomobject] -or $properties.Count -gt 0) {
        $map = [ordered]@{}
        foreach ($property in $properties) { $map[$property.Name] = ConvertTo-AIJsonMap $property.Value }
        return ,$map
    }
    $Value
}

function ConvertFrom-AIJson([Parameter(Mandatory)][string]$Json) {
    $parsed = $Json | ConvertFrom-Json -ErrorAction Stop
    ConvertTo-AIJsonMap $parsed
}

function Read-AITextFile([Parameter(Mandatory)][string]$Path, [switch]$Utf8Only) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return '' }

    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    if ($Utf8Only) {
        $offset = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
        return $strictUtf8.GetString($bytes, $offset, $bytes.Length - $offset)
    }

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

function Resolve-AIStorageOverride([string]$Value, [string]$VariableName) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if (-not (Test-AIPathFullyQualified $Value)) {
        throw "$VariableName 必须是完整的绝对路径。"
    }
    [IO.Path]::GetFullPath($Value)
}

function Get-AIConfigDirectory {
    $override = Resolve-AIStorageOverride $env:PSAI_CONFIG_HOME 'PSAI_CONFIG_HOME'
    if ($override) { return $override }
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell/PSAITerminal'
}

function Get-AIDataDirectory {
    $override = Resolve-AIStorageOverride $env:PSAI_DATA_HOME 'PSAI_DATA_HOME'
    if ($override) { return $override }
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PowerShell/PSAITerminal'
}

function New-AIDefaultConfig {
    [ordered]@{
        schemaVersion = 2
        revision = 0L
        shortcutPresetVersion = 4
        language = 'en-US'
        mode = 'Off'
        lastEnabledMode = 'Auto'
        activeModel = $null
        activeSession = $null
        models = [ordered]@{}
        shortcuts = [ordered]@{
            cycleMode = 'F6'
            forceAI = 'F2'
            forceShell = 'F3'
            explainLast = 'F7'
            openSettings = $null
            selectModel = $null
        }
        appearance = [ordered]@{
            colorEnabled = $true
        }
        integrations = [ordered]@{
            enterRouting = $true
            feedbackProvider = $true
            predictor = $false
        }
        execution = [ordered]@{
            maxAgentSteps = 12
            requestTimeoutSeconds = 120
            contextBudgetPercent = 75
            recentTurns = 8
            outputCaptureCharacters = 65536
        }
        onboardingShown = $false
    }
}

function Test-AIMapContains($Map, [string]$Key) {
    if ($Map -is [hashtable]) { return $Map.ContainsKey($Key) }
    $Map.Contains($Key)
}

function Get-AIRevision([Collections.IDictionary]$Value, [string]$Label) {
    if (-not (Test-AIMapContains $Value 'revision')) { return 0L }
    $revision = $Value.revision
    $isInteger = $revision -is [sbyte] -or $revision -is [byte] -or $revision -is [int16] -or
        $revision -is [uint16] -or $revision -is [int32] -or $revision -is [uint32] -or
        $revision -is [int64] -or $revision -is [uint64]
    if (-not $isInteger -or [decimal]$revision -lt 0 -or [decimal]$revision -ge [long]::MaxValue) {
        throw "$Label revision 无效。"
    }
    [long]$revision
}

function Get-AIStoredRevision([string]$Path, [string]$Label, [int]$MaximumBytes) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return -1L }
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.Length -gt $MaximumBytes) { throw "${Label}文件超过 $MaximumBytes 字节上限。" }
    $stored = ConvertFrom-AIJson (Read-AITextFile $Path -Utf8Only)
    if ($stored -isnot [Collections.IDictionary]) { throw "${Label}文件根节点无效。" }
    Get-AIRevision $stored $Label
}

function Invoke-AIWithFileLock([string]$Path, [scriptblock]$Action) {
    $lock = [PSAITerminal.AITerminalAtomicFile]::AcquireLock($Path, $script:FileLockTimeoutMilliseconds)
    try { & $Action }
    finally { $lock.Dispose() }
}

function Assert-AISerializedSize([string]$Json, [int]$MaximumBytes, [string]$Label) {
    $bytes = [Text.Encoding]::UTF8.GetByteCount($Json)
    if ($bytes -gt $MaximumBytes) { throw "${Label}超过 $MaximumBytes 字节上限。" }
}

function Assert-AIModelName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 64 -or
        $Name -match '[\\/:*?"<>|\x00-\x1F\x7F-\x9F]') {
        throw '模型配置名称不能为空、不能超过 64 个字符，且不能包含路径符号或控制字符。'
    }
}

function Assert-AIModelId([string]$ModelId) {
    if ([string]::IsNullOrWhiteSpace($ModelId) -or $ModelId.Length -gt 512 -or
        $ModelId -match '[\x00-\x1F\x7F-\x9F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]') {
        throw '模型 ID 不能为空、不能超过 512 个字符，且不能包含控制字符。'
    }
}

function Assert-AIIntegerValue($Value, [int]$Minimum, [int]$Maximum, [string]$Label) {
    $isInteger = $Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
    if (-not $isInteger) { throw "$Label 必须是整数。" }
    $number = [decimal]$Value
    if ($number -lt $Minimum -or $number -gt $Maximum) {
        throw "$Label 必须在 $Minimum 到 $Maximum 之间。"
    }
}

function Assert-AIModelParameters($Value, [string]$Path = 'parameters', [int]$Depth = 0) {
    if ($Depth -gt 10) { throw "模型参数 '$Path' 嵌套过深。" }
    if ($Value -is [Collections.IDictionary]) {
        if ($Value.Count -gt 200) { throw "模型参数 '$Path' 项目过多。" }
        foreach ($entry in $Value.GetEnumerator()) {
            $name = [string]$entry.Key
            if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 128 -or $name -match '[\x00-\x1F\x7F-\x9F]') {
                throw "模型参数 '$Path' 包含无效字段名。"
            }
            if ($name -match '(?i)(api[-_]?key|access[-_]?token|authorization|password|passwd|secret|credential)') {
                throw "模型参数 '$Path.$name' 看起来包含凭据，请改用系统密钥库。"
            }
            Assert-AIModelParameters $entry.Value "$Path.$name" ($Depth + 1)
        }
    } elseif ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        $index = 0
        foreach ($item in $Value) {
            if ($index -ge 1000) { throw "模型参数 '$Path' 数组过长。" }
            Assert-AIModelParameters $item "$Path[$index]" ($Depth + 1)
            $index++
        }
    } elseif ($Value -is [string]) {
        if ($Value.Length -gt 65536 -or $Value -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') {
            throw "模型参数 '$Path' 包含过长文本或无效控制字符。"
        }
    } elseif (($Value -is [single] -and ([single]::IsNaN($Value) -or [single]::IsInfinity($Value))) -or
        ($Value -is [double] -and ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)))) {
        throw "模型参数 '$Path' 不能是 NaN 或无穷大。"
    } elseif ($null -ne $Value -and $Value -isnot [bool] -and
        $Value -isnot [sbyte] -and $Value -isnot [byte] -and $Value -isnot [int16] -and
        $Value -isnot [uint16] -and $Value -isnot [int32] -and $Value -isnot [uint32] -and
        $Value -isnot [int64] -and $Value -isnot [uint64] -and $Value -isnot [single] -and
        $Value -isnot [double] -and $Value -isnot [decimal]) {
        throw "模型参数 '$Path' 只能使用 JSON 对象、数组、字符串、布尔值、数字或 null。"
    }
}

function ConvertTo-AICapabilities([Collections.IDictionary]$Value) {
    foreach ($name in @('streaming','toolCalling','usage')) {
        if ((Test-AIMapContains $Value $name) -and $Value[$name] -isnot [bool]) {
            throw "模型能力 '$name' 必须是布尔值。"
        }
    }
    [ordered]@{
        streaming = if (Test-AIMapContains $Value 'streaming') { [bool]$Value.streaming } else { $true }
        toolCalling = if (Test-AIMapContains $Value 'toolCalling') { [bool]$Value.toolCalling } else { $false }
        usage = if (Test-AIMapContains $Value 'usage') { [bool]$Value.usage } else { $false }
    }
}

function Assert-AIEndpointUri([uri]$Uri) {
    if (-not [PSAITerminal.AITerminalSecurity]::IsEndpointAllowed($Uri)) {
        throw '接口地址只允许 HTTPS；HTTP 仅允许本机环回地址，且不能包含用户名或密码。'
    }
    if ($Uri.Query -or $Uri.Fragment) { throw '接口基础地址不能包含查询参数或片段。' }
}

function ConvertTo-AIEndpoint([string]$Protocol, [uri]$Endpoint) {
    ([PSAITerminal.AITerminalEndpointResolver]::NormalizeBaseEndpoint($Protocol, $Endpoint)).AbsoluteUri.TrimEnd('/')
}

function Assert-AIConfigCandidate([Collections.IDictionary]$Candidate) {
    Assert-AIIntegerValue $Candidate.schemaVersion 2 2 '配置版本'
    [void](Get-AIRevision $Candidate '配置')
    Assert-AIIntegerValue $Candidate.shortcutPresetVersion 4 4 '快捷键预设版本'
    if ([string]$Candidate.language -notin @('en-US','zh-CN')) { throw '配置中的 language 必须是 en-US 或 zh-CN。' }
    if ([string]$Candidate.mode -notin $script:ValidModes) { throw '配置中的模式无效。' }
    if ([string]$Candidate.lastEnabledMode -notin @('AI', 'Auto')) { throw '配置中的上次启用模式无效。' }
    if ($Candidate.models -isnot [Collections.IDictionary]) { throw '配置中的 models 必须是对象。' }
    if ($Candidate.models.Count -gt 100) { throw '模型配置不能超过 100 个。' }
    foreach ($section in @('shortcuts', 'appearance', 'integrations', 'execution')) {
        if ($Candidate[$section] -isnot [Collections.IDictionary]) { throw "配置中的 $section 必须是对象。" }
    }
    if ($Candidate.onboardingShown -isnot [bool]) { throw '配置中的 onboardingShown 必须是布尔值。' }

    $seenShortcuts = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($shortcutName in @('cycleMode','forceAI','forceShell','explainLast','openSettings','selectModel')) {
        $shortcut = $Candidate.shortcuts[$shortcutName]
        if ($null -eq $shortcut -and $shortcutName -in @('openSettings','selectModel')) { continue }
        if ($shortcut -isnot [string] -or [string]::IsNullOrWhiteSpace($shortcut) -or $shortcut.Length -gt 64 -or
            $shortcut -match '[\x00-\x1F\x7F-\x9F]') {
            throw "快捷键 '$shortcutName' 无效。"
        }
        if (-not $seenShortcuts.Add($shortcut)) { throw "快捷键重复：$shortcut" }
    }
    foreach ($name in @('colorEnabled')) {
        if ($Candidate.appearance[$name] -isnot [bool]) { throw "外观配置 '$name' 必须是布尔值。" }
    }
    foreach ($name in @('enterRouting','feedbackProvider','predictor')) {
        if ($Candidate.integrations[$name] -isnot [bool]) { throw "集成配置 '$name' 必须是布尔值。" }
    }
    if ($Candidate.activeSession -and ([string]$Candidate.activeSession) -notmatch '^[a-fA-F0-9]{32}$') {
        throw '当前会话 ID 无效。'
    }

    foreach ($entry in $Candidate.models.GetEnumerator()) {
        $name = [string]$entry.Key
        $model = $entry.Value
        Assert-AIModelName $name
        if ($model -isnot [Collections.IDictionary]) { throw "模型 '$name' 的配置无效。" }
        if ([string]$model.name -ne $name) { throw "模型 '$name' 的名称引用不一致。" }
        if ([string]$model.protocol -notin $script:ValidProtocols) { throw "模型 '$name' 的协议无效。" }
        try { Assert-AIModelId ([string]$model.modelId) }
        catch { throw "模型 '$name' 的模型 ID 无效：$($_.Exception.Message)" }
        $normalized = ConvertTo-AIEndpoint ([string]$model.protocol) ([uri][string]$model.endpoint)
        if ($normalized -ne ([string]$model.endpoint).TrimEnd('/')) { $model.endpoint = $normalized }
        Assert-AIIntegerValue $model.contextWindow 1024 2097152 "模型 '$name' 的上下文窗口"
        if ($model.parameters -isnot [Collections.IDictionary] -or $model.capabilities -isnot [Collections.IDictionary]) {
            throw "模型 '$name' 的参数或能力无效。"
        }
        foreach ($capability in @('streaming','toolCalling','usage')) {
            if (-not (Test-AIMapContains $model.capabilities $capability)) { throw "模型 '$name' 缺少能力字段 $capability。" }
        }
        Assert-AIModelParameters $model.parameters
    }

    if ($Candidate.activeModel -and -not (Test-AIMapContains $Candidate.models ([string]$Candidate.activeModel))) {
        throw '当前模型不存在。'
    }
    if ($Candidate.mode -ne 'Off' -and -not $Candidate.activeModel) {
        throw 'AI 或 Auto 模式必须先选择模型。'
    }
    Assert-AIIntegerValue $Candidate.execution.maxAgentSteps 1 100 'Agent 最大步骤数'
    Assert-AIIntegerValue $Candidate.execution.requestTimeoutSeconds 10 600 '请求超时'
    Assert-AIIntegerValue $Candidate.execution.contextBudgetPercent 50 90 '上下文压缩阈值'
    Assert-AIIntegerValue $Candidate.execution.recentTurns 2 32 '压缩后保留轮数'
    Assert-AIIntegerValue $Candidate.execution.outputCaptureCharacters 1024 65536 '步骤输出上限'
}

function Merge-AIConfig([Collections.IDictionary]$Loaded) {
    $candidate = New-AIDefaultConfig
    $shortcutVersion = if (Test-AIMapContains $Loaded 'shortcutPresetVersion') { [int]$Loaded.shortcutPresetVersion } else { 1 }
    foreach ($key in @('revision','language','mode', 'lastEnabledMode', 'activeModel', 'activeSession', 'models', 'onboardingShown')) {
        if (Test-AIMapContains $Loaded $key) { $candidate[$key] = $Loaded[$key] }
    }
    foreach ($section in @('shortcuts', 'appearance', 'integrations', 'execution')) {
        if (-not (Test-AIMapContains $Loaded $section)) { continue }
        if ($section -eq 'shortcuts' -and $shortcutVersion -lt 4) {
            $script:ShortcutMigrated = $true
            continue
        }
        if ($Loaded[$section] -isnot [Collections.IDictionary]) { throw "配置中的 $section 必须是对象。" }
        foreach ($key in @($candidate[$section].Keys)) {
            if (Test-AIMapContains $Loaded[$section] $key) { $candidate[$section][$key] = $Loaded[$section][$key] }
        }
    }
    $candidate.schemaVersion = 2
    $candidate.shortcutPresetVersion = 4
    foreach ($model in @($candidate.models.Values)) {
        if ($model.capabilities -is [Collections.IDictionary]) { $model.capabilities = ConvertTo-AICapabilities $model.capabilities }
    }
    Assert-AIConfigCandidate $candidate
    $candidate
}

function Initialize-AIState {
    $script:ConfigDirectory = Get-AIConfigDirectory
    $script:ConfigPath = Join-Path $script:ConfigDirectory 'config.json'
    $script:DataDirectory = Get-AIDataDirectory
    $script:SessionDirectory = Join-Path $script:DataDirectory 'sessions'
    $script:RunDirectory = Join-Path $script:DataDirectory 'runs'
    [PSAITerminal.AITerminalAtomicFile]::EnsurePrivateDirectory($script:ConfigDirectory)
    [PSAITerminal.AITerminalAtomicFile]::EnsurePrivateDirectory($script:DataDirectory)
    $script:Config = New-AIDefaultConfig
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { return }

    try {
        [PSAITerminal.AITerminalAtomicFile]::EnsurePrivateFile($script:ConfigPath)
        $configFile = Get-Item -LiteralPath $script:ConfigPath -ErrorAction Stop
        if ($configFile.Length -gt 1MB) { throw '配置文件超过 1 MiB 上限。' }
        $loaded = ConvertFrom-AIJson (Read-AITextFile $script:ConfigPath -Utf8Only)
        $script:Config = Merge-AIConfig $loaded
    } catch {
        $script:ConfigLoadFailed = $true
        $script:Config = New-AIDefaultConfig
        $backup = "$($script:ConfigPath).corrupt.$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss')).json"
        try {
            Copy-Item -LiteralPath $script:ConfigPath -Destination $backup -ErrorAction Stop
            [PSAITerminal.AITerminalAtomicFile]::EnsurePrivateFile($backup)
        }
        catch { Write-Warning "无法备份损坏配置：$($_.Exception.Message)" }
        Write-Warning "PSAITerminal 配置无法读取，已进入 Off 模式。原文件未覆盖。$($_.Exception.Message)"
        return
    }
    if ($script:ShortcutMigrated) {
        try { Save-AIConfig }
        catch { Write-Warning "快捷键配置已在当前会话迁移，但暂时无法写入磁盘；下次启动会重试：$($_.Exception.Message)" }
    }
}

function Save-AIConfig {
    param([switch]$LockHeld)
    if (-not $LockHeld) {
        return Invoke-AIWithFileLock $script:ConfigPath { Save-AIConfig -LockHeld }
    }

    Assert-AIConfigCandidate $script:Config
    $replacingCorruptConfig = $script:ConfigLoadFailed
    $previousRevision = Get-AIRevision $script:Config '配置'
    try {
        if (-not $replacingCorruptConfig) {
            $storedRevision = Get-AIStoredRevision $script:ConfigPath '配置' $script:MaximumConfigBytes
            if (($storedRevision -ge 0 -and $storedRevision -ne $previousRevision) -or
                ($storedRevision -lt 0 -and $previousRevision -ne 0)) {
                throw '配置已被另一个 PowerShell 进程修改。请重新导入模块后重试。'
            }
        } else {
            Write-Warning '正在用当前 Off 状态替换损坏配置；原始内容已保存在旁路备份中。'
        }
        $script:Config.revision = $previousRevision + 1
        $json = $script:Config | ConvertTo-Json -Depth 30
        Assert-AISerializedSize $json $script:MaximumConfigBytes '配置文件'
        [PSAITerminal.AITerminalAtomicFile]::WriteAllText($script:ConfigPath, $json)
        if ($replacingCorruptConfig) { $script:ConfigLoadFailed = $false }
    } catch {
        $script:Config.revision = $previousRevision
        throw
    }
}

function Copy-AIConfig {
    ConvertFrom-AIJson ($script:Config | ConvertTo-Json -Depth 30)
}

function Invoke-AIConfigMutation([scriptblock]$Mutation) {
    $previous = Copy-AIConfig
    try {
        & $Mutation
        Save-AIConfig
    } catch {
        $script:Config = $previous
        throw
    }
}

function New-AISessionObject([string]$Title) {
    $now = [DateTime]::UtcNow.ToString('O')
    [ordered]@{
        schemaVersion = 1
        revision = 0L
        id = [guid]::NewGuid().ToString('N')
        title = if ([string]::IsNullOrWhiteSpace($Title)) { '新会话' } else { (Protect-AIText $Title 120) }
        createdUtc = $now
        updatedUtc = $now
        summary = ''
        turns = @()
        inputTokens = 0L
        outputTokens = 0L
    }
}

function Get-AISessionPath([string]$Id) {
    if ($Id -notmatch '^[a-fA-F0-9]{32}$') { throw '会话 ID 无效。' }
    Join-Path $script:SessionDirectory "$Id.json"
}

function Save-AISession([Collections.IDictionary]$Session = $script:CurrentSession, [switch]$LockHeld,
    [switch]$RevisionAlreadyValidated) {
    if (-not $Session) { return }
    if ($RevisionAlreadyValidated -and -not $LockHeld) {
        throw '只有在持有会话文件锁时才能跳过修订号复核。'
    }
    $path = Get-AISessionPath ([string]$Session.id)
    if (-not $LockHeld) {
        return Invoke-AIWithFileLock $path { Save-AISession $Session -LockHeld }
    }

    $previousUpdatedUtc = $Session.updatedUtc
    $previousRevision = Get-AIRevision $Session '会话'
    try {
        if (-not $RevisionAlreadyValidated) {
            $storedRevision = Get-AIStoredRevision $path '会话' $script:MaximumSessionBytes
            if (($storedRevision -ge 0 -and $storedRevision -ne $previousRevision) -or
                ($storedRevision -lt 0 -and $previousRevision -ne 0)) {
                throw '会话已被另一个 PowerShell 进程修改。请重试当前操作。'
            }
        }
        if ($Session.turns -isnot [Collections.IList] -or $Session.turns -is [string] -or $Session.turns.Count -gt 2000) {
            throw '会话 turns 必须是最多包含 2000 项的数组。'
        }
        $Session.revision = $previousRevision + 1
        $Session.updatedUtc = [DateTime]::UtcNow.ToString('O')
        $json = $Session | ConvertTo-Json -Depth 50
        Assert-AISerializedSize $json $script:MaximumSessionBytes '会话文件'
        [PSAITerminal.AITerminalAtomicFile]::WriteAllText($path, $json)
    } catch {
        $Session.updatedUtc = $previousUpdatedUtc
        $Session.revision = $previousRevision
        throw
    }
}

function Import-AISession([string]$Id) {
    $path = Get-AISessionPath $Id
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        [PSAITerminal.AITerminalAtomicFile]::EnsurePrivateFile($path)
        $sessionFile = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($sessionFile.Length -gt 16MB) { throw '会话文件超过 16 MiB 上限。' }
        $session = ConvertFrom-AIJson (Read-AITextFile $path -Utf8Only)
        Assert-AIIntegerValue $session.schemaVersion 1 1 '会话版本'
        $session.revision = Get-AIRevision $session '会话'
        if ([string]$session.id -ne $Id -or $session.id -notmatch '^[a-fA-F0-9]{32}$') { throw '会话 ID 不一致。' }
        if ($session.turns -isnot [Collections.IList] -or $session.turns -is [string] -or $session.turns.Count -gt 2000) {
            throw '会话 turns 必须是最多包含 2000 项的数组。'
        }
        foreach ($dateName in @('createdUtc','updatedUtc')) {
            $parsedDate = [datetime]::MinValue
            if (-not [datetime]::TryParse([string]$session[$dateName], [ref]$parsedDate)) { throw "会话 $dateName 无效。" }
        }
        if ($session.title -isnot [string] -or $session.title.Length -gt 120) { throw '会话标题无效。' }
        if ($session.summary -isnot [string] -or $session.summary.Length -gt 65536) { throw '会话摘要无效。' }
        foreach ($tokenName in @('inputTokens','outputTokens')) {
            $tokenValue = $session[$tokenName]
            $isInteger = $tokenValue -is [sbyte] -or $tokenValue -is [byte] -or $tokenValue -is [int16] -or
                $tokenValue -is [uint16] -or $tokenValue -is [int32] -or $tokenValue -is [uint32] -or
                $tokenValue -is [int64] -or $tokenValue -is [uint64]
            if (-not $isInteger -or [decimal]$tokenValue -lt 0 -or [decimal]$tokenValue -gt [long]::MaxValue) {
                throw "会话 $tokenName 无效。"
            }
        }
        for ($index = 0; $index -lt $session.turns.Count; $index++) {
            $turn = $session.turns[$index]
            if ($turn -isnot [Collections.IDictionary] -or [string]$turn.id -notmatch '^[a-fA-F0-9]{32}$') {
                throw "会话 Turn $index 无效。"
            }
            if ($turn.role -isnot [string] -or [string]::IsNullOrWhiteSpace($turn.role) -or $turn.role.Length -gt 32 -or
                $turn.kind -isnot [string] -or [string]::IsNullOrWhiteSpace($turn.kind) -or $turn.kind.Length -gt 64 -or
                $turn.content -isnot [string]) {
                throw "会话 Turn $index 的字段无效。"
            }
            $turnDate = [datetime]::MinValue
            if (-not [datetime]::TryParse([string]$turn.createdUtc, [ref]$turnDate)) { throw "会话 Turn $index 的时间无效。" }
            if ($turn.metadata -isnot [Collections.IDictionary]) { throw "会话 Turn $index 的 metadata 无效。" }
            Assert-AIModelParameters $turn.metadata "turns[$index].metadata"
            $turn.role = Protect-AIText ([string]$turn.role) 32
            $turn.kind = Protect-AIText ([string]$turn.kind) 64
            $turn.content = Protect-AIText ([string]$turn.content) 65536
        }
        $session.title = Protect-AIText ([string]$session.title) 120
        $session.summary = Protect-AIText ([string]$session.summary) 16384
        if (Test-AIMapContains $session 'compactedTurnCount') {
            Assert-AIIntegerValue $session.compactedTurnCount 0 $session.turns.Count '会话已压缩 Turn 数'
        }
        $session
    } catch {
        Write-Warning "无法读取会话 $Id：$($_.Exception.Message)"
        $null
    }
}

function Initialize-AISessionState {
    [PSAITerminal.AITerminalAtomicFile]::EnsurePrivateDirectory($script:SessionDirectory)
    [PSAITerminal.AITerminalAtomicFile]::EnsurePrivateDirectory($script:RunDirectory)
    $session = if ($script:Config.activeSession) { Import-AISession ([string]$script:Config.activeSession) } else { $null }
    if (-not $session) {
        $session = New-AISessionObject '默认会话'
        Save-AISession $session
        if (-not $script:ConfigLoadFailed) {
            Invoke-AIConfigMutation { $script:Config.activeSession = [string]$session.id }
        } else { $script:Config.activeSession = [string]$session.id }
    }
    $script:CurrentSession = $session
    $lastTool = @($session.turns | Where-Object kind -eq 'tool_result' | Select-Object -Last 1)
    if ($lastTool.Count -and $lastTool[0].metadata -is [Collections.IDictionary]) {
        $metadata = $lastTool[0].metadata
        $script:LastCommandResult = [pscustomobject]@{
            Command=[string]$metadata.command;Succeeded=[bool]$metadata.succeeded;Output=[string]$metadata.output
            Error=if([bool]$metadata.succeeded){$null}else{[string]$metadata.output};Source='AI'
            CompletedUtc=[datetime]$lastTool[0].createdUtc;RunId=[string]$metadata.runId;StepId=[string]$metadata.stepId
        }
    }
}

function Add-AISessionUsageValues([Collections.IDictionary]$Session, [long]$InputTokens, [long]$OutputTokens) {
    if ($InputTokens -lt 0 -or $OutputTokens -lt 0) { throw '模型 Token 用量不能为负数。' }
    $newInputTokens = [decimal][long]$Session.inputTokens + [decimal]$InputTokens
    $newOutputTokens = [decimal][long]$Session.outputTokens + [decimal]$OutputTokens
    if ($newInputTokens -gt [long]::MaxValue -or $newOutputTokens -gt [long]::MaxValue) {
        throw '会话 Token 用量超过 Int64 上限。'
    }
    $Session.inputTokens = [long]$newInputTokens
    $Session.outputTokens = [long]$newOutputTokens
}

function Update-AISessionUsage([long]$InputTokens, [long]$OutputTokens) {
    if ($InputTokens -lt 0 -or $OutputTokens -lt 0) { throw '模型 Token 用量不能为负数。' }
    if (-not $script:CurrentSession -or ($InputTokens -eq 0 -and $OutputTokens -eq 0)) { return }
    $sessionId = [string]$script:CurrentSession.id
    $path = Get-AISessionPath $sessionId
    Invoke-AIWithFileLock $path {
        $latest = Import-AISession $sessionId
        if (-not $latest) { throw "会话不存在或无法读取：$sessionId" }
        Add-AISessionUsageValues $latest $InputTokens $OutputTokens
        Save-AISession $latest -LockHeld -RevisionAlreadyValidated
        $script:CurrentSession = $latest
    }
}

function Add-AISessionTurn([string]$Role, [string]$Content, [string]$Kind = 'message', [hashtable]$Metadata = @{},
    [long]$InputTokens = 0, [long]$OutputTokens = 0) {
    if (-not $script:CurrentSession) { return }
    $safeContent = Protect-AIText $Content 65536
    $turn = [ordered]@{
        id = [guid]::NewGuid().ToString('N')
        role = $Role
        kind = $Kind
        content = $safeContent
        createdUtc = [DateTime]::UtcNow.ToString('O')
        metadata = $Metadata
    }
    $sessionId = [string]$script:CurrentSession.id
    $path = Get-AISessionPath $sessionId
    Invoke-AIWithFileLock $path {
        $latest = Import-AISession $sessionId
        if (-not $latest) { throw "会话不存在或无法读取：$sessionId" }
        if ($latest.turns.Count -ge 2000) { throw '会话已达到 2000 个 Turn 上限，请新建会话后继续。' }
        $latest.turns = @($latest.turns) + @($turn)
        Add-AISessionUsageValues $latest $InputTokens $OutputTokens
        Save-AISession $latest -LockHeld -RevisionAlreadyValidated
        $script:CurrentSession = $latest
        $turn
    }
}

function New-PSAISession {
    [CmdletBinding()] param([string]$Title = '新会话', [switch]$NoSelect)
    $session = New-AISessionObject $Title
    Save-AISession $session
    if (-not $NoSelect -or -not $script:CurrentSession) {
        Invoke-AIConfigMutation { $script:Config.activeSession = [string]$session.id }
        $script:CurrentSession = $session
    }
    [pscustomobject]$session
}

function Get-PSAISession {
    [CmdletBinding()] param([string]$Id)
    $sessions = if ($Id) { @((Import-AISession $Id)) } else {
        @(Get-ChildItem -LiteralPath $script:SessionDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue |
            ForEach-Object { Import-AISession $_.BaseName })
    }
    $sessions | Where-Object { $_ } | Sort-Object updatedUtc -Descending | ForEach-Object {
        [pscustomobject]@{
            Id = $_.id; Title = $_.title; CreatedUtc = [datetime]$_.createdUtc; UpdatedUtc = [datetime]$_.updatedUtc
            TurnCount = @($_.turns).Count; Active = ([string]$_.id -eq [string]$script:Config.activeSession)
            InputTokens = [long]$_.inputTokens; OutputTokens = [long]$_.outputTokens
        }
    }
}

function Select-PSAISession {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Id)
    $session = Import-AISession $Id
    if (-not $session) { throw "会话不存在：$Id" }
    Invoke-AIConfigMutation { $script:Config.activeSession = $Id }
    $script:CurrentSession = $session
    Get-PSAISession -Id $Id
}

function Clear-PSAISession {
    [CmdletBinding(SupportsShouldProcess)] param([string]$Id = $script:Config.activeSession)
    if (-not $Id) { return }
    $session = Import-AISession $Id
    if (-not $session) { throw "会话不存在：$Id" }
    if (-not $PSCmdlet.ShouldProcess($Id, '清空 AI 会话上下文')) { return }
    $path = Get-AISessionPath $Id
    Invoke-AIWithFileLock $path {
        $latest = Import-AISession $Id
        if (-not $latest) { throw "会话不存在或无法读取：$Id" }
        $latest.summary = ''
        $latest.turns = @()
        $latest.inputTokens = 0L
        $latest.outputTokens = 0L
        [void]$latest.Remove('compactedTurnCount')
        Save-AISession $latest -LockHeld
        if ($Id -eq $script:Config.activeSession) { $script:CurrentSession = $latest }
    }
}

function ConvertFrom-AISecureString([Security.SecureString]$Value) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Get-AISecretTarget([string]$Name) { "PSAITerminal/Model/$Name" }

function Save-AISecret([string]$Name, [string]$Secret, [switch]$SessionOnly) {
    if ($SessionOnly) {
        $script:SessionSecrets[$Name] = $Secret
        return
    }
    [PSAITerminal.PlatformCredentialStore]::Set((Get-AISecretTarget $Name), $Secret)
    [void]$script:SessionSecrets.Remove($Name)
    $script:LastSecretStoreError = $null
}

function Get-AISecret([string]$Name) {
    if ($script:SessionSecrets.ContainsKey($Name)) { return [string]$script:SessionSecrets[$Name] }
    try {
        $value = [PSAITerminal.PlatformCredentialStore]::Get((Get-AISecretTarget $Name))
        $script:LastSecretStoreError = $null
        $value
    } catch {
        $script:LastSecretStoreError = $_.Exception.Message
        $null
    }
}

function Remove-AISecret([string]$Name) {
    [void]$script:SessionSecrets.Remove($Name)
    [PSAITerminal.PlatformCredentialStore]::Remove((Get-AISecretTarget $Name))
}

function Protect-AIText([AllowNull()][string]$Text, [int]$MaximumCharacters = 65536) {
    $secrets = @($script:Config.models.Keys | ForEach-Object { Get-AISecret ([string]$_) } | Where-Object { $_ })
    [PSAITerminal.AITerminalSecurity]::ProtectText($Text, [string[]]$secrets, $MaximumCharacters)
}

function Get-AICommandRisk([string]$Command) {
    $risk = [PSAITerminal.AITerminalSecurity]::ClassifyRisk('powershell', $Command)
    if ($risk -eq [PSAITerminal.AITerminalRisk]::High) { return $risk }

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { return [PSAITerminal.AITerminalRisk]::High }

    foreach ($commandAst in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $commandAst.GetCommandName()
        if (-not $name) { return [PSAITerminal.AITerminalRisk]::High }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $resolved = $false
        for ($depth = 0; $depth -lt 8 -and $seen.Add($name); $depth++) {
            $commandInfo = Get-Command -Name ([WildcardPattern]::Escape($name)) -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $commandInfo) { return [PSAITerminal.AITerminalRisk]::High }
            if ($commandInfo.CommandType -eq [Management.Automation.CommandTypes]::Alias) {
                $resolvedName = if ($commandInfo.ResolvedCommand) {
                    [string]$commandInfo.ResolvedCommand.Name
                } else {
                    [string]$commandInfo.Definition
                }
                if (-not $resolvedName) { return [PSAITerminal.AITerminalRisk]::High }
                $resolvedRisk = [PSAITerminal.AITerminalSecurity]::ClassifyRisk('powershell', "$resolvedName __PSAI_ARGUMENT__")
                if ([int]$resolvedRisk -gt [int]$risk) { $risk = $resolvedRisk }
                if ($risk -eq [PSAITerminal.AITerminalRisk]::High) { return $risk }
                $name = $resolvedName
                continue
            }
            $resolvedRisk = [PSAITerminal.AITerminalSecurity]::ClassifyRisk('powershell', "$($commandInfo.Name) __PSAI_ARGUMENT__")
            if ([int]$resolvedRisk -gt [int]$risk) { $risk = $resolvedRisk }
            if ($risk -eq [PSAITerminal.AITerminalRisk]::High) { return $risk }
            if ($commandInfo.CommandType -ne [Management.Automation.CommandTypes]::Cmdlet) {
                return [PSAITerminal.AITerminalRisk]::High
            }
            $resolved = $true
            break
        }
        if (-not $resolved) { return [PSAITerminal.AITerminalRisk]::High }
    }
    $risk
}

function Get-AIApprovalDigest([string]$RunId, [string]$StepId, [string]$Command) {
    $payload = "$($RunId.Length):$RunId$($StepId.Length):$StepId$($Command.Length):$Command"
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $hash = $hasher.ComputeHash($bytes) } finally { $hasher.Dispose() }
    ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-AIDefaultEndpoint([string]$Protocol) {
    switch ($Protocol) {
        'Anthropic' { 'https://api.anthropic.com' }
        'GeminiNative' { 'https://generativelanguage.googleapis.com' }
        'Ollama' { 'http://127.0.0.1:11434' }
        default { 'https://api.openai.com' }
    }
}

function Get-AIActiveModel {
    $name = [string]$script:Config.activeModel
    if (-not $name -or -not (Test-AIMapContains $script:Config.models $name)) {
        throw '尚未配置活动模型。请输入 ai，选择“模型配置”后新增模型。'
    }
    $script:Config.models[$name]
}

function Assert-AIActiveModelReady {
    $model = Get-AIActiveModel
    if ($model.protocol -ne 'Ollama' -and -not (Get-AISecret ([string]$model.name))) {
        if ($script:LastSecretStoreError) { throw "系统密钥库无法读取：$script:LastSecretStoreError" }
        throw "模型 '$($model.name)' 缺少 API Key。请输入 ai，打开【模型配置】，选择该模型后编辑配置并更新 API Key。"
    }
    $model
}

function New-PSAIModel {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Anthropic','OpenAIChat','OpenAIResponses','GeminiNative','Ollama')][string]$Protocol,
        [Parameter(Mandatory)][uri]$Endpoint,
        [Parameter(Mandatory)][string]$ModelId,
        [Security.SecureString]$ApiKey,
        [ValidateRange(1024,2097152)][int]$ContextWindow = 32768,
        [hashtable]$Parameters = @{},
        [hashtable]$Capabilities = @{streaming=$true;toolCalling=$true;usage=$false},
        [switch]$SessionOnly,
        [switch]$SetActive
    )
    Assert-AIModelName $Name
    Assert-AIModelId $ModelId
    if (Test-AIMapContains $script:Config.models $Name) { throw "模型配置已存在：$Name" }
    if ($Protocol -eq 'Ollama' -and $ApiKey) { throw 'Ollama 默认不发送 API Key，请移除 -ApiKey。' }
    if ($Protocol -ne 'Ollama' -and -not $ApiKey) { throw "$Protocol 必须提供 API Key。" }
    Assert-AIModelParameters $Parameters
    $normalizedEndpoint = ConvertTo-AIEndpoint $Protocol $Endpoint
    $previous = Copy-AIConfig
    $oldSecret = Get-AISecret $Name
    $oldSecretWasSessionOnly = $script:SessionSecrets.ContainsKey($Name)
    $secretWritten = $false
    try {
        $model = [ordered]@{
            name = $Name
            protocol = $Protocol
            endpoint = $normalizedEndpoint
            modelId = $ModelId.Trim()
            credentialTarget = if ($Protocol -eq 'Ollama') { $null } else { Get-AISecretTarget $Name }
            contextWindow = $ContextWindow
            capabilities = ConvertTo-AICapabilities $Capabilities
            parameters = $Parameters
        }
        $script:Config.models[$Name] = $model
        if ($SetActive -or -not $script:Config.activeModel) { $script:Config.activeModel = $Name }
        if ($ApiKey) {
            $plain = ConvertFrom-AISecureString $ApiKey
            try { Save-AISecret $Name $plain -SessionOnly:$SessionOnly; $secretWritten = $true }
            finally { $plain = $null }
        }
        Save-AIConfig
    } catch {
        $failure = $_
        $script:Config = $previous
        if ($secretWritten) {
            try {
                if ($oldSecret) { Save-AISecret $Name $oldSecret -SessionOnly:$oldSecretWasSessionOnly }
                else { Remove-AISecret $Name }
            } catch { Write-Warning "恢复模型密钥失败：$Name" }
        }
        throw $failure
    }
    Get-PSAIModel -Name $Name
}

function Get-PSAIModel {
    [CmdletBinding()] param([string]$Name)
    if ($Name -and -not (Test-AIMapContains $script:Config.models $Name)) { throw "模型不存在：$Name" }
    $models = if ($Name) { @($script:Config.models[$Name]) } else { @($script:Config.models.Values) }
    $models | Where-Object { $null -ne $_ } | ForEach-Object {
        [pscustomobject]@{
            Name = $_.name
            Protocol = $_.protocol
            Endpoint = $_.endpoint
            ModelId = $_.modelId
            ContextWindow = [int]$_.contextWindow
            Capabilities = [pscustomobject]$_.capabilities
            Active = ([string]$_.name -eq [string]$script:Config.activeModel)
            HasSecret = if ($_.protocol -eq 'Ollama') { $false } else { [bool](Get-AISecret ([string]$_.name)) }
        }
    }
}

function Set-PSAIModel {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Anthropic','OpenAIChat','OpenAIResponses','GeminiNative','Ollama')][string]$Protocol,
        [uri]$Endpoint,
        [string]$ModelId,
        [Security.SecureString]$ApiKey,
        [ValidateRange(1024,2097152)][int]$ContextWindow,
        [hashtable]$Parameters,
        [hashtable]$Capabilities,
        [switch]$SessionOnly
    )
    if (-not (Test-AIMapContains $script:Config.models $Name)) { throw "模型不存在：$Name" }
    $previous = Copy-AIConfig
    $oldSecret = Get-AISecret $Name
    $oldSecretWasSessionOnly = $script:SessionSecrets.ContainsKey($Name)
    $model = $script:Config.models[$Name]
    $protocolChanged = $PSBoundParameters.ContainsKey('Protocol') -and $Protocol -ne [string]$model.protocol
    try {
        if ($protocolChanged -and -not $PSBoundParameters.ContainsKey('Endpoint')) {
            throw '更改协议时必须同时提供新的接口地址。'
        }
        if ($protocolChanged -and $Protocol -ne 'Ollama' -and -not $ApiKey) {
            throw '更改到需要鉴权的协议时必须同时提供新的 API Key，旧协议密钥不会复用。'
        }
        if ($PSBoundParameters.ContainsKey('Protocol')) { $model.protocol = $Protocol }
        if ($PSBoundParameters.ContainsKey('Endpoint')) { $model.endpoint = ConvertTo-AIEndpoint ([string]$model.protocol) $Endpoint }
        else { $model.endpoint = ConvertTo-AIEndpoint ([string]$model.protocol) ([uri][string]$model.endpoint) }
        if ($PSBoundParameters.ContainsKey('ModelId')) {
            Assert-AIModelId $ModelId
            $model.modelId = $ModelId.Trim()
        }
        if ($PSBoundParameters.ContainsKey('ContextWindow')) { $model.contextWindow = $ContextWindow }
        if ($PSBoundParameters.ContainsKey('Parameters')) { Assert-AIModelParameters $Parameters; $model.parameters = $Parameters }
        if ($PSBoundParameters.ContainsKey('Capabilities')) { $model.capabilities = ConvertTo-AICapabilities $Capabilities }

        if ($model.protocol -eq 'Ollama') {
            $model.credentialTarget = $null
            Remove-AISecret $Name
        } else {
            $model.credentialTarget = Get-AISecretTarget $Name
            if ($ApiKey) {
                $plain = ConvertFrom-AISecureString $ApiKey
                try { Save-AISecret $Name $plain -SessionOnly:$SessionOnly }
                finally { $plain = $null }
            } elseif (-not (Get-AISecret $Name)) {
                throw "$($model.protocol) 必须配置 API Key。"
            }
        }
        Save-AIConfig
    } catch {
        $failure = $_
        $script:Config = $previous
        try {
            if ($oldSecret) { Save-AISecret $Name $oldSecret -SessionOnly:$oldSecretWasSessionOnly }
            else { Remove-AISecret $Name }
        } catch { Write-Warning "恢复模型密钥失败：$Name" }
        throw $failure
    }
    Get-PSAIModel -Name $Name
}

function Select-PSAIModel {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-AIMapContains $script:Config.models $Name)) { throw "模型不存在：$Name" }
    Invoke-AIConfigMutation { $script:Config.activeModel = $Name }
    Get-PSAIModel -Name $Name
}

function Remove-PSAIModel {
    [CmdletBinding(SupportsShouldProcess)] param(
        [Parameter(Mandatory)][string]$Name,
        [string]$ReplacementModel,
        [switch]$KeepCredential
    )
    if (-not (Test-AIMapContains $script:Config.models $Name)) { throw "模型不存在：$Name" }
    $remaining = @($script:Config.models.Keys | Where-Object { [string]$_ -ne $Name })
    if ($ReplacementModel -and $ReplacementModel -notin $remaining) { throw '替换模型不存在或正是要删除的模型。' }
    if ($script:Config.activeModel -eq $Name -and $remaining.Count -gt 0 -and -not $ReplacementModel) {
        throw '删除当前模型前必须通过 -ReplacementModel 选择新的当前模型。'
    }
    if (-not $PSCmdlet.ShouldProcess($Name, '删除 AI 模型配置')) { return }

    $previous = Copy-AIConfig
    $oldSecret = Get-AISecret $Name
    $oldSecretWasSessionOnly = $script:SessionSecrets.ContainsKey($Name)
    try {
        [void]$script:Config.models.Remove($Name)
        if ($script:Config.activeModel -eq $Name) {
            $script:Config.activeModel = if ($ReplacementModel) { $ReplacementModel } else { $null }
            if (-not $script:Config.activeModel) { $script:Config.mode = 'Off' }
        }
        if (-not $KeepCredential) { Remove-AISecret $Name }
        Save-AIConfig
    } catch {
        $failure = $_
        $script:Config = $previous
        if ($oldSecret) {
            try { Save-AISecret $Name $oldSecret -SessionOnly:$oldSecretWasSessionOnly }
            catch { Write-Warning "恢复模型密钥失败：$Name。$($_.Exception.Message)" }
        }
        throw $failure
    }
}

function Resolve-AIModelListEndpoint([string]$Protocol, [uri]$Endpoint) {
    [PSAITerminal.AITerminalEndpointResolver]::ResolveModelListEndpoint($Protocol, $Endpoint).AbsoluteUri
}

function Resolve-AIRequestEndpoint([Collections.IDictionary]$Model) {
    [PSAITerminal.AITerminalEndpointResolver]::ResolveRequestEndpoint(
        [string]$Model.protocol,
        [uri][string]$Model.endpoint,
        [string]$Model.modelId).AbsoluteUri
}

function Get-AIProperty($Value, [string]$Name) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        if (Test-AIMapContains $Value $Name) { return $Value[$Name] }
        return $null
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    $null
}

function Add-AIAuthenticationHeaders([Net.Http.HttpRequestMessage]$Request, [string]$Protocol, [AllowNull()][string]$Secret) {
    switch ($Protocol) {
        'Anthropic' {
            if (-not $Secret) { throw 'Anthropic 模型缺少 API Key。' }
            $Request.Headers.Add('x-api-key', $Secret)
            $Request.Headers.Add('anthropic-version', '2023-06-01')
        }
        'GeminiNative' {
            if (-not $Secret) { throw 'Gemini 模型缺少 API Key。' }
            $Request.Headers.Add('x-goog-api-key', $Secret)
        }
        { $_ -in @('OpenAIChat', 'OpenAIResponses') } {
            if (-not $Secret) { throw 'OpenAI 模型缺少 API Key。' }
            $Request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Secret)
        }
        'Ollama' {
            # Ollama 默认不发送任何旧协议凭据。
        }
    }
}

function New-AIHttpClient([uri]$Endpoint) {
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    if ($Endpoint.IsLoopback) { $handler.UseProxy = $false }
    $client = [Net.Http.HttpClient]::new($handler, $true)
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $client
}

function Get-AIRemoteModels {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][ValidateSet('Anthropic','OpenAIChat','OpenAIResponses','GeminiNative','Ollama')][string]$Protocol,
        [Parameter(Mandatory)][uri]$Endpoint,
        [AllowNull()][string]$Secret,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None
    )
    $normalized = [uri](ConvertTo-AIEndpoint $Protocol $Endpoint)
    $listEndpoint = Resolve-AIModelListEndpoint $Protocol $normalized
    if ($Protocol -ne 'Ollama' -and -not $Secret) { throw '获取模型列表需要 API Key。' }

    $client = New-AIHttpClient ([uri]$listEndpoint)
    $timeoutSource = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds([int]$script:Config.execution.requestTimeoutSeconds))
    $linkedSource = [Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken, $timeoutSource.Token)
    $requestToken = $linkedSource.Token
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $listEndpoint)
    $response = $null
    try {
        Add-AIAuthenticationHeaders $request $Protocol $Secret
        $response = [PSAITerminal.AITerminalHttpTransport]::Send(
            $client, $request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $requestToken)
        $body = [PSAITerminal.AITerminalHttpContent]::ReadString($response.Content, 8MB, $requestToken)
        $safeBody = [PSAITerminal.AITerminalSecurity]::ProtectText($body, [string[]]@($Secret), 2048)
        if (-not $response.IsSuccessStatusCode) {
            throw "无法获取模型列表（HTTP $([int]$response.StatusCode)）：$safeBody"
        }
        try { $payload = $body | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "模型列表响应不是有效 JSON：$safeBody" }

        $entries = if ($Protocol -in @('Anthropic','OpenAIChat','OpenAIResponses')) {
            @(Get-AIProperty $payload 'data')
        } else { @(Get-AIProperty $payload 'models') }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $result = [Collections.Generic.List[object]]::new()
        foreach ($entry in $entries) {
            if ($null -eq $entry) { continue }
            if ($Protocol -eq 'GeminiNative') {
                $methods = @(Get-AIProperty $entry 'supportedGenerationMethods')
                if ($methods.Count -eq 0) { $methods = @(Get-AIProperty $entry 'supportedActions') }
                if ($methods -notcontains 'generateContent') { continue }
                $id = ([string](Get-AIProperty $entry 'name')) -replace '^models/', ''
            } elseif ($Protocol -eq 'Ollama') {
                $id = [string](Get-AIProperty $entry 'name')
                if (-not $id) { $id = [string](Get-AIProperty $entry 'model') }
            } else { $id = [string](Get-AIProperty $entry 'id') }
            if ([string]::IsNullOrWhiteSpace($id) -or $id.Length -gt 512 -or
                $id -match '[\x00-\x1F\x7F-\x9F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]' -or
                -not $seen.Add($id)) { continue }

            $displayName = [string](Get-AIProperty $entry 'display_name')
            if (-not $displayName) { $displayName = [string](Get-AIProperty $entry 'displayName') }
            if (-not $displayName) { $displayName = $id }
            $displayName = [PSAITerminal.AITerminalSecurity]::ProtectText($displayName, [string[]]@($Secret), 512)
            $contextWindow = 0
            $contextText = [string](Get-AIProperty $entry 'inputTokenLimit')
            $parsedWindow = 0
            if ($contextText -and [int]::TryParse($contextText, [ref]$parsedWindow) -and
                $parsedWindow -ge 1024 -and $parsedWindow -le 2097152) {
                $contextWindow = $parsedWindow
            }
            $result.Add([pscustomobject]@{Id=$id;DisplayName=$displayName;ContextWindow=$contextWindow})
            if ($result.Count -ge 500) { break }
        }
        $result.ToArray()
    } finally {
        if ($response) { $response.Dispose() }
        $request.Dispose()
        $client.Dispose(); $linkedSource.Dispose(); $timeoutSource.Dispose()
        $Secret = $null
    }
}

function Test-PSAIModel {
    [CmdletBinding()] param(
        [string]$Name = $script:Config.activeModel,
        [switch]$ProbeCapabilities,
        [Security.SecureString]$SecretOverride,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None
    )
    if (-not $Name -or -not (Test-AIMapContains $script:Config.models $Name)) { throw "模型不存在：$Name" }
    $model = $script:Config.models[$Name]
    $plain = if ($SecretOverride) { ConvertFrom-AISecureString $SecretOverride } else { Get-AISecret $Name }
    try {
        $remote = @()
        $modelListAvailable = $false
        $modelListed = $null
        $listWarning = $null
        try {
            $remote = @(Get-AIRemoteModels -Protocol $model.protocol -Endpoint ([uri]$model.endpoint) -Secret $plain -CancellationToken $CancellationToken)
            $modelListAvailable = $true
            $modelListed = @($remote | Where-Object Id -eq $model.modelId).Count -gt 0
        } catch {
            $listWarning = Protect-AIText $_.Exception.Message 2048
        }

        try {
            $probePrompt = if ($ProbeCapabilities) {
                '不要执行任何操作。请调用 powershell 工具提出 Get-Date 命令，用于验证结构化工具能力。'
            } else { '只回复 OK，不要调用工具。' }
            $probe = Invoke-AIModelText -Model $model -Prompt $probePrompt -NoRender `
                -EnableTools:$ProbeCapabilities -SecretOverride $plain -CancellationToken $CancellationToken
        } catch {
            return [pscustomobject]@{
                Name = $Name; Success = $false; Endpoint = [string]$model.endpoint; ModelId = [string]$model.modelId
                ModelListAvailable = $modelListAvailable; ModelListed = $modelListed; AvailableModelCount = $remote.Count
                GenerationProbed = $true; ToolCallingProbed = [bool]$ProbeCapabilities; ToolCallingSupported = $null
                UsageReported = $null; Response = $null; Warning = $listWarning
                Error = Protect-AIText $_.Exception.Message 4096
            }
        }

        $toolCallingSupported = if ($ProbeCapabilities) { @($probe.ToolCalls).Count -gt 0 } else { $null }
        $usageReported = ([long]$probe.InputTokens -gt 0 -or [long]$probe.OutputTokens -gt 0)
        if ($ProbeCapabilities) {
            Invoke-AIConfigMutation {
                $storedModel = $script:Config.models[$Name]
                $storedModel.capabilities.streaming = $true
                $storedModel.capabilities.toolCalling = [bool]$toolCallingSupported
                $storedModel.capabilities.usage = $usageReported
                $storedModel.lastTestUtc = [DateTime]::UtcNow.ToString('O')
            }
        }

        [pscustomobject]@{
            Name = $Name; Success = $true; Endpoint = [string]$model.endpoint; ModelId = [string]$model.modelId
            ModelListAvailable = $modelListAvailable; ModelListed = $modelListed; AvailableModelCount = $remote.Count
            GenerationProbed = $true; ToolCallingProbed = [bool]$ProbeCapabilities
            ToolCallingSupported = $toolCallingSupported; UsageReported = $usageReported
            Response = Protect-AIText $probe.Text 2048; Warning = $listWarning; Error = $null
        }
    } finally { $plain = $null }
}

function New-AIPowerShellToolSchema {
    [ordered]@{
        type = 'object'
        properties = [ordered]@{
            purpose = @{type='string';description='执行这条命令的目的'}
            command = @{type='string';description='完整的 PowerShell 命令'}
            expectedOutcome = @{type='string';description='预期结果'}
            sideEffects = @{type='string';description='可能副作用，没有则写“无”'}
            rollbackHint = @{type='string';description='回滚方法；不可回滚时明确说明'}
        }
        required = @('purpose','command','expectedOutcome','sideEffects','rollbackHint')
        additionalProperties = $false
    }
}

function Add-AIToolsToRequestBody([Collections.IDictionary]$Body, [string]$Protocol) {
    $schema = New-AIPowerShellToolSchema
    $description = '在用户本地当前 PowerShell 会话中执行一条命令。仅在确实需要操作本机时调用。'
    switch ($Protocol) {
        'OpenAIChat' {
            $Body.tools = @(@{type='function';function=@{name='powershell';description=$description;parameters=$schema;strict=$true}})
            $Body.tool_choice = 'auto'
        }
        'OpenAIResponses' {
            $Body.tools = @(@{type='function';name='powershell';description=$description;parameters=$schema;strict=$true})
            $Body.tool_choice = 'auto'
        }
        'Anthropic' { $Body.tools = @(@{name='powershell';description=$description;input_schema=$schema}) }
        'GeminiNative' {
            $Body.tools = @(@{functionDeclarations=@(@{name='powershell';description=$description;parameters=$schema})})
        }
        'Ollama' {
            $Body.tools = @(@{type='function';function=@{name='powershell';description=$description;parameters=$schema}})
        }
    }
}

function New-AIRequestBody([Collections.IDictionary]$Model, [string]$Prompt, [switch]$EnableTools) {
    $system = if ((Get-AILanguage) -eq 'en-US') {
        'You are an assistant running in the user''s local PowerShell session. Reply in English. Do not assume a cloud server exists. Never request or reveal API keys.'
    } else {
        '你是运行在用户本地 PowerShell 中的助手。用简体中文回答；不要假设存在云服务器；不要请求或输出 API Key。'
    }
    $body = switch ([string]$Model.protocol) {
        'Anthropic' { [ordered]@{model=$Model.modelId;max_tokens=4096;system=$system;messages=@(@{role='user';content=$Prompt});stream=$true} }
        'OpenAIChat' { [ordered]@{model=$Model.modelId;messages=@(@{role='system';content=$system},@{role='user';content=$Prompt});stream=$true} }
        'OpenAIResponses' { [ordered]@{model=$Model.modelId;instructions=$system;input=$Prompt;stream=$true} }
        'GeminiNative' { [ordered]@{systemInstruction=@{parts=@(@{text=$system})};contents=@(@{role='user';parts=@(@{text=$Prompt})})} }
        'Ollama' { [ordered]@{model=$Model.modelId;messages=@(@{role='system';content=$system},@{role='user';content=$Prompt});stream=$true} }
    }
    if ($Model.parameters -is [Collections.IDictionary]) {
        if ($Model.protocol -eq 'GeminiNative') { $body.generationConfig = $Model.parameters }
        elseif ($Model.protocol -eq 'Ollama') { $body.options = $Model.parameters }
        else {
            foreach ($entry in $Model.parameters.GetEnumerator()) {
                if ([string]$entry.Key -notin @('model','messages','input','instructions','system','tools','stream')) {
                    $body[[string]$entry.Key] = $entry.Value
                }
            }
        }
    }
    if ($EnableTools) { Add-AIToolsToRequestBody $body ([string]$Model.protocol) }
    $body
}

function Test-AIColorEnabled {
    [bool]$script:Config.appearance.colorEnabled -and
        $null -eq [Environment]::GetEnvironmentVariable('NO_COLOR')
}

function Write-AIColoredHost([AllowNull()]$Text, [ConsoleColor]$Color, [switch]$NoNewline) {
    if (Test-AIColorEnabled) { Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline }
    else { Write-Host $Text -NoNewline:$NoNewline }
}

function Write-AIStreamText([string]$Text, [switch]$First) {
    if ($First) {
        Write-AIColoredHost 'AI  ' DarkCyan -NoNewline
    }
    Write-AIColoredHost $Text DarkCyan -NoNewline
}

function Read-AIStreamPayloads([IO.StreamReader]$Reader, [string]$Protocol, [Threading.CancellationToken]$CancellationToken) {
    $data = [Collections.Generic.List[string]]::new()
    $dataCharacters = 0
    while ($null -ne ($line = [PSAITerminal.AITerminalHttpContent]::ReadLine($Reader, $CancellationToken))) {
        if ($line.Length -gt 1MB) { throw '模型流式响应的单行数据超过 1 MiB 上限。' }
        if ($Protocol -eq 'Ollama' -and $line -and -not $line.StartsWith('data:') -and
            -not $line.StartsWith('event:') -and -not $line.StartsWith('id:') -and -not $line.StartsWith('retry:')) {
            $line.Trim()
            continue
        }
        if (-not $line) {
            if ($data.Count) { $data -join "`n"; $data.Clear(); $dataCharacters = 0 }
            continue
        }
        if ($line.StartsWith('id:') -and $data.Count) { $data -join "`n"; $data.Clear(); $dataCharacters = 0 }
        if ($line.StartsWith(':') -or $line.StartsWith('event:') -or $line.StartsWith('id:') -or $line.StartsWith('retry:')) {
            continue
        }
        if ($line.StartsWith('data:')) {
            $part = $line.Substring(5).TrimStart()
            if ($data.Count -and $part.StartsWith('{') -and $data[0].StartsWith('{')) { $data -join "`n"; $data.Clear(); $dataCharacters = 0 }
            $dataCharacters += $part.Length
            if ($dataCharacters -gt 1MB) { throw '模型流式响应的单个事件超过 1 MiB 上限。' }
            $data.Add($part)
        }
        elseif ($line.TrimStart().StartsWith('{') -or $line.Trim() -eq '[DONE]') {
            if ($data.Count) { $data -join "`n"; $data.Clear(); $dataCharacters = 0 }
            $line.Trim()
        }
    }
    if ($data.Count) { $data -join "`n" }
}

function Invoke-AIModelText {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][Collections.IDictionary]$Model,
        [Parameter(Mandatory)][string]$Prompt,
        [switch]$NoRender,
        [switch]$EnableTools,
        [AllowNull()][string]$SecretOverride,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None
    )
    $endpoint = Resolve-AIRequestEndpoint $Model
    $secret = if ($Model.protocol -eq 'Ollama') { $null } elseif ($PSBoundParameters.ContainsKey('SecretOverride')) { $SecretOverride } else { Get-AISecret ([string]$Model.name) }
    if ($Model.protocol -ne 'Ollama' -and -not $secret) { throw "模型 '$($Model.name)' 没有可用 API Key。" }
    $json = New-AIRequestBody $Model $Prompt -EnableTools:$EnableTools | ConvertTo-Json -Depth 50 -Compress
    $client = New-AIHttpClient ([uri]$endpoint)
    $timeoutSource = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds([int]$script:Config.execution.requestTimeoutSeconds))
    $linkedSource = [Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken, $timeoutSource.Token)
    $requestToken = $linkedSource.Token
    $attempt = 0
    $response = $null
    $request = $null
    while ($true) {
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $endpoint)
        $request.Content = [Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
        Add-AIAuthenticationHeaders $request ([string]$Model.protocol) $secret
        try {
            $response = [PSAITerminal.AITerminalHttpTransport]::Send(
                $client, $request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $requestToken)
            $status = [int]$response.StatusCode
            if (($status -in @(408,429) -or $status -in 500..599) -and $attempt -lt 2) {
                [void][PSAITerminal.AITerminalHttpContent]::ReadString($response.Content, 1MB, $requestToken)
                $response.Dispose(); $request.Dispose(); $response=$null; $request=$null
                $attempt++
                [void]([Threading.Tasks.Task]::Delay(
                    [Math]::Min(2000, 250 * [Math]::Pow(2, $attempt)), $requestToken).GetAwaiter().GetResult())
                continue
            }
            if (-not $response.IsSuccessStatusCode) {
                $errorBody = [PSAITerminal.AITerminalHttpContent]::ReadString($response.Content, 65536, $requestToken)
                throw "模型接口返回 HTTP $status：$([PSAITerminal.AITerminalSecurity]::ProtectText($errorBody,[string[]]@($secret),2048))"
            }
            break
        } catch {
            if ($request) { $request.Dispose() }
            if ($response) { $response.Dispose() }
            $client.Dispose(); $linkedSource.Dispose(); $timeoutSource.Dispose()
            throw
        }
    }

    $text = [Text.StringBuilder]::new()
    $parsed = 0
    $responseState = [ordered]@{Terminal=$false;InputTokens=0L;OutputTokens=0L}
    $first = $true
    $toolCalls = [ordered]@{}
    $toolItemMap = @{}
    $sanitizer = [PSAITerminal.AITerminalStreamingTextSanitizer]::new()
    $reader = [IO.StreamReader]::new(
        [PSAITerminal.AITerminalHttpContent]::ReadStream($response.Content, $requestToken))
    try {
        Read-AIStreamPayloads $reader ([string]$Model.protocol) $requestToken | ForEach-Object {
            $payload = [string]$_
            if (-not $payload) { return }
            if ($payload -eq '[DONE]') { $responseState.Terminal = $true; return }
            try { $chunk = $payload | ConvertFrom-Json -ErrorAction Stop }
            catch { throw "模型接口返回了无法解析的流数据：$(Protect-AIText $payload 1024)" }
            $parsed++
            $delta = $null
            switch ([string]$Model.protocol) {
                'OpenAIChat' {
                    $usage = Get-AIProperty $chunk 'usage'
                    if ($usage) { $responseState.InputTokens=[long](Get-AIProperty $usage 'prompt_tokens');$responseState.OutputTokens=[long](Get-AIProperty $usage 'completion_tokens') }
                    $choices = @(Get-AIProperty $chunk 'choices')
                    if ($choices.Count) {
                        $choice = $choices[0]
                        $choiceDelta = Get-AIProperty $choice 'delta'
                        $delta = Get-AIProperty $choiceDelta 'content'
                        foreach ($call in @(Get-AIProperty $choiceDelta 'tool_calls')) {
                            if (-not $call) { continue }
                            $index = [string](Get-AIProperty $call 'index')
                            $id = [string](Get-AIProperty $call 'id')
                            $function = Get-AIProperty $call 'function'
                            if (-not (Test-AIMapContains $toolCalls $index)) {
                                $toolCalls[$index] = [ordered]@{id=$id;name='';arguments=''}
                            }
                            if ($id) { $toolCalls[$index].id = $id }
                            $name = [string](Get-AIProperty $function 'name')
                            if ($name) { $toolCalls[$index].name += $name }
                            $arguments = [string](Get-AIProperty $function 'arguments')
                            if ($arguments) { $toolCalls[$index].arguments += $arguments }
                        }
                        if ($null -ne (Get-AIProperty $choice 'finish_reason')) { $responseState.Terminal = $true }
                    }
                }
                'OpenAIResponses' {
                    $type = [string](Get-AIProperty $chunk 'type')
                    if ($type -eq 'response.output_text.delta') { $delta = Get-AIProperty $chunk 'delta' }
                    elseif ($type -eq 'response.output_item.added') {
                        $item = Get-AIProperty $chunk 'item'
                        if ([string](Get-AIProperty $item 'type') -eq 'function_call') {
                            $itemId = [string](Get-AIProperty $item 'id')
                            $callId = [string](Get-AIProperty $item 'call_id')
                            if (-not $callId) { $callId = $itemId }
                            $toolCalls[$callId] = [ordered]@{id=$callId;name=[string](Get-AIProperty $item 'name');arguments=[string](Get-AIProperty $item 'arguments')}
                            if ($itemId) { $toolItemMap[$itemId] = $callId }
                        }
                    }
                    elseif ($type -eq 'response.function_call_arguments.delta') {
                        $key = [string](Get-AIProperty $chunk 'item_id')
                        if (Test-AIMapContains $toolItemMap $key) { $key = [string]$toolItemMap[$key] }
                        if (Test-AIMapContains $toolCalls $key) { $toolCalls[$key].arguments += [string](Get-AIProperty $chunk 'delta') }
                    }
                    elseif ($type -eq 'response.function_call_arguments.done') {
                        $key = [string](Get-AIProperty $chunk 'item_id')
                        if (Test-AIMapContains $toolItemMap $key) { $key = [string]$toolItemMap[$key] }
                        if (Test-AIMapContains $toolCalls $key) { $toolCalls[$key].arguments = [string](Get-AIProperty $chunk 'arguments') }
                    }
                    elseif ($type -eq 'response.completed') {
                        $responseState.Terminal = $true
                        $usage = Get-AIProperty (Get-AIProperty $chunk 'response') 'usage'
                        if ($usage) { $responseState.InputTokens=[long](Get-AIProperty $usage 'input_tokens');$responseState.OutputTokens=[long](Get-AIProperty $usage 'output_tokens') }
                    }
                }
                'Anthropic' {
                    $type = [string](Get-AIProperty $chunk 'type')
                    if ($type -eq 'content_block_start') {
                        $block = Get-AIProperty $chunk 'content_block'
                        if ([string](Get-AIProperty $block 'type') -eq 'tool_use') {
                            $key = [string](Get-AIProperty $chunk 'index')
                            $initialInput = Get-AIProperty $block 'input'
                            $hasInitialInput = $initialInput -and (
                                ($initialInput -is [Collections.IDictionary] -and $initialInput.Count -gt 0) -or
                                ($initialInput -isnot [Collections.IDictionary] -and @($initialInput.PSObject.Properties).Count -gt 0))
                            $initialArguments = if ($hasInitialInput) {
                                $initialInput | ConvertTo-Json -Depth 30 -Compress
                            } else { '' }
                            $toolCalls[$key] = [ordered]@{id=[string](Get-AIProperty $block 'id');name=[string](Get-AIProperty $block 'name');arguments=$initialArguments}
                        }
                    }
                    elseif ($type -eq 'content_block_delta') {
                        $blockDelta = Get-AIProperty $chunk 'delta'
                        $delta = Get-AIProperty $blockDelta 'text'
                        if ([string](Get-AIProperty $blockDelta 'type') -eq 'input_json_delta') {
                            $key = [string](Get-AIProperty $chunk 'index')
                            if (Test-AIMapContains $toolCalls $key) { $toolCalls[$key].arguments += [string](Get-AIProperty $blockDelta 'partial_json') }
                        }
                    }
                    elseif ($type -eq 'message_stop') { $responseState.Terminal = $true }
                    $usage = Get-AIProperty (Get-AIProperty $chunk 'message') 'usage'
                    if ($usage) { $responseState.InputTokens=[long](Get-AIProperty $usage 'input_tokens');$responseState.OutputTokens=[long](Get-AIProperty $usage 'output_tokens') }
                }
                'GeminiNative' {
                    $metadata = Get-AIProperty $chunk 'usageMetadata'
                    if ($metadata) { $responseState.InputTokens=[long](Get-AIProperty $metadata 'promptTokenCount');$responseState.OutputTokens=[long](Get-AIProperty $metadata 'candidatesTokenCount') }
                    $candidates = @(Get-AIProperty $chunk 'candidates')
                    if ($candidates.Count) {
                        $candidate = $candidates[0]
                        if (Get-AIProperty $candidate 'finishReason') { $responseState.Terminal = $true }
                        $parts = @(Get-AIProperty (Get-AIProperty $candidate 'content') 'parts')
                        foreach ($part in $parts) {
                            $functionCall = Get-AIProperty $part 'functionCall'
                            if ($functionCall) {
                                $key = [string]$toolCalls.Count
                                $toolCalls[$key] = [ordered]@{id=[guid]::NewGuid().ToString('N');name=[string](Get-AIProperty $functionCall 'name');arguments=(Get-AIProperty $functionCall 'args' | ConvertTo-Json -Depth 30 -Compress)}
                            } elseif (-not (Get-AIProperty $part 'thought')) { $delta += [string](Get-AIProperty $part 'text') }
                        }
                    }
                }
                'Ollama' {
                    if ([bool](Get-AIProperty $chunk 'done')) { $responseState.Terminal = $true }
                    $message = Get-AIProperty $chunk 'message'
                    $delta = Get-AIProperty $message 'content'
                    foreach ($call in @(Get-AIProperty $message 'tool_calls')) {
                        if (-not $call) { continue }
                        $function = Get-AIProperty $call 'function'
                        $key = [string]$toolCalls.Count
                        $arguments = Get-AIProperty $function 'arguments'
                        if ($arguments -isnot [string]) { $arguments = $arguments | ConvertTo-Json -Depth 30 -Compress }
                        $toolCalls[$key] = [ordered]@{id=[string](Get-AIProperty $call 'id');name=[string](Get-AIProperty $function 'name');arguments=[string]$arguments}
                    }
                    $responseState.InputTokens = [long](Get-AIProperty $chunk 'prompt_eval_count')
                    $responseState.OutputTokens = [long](Get-AIProperty $chunk 'eval_count')
                }
            }
            if ($delta) {
                $safeDelta = $sanitizer.Sanitize([string]$delta)
                if ($text.Length + $safeDelta.Length -gt 1MB) { throw '模型文本响应超过 1 MiB 上限。' }
                [void]$text.Append($safeDelta)
                if (-not $NoRender -and $safeDelta) { Write-AIStreamText $safeDelta -First:$first; $first = $false }
            }
            if ($toolCalls.Count -gt 8) { throw '模型一次返回的工具调用超过 8 个。' }
            foreach ($toolCall in $toolCalls.Values) {
                if ([string]$toolCall.name -and ([string]$toolCall.name).Length -gt 128) { throw '模型工具名称过长。' }
                if ([string]$toolCall.arguments -and ([string]$toolCall.arguments).Length -gt 65536) { throw '模型工具参数超过 64 KiB 上限。' }
            }
        }
        if (-not $NoRender -and -not $first) { Write-Host '' }
    } finally {
        $reader.Dispose(); $response.Dispose(); $request.Dispose(); $client.Dispose(); $linkedSource.Dispose(); $timeoutSource.Dispose(); $secret=$null
    }
    if ($parsed -eq 0) { throw '模型流式响应中没有可解析的数据。' }
    if (-not $responseState.Terminal) { throw '模型流式响应在完成标志之前中断。' }
    if ($text.Length -eq 0 -and $toolCalls.Count -eq 0) { throw '模型没有返回文本或工具调用。' }
    [pscustomobject]@{Text=$text.ToString();ToolCalls=@($toolCalls.Values);InputTokens=[long]$responseState.InputTokens;OutputTokens=[long]$responseState.OutputTokens}
}

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

function Show-AIHelp {
    Write-Host ''
    Write-AIColoredHost (Get-AIText 'CommonCommands') Magenta
    if ((Get-AILanguage) -eq 'en-US') {
        Write-Host '  ai                         Open settings'
        Write-Host '  ai <question>              Ask AI explicitly'
        Write-Host '  Get-PSAIModel              List configured models'
        Write-Host '  Get-PSAISession            List persistent sessions'
        Write-Host '  Get-PSAIRun                List Agent runs and recovery state'
        Write-Host '  ai resume <RunId>          Resume an unfinished run'
        Write-Host '  Set-PSAITerminalMode Auto  Enable Auto mode'
    } else {
        Write-Host '  ai                         打开设置'
        Write-Host '  ai <内容>                  显式询问 AI'
        Write-Host '  Get-PSAIModel              查看模型'
        Write-Host '  Get-PSAISession            查看持久会话'
        Write-Host '  Get-PSAIRun                查看 Agent Run 和恢复状态'
        Write-Host '  ai resume <RunId>          在顶层恢复未完成 Run'
        Write-Host '  Set-PSAITerminalMode Auto  启用自动模式'
    }
    Write-Host ''
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
        Write-Host "0. $(Get-AIText 'Back')"
        $choice = Read-AIChoice (Get-AIText 'SelectNumber') @(0,1,2,3,4,5,6) $null
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

function Get-AISessionContextText([int]$MaximumCharacters = 131072) {
    if (-not $script:CurrentSession) { return '' }
    $parts = [Collections.Generic.List[string]]::new()
    if ($script:CurrentSession.summary) { $parts.Add("较早对话摘要：`n$($script:CurrentSession.summary)") }
    $start = if (Test-AIMapContains $script:CurrentSession 'compactedTurnCount') { [int]$script:CurrentSession.compactedTurnCount } else { 0 }
    $turns = @($script:CurrentSession.turns)
    for ($index=$start; $index -lt $turns.Count; $index++) {
        $turn = $turns[$index]
        $label = switch ([string]$turn.role) { 'user' {'用户'} 'assistant' {'AI'} 'tool' {'工具结果'} default {[string]$turn.role} }
        $parts.Add("[$label/$($turn.kind)] $($turn.content)")
    }
    $value = Protect-AIText ($parts -join "`n`n") -1
    if ($value.Length -le $MaximumCharacters) { return $value }
    $marker = "[较早上下文已省略，完整内容仍保存在会话文件中]`n"
    $keep = [Math]::Max(0, $MaximumCharacters - $marker.Length)
    $startIndex = $value.Length - $keep
    if ($startIndex -gt 0 -and [char]::IsLowSurrogate($value[$startIndex])) { $startIndex++ }
    $marker + $value.Substring($startIndex)
}

function Compress-AISessionIfNeeded([Collections.IDictionary]$Model, [Threading.CancellationToken]$CancellationToken) {
    if (-not $script:CurrentSession) { return }
    $turns = @($script:CurrentSession.turns)
    $recentCount = [int]$script:Config.execution.recentTurns
    if ($turns.Count -le $recentCount) { return }
    $window = [int]$Model.contextWindow
    $thresholdCharacters = [int]([Math]::Max(4096, $window * 4 * ([int]$script:Config.execution.contextBudgetPercent / 100.0)))
    $context = Get-AISessionContextText ([Math]::Min(1048576, $thresholdCharacters + 1))
    if ($context.Length -le $thresholdCharacters) { return }

    $targetCount = $turns.Count - $recentCount
    $alreadyCompacted = if (Test-AIMapContains $script:CurrentSession 'compactedTurnCount') { [int]$script:CurrentSession.compactedTurnCount } else { 0 }
    if ($targetCount -le $alreadyCompacted) { return }
    $source = [Collections.Generic.List[string]]::new()
    if ($script:CurrentSession.summary) { $source.Add("已有摘要：$($script:CurrentSession.summary)") }
    for ($index=$alreadyCompacted; $index -lt $targetCount; $index++) {
        $source.Add("$($turns[$index].role)：$($turns[$index].content)")
    }
    $summaryPrompt = "把下面本地终端会话压缩为简洁事实摘要。保留用户目标、关键路径、已执行命令、结果、错误、未完成事项和明确偏好；不要补充不存在的信息；不要调用工具。`n`n$(Protect-AIText ($source -join "`n") 60000)"
    $previousSummary = [string]$script:CurrentSession.summary
    $hadCompactedTurnCount = Test-AIMapContains $script:CurrentSession 'compactedTurnCount'
    $previousCompactedTurnCount = if ($hadCompactedTurnCount) { [int]$script:CurrentSession.compactedTurnCount } else { 0 }
    $previousInputTokens = [long]$script:CurrentSession.inputTokens
    $previousOutputTokens = [long]$script:CurrentSession.outputTokens
    try {
        $summaryResult = Invoke-AIModelText -Model $Model -Prompt $summaryPrompt -NoRender -CancellationToken $CancellationToken
        $script:CurrentSession.summary = Protect-AIText $summaryResult.Text 16384
        $script:CurrentSession.compactedTurnCount = $targetCount
        Add-AISessionUsageValues $script:CurrentSession ([long]$summaryResult.InputTokens) ([long]$summaryResult.OutputTokens)
        Save-AISession
    } catch {
        $script:CurrentSession.summary = $previousSummary
        if ($hadCompactedTurnCount) { $script:CurrentSession.compactedTurnCount = $previousCompactedTurnCount }
        else { [void]$script:CurrentSession.Remove('compactedTurnCount') }
        $script:CurrentSession.inputTokens = $previousInputTokens
        $script:CurrentSession.outputTokens = $previousOutputTokens
        Write-Warning "会话自动压缩失败，本次继续使用最近上下文：$($_.Exception.Message)"
    }
}

function Invoke-AISessionModel([Collections.IDictionary]$Model, [string]$Instruction, [switch]$EnableTools,
    [switch]$NoRender, [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None) {
    Compress-AISessionIfNeeded $Model $CancellationToken
    $context = Get-AISessionContextText
    $prompt = if ($context) { "以下是持久会话上下文：`n$context`n`n当前要求：$Instruction" } else { $Instruction }
    $result = Invoke-AIModelText -Model $Model -Prompt $prompt -EnableTools:$EnableTools -NoRender:$NoRender -CancellationToken $CancellationToken
    $result
}

function Get-AIRunPath([string]$Id) {
    if ($Id -notmatch '^[a-fA-F0-9]{32}$') { throw 'Run ID 无效。' }
    Join-Path $script:RunDirectory "$Id.json"
}

function Save-AIRun([Collections.IDictionary]$Run, [switch]$LockHeld) {
    $path = Get-AIRunPath ([string]$Run.id)
    if (-not $LockHeld) {
        return Invoke-AIWithFileLock $path { Save-AIRun $Run -LockHeld }
    }

    $previousUpdatedUtc = $Run.updatedUtc
    $previousRevision = Get-AIRevision $Run 'Run'
    try {
        $storedRevision = Get-AIStoredRevision $path 'Run' $script:MaximumRunBytes
        if (($storedRevision -ge 0 -and $storedRevision -ne $previousRevision) -or
            ($storedRevision -lt 0 -and $previousRevision -ne 0)) {
            throw 'Run 已被另一个 PowerShell 进程修改。请重新读取状态后重试。'
        }
        if ($Run.events -isnot [Collections.IList] -or $Run.events -is [string] -or $Run.events.Count -gt 200) {
            throw 'Run 事件必须是最多包含 200 项的数组。'
        }
        $Run.revision = $previousRevision + 1
        $Run.updatedUtc = [DateTime]::UtcNow.ToString('O')
        $json = Protect-AIText ($Run | ConvertTo-Json -Depth 50) -1
        Assert-AISerializedSize $json $script:MaximumRunBytes 'Run 检查点'
        [PSAITerminal.AITerminalAtomicFile]::WriteAllText($path, $json)
    } catch {
        $Run.updatedUtc = $previousUpdatedUtc
        $Run.revision = $previousRevision
        throw
    }
}

function Import-AIRun([string]$Id) {
    $path = Get-AIRunPath $Id
    if (-not (Test-Path -LiteralPath $path)) { throw "Run 不存在：$Id" }
    [PSAITerminal.AITerminalAtomicFile]::EnsurePrivateFile($path)
    $runFile = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($runFile.Length -gt 4MB) { throw 'Run 检查点超过 4 MiB 上限。' }
    $run = ConvertFrom-AIJson (Read-AITextFile $path -Utf8Only)
    Assert-AIIntegerValue $run.schemaVersion 1 1 'Run 版本'
    $run.revision = Get-AIRevision $run 'Run'
    if ([string]$run.id -ne $Id -or $run.id -notmatch '^[a-fA-F0-9]{32}$' -or
        [string]$run.sessionId -notmatch '^[a-fA-F0-9]{32}$') { throw 'Run 检查点 ID 无效。' }
    if ([string]$run.state -notin @('Created','CallingModel','Streaming','AwaitingApproval','ExecutingTool','Observing','Completed','Cancelled','Failed')) {
        throw 'Run 状态无效。'
    }
    Assert-AIIntegerValue $run.maxSteps 1 100 'Run 最大步骤数'
    Assert-AIIntegerValue $run.stepCount 0 ([int]$run.maxSteps) 'Run 当前步骤数'
    if ($run.task -isnot [string] -or $run.task.Length -gt 16384) { throw 'Run 任务文本无效。' }
    foreach ($dateName in @('createdUtc','updatedUtc')) {
        $parsedDate = [datetime]::MinValue
        if (-not [datetime]::TryParse([string]$run[$dateName], [ref]$parsedDate)) { throw "Run $dateName 无效。" }
    }
    if ($run.events -isnot [Collections.IList] -or $run.events -is [string] -or $run.events.Count -gt 200) {
        throw 'Run 事件必须是最多包含 200 项的数组。'
    }
    for ($index = 0; $index -lt $run.events.Count; $index++) {
        $runEvent = $run.events[$index]
        if ($runEvent -isnot [Collections.IDictionary] -or [string]$runEvent.id -notmatch '^[a-fA-F0-9]{32}$' -or
            $runEvent.type -isnot [string] -or [string]::IsNullOrWhiteSpace($runEvent.type) -or $runEvent.type.Length -gt 64 -or
            $runEvent.data -isnot [Collections.IDictionary]) { throw "Run 事件 $index 无效。" }
        $eventDate = [datetime]::MinValue
        if (-not [datetime]::TryParse([string]$runEvent.createdUtc, [ref]$eventDate)) { throw "Run 事件 $index 的时间无效。" }
        Assert-AIModelParameters $runEvent.data "events[$index].data"
    }
    if ($run.state -in @('AwaitingApproval','ExecutingTool')) {
        if ($run.pendingProposal -isnot [Collections.IDictionary] -or
            [string]$run.pendingProposal.stepId -notmatch '^[a-fA-F0-9]{32}$') { throw 'Run 待执行提议无效。' }
        $validatedProposal = ConvertFrom-AIToolCall ([ordered]@{
            id=[string]$run.pendingProposal.id;name='powershell';arguments=[ordered]@{
                purpose=$run.pendingProposal.purpose;command=$run.pendingProposal.command
                expectedOutcome=$run.pendingProposal.expectedOutcome;sideEffects=$run.pendingProposal.sideEffects
                rollbackHint=$run.pendingProposal.rollbackHint
            }
        })
        foreach ($field in @('purpose','command','expectedOutcome','sideEffects','rollbackHint')) {
            $run.pendingProposal[$field] = $validatedProposal[$field]
        }
        $approvalFields = @('approvalDigest','approvalRevision','approvalRisk')
        $approvalFieldCount = @($approvalFields | Where-Object { Test-AIMapContains $run.pendingProposal $_ }).Count
        if ($approvalFieldCount -notin @(0, $approvalFields.Count)) { throw 'Run 命令批准记录不完整。' }
        if ($approvalFieldCount -eq $approvalFields.Count) {
            if ([string]$run.pendingProposal.approvalDigest -notmatch '^[a-f0-9]{64}$' -or
                [string]$run.pendingProposal.approvalRisk -notin @('Low','Medium','High')) {
                throw 'Run 命令批准记录无效。'
            }
            $run.pendingProposal.approvalRevision = Get-AIRevision @{revision=$run.pendingProposal.approvalRevision} 'Run 批准'
        }
        $run.pendingProposal.risk = [string](Get-AICommandRisk ([string]$run.pendingProposal.command))
    }
    $run.task = Protect-AIText ([string]$run.task) 16384
    if (Test-AIMapContains $run 'finalText') { $run.finalText = Protect-AIText ([string]$run.finalText) 65536 }
    $run
}

function Add-AIRunEvent([Collections.IDictionary]$Run, [string]$Type, [hashtable]$Data = @{}) {
    $runEvent = [ordered]@{id=[guid]::NewGuid().ToString('N');type=$Type;createdUtc=[DateTime]::UtcNow.ToString('O');data=$Data}
    $previousEvents = @($Run.events)
    try {
        $Run.events = $previousEvents + @($runEvent)
        if (@($Run.events).Count -gt 200) { $Run.events = @($Run.events | Select-Object -Last 200) }
        Save-AIRun $Run
    } catch {
        $Run.events = $previousEvents
        throw
    }
}

function Set-AIRunState([Collections.IDictionary]$Run, [string]$State, [hashtable]$Data = @{}) {
    $previousState = $Run.state
    try {
        $Run.state = $State
        Add-AIRunEvent $Run $State $Data
    } catch {
        $Run.state = $previousState
        throw
    }
}

function Remove-AIProposalApproval([Collections.IDictionary]$Proposal) {
    foreach ($field in @('approvalDigest','approvalRevision','approvalRisk')) {
        if (Test-AIMapContains $Proposal $field) { [void]$Proposal.Remove($field) }
    }
}

function Set-AIProposalApproval([Collections.IDictionary]$Run, [Collections.IDictionary]$Proposal,
    [PSAITerminal.AITerminalRisk]$Risk) {
    $previous = [ordered]@{}
    foreach ($field in @('approvalDigest','approvalRevision','approvalRisk')) {
        if (Test-AIMapContains $Proposal $field) { $previous[$field] = $Proposal[$field] }
    }
    Remove-AIProposalApproval $Proposal
    $digest = Get-AIApprovalDigest ([string]$Run.id) ([string]$Proposal.stepId) ([string]$Proposal.command)
    $approvalRevision = (Get-AIRevision $Run 'Run') + 1L
    $Proposal.approvalDigest = $digest
    $Proposal.approvalRevision = $approvalRevision
    $Proposal.approvalRisk = [string]$Risk
    try {
        Add-AIRunEvent $Run 'ProposalApproved' @{
            stepId=[string]$Proposal.stepId;approvalDigest=$digest;approvalRevision=$approvalRevision;risk=[string]$Risk
        }
    } catch {
        Remove-AIProposalApproval $Proposal
        foreach ($entry in $previous.GetEnumerator()) { $Proposal[[string]$entry.Key] = $entry.Value }
        throw
    }
    [pscustomobject]@{Digest=$digest;Revision=$approvalRevision;Risk=[string]$Risk}
}

function Revoke-AIProposalApproval([Collections.IDictionary]$Run, [Collections.IDictionary]$Proposal,
    [string]$Reason) {
    $previous = [ordered]@{}
    foreach ($field in @('approvalDigest','approvalRevision','approvalRisk')) {
        if (Test-AIMapContains $Proposal $field) { $previous[$field] = $Proposal[$field] }
    }
    if ($previous.Count -eq 0) { return }
    Remove-AIProposalApproval $Proposal
    try {
        Add-AIRunEvent $Run 'ApprovalInvalidated' @{stepId=[string]$Proposal.stepId;reason=$Reason}
    } catch {
        foreach ($entry in $previous.GetEnumerator()) { $Proposal[[string]$entry.Key] = $entry.Value }
        throw
    }
}

function ConvertFrom-AIToolCall($Call) {
    if ([string](Get-AIProperty $Call 'name') -ne 'powershell') { throw '模型请求了未注册的工具。' }
    $arguments = Get-AIProperty $Call 'arguments'
    if ($arguments -isnot [Collections.IDictionary]) {
        try { $arguments = ConvertFrom-AIJson ([string]$arguments) }
        catch { throw 'PowerShell 工具参数不是有效 JSON。' }
    }
    foreach ($field in @('purpose','command','expectedOutcome','sideEffects','rollbackHint')) {
        if ([string]::IsNullOrWhiteSpace([string]$arguments[$field])) { throw "PowerShell 工具参数缺少 $field。" }
        $arguments[$field] = Protect-AIText ([string]$arguments[$field]) $(if($field -eq 'command'){16384}else{4096})
    }
    $tokens=$null; $parseErrors=$null
    $ast = [Management.Automation.Language.Parser]::ParseInput([string]$arguments.command,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count) { throw '模型生成的 PowerShell 命令存在语法错误。' }
    $forbidden = $ast.Find({ param($node) $node -is [Management.Automation.Language.ExitStatementAst] -or
        $node -is [Management.Automation.Language.ReturnStatementAst] -or
        $node -is [Management.Automation.Language.BreakStatementAst] -or
        $node -is [Management.Automation.Language.ContinueStatementAst] }, $true)
    if ($forbidden) { throw 'Agent 命令不能包含 exit、return、break 或 continue；请改为普通 Shell 手动执行。' }
    [ordered]@{
        id = if (Get-AIProperty $Call 'id') { [string](Get-AIProperty $Call 'id') } else { [guid]::NewGuid().ToString('N') }
        purpose = $arguments.purpose; command = $arguments.command; expectedOutcome = $arguments.expectedOutcome
        sideEffects = $arguments.sideEffects; rollbackHint = $arguments.rollbackHint
    }
}

function Show-AIToolApproval([Collections.IDictionary]$Run, [Collections.IDictionary]$Proposal,
    [Threading.CancellationToken]$CancellationToken) {
    Revoke-AIProposalApproval $Run $Proposal 'ApprovalScreenOpened'
    while ($true) {
        $CancellationToken.ThrowIfCancellationRequested()
        $risk = Get-AICommandRisk ([string]$Proposal.command)
        $riskColor = switch ([string]$risk) { 'High' {'Red'} 'Medium' {'Yellow'} default {'Green'} }
        Write-Host ''; Write-Host "$(Get-AIText 'ApprovalPurpose'): $($Proposal.purpose)"
        Write-AIColoredHost "$(Get-AIText 'ApprovalCommand'): $($Proposal.command)" $riskColor
        Write-Host "$(Get-AIText 'ApprovalExpected'): $($Proposal.expectedOutcome)"
        Write-Host "$(Get-AIText 'ApprovalSideEffects'): $($Proposal.sideEffects)"
        if ([string]$risk -eq 'High') { Write-Host "$(Get-AIText 'ApprovalRollback'): $($Proposal.rollbackHint)" }
        Write-AIColoredHost "$(Get-AIText 'ApprovalRisk'): $risk" $riskColor
        Write-Warning (Get-AIText 'ApprovalNotice')
        $approvalMenu = Get-AIText 'ApprovalMenu'
        Write-Host ''; Write-Host "1. $($approvalMenu[0])"; Write-Host "2. $($approvalMenu[1])"; Write-Host "3. $($approvalMenu[2])"; Write-Host "4. $($approvalMenu[3])"
        $defaultChoice = if ([string]$risk -eq 'High') { $null } else { [Nullable[int]]1 }
        $choice = Read-AIChoice (Get-AIText 'SelectNumber') @(1,2,3,4) $defaultChoice
        if ($choice -eq 1) {
            $currentRisk = Get-AICommandRisk ([string]$Proposal.command)
            if ([string]$currentRisk -ne [string]$risk) {
                Write-Warning '命令风险或解析结果已变化，请重新核对后再确认。'
                continue
            }
            if ([string]$risk -eq 'High' -and -not (Read-AIYesNo (Get-AIText 'HighRiskConfirm') $false)) {
                continue
            }
            $approval = Set-AIProposalApproval $Run $Proposal $risk
            return [pscustomobject]@{
                RunId=$Run.id;StepId=$Proposal.stepId;Command=$Proposal.command
                ApprovalDigest=$approval.Digest;ApprovalRevision=$approval.Revision
                OutputLimit=[int]$script:Config.execution.outputCaptureCharacters
            }
        }
        if ($choice -eq 2) {
            $edited = (Read-Host (Get-AIText 'EditedCommand')).Trim()
            if (-not $edited) { continue }
            try {
                $validated = ConvertFrom-AIToolCall ([ordered]@{id=$Proposal.id;name='powershell';arguments=[ordered]@{
                    purpose=$Proposal.purpose;command=$edited;expectedOutcome=$Proposal.expectedOutcome
                    sideEffects=$Proposal.sideEffects;rollbackHint=$Proposal.rollbackHint
                }})
                $Proposal.command = $validated.command
                Remove-AIProposalApproval $Proposal
            } catch { Write-Warning $_.Exception.Message; continue }
            $model = Get-AIActiveModel
            try {
                $explanation = Invoke-AISessionModel $model "重新解释用户编辑后的命令，只返回简短说明：$edited" -NoRender -CancellationToken $CancellationToken
                Update-AISessionUsage ([long]$explanation.InputTokens) ([long]$explanation.OutputTokens)
                $Proposal.purpose = Protect-AIText $explanation.Text 4096
            } catch {
                Write-Warning "重新解释失败，保留编辑后的命令供再次确认：$($_.Exception.Message)"
                $Proposal.purpose = '执行用户编辑后的 PowerShell 命令。'
            }
            $Proposal.expectedOutcome = '按编辑后的命令执行并观察真实结果。'
            $Proposal.sideEffects = '已由用户编辑，将按确定性风险规则重新评估。'
            $Run.pendingProposal = $Proposal
            Add-AIRunEvent $Run 'ProposalEdited' @{stepId=$Proposal.stepId}
            continue
        }
        $Run.pendingProposal = $null
        Set-AIRunState $Run $(if($choice -eq 3){'Cancelled'}else{'Cancelled'}) @{reason=if($choice -eq 3){'Rejected'}else{'Stopped'}}
        return $null
    }
}

function Invoke-AIHarnessModelStep([Collections.IDictionary]$Run, [Threading.CancellationToken]$CancellationToken,
    [string]$RepairMessage) {
    if ([int]$Run.stepCount -ge [int]$Run.maxSteps) {
        Set-AIRunState $Run 'Failed' @{reason='MaxSteps'}
        throw "Agent 已达到最大步骤数：$($Run.maxSteps)"
    }
    $model = Get-AIActiveModel
    if (-not [bool]$model.capabilities.toolCalling) {
        Set-AIRunState $Run 'Failed' @{reason='ToolCallingUnsupported'}
        throw "当前模型 '$($model.name)' 未启用结构化工具调用，只能用于问答和解释。"
    }
    Set-AIRunState $Run 'CallingModel' @{model=$model.name}
    $instruction = "继续完成 Run $($Run.id) 的本地任务。需要执行命令时必须调用 powershell 工具；已有结果足够时直接给出总结，不要调用工具。"
    if ($RepairMessage) { $instruction += "`n上一次工具调用无效：$RepairMessage。请只修正一次。" }
    Set-AIRunState $Run 'Streaming' @{model=$model.name}
    $response = Invoke-AISessionModel $model $instruction -EnableTools -CancellationToken $CancellationToken
    $usagePersisted = $false
    if ($response.Text) {
        Add-AISessionTurn 'assistant' $response.Text 'message' @{runId=$Run.id} `
            -InputTokens ([long]$response.InputTokens) -OutputTokens ([long]$response.OutputTokens) | Out-Null
        $usagePersisted = $true
    }
    $calls = @($response.ToolCalls)
    if ($calls.Count -eq 0) {
        $Run.finalText = Protect-AIText $response.Text 65536
        Set-AIRunState $Run 'Completed'
        return $null
    }
    try {
        if ($calls.Count -ne 1) { throw '每一步只能调用一个工具。' }
        $proposal = ConvertFrom-AIToolCall $calls[0]
    } catch {
        if (-not $usagePersisted) {
            Update-AISessionUsage ([long]$response.InputTokens) ([long]$response.OutputTokens)
            $usagePersisted = $true
        }
        if (-not $RepairMessage) { return Invoke-AIHarnessModelStep $Run $CancellationToken $_.Exception.Message }
        Set-AIRunState $Run 'Failed' @{reason='InvalidToolCall';message=(Protect-AIText $_.Exception.Message 1024)}
        throw '模型连续两次返回无效工具调用，已停止且没有执行命令。'
    }
    $Run.stepCount = [int]$Run.stepCount + 1
    $proposalInputTokens = if ($usagePersisted) { 0L } else { [long]$response.InputTokens }
    $proposalOutputTokens = if ($usagePersisted) { 0L } else { [long]$response.OutputTokens }
    Add-AISessionTurn 'assistant' ($proposal | ConvertTo-Json -Depth 10 -Compress) 'tool_proposal' `
        @{runId=$Run.id;toolCallId=$proposal.id} -InputTokens $proposalInputTokens -OutputTokens $proposalOutputTokens | Out-Null
    $proposal.risk = [string](Get-AICommandRisk ([string]$proposal.command))
    $proposal.stepId = [guid]::NewGuid().ToString('N')
    $Run.pendingProposal = $proposal
    Set-AIRunState $Run 'AwaitingApproval' @{stepId=$proposal.stepId}
    Show-AIToolApproval $Run $proposal $CancellationToken
}

function Start-PSAIRun {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Task,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    $safeTask = Protect-AIText $Task 16384
    Add-AISessionTurn 'user' $safeTask 'task' | Out-Null
    $run = [ordered]@{
        schemaVersion=1;revision=0L;id=[guid]::NewGuid().ToString('N');sessionId=$script:CurrentSession.id
        task=$safeTask;state='Created';stepCount=0;maxSteps=[int]$script:Config.execution.maxAgentSteps
        pendingProposal=$null;events=@();createdUtc=[DateTime]::UtcNow.ToString('O');updatedUtc=[DateTime]::UtcNow.ToString('O')
    }
    Save-AIRun $run
    Add-AIRunEvent $run 'Created'
    try { Invoke-AIHarnessModelStep $run $CancellationToken $null }
    catch {
        if ($CancellationToken.IsCancellationRequested) { Set-AIRunState $run 'Cancelled' @{reason='Cancelled'} }
        elseif ($run.state -notin @('Failed','Cancelled')) { Set-AIRunState $run 'Failed' @{message=(Protect-AIText $_.Exception.Message 2048)} }
        throw
    }
}

function Start-PSAIToolExecution {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$StepId,
        [Parameter(Mandatory)][string]$ApprovalDigest,
        [Parameter(Mandatory)][long]$ApprovalRevision
    )
    $run = Import-AIRun $RunId
    if ($run.state -ne 'AwaitingApproval' -or [string]$run.pendingProposal.stepId -ne $StepId) { throw 'Run 当前没有匹配的待执行步骤。' }
    $proposal = $run.pendingProposal
    $approvalFields = @('approvalDigest','approvalRevision','approvalRisk')
    if (@($approvalFields | Where-Object { Test-AIMapContains $proposal $_ }).Count -ne $approvalFields.Count) {
        throw '命令尚未获得有效批准，未执行任何命令。请重新确认。'
    }
    $currentRevision = Get-AIRevision $run 'Run'
    $currentDigest = Get-AIApprovalDigest ([string]$run.id) ([string]$proposal.stepId) ([string]$proposal.command)
    $currentRisk = [string](Get-AICommandRisk ([string]$proposal.command))
    if ($ApprovalDigest -notmatch '^[a-f0-9]{64}$' -or
        $ApprovalRevision -ne $currentRevision -or
        $ApprovalRevision -ne [long]$proposal.approvalRevision -or
        $ApprovalDigest -cne [string]$proposal.approvalDigest -or
        $ApprovalDigest -cne $currentDigest -or
        $currentRisk -ne [string]$proposal.approvalRisk) {
        throw '命令批准已过期，或命令、风险和 Run 修订号已经变化；未执行任何命令，请重新确认。'
    }
    Set-AIRunState $run 'ExecutingTool' @{stepId=$StepId;approvalDigest=$ApprovalDigest;approvalRevision=$ApprovalRevision}
}

function Complete-PSAIToolExecution {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$StepId,
        [Parameter(Mandatory)][bool]$Succeeded,[AllowNull()][string]$Output,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    $run = Import-AIRun $RunId
    if ($run.state -ne 'ExecutingTool' -or [string]$run.pendingProposal.stepId -ne $StepId) { throw 'Run 执行状态与结果不匹配。' }
    $proposal = $run.pendingProposal
    $safeOutput = Protect-AIText $Output ([int]$script:Config.execution.outputCaptureCharacters)
    $script:LastCommandResult = [pscustomobject]@{
        Command=[string]$proposal.command;Succeeded=$Succeeded;Output=$safeOutput
        Error=if($Succeeded){$null}else{$safeOutput};Source='AI';CompletedUtc=[DateTime]::UtcNow;RunId=$RunId;StepId=$StepId
    }
    Invoke-AIOfficialAddPrediction ([string]$proposal.command)
    Add-AISessionTurn 'tool' "命令：$($proposal.command)`n状态：$(if($Succeeded){'成功'}else{'失败'})`n输出：$safeOutput" 'tool_result' @{
        runId=$RunId;stepId=$StepId;succeeded=$Succeeded;command=[string]$proposal.command;output=$safeOutput
    } | Out-Null
    $run.pendingProposal = $null
    Set-AIRunState $run 'Observing' @{stepId=$StepId;succeeded=$Succeeded;output=$safeOutput}
    $mark = if ($Succeeded) { '✓' } else { '✗' }
    Write-AIColoredHost "◆ $mark 命令已完成 · F7 解释" DarkGray
    try { Invoke-AIHarnessModelStep $run $CancellationToken $null }
    catch {
        if ($CancellationToken.IsCancellationRequested) { Set-AIRunState $run 'Cancelled' @{reason='Cancelled'} }
        elseif ($run.state -notin @('Failed','Cancelled')) { Set-AIRunState $run 'Failed' @{message=(Protect-AIText $_.Exception.Message 2048)} }
        throw
    }
}

function Get-PSAIRun {
    [CmdletBinding()] param([string]$Id)
    $runs = if ($Id) { @((Import-AIRun $Id)) } else {
        @(Get-ChildItem -LiteralPath $script:RunDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                $runFile = $_
                try { Import-AIRun $runFile.BaseName }
                catch { Write-Warning "跳过无法读取的 Run 文件：$($runFile.FullName)。$($_.Exception.Message)" }
            })
    }
    $runs | Where-Object { $_ } | Sort-Object updatedUtc -Descending | ForEach-Object {
        [pscustomobject]@{Id=$_.id;SessionId=$_.sessionId;Task=$_.task;State=$_.state;StepCount=[int]$_.stepCount;UpdatedUtc=[datetime]$_.updatedUtc}
    }
}

function Resume-PSAIRun {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Id,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    $run = Import-AIRun $Id
    if ($run.sessionId -ne $script:CurrentSession.id) { Select-PSAISession -Id ([string]$run.sessionId) | Out-Null }
    switch ([string]$run.state) {
        'AwaitingApproval' { Show-AIToolApproval $run $run.pendingProposal $CancellationToken }
        'ExecutingTool' { throw "Run 在命令执行期间中断。为避免重复执行，请先运行 Resolve-PSAIRun -Id $Id -Outcome NotExecuted、Succeeded 或 Failed。" }
        { $_ -in @('Created','CallingModel','Streaming','Observing') } { Invoke-AIHarnessModelStep $run $CancellationToken $null }
        default { Write-Warning "Run 已处于终态：$($run.state)" }
    }
}

function Resolve-PSAIRun {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('NotExecuted','Succeeded','Failed')][string]$Outcome,[string]$Output='')
    $run = Import-AIRun $Id
    if ($run.state -ne 'ExecutingTool') { throw '只有在工具执行期间中断的 Run 需要人工解决。' }
    if ($Outcome -eq 'NotExecuted') {
        Set-AIRunState $run 'AwaitingApproval' @{resolution='NotExecuted'}
        return Resume-PSAIRun -Id $Id
    }
    Complete-PSAIToolExecution -RunId $Id -StepId ([string]$run.pendingProposal.stepId) -Succeeded:($Outcome -eq 'Succeeded') -Output $Output
}

function Stop-PSAIRun {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Id)
    $run = Import-AIRun $Id
    if ($run.state -in @('Completed','Cancelled','Failed')) { return Get-PSAIRun -Id $Id }
    $run.pendingProposal = $null
    Set-AIRunState $run 'Cancelled' @{reason='UserStopped'}
    Get-PSAIRun -Id $Id
}

function Invoke-PSAI {
    [CmdletBinding()] param(
        [Parameter(Position=0,ValueFromRemainingArguments)][string[]]$Prompt,
        [switch]$Agent,
        [switch]$ExplainLast,
        [Parameter(DontShow)][ValidatePattern('^[a-f0-9]{32}$')][string]$PendingInvocation,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None
    )
    if ($PendingInvocation) { return Get-AIPendingInvocationScript $PendingInvocation }
    if (-not $PSBoundParameters.ContainsKey('Prompt') -and -not $Agent -and -not $ExplainLast -and $script:NextPendingInvocationId) {
        $pendingId = [string]$script:NextPendingInvocationId
        $script:NextPendingInvocationId = $null
        return Get-AIPendingInvocationScript $pendingId
    }
    if ($ExplainLast) { return Show-PSAIResultExplanation }
    $text = ($Prompt -join ' ').Trim()
    if (-not $text) { return Open-PSAISettings }
    if ($Agent) { throw '直接运行 Invoke-PSAI -Agent 无法保证命令处于调用者顶层作用域。请使用 F2，或切换到 AI/Auto 模式后提交输入。' }
    $model = Get-AIActiveModel
    Add-AISessionTurn 'user' $text 'message' | Out-Null
    $result = Invoke-AISessionModel -Model $model -Instruction '回答用户最后一条消息，不要调用工具。' -CancellationToken $CancellationToken
    if ($result.Text) {
        Add-AISessionTurn 'assistant' $result.Text 'message' @{} `
            -InputTokens ([long]$result.InputTokens) -OutputTokens ([long]$result.OutputTokens) | Out-Null
    }
}

function Show-PSAIResultExplanation {
    [CmdletBinding()] param()
    Update-AILastSubmittedFromHistory
    $feedback = Get-AIOfficialFeedback
    if (-not $script:LastCommandResult -and -not $script:LastSubmittedCommand -and -not $feedback) {
        Write-Warning '当前会话还没有最近命令。'; return
    }
    $model = Get-AIActiveModel
    if ($script:LastCommandResult) {
        $result = $script:LastCommandResult
        $details = if ($result.Output) { "输出：$($result.Output)" }
            elseif ($result.Error) { "错误：$($result.Error)" }
            elseif ($result.Succeeded) { '执行状态：成功；模块为保持系统原始输出未截获输出内容。' }
            else { '执行状态：失败。' }
        $prompt = "请解释最近一次本地 PowerShell 命令及其结果，不要调用工具：`n命令：$($result.Command)`n$details"
    } elseif ($script:LastSubmittedCommand) {
        $prompt = "请解释最近一次提交的本地 PowerShell 命令，不要调用工具。模块没有截获这次执行状态：`n命令：$($script:LastSubmittedCommand.Command)"
    } else {
        $prompt = "请解释下面失败的本地 PowerShell 命令，不要调用工具：`n命令：$($feedback.CommandLine)`n错误：$($feedback.Error)`n位置：$($feedback.CurrentLocation)"
    }
    Add-AISessionTurn 'user' $prompt 'explanation_request' | Out-Null
    $result = Invoke-AISessionModel -Model $model -Instruction '解释最近一次命令和结果，不要调用工具。'
    if ($result.Text) {
        Add-AISessionTurn 'assistant' $result.Text 'explanation' @{} `
            -InputTokens ([long]$result.InputTokens) -OutputTokens ([long]$result.OutputTokens) | Out-Null
    }
}

function New-AITopLevelHarnessScript([string]$StartExpression) {
    $suffix = [guid]::NewGuid().ToString('N')
    $step = "__PSAI_${suffix}_Step"
    $collector = "__PSAI_${suffix}_Collector"
    $success = "__PSAI_${suffix}_Success"
    $code = "__PSAI_${suffix}_Code"
    $outputLimit = "__PSAI_${suffix}_OutputLimit"
    $executionState = "__PSAI_${suffix}_ExecutionState"
    $template = @'
${STEP} = {START}
try {
    while ($null -ne ${STEP}) {
        Start-PSAIToolExecution -RunId ([string]${STEP}.RunId) -StepId ([string]${STEP}.StepId) -ApprovalDigest ([string]${STEP}.ApprovalDigest) -ApprovalRevision ([long]${STEP}.ApprovalRevision)
        ${SUCCESS} = $false
        ${OUTPUT_LIMIT} = if (${STEP}.PSObject.Properties['OutputLimit']) { [int]${STEP}.OutputLimit } else { 65536 }
        if (${OUTPUT_LIMIT} -lt 1024 -or ${OUTPUT_LIMIT} -gt 65536) { ${OUTPUT_LIMIT} = 65536 }
        ${COLLECTOR} = [PSAITerminal.AITerminalBoundedTextCollector]::new(${OUTPUT_LIMIT})
        ${EXECUTION_STATE} = [ordered]@{
            LastSuccess = $false
            HadError = $false
            NativePreferenceAvailable = $false
            PreviousNativePreference = $null
            LastExitCodeTracked = $false
            LastExitCodeAvailable = $false
            PreviousLastExitCode = $null
        }
        ${CODE} = [string]${STEP}.Command + [Environment]::NewLine + '${EXECUTION_STATE}.LastSuccess=$?'
        try {
            if ($PSVersionTable.PSVersion -ge [version]'7.3') {
                ${EXECUTION_STATE}.NativePreferenceAvailable = $true
                ${EXECUTION_STATE}.PreviousNativePreference = [bool]$PSNativeCommandUseErrorActionPreference
                $PSNativeCommandUseErrorActionPreference = $true
            } else {
                ${EXECUTION_STATE}.LastExitCodeTracked = $true
                ${EXECUTION_STATE}.LastExitCodeAvailable = $null -ne (Get-Variable LASTEXITCODE -ErrorAction SilentlyContinue)
                if (${EXECUTION_STATE}.LastExitCodeAvailable) {
                    ${EXECUTION_STATE}.PreviousLastExitCode = [int](Get-Variable LASTEXITCODE).Value
                }
                $LASTEXITCODE = 0
            }
            . ([scriptblock]::Create(${CODE})) *>&1 | ForEach-Object {
                if ($_ -is [Management.Automation.ErrorRecord]) { ${EXECUTION_STATE}.HadError = $true }
                $_
            } | Out-String -Stream | ForEach-Object {
                ${COLLECTOR}.Append($_ + [Environment]::NewLine)
                $_ | Out-Host
            }
            if (${EXECUTION_STATE}.LastExitCodeTracked -and [int]$LASTEXITCODE -ne 0) {
                ${EXECUTION_STATE}.HadError = $true
            }
        } catch {
            ${EXECUTION_STATE}.HadError = $true
            ${EXECUTION_STATE}.LastSuccess = $false
            ${COLLECTOR}.Append(($_ | Out-String))
            $_ | Out-Host
        } finally {
            if (${EXECUTION_STATE}.NativePreferenceAvailable) {
                $PSNativeCommandUseErrorActionPreference = [bool]${EXECUTION_STATE}.PreviousNativePreference
            } elseif (${EXECUTION_STATE}.LastExitCodeTracked) {
                if (${EXECUTION_STATE}.LastExitCodeAvailable) {
                    $LASTEXITCODE = [int]${EXECUTION_STATE}.PreviousLastExitCode
                } else {
                    Remove-Variable LASTEXITCODE -Scope 0 -ErrorAction SilentlyContinue
                }
            }
        }
        ${SUCCESS} = [bool]${EXECUTION_STATE}.LastSuccess -and -not [bool]${EXECUTION_STATE}.HadError
        ${STEP} = Complete-PSAIToolExecution -RunId ([string]${STEP}.RunId) -StepId ([string]${STEP}.StepId) -Succeeded:([bool]${SUCCESS}) -Output (${COLLECTOR}.GetText())
    }
} finally {
    Remove-Variable -Name '{STEP_NAME}','{COLLECTOR_NAME}','{SUCCESS_NAME}','{CODE_NAME}','{OUTPUT_LIMIT_NAME}','{EXECUTION_STATE_NAME}' -Scope 0 -ErrorAction SilentlyContinue
}
'@
    $template.Replace('{START}', $StartExpression).
        Replace('${STEP}', "`$$step").Replace('${COLLECTOR}', "`$$collector").
        Replace('${SUCCESS}', "`$$success").Replace('${CODE}', "`$$code").
        Replace('${OUTPUT_LIMIT}', "`$$outputLimit").
        Replace('${EXECUTION_STATE}', "`$$executionState").
        Replace('{STEP_NAME}', $step).Replace('{COLLECTOR_NAME}', $collector).
        Replace('{SUCCESS_NAME}', $success).Replace('{CODE_NAME}', $code).
        Replace('{OUTPUT_LIMIT_NAME}', $outputLimit).Replace('{EXECUTION_STATE_NAME}', $executionState)
}

function New-AIPendingInvocationLine([string]$ScriptText) {
    if ([string]::IsNullOrWhiteSpace($ScriptText)) { throw '内部调度脚本不能为空。' }
    $tokens = $null; $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($ScriptText, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw "内部调度脚本无效：$($parseErrors[0].Message)" }

    if ($script:NextPendingInvocationId -and $script:PendingInvocationScripts.ContainsKey([string]$script:NextPendingInvocationId)) {
        [void]$script:PendingInvocationScripts.Remove([string]$script:NextPendingInvocationId)
    }
    if ($script:PendingInvocationScripts.Count -ge 32) { $script:PendingInvocationScripts.Clear() }
    $id = [guid]::NewGuid().ToString('N')
    $script:PendingInvocationScripts[$id] = $ScriptText
    $script:NextPendingInvocationId = $id
    '. (Invoke-PSAI)'
}

function Get-AIPendingInvocationScript([string]$Id) {
    if ([string]$script:NextPendingInvocationId -eq $Id) { $script:NextPendingInvocationId = $null }
    if (-not $script:PendingInvocationScripts.ContainsKey($Id)) {
        throw '该内部调度请求不存在或已经执行。'
    }
    $scriptText = $script:PendingInvocationScripts[$Id]
    [void]$script:PendingInvocationScripts.Remove($Id)
    [scriptblock]::Create($scriptText)
}

function ConvertTo-AIInvocationLine([string]$Text, [switch]$Agent) {
    $escaped = $Text.Replace("'", "''")
    if ($Agent) { return New-AITopLevelHarnessScript "Start-PSAIRun -Task '$escaped'" }
    "Invoke-PSAI -Prompt '$escaped'"
}

function ConvertTo-AIAutoShellLine([string]$Text) {
    $escaped = $Text.Replace("'", "''")
    $suffix = [guid]::NewGuid().ToString('N')
    $success = "__PSAI_${suffix}_Success"
    $errorRecord = "__PSAI_${suffix}_Error"
    $fallback = New-AITopLevelHarnessScript "Start-PSAIAutoFallback -Command '$escaped' -ErrorRecord `$$errorRecord"
    @"
`$$success = `$false
`$$errorRecord = `$null
try {
$Text
`$$success = `$?
if (-not `$$success) { `$$errorRecord = `$Error[0] }
} catch {
`$$errorRecord = `$_
`$$success = `$false
Write-Error -ErrorRecord `$_ -ErrorAction Continue
}
Invoke-PSAIAutoCompletion -Command '$escaped' -Succeeded:([bool]`$$success) -ErrorRecord `$$errorRecord
if (-not `$$success) {
$fallback
}
Remove-Variable -Name '$success','$errorRecord' -Scope 0 -ErrorAction SilentlyContinue
"@
}

function Set-AILastSubmittedCommand([string]$Command) {
    $script:LastCommandResult = $null
    $script:LastSubmittedCommand = [pscustomobject]@{
        Command = $Command
        SubmittedUtc = [DateTime]::UtcNow
    }
}

function Update-AILastSubmittedFromHistory {
    try {
        $item = [Microsoft.PowerShell.PSConsoleReadLine]::GetHistoryItems() |
            Where-Object { $_.CommandLine -notmatch '^(?i:Show-PSAIResultExplanation|Open-PSAISettings|Set-PSAITerminalMode)(?:\s|$)' } |
            Select-Object -Last 1
        if (-not $item) { return }
        $historyUtc = $item.StartTime.ToUniversalTime()
        if (-not $script:LastCommandResult -or $historyUtc -gt ([datetime]$script:LastCommandResult.CompletedUtc).ToUniversalTime()) {
            $script:LastCommandResult = $null
            $script:LastSubmittedCommand = [pscustomobject]@{Command=[string]$item.CommandLine;SubmittedUtc=$historyUtc}
        }
    } catch {
        # 非交互环境没有活动的 PSReadLine 实例，保留模块已有记录。
        Write-Verbose "无法读取 PSReadLine 历史：$($_.Exception.Message)"
    }
}

function Invoke-PSAIAutoCompletion {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][bool]$Succeeded,
        [AllowNull()]$ErrorRecord
    )
    $script:LastCommandResult = [pscustomobject]@{
        Command = $Command
        Succeeded = $Succeeded
        Output = $null
        Error = if ($Succeeded) { $null } else { Protect-AIText ($ErrorRecord | Out-String) 8192 }
        Source = 'Shell'
        CompletedUtc = [DateTime]::UtcNow
    }
}

function Start-PSAIAutoFallback {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$Command,
        [AllowNull()]$ErrorRecord
    )
    $safeCommand = Protect-AIText $Command 4096
    $safeError = Protect-AIText ($ErrorRecord | Out-String) 8192
    $task = "刚才的本地 PowerShell 命令执行失败。请根据原命令和真实错误提出修复或诊断命令。`n原命令：$safeCommand`n错误：$safeError"
    Start-PSAIRun -Task $task -CancellationToken ([Threading.CancellationToken]::None)
}

function Set-AICurrentBuffer([string]$Text) {
    $current = $null; $cursor = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$current, [ref]$cursor)
    [Microsoft.PowerShell.PSConsoleReadLine]::Replace(0, ([string]$current).Length, $Text)
}

function Get-AICurrentBuffer {
    $line = $null; $cursor = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    [string]$line
}

function Test-AIAutoRoute([string]$Line) {
    $commandExists = [Func[string,bool]]{
        param($name)
        [bool](Get-Command -Name ([WildcardPattern]::Escape($name)) -ErrorAction SilentlyContinue)
    }
    $pathExists = [Func[string,bool]]{
        param($name)
        if (-not (Test-Path -LiteralPath $name -PathType Leaf)) { return $false }
        [IO.Path]::GetExtension($name) -in @('.ps1','.psm1','.cmd','.bat','.exe','.com')
    }
    [PSAITerminal.AITerminalInputRouter]::NeedsAgent($Line, $commandExists, $pathExists)
}

function ConvertTo-AISubmittedLine([string]$Line) {
    $action = [string]$script:NextReadLineAction
    $script:NextReadLineAction = $null
    if ($action -eq 'ForceShell' -or [string]::IsNullOrWhiteSpace($Line) -or
        [PSAITerminal.AITerminalInputRouter]::IsIncomplete($Line)) { return $Line }

    $trimmed = $Line.Trim()
    if ($trimmed -match '^(?i:ai)$') { return 'Open-PSAISettings' }
    if ($trimmed -match '^(?i:ai)\s+resume\s+([a-f0-9]{32})$') {
        return New-AIPendingInvocationLine (New-AITopLevelHarnessScript "Resume-PSAIRun -Id '$($Matches[1])'")
    }
    if ($trimmed -match '^(?i:ai)\s+resolve\s+([a-f0-9]{32})\s+(NotExecuted|Succeeded|Failed)$') {
        return New-AIPendingInvocationLine (New-AITopLevelHarnessScript "Resolve-PSAIRun -Id '$($Matches[1])' -Outcome '$($Matches[2])'")
    }
    if ($trimmed -match '^(?i:ai)\s+(.+)$') {
        Set-AILastSubmittedCommand $Line
        return New-AIPendingInvocationLine (ConvertTo-AIInvocationLine $Matches[1] -Agent)
    }
    if ($action -eq 'ForceAI') {
        Set-AILastSubmittedCommand $Line
        return New-AIPendingInvocationLine (ConvertTo-AIInvocationLine $Line -Agent)
    }
    if ($trimmed -match '^(?i:Show-PSAIResultExplanation)(?:\s|$)' -or $script:Config.mode -eq 'Off') {
        return $Line
    }

    Set-AILastSubmittedCommand $Line
    if ($script:Config.mode -eq 'AI' -or ($script:Config.mode -eq 'Auto' -and (Test-AIAutoRoute $Line))) {
        return New-AIPendingInvocationLine (ConvertTo-AIInvocationLine $Line -Agent)
    }
    if ($script:Config.mode -eq 'Auto') {
        return New-AIPendingInvocationLine (ConvertTo-AIAutoShellLine $Line)
    }
    $Line
}

function Invoke-AIEnterHandler {
    [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
}

function Invoke-AIHostReadLine([bool]$LastRunStatus) {
    if (-not $script:OriginalPSConsoleHostReadLine) {
        throw 'PSAITerminal 无法找到宿主原始输入读取函数。'
    }
    if ($LastRunStatus) { $null = $true }
    else { Write-Error 'PSAITerminal input status preservation' -ErrorAction Ignore }
    $line = & $script:OriginalPSConsoleHostReadLine
    ConvertTo-AISubmittedLine $line
}

function Get-AIPSReadLineKeyHandler([string]$Key) {
    $command = Get-Command Get-PSReadLineKeyHandler -ErrorAction SilentlyContinue
    if (-not $command) { return $null }
    if ($command.Parameters.ContainsKey('Chord')) {
        return Get-PSReadLineKeyHandler -Chord $Key -ErrorAction SilentlyContinue
    }
    @(Get-PSReadLineKeyHandler -Bound -ErrorAction SilentlyContinue | Where-Object {
        @([string]$_.Key -split ',\s*') -contains $Key
    }) | Select-Object -First 1
}

function Set-AIPSAIKeyHandler([string]$Key, [string]$Description, [scriptblock]$Handler,
    [string[]]$ReplaceableFunctions, [switch]$Force) {
    if (-not $Key) { return $false }
    $current = Get-AIPSReadLineKeyHandler $Key
    if ($current -and $current.Function -notlike 'PSAI*' -and $current.Function -notin $ReplaceableFunctions -and -not $Force) {
        Write-Warning "快捷键 $Key 已由 '$($current.Function)' 使用，PSAITerminal 未覆盖。"
        return $false
    }
    if (-not (Test-AIMapContains $script:OriginalKeyBindings $Key)) {
        $script:OriginalKeyBindings[$Key] = if ($current) { [string]$current.Function } else { $null }
    }
    Set-PSReadLineKeyHandler -Key $Key -BriefDescription $Description -LongDescription $Description -ScriptBlock $Handler
    [void]$script:BoundKeys.Add($Key)
    $true
}

function Register-AIPSReadLineIntegration {
    param([switch]$Force)
    if ($script:PSReadLineIntegrated -or $Host.Name -ne 'ConsoleHost' -or
        [Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return }
    if (-not (Get-Module PSReadLine) -and -not (Import-Module PSReadLine -ErrorAction SilentlyContinue -PassThru)) { return }

    $readLineCommand = Get-Command PSConsoleHostReadLine -CommandType Function -ErrorAction SilentlyContinue
    if (-not $readLineCommand) { return }
    $state = Get-AIPromptIntegrationState
    if ($state -and $state.PSObject.Properties['ReadLineWrapper'] -and
        (Test-AISamePromptScriptBlock $readLineCommand.ScriptBlock $state.ReadLineWrapper)) {
        $script:OriginalPSConsoleHostReadLine = $state.OriginalReadLine
    } else {
        $script:OriginalPSConsoleHostReadLine = $readLineCommand.ScriptBlock
    }
    $script:PSAIHostReadLine = [scriptblock]::Create(@'
[System.Diagnostics.DebuggerHidden()]
param()
$lastRunStatus = $?
Microsoft.PowerShell.Core\Set-StrictMode -Off
$state = [AppDomain]::CurrentDomain.GetData('__PSAITerminalPromptIntegrationState')
$module = if ($state -and $state.Owner) { $state.Owner } else { Get-Module PSAITerminal | Select-Object -Last 1 }
if (-not $module) { throw 'PSAITerminal 输入路由的活动模块实例不存在。' }
& $module { param($status) Invoke-AIHostReadLine $status } $lastRunStatus
'@)
    Set-Item -LiteralPath Function:\global:PSConsoleHostReadLine -Value $script:PSAIHostReadLine

    if ($script:ShortcutMigrated) {
        $shiftEnter = Get-AIPSReadLineKeyHandler 'Shift+Enter'
        if (-not $shiftEnter -or $shiftEnter.Function -eq 'PSAIForceAI') {
            Set-PSReadLineKeyHandler -Key 'Shift+Enter' -Function AddLine
        }
        foreach ($legacyKey in @('Alt+A','Alt+S','Alt+M','Alt+E','Alt+Enter','Ctrl+Shift+I','Ctrl+Shift+E','Ctrl+Shift+,','Ctrl+Shift+M')) {
            $legacyHandler = Get-AIPSReadLineKeyHandler $legacyKey
            if ($legacyHandler -and $legacyHandler.Function -like 'PSAI*') { Remove-PSReadLineKeyHandler -Chord $legacyKey }
        }
    }

    $script:OriginalAddToHistoryHandler = (Get-PSReadLineOption).AddToHistoryHandler
    $script:PSAIAddToHistoryHandler = [Func[string,object]]{
        param([string]$line)
        if ($script:InternalHistoryLines.Remove($line)) { return [Microsoft.PowerShell.AddToHistoryOption]::SkipAdding }
        if ($script:OriginalAddToHistoryHandler) { return $script:OriginalAddToHistoryHandler.Invoke($line) }
        [Microsoft.PowerShell.AddToHistoryOption]::MemoryAndFile
    }
    Set-PSReadLineOption -AddToHistoryHandler $script:PSAIAddToHistoryHandler

    if ([bool]$script:Config.integrations.enterRouting) {
        [void](Set-AIPSAIKeyHandler Enter 'PSAIEnter' { Invoke-AIEnterHandler } @('AcceptLine') -Force:$Force)
    }
    [void](Set-AIPSAIKeyHandler $script:Config.shortcuts.cycleMode 'PSAICycleMode' {
        $next = switch ([string]$script:Config.mode) { 'Off' {'AI'} 'AI' {'Auto'} default {'Off'} }
        if ($next -ne 'Off' -and -not $script:Config.activeModel) {
            Set-AICurrentBuffer 'Open-PSAISettings'
        } else {
            Set-AICurrentBuffer "Set-PSAITerminalMode $next"
        }
        $script:NextReadLineAction = 'ForceShell'
        [void]$script:InternalHistoryLines.Add((Get-AICurrentBuffer))
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    } @() -Force:$Force)
    [void](Set-AIPSAIKeyHandler $script:Config.shortcuts.forceAI 'PSAIForceAI' {
        $line = Get-AICurrentBuffer
        if ($line) {
            Set-AILastSubmittedCommand $line
            $script:NextReadLineAction = 'ForceAI'
        }
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    } @('SwitchPredictionView') -Force:$Force)
    [void](Set-AIPSAIKeyHandler $script:Config.shortcuts.forceShell 'PSAIForceShell' {
        $line = Get-AICurrentBuffer
        if ($line) { Set-AILastSubmittedCommand $line; $script:NextReadLineAction = 'ForceShell' }
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    } @('CharacterSearch') -Force:$Force)
    if ($script:Config.shortcuts.openSettings) {
        [void](Set-AIPSAIKeyHandler $script:Config.shortcuts.openSettings 'PSAISettings' {
            Set-AICurrentBuffer 'Open-PSAISettings'; $script:NextReadLineAction = 'ForceShell'; [void]$script:InternalHistoryLines.Add('Open-PSAISettings'); [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
        } @() -Force:$Force)
    }
    if ($script:Config.shortcuts.selectModel) {
        [void](Set-AIPSAIKeyHandler $script:Config.shortcuts.selectModel 'PSAIModels' {
            Set-AICurrentBuffer 'Open-PSAIModelSelector'; $script:NextReadLineAction = 'ForceShell'; [void]$script:InternalHistoryLines.Add('Open-PSAIModelSelector'); [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
        } @() -Force:$Force)
    }
    [void](Set-AIPSAIKeyHandler $script:Config.shortcuts.explainLast 'PSAIExplain' {
        Update-AILastSubmittedFromHistory
        Set-AICurrentBuffer 'Show-PSAIResultExplanation'; $script:NextReadLineAction = 'ForceShell'; [void]$script:InternalHistoryLines.Add('Show-PSAIResultExplanation'); [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    } @() -Force:$Force)
    $script:PSReadLineIntegrated = $true
}

function Unregister-AIPSReadLineIntegration {
    if (-not $script:PSReadLineIntegrated) { return }
    foreach ($key in @($script:BoundKeys)) {
        $current = Get-AIPSReadLineKeyHandler $key
        if (-not $current -or $current.Function -notlike 'PSAI*') { continue }
        $original = $script:OriginalKeyBindings[$key]
        if ($original) { Set-PSReadLineKeyHandler -Key $key -Function $original }
        else { Remove-PSReadLineKeyHandler -Chord $key -ErrorAction SilentlyContinue }
    }
    $currentHistoryHandler = (Get-PSReadLineOption).AddToHistoryHandler
    if ([object]::ReferenceEquals($currentHistoryHandler, $script:PSAIAddToHistoryHandler)) {
        Set-PSReadLineOption -AddToHistoryHandler $script:OriginalAddToHistoryHandler
    }
    $currentReadLine = Get-Command PSConsoleHostReadLine -CommandType Function -ErrorAction SilentlyContinue
    if ($script:OriginalPSConsoleHostReadLine -and $currentReadLine -and
        [object]::ReferenceEquals($currentReadLine.ScriptBlock, $script:PSAIHostReadLine)) {
        Set-Item -LiteralPath Function:\global:PSConsoleHostReadLine -Value $script:OriginalPSConsoleHostReadLine
    }
    $script:BoundKeys.Clear()
    $script:OriginalKeyBindings.Clear()
    $script:InternalHistoryLines.Clear()
    $script:PendingInvocationScripts.Clear()
    $script:NextPendingInvocationId = $null
    $script:NextReadLineAction = $null
    $script:PSAIHostReadLine = $null
    $script:OriginalPSConsoleHostReadLine = $null
    $script:PSAIAddToHistoryHandler = $null
    $script:OriginalAddToHistoryHandler = $null
    $script:PSReadLineIntegrated = $false
}

function Enable-PSAIPredictor {
    [CmdletBinding()] param()
    if (-not $script:OfficialIntegrationAvailable) {
        throw '当前宿主不支持 PowerShell 预测器；请在 PowerShell 7.4 或更高版本中使用此功能。'
    }
    Invoke-AIConfigMutation { $script:Config.integrations.predictor = $true }
    try {
        [PSAITerminal.AITerminalOfficialIntegration]::RegisterPredictor()
        $script:PredictorEnabled = $true
    } catch {
        Invoke-AIConfigMutation { $script:Config.integrations.predictor = $false }
        throw
    }
}

function Disable-PSAIPredictor {
    [CmdletBinding()] param()
    if (-not $script:OfficialIntegrationAvailable) {
        throw '当前宿主不支持 PowerShell 预测器；共享配置未被修改。'
    }
    [PSAITerminal.AITerminalOfficialIntegration]::UnregisterPredictor()
    $script:PredictorEnabled = $false
    try { Invoke-AIConfigMutation { $script:Config.integrations.predictor = $false } }
    catch {
        [PSAITerminal.AITerminalOfficialIntegration]::RegisterPredictor()
        $script:PredictorEnabled = $true
        throw
    }
}

function Get-AIShortcutStatus {
    $definitions = @(
        [pscustomobject]@{Action='交给 AI';Key=[string]$script:Config.shortcuts.forceAI;Expected='PSAIForceAI'},
        [pscustomobject]@{Action='强制 Shell';Key=[string]$script:Config.shortcuts.forceShell;Expected='PSAIForceShell'},
        [pscustomobject]@{Action='切换模式';Key=[string]$script:Config.shortcuts.cycleMode;Expected='PSAICycleMode'},
        [pscustomobject]@{Action='解释命令';Key=[string]$script:Config.shortcuts.explainLast;Expected='PSAIExplain'}
    )
    foreach ($definition in $definitions) {
        $actual = $null
        try {
            $handler = Get-AIPSReadLineKeyHandler $definition.Key
            if ($handler) { $actual = [string]$handler.Function }
        } catch { Write-Verbose "无法检查快捷键 $($definition.Key)：$($_.Exception.Message)" }
        [pscustomobject]@{
            Action = $definition.Action
            Key = $definition.Key
            Expected = $definition.Expected
            Actual = $actual
            Active = ($actual -eq $definition.Expected)
        }
    }
}

function Test-AIProfileIntegration {
    try {
        if (-not (Test-Path -LiteralPath $PROFILE.CurrentUserCurrentHost)) { return $false }
        (Read-AITextFile $PROFILE.CurrentUserCurrentHost) -match '(?m)^# PSAITerminal 自动加载（开始）$'
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
        $hasCredential = $activeModel.protocol -eq 'Ollama' -or [bool](Get-AISecret ([string]$activeModel.name))
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

function Get-AIProfileUpdate([string]$Content, [AllowNull()][string]$Block) {
    $knownRepair = $false
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
                    [regex]::Matches($candidate, [regex]::Escape($endText)).Count -eq 1) {
                    $Content = $candidate; $knownRepair = $true
                }
            }
        }
    }
    $markerPattern = '(?m)(?:^|(?<=\$\())# PSAITerminal 自动加载（(?<Kind>开始|结束)）\r?$(?:\n)?'
    $markers = @([regex]::Matches($Content, $markerPattern))
    if ($markers.Count -eq 0) {
        if ($null -eq $Block) { return [pscustomobject]@{ Content = $Content; RepairNeeded = $false } }
        $separator = if ($Content -and -not $Content.EndsWith("`n")) { [Environment]::NewLine } else { '' }
        return [pscustomobject]@{
            Content = $Content + $separator + $Block.TrimEnd("`r", "`n") + [Environment]::NewLine
            RepairNeeded = $false
        }
    }
    $depth = 0; $maximumDepth = 0; $rangeStart = -1
    $ranges = [Collections.Generic.List[object]]::new()
    foreach ($marker in $markers) {
        if ($marker.Groups['Kind'].Value -eq '开始') {
            if ($depth -eq 0) { $rangeStart = $marker.Index }
            $depth++; $maximumDepth = [Math]::Max($maximumDepth, $depth)
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
    if ($null -ne $Block) { $updated = $updated.Insert($ranges[0].Start, $Block.TrimEnd("`r", "`n") + [Environment]::NewLine) }
    [pscustomobject]@{ Content = $updated; RepairNeeded = $knownRepair -or $markers.Count -ne 2 -or $maximumDepth -ne 1 }
}

function Install-PSAIProfileIntegration {
    [CmdletBinding(SupportsShouldProcess)] param()
    $path = $PROFILE.CurrentUserCurrentHost
    $start = '# PSAITerminal 自动加载（开始）'; $end = '# PSAITerminal 自动加载（结束）'
    $content = if (Test-Path -LiteralPath $path) { Read-AITextFile $path } else { '' }
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
        $profileUpdate = Get-AIProfileUpdate $content $block
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
    $content = Read-AITextFile $path
    $updated = (Get-AIProfileUpdate $content $null).Content
    if ($updated -ne $content -and $PSCmdlet.ShouldProcess($path, '移除 PSAITerminal 自动加载')) {
        [PSAITerminal.AITerminalAtomicFile]::WriteAllText($path, $updated)
    }
}

Initialize-AIState
Initialize-AISessionState

if ($script:OfficialIntegrationAvailable -and $script:Config.integrations.feedbackProvider) {
    [PSAITerminal.AITerminalOfficialIntegration]::RegisterFeedback(); $script:FeedbackEnabled = $true
}
if ($script:OfficialIntegrationAvailable -and $script:Config.integrations.predictor) {
    [PSAITerminal.AITerminalOfficialIntegration]::RegisterPredictor(); $script:PredictorEnabled = $true
}
Register-AIPSReadLineIntegration
Register-AIPromptIntegration
if ($script:Config.activeModel -and $Host.Name -eq 'ConsoleHost' -and
    -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) {
    $configuredModel = $script:Config.models[[string]$script:Config.activeModel]
    if ($configuredModel -and $configuredModel.protocol -ne 'Ollama' -and -not (Get-AISecret ([string]$configuredModel.name))) {
        $detail = if ($script:LastSecretStoreError) { "系统密钥库无法读取：$script:LastSecretStoreError" }
            else { '缺少 API Key' }
        Write-Warning "PSAITerminal 模型 '$($configuredModel.name)' $detail。输入 ai，在模型详情中选择【编辑配置】后更新。"
    }
}
if (-not $script:ConfigLoadFailed -and -not [bool]$script:Config.onboardingShown -and $Host.Name -eq 'ConsoleHost' -and
    -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) {
    Write-AIColoredHost (Get-AIText 'LoadedGuide') DarkCyan
    $script:Config.onboardingShown = $true
    try { Save-AIConfig }
    catch {
        $script:Config.onboardingShown = $false
        Write-Warning "无法保存首次使用状态：$($_.Exception.Message)"
    }
}
$ExecutionContext.SessionState.Module.OnRemove = {
    Unregister-AIPSReadLineIntegration
    Unregister-AIPromptIntegration
    if ($script:OfficialIntegrationAvailable) {
        [PSAITerminal.AITerminalOfficialIntegration]::UnregisterAll()
    }
}

Set-Alias -Name Configure-PSAI -Value Open-PSAISettings -Scope Script

Export-ModuleMember -Function @(
    'Enable-PSAITerminal','Disable-PSAITerminal','Get-PSAITerminalMode','Set-PSAITerminalMode',
    'Get-PSAITerminalOption','Set-PSAITerminalOption','Open-PSAISettings','Open-PSAIModelSelector',
    'New-PSAIModel','Get-PSAIModel','Set-PSAIModel','Select-PSAIModel','Remove-PSAIModel','Test-PSAIModel',
    'New-PSAISession','Get-PSAISession','Select-PSAISession','Clear-PSAISession',
    'Start-PSAIRun','Get-PSAIRun','Resume-PSAIRun','Resolve-PSAIRun','Stop-PSAIRun',
    'Start-PSAIToolExecution','Complete-PSAIToolExecution','Start-PSAIAutoFallback',
    'Invoke-PSAI','Invoke-PSAIAutoCompletion','Show-PSAIResultExplanation','Enable-PSAIPredictor','Disable-PSAIPredictor',
    'Get-PSAIIntegrationStatus','Test-PSAIConfiguration','Install-PSAIProfileIntegration','Uninstall-PSAIProfileIntegration'
) -Alias @('Configure-PSAI')
