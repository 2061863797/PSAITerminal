# 模型配置的增删改查、远程模型列表与连通性测试。

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
