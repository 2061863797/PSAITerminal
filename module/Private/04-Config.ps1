# 配置管理、原子读写与并发乐观锁。

function Get-AIUserHomeDirectory {
    $path = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($path)) { $path = $HOME }
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-PSAIPathFullyQualified $path)) {
        throw '无法确定当前用户主目录。'
    }
    [IO.Path]::GetFullPath($path)
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

function Resolve-AIStorageOverride([string]$Value, [string]$VariableName) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if (-not (Test-PSAIPathFullyQualified $Value)) {
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
        schemaVersion = 3
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
    $stored = ConvertFrom-AIJson (Read-PSAITextFile $Path -Utf8Only)
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
    Assert-AIIntegerValue $Candidate.schemaVersion 3 3 '配置版本'
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
    $candidate.schemaVersion = 3
    $candidate.shortcutPresetVersion = 4
    foreach ($model in @($candidate.models.Values)) {
        if ($model -isnot [Collections.IDictionary]) { continue }
        if ($model.capabilities -is [Collections.IDictionary]) { $model.capabilities = ConvertTo-AICapabilities $model.capabilities }
        if (Update-AILegacyModel $model) { $script:ConfigMigrated = $true }
    }
    Assert-AIConfigCandidate $candidate
    $candidate
}

# 1.0.x 的 OpenAIResponses、GeminiNative、Ollama 模型迁移到 OpenAI 兼容接口。
function Update-AILegacyModel([Collections.IDictionary]$Model) {
    $protocol = [string]$Model.protocol
    if ($protocol -notin @('OpenAIResponses','GeminiNative','Ollama')) { return $false }
    $uri = [uri][string]$Model.endpoint
    $base = $uri.GetLeftPart([UriPartial]::Authority) + $uri.AbsolutePath.TrimEnd('/')
    if ($protocol -eq 'GeminiNative') {
        if ($base -notmatch '/v\d+[a-z0-9]*$') { $base += '/v1beta' }
        $Model.endpoint = "$base/openai"
        $Model.modelId = ([string]$Model.modelId) -replace '^models/', ''
    } elseif ($protocol -eq 'Ollama') {
        $Model.endpoint = $base -replace '/api$', ''
    }
    if ($protocol -ne 'OpenAIResponses') { $Model.parameters = [ordered]@{} }
    $Model.protocol = 'OpenAIChat'
    Write-Warning "PSAITerminal 已把模型 '$($Model.name)' 从 $protocol 迁移到 OpenAI 兼容接口：$($Model.endpoint)"
    $true
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
        $loaded = ConvertFrom-AIJson (Read-PSAITextFile $script:ConfigPath -Utf8Only)
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
    if ($script:ShortcutMigrated -or $script:ConfigMigrated) {
        try { Save-AIConfig }
        catch { Write-Warning "配置已在当前会话迁移，但暂时无法写入磁盘；下次启动会重试：$($_.Exception.Message)" }
    }
    $script:SecretMaskingCacheInitialized = $false
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
