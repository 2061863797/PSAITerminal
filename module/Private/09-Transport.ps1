# REST HTTP 客户端、请求体构造与 SSE 流式解析。

function Resolve-AIRequestEndpoint([Collections.IDictionary]$Model) {
    [PSAITerminal.AITerminalEndpointResolver]::ResolveRequestEndpoint([string]$Model.protocol, [uri][string]$Model.endpoint).AbsoluteUri
}

# 本机环回地址上的服务（Ollama、LM Studio 等）可以不配置 API Key。
function Test-AIApiKeyOptional([AllowNull()][string]$Endpoint) {
    if ([string]::IsNullOrWhiteSpace($Endpoint)) { return $false }
    try { ([uri]$Endpoint).IsLoopback } catch { $false }
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
    if ($Protocol -eq 'Anthropic') {
        $Request.Headers.Add('anthropic-version', '2023-06-01')
        if ($Secret) { $Request.Headers.Add('x-api-key', $Secret) }
    } elseif ($Secret) {
        $Request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Secret)
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

function New-AIPowerShellToolSchema {
    [ordered]@{
        type = 'object'
        properties = [ordered]@{
            command = @{type='string';description='One complete PowerShell command to run in the user''s current session.'}
            purpose = @{type='string';description='One short sentence explaining why, in the user''s language.'}
        }
        required = @('command','purpose')
        additionalProperties = $false
    }
}
function Add-AIToolsToRequestBody([Collections.IDictionary]$Body, [string]$Protocol) {
    $schema = New-AIPowerShellToolSchema
    $description = 'Run one PowerShell command in the user''s local session after the user approves it. Use only when you need to inspect or change the machine.'
    if ($Protocol -eq 'Anthropic') {
        $Body.tools = @(@{name='powershell';description=$description;input_schema=$schema})
    } else {
        $Body.tools = @(@{type='function';function=@{name='powershell';description=$description;parameters=$schema}})
    }
}

function Get-AIRuntimeContextText {
    $lang = Get-AILanguage
    $location = try { [string]$ExecutionContext.SessionState.Path.CurrentLocation } catch { '' }
    if ([string]::IsNullOrWhiteSpace($location)) {
        $location = try { [Environment]::CurrentDirectory } catch { '' }
    }
    $isAdmin = try {
        ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }

    $hostDesc = if ($script:HostEdition -eq 'Desktop') { "Windows PowerShell $($script:HostVersion)" } else { "PowerShell $($script:HostVersion)" }
    $syntaxRule = if ($script:HostEdition -eq 'Desktop') {
        if ($lang -eq 'en-US') {
            'Running on Windows PowerShell 5.1. Do NOT use &&, ||, ternary operator (?:), or ?? operator. Separate multiple commands using newlines or semicolons (;).'
        } else {
            '当前宿主为 Windows PowerShell 5.1。严禁使用 &&、|| 管道连接符，严禁使用三元运算符 ?: 或 ?? 空值合并操作符；多条命令必须用换行或分号 ; 分隔。'
        }
    } else {
        if ($lang -eq 'en-US') {
            'Running on PowerShell 7+. Modern PowerShell syntax is supported.'
        } else {
            '当前宿主为 PowerShell 7+。支持现代 PowerShell 语法。'
        }
    }

    if ($lang -eq 'en-US') {
        @"
[Runtime Environment]
- Host: $hostDesc
- Working Directory: $location
- Elevated (Admin): $isAdmin
- Syntax Constraints: $syntaxRule
"@
    } else {
        @"
[运行时环境]
- 宿主：$hostDesc
- 当前目录：$location
- 管理员权限：$(if($isAdmin){'是'}else{'否'})
- 语法约束：$syntaxRule
"@
    }
}

function ConvertTo-AIProtocolMessages([Collections.IList]$StandardMessages, [string]$Protocol, [string]$SystemPrompt) {
    switch ($Protocol) {
        'Anthropic' {
            $list = [Collections.Generic.List[object]]::new()
            foreach ($item in $StandardMessages) {
                $role = if ([string]$item.role -eq 'assistant') { 'assistant' } else { 'user' }
                $content = [string]$item.content
                if ($list.Count -gt 0 -and $list[$list.Count - 1].role -eq $role) {
                    $list[$list.Count - 1].content += "`n`n$content"
                } else {
                    $list.Add([ordered]@{ role = $role; content = $content })
                }
            }
            if ($list.Count -gt 0 -and $list[0].role -ne 'user') {
                $list.Insert(0, [ordered]@{ role = 'user'; content = 'Hello' })
            }
            return $list
        }
        default {
            $list = [Collections.Generic.List[object]]::new()
            if ($SystemPrompt) {
                $list.Add([ordered]@{ role = 'system'; content = $SystemPrompt })
            }
            foreach ($item in $StandardMessages) {
                $role = if ([string]$item.role -eq 'assistant') { 'assistant' } else { 'user' }
                $content = [string]$item.content
                $list.Add([ordered]@{ role = $role; content = $content })
            }
            return $list
        }
    }
}

function New-AIRequestBody([Collections.IDictionary]$Model, [AllowNull()][string]$Prompt = $null,
    [switch]$EnableTools, [AllowNull()][Collections.IList]$Messages = $null) {
    $english = (Get-AILanguage) -eq 'en-US'
    $baseSystem = if ($EnableTools -and $english) {
        @"
You are a terminal assistant inside the user's local PowerShell session. Reply in English. Never request or reveal API keys.
1. The input may be a question, a request to do something, or a mistyped PowerShell command. Answer questions directly in text without tools.
2. To inspect or change the machine, call the powershell tool with exactly one command and a one-sentence purpose. Never write JSON in the message text instead of calling the tool.
3. Prefer the shortest direct native command; no needless loops, formatting, or separator lines.
4. Tool results tell you whether the command succeeded and what it printed. Continue from the real result. On failure, state the cause in one sentence before proposing a fix. When done, confirm the outcome in one or two sentences.
5. If the user rejects a command, follow their feedback and do not repeat the same command.
"@
    } elseif ($EnableTools) {
        @"
你是运行在用户本地 PowerShell 会话中的终端助手。用简体中文回答；不要请求或输出 API Key。
1. 用户的输入可能是问题、操作请求，或写错的 PowerShell 命令。只需要回答的问题直接用文字回答，不调用工具。
2. 需要查看或改变本机状态时，调用 powershell 工具，每次只提议一条命令，并用一句话填写 purpose。不要在正文里写 JSON 代替工具调用。
3. 优先使用最短、最直接的原生命令，不加多余的循环、格式化或分隔线。
4. 工具结果会说明命令是否成功以及输出。根据真实结果继续；失败时先用一句话说明原因再提出修正命令；完成后用一两句话确认结果，不要长篇总结。
5. 用户拒绝某条命令时，按用户的反馈调整，不要重复同一条命令。
"@
    } elseif ($english) {
        @"
You are an assistant inside the user's local PowerShell session. Reply in English. Never request or reveal API keys.
Answer directly and concisely. When a command helps, show the shortest direct PowerShell command in a ```powershell block; you cannot run it yourself.
"@
    } else {
        @"
你是运行在用户本地 PowerShell 会话中的助手。用简体中文回答；不要请求或输出 API Key。
直接、简洁地回答。需要命令时，在 ```powershell 代码块中给出最短、最直接的 PowerShell 命令；你不能自己执行命令。
"@
    }
    $runtimeContext = Get-AIRuntimeContextText
    $system = "$baseSystem`n`n$runtimeContext"
    $protocol = [string]$Model.protocol
    $hasMessages = ($null -ne $Messages -and $Messages.Count -gt 0)

    if (-not $hasMessages) { $Messages = @([ordered]@{role='user';content=$Prompt}) }
    # @() 防止合并后只剩一条消息时 PowerShell 把列表展开成单个字典，序列化成 JSON 对象而不是数组。
    $protocolMessages = @(ConvertTo-AIProtocolMessages $Messages $protocol $system)
    $body = if ($protocol -eq 'Anthropic') {
        [ordered]@{model=$Model.modelId;max_tokens=4096;system=$system;messages=$protocolMessages;stream=$true}
    } else {
        [ordered]@{model=$Model.modelId;messages=$protocolMessages;stream=$true}
    }
    if ($Model.parameters -is [Collections.IDictionary]) {
        foreach ($entry in $Model.parameters.GetEnumerator()) {
            if ([string]$entry.Key -notin @('model','messages','system','tools','stream')) {
                $body[[string]$entry.Key] = $entry.Value
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
        [Parameter()][string]$Prompt,
        [switch]$NoRender,
        [switch]$EnableTools,
        [AllowNull()][string]$SecretOverride,
        [AllowNull()][Collections.IList]$Messages = $null,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None
    )
    $endpoint = Resolve-AIRequestEndpoint $Model
    $secret = if ($PSBoundParameters.ContainsKey('SecretOverride')) { $SecretOverride } else { Get-AISecret ([string]$Model.name) }
    if (-not $secret -and -not (Test-AIApiKeyOptional ([string]$Model.endpoint))) { throw "模型 '$($Model.name)' 没有可用 API Key。" }
    $json = if ($Messages -and $Messages.Count -gt 0) {
        New-AIRequestBody $Model -Messages $Messages -EnableTools:$EnableTools | ConvertTo-Json -Depth 50 -Compress
    } else {
        New-AIRequestBody $Model -Prompt $Prompt -EnableTools:$EnableTools | ConvertTo-Json -Depth 50 -Compress
    }
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
    $toolProposalText = if ($EnableTools) { [Text.StringBuilder]::new() } else { $null }
    $parsed = 0
    $responseState = [ordered]@{Terminal=$false;InputTokens=0L;OutputTokens=0L}
    $first = $true
    $toolCalls = [ordered]@{}
    $sanitizer = [PSAITerminal.AITerminalStreamingTextSanitizer]::new()
    $reader = $null
    try {
        $reader = [IO.StreamReader]::new(
            [PSAITerminal.AITerminalHttpContent]::ReadStream($response.Content, $requestToken))
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
                    # message_delta 携带最终输出用量。
                    $finalUsage = Get-AIProperty $chunk 'usage'
                    if ($type -eq 'message_delta' -and $finalUsage) { $responseState.OutputTokens=[long](Get-AIProperty $finalUsage 'output_tokens') }
                }
            }
            if ($delta) {
                # 工具正文按原文校验；显示清洗不能悄悄改变待执行命令。
                if ($null -ne $toolProposalText) {
                    if ($toolProposalText.Length + ([string]$delta).Length -gt 1MB) { throw '模型工具正文超过 1 MiB 上限。' }
                    [void]$toolProposalText.Append([string]$delta)
                }
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
        if ($reader) { $reader.Dispose() }
        $response.Dispose(); $request.Dispose(); $client.Dispose(); $linkedSource.Dispose(); $timeoutSource.Dispose(); $secret=$null
    }
    if ($parsed -eq 0) { throw '模型流式响应中没有可解析的数据。' }
    if (-not $responseState.Terminal) {
        if ($text.Length -gt 0 -or $toolCalls.Count -gt 0) {
            Write-Verbose '模型流式响应在连接正常关闭前未包含显式完成标记，按已接收内容正常返回。'
            $responseState.Terminal = $true
        } else {
            throw '模型流式响应在完成标志之前中断。'
        }
    }
    if ($text.Length -eq 0 -and $toolCalls.Count -eq 0) { throw '模型没有返回文本或工具调用。' }
    [pscustomobject]@{Text=$text.ToString();ToolProposalText=$(if($null -ne $toolProposalText){$toolProposalText.ToString()}else{$null});ToolCalls=@($toolCalls.Values);InputTokens=[long]$responseState.InputTokens;OutputTokens=[long]$responseState.OutputTokens}
}
