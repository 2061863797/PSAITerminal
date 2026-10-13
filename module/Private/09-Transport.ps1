# REST HTTP 客户端、请求体构造与 SSE 流式解析。

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

function New-AIPowerShellToolSchema {
    [ordered]@{
        type = 'object'
        properties = [ordered]@{
            purpose = @{type='string';description='执行这条命令的目的'}
            command = @{type='string';description='完整的 PowerShell 命令'}
            expectedOutcome = @{type='string';description='预期结果'}
            sideEffects = @{type='string';description='可能副作用，没有则写“无”'}
            rollbackHint = @{type='string';description='回滚方法；不可回滚时明确说明'}
            plan = @{type='object';properties=[ordered]@{
                mode=@{type='string';enum=@('Single','Multi')}
                steps=@{type='array';items=@{type='string'};description='按执行顺序列出步骤摘要；需要验证产物时保留验证步骤'}
                completionCondition=@{type='string';description='任务完成的可检验条件'}
            };required=@('mode','steps','completionCondition');additionalProperties=$false}
            stepIndex = @{type='integer';description='所属计划步骤，从 1 开始'}
            stepRole = @{type='string';enum=@('Operation','Verify','Cleanup','Retry')}
            afterSuccess = @{type='string';enum=@('Complete','Observe')}
        }
        required = @('purpose','command','expectedOutcome','sideEffects','rollbackHint','plan','stepIndex','stepRole','afterSuccess')
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
        'GeminiNative' {
            $list = [Collections.Generic.List[object]]::new()
            foreach ($item in $StandardMessages) {
                $role = if ([string]$item.role -eq 'assistant') { 'model' } else { 'user' }
                $content = [string]$item.content
                if ($list.Count -gt 0 -and $list[$list.Count - 1].role -eq $role) {
                    $list[$list.Count - 1].parts[0].text += "`n`n$content"
                } else {
                    $list.Add([ordered]@{ role = $role; parts = @(@{ text = $content }) })
                }
            }
            if ($list.Count -gt 0 -and $list[0].role -ne 'user') {
                $list.Insert(0, [ordered]@{ role = 'user'; parts = @(@{ text = 'Hello' }) })
            }
            return $list
        }
        'OpenAIResponses' {
            $lines = [Collections.Generic.List[string]]::new()
            foreach ($item in $StandardMessages) {
                $prefix = if ([string]$item.role -eq 'assistant') { 'AI' } else { 'User' }
                $lines.Add("[$prefix] $($item.content)")
            }
            return ($lines -join "`n`n")
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
    $baseSystem = if ((Get-AILanguage) -eq 'en-US') {
        if ($EnableTools) {
            @"
You are an autonomous terminal agent running in the user's local PowerShell session. Reply in English. Do not assume a cloud server exists. Never request or reveal API keys.

[Agent Operating Rules]
1. Tool Invocation: When executing commands, diagnosing errors with corrective commands, or inspecting the system, you MUST invoke the `powershell` tool call. Never output raw JSON tool parameter blocks in message text to substitute for tool calls.
2. Explanations & Recovery: When recovering from a failed step or diagnosing syntax errors, explain the root cause clearly in plain text, then invoke the `powershell` tool with the corrective step.
3. Simplicity First: When commands are required, prefer the shortest, most direct native PowerShell command. Never overcomplicate commands with unnecessary loops, multi-tier pipelines, redundant variables, custom Format-Table styling, or extra Write-Host dividers.
4. Respect User Intent: Keep commands minimal and focused directly on the user's goal.
"@
        } else {
            @"
You are an assistant running in the user's local PowerShell session. Reply in English. Do not assume a cloud server exists. Never request or reveal API keys.

[Core Operating Rules]
1. Direct Answers: For natural language inquiries (greetings, conceptual questions, syntax explanations, general text), reply directly with a clear and natural explanation in English.
2. Code Correction: If the user asks to explain or fix code, directly diagnose the root cause, provide the corrected command in a ```powershell ... ``` block, and give practical advice.
3. Simplicity First: When commands are required, prefer the shortest, most direct native PowerShell command. Never overcomplicate commands with unnecessary loops, multi-tier pipelines, redundant variables, custom Format-Table styling, or extra Write-Host dividers.
4. Respect User Input: Keep explanations clear, direct, and concise.
"@
        }
    } else {
        if ($EnableTools) {
            @"
你是运行在用户本地 PowerShell 中的终端智能体。用简体中文回答；不要假设存在云服务器；不要请求或输出 API Key。

[智能体操作准则]
1. 工具调用：当需要执行命令、验证结果或提出修复指令时，必须通过 API 提供的 `powershell` 工具调用发起，严禁在正文纯文本中输出 JSON 代码块来替代工具调用。
2. 解释与诊断：在失败恢复或诊断代码时，在正文中用简明纯文本解释核心原因，同时必须通过 `powershell` 工具调用提出执行或修复步骤。
3. 极简命令优先：优先输出单行、最少、最直接的原生 PowerShell 命令。严禁无必要的复杂化包装（严禁随意添加循环、多层管道、冗余变量、自定义 Format-Table 拼接或多余的 Write-Host 分隔线）。如果一条简单原生命令即可完成，直接给出该命令。
4. 尊重用户原意：保持命令精简，紧密围绕用户目标，不要无意义地将其重写为多行复杂脚本。
"@
        } else {
            @"
你是运行在用户本地 PowerShell 中的助手。用简体中文回答；不要假设存在云服务器；不要请求或输出 API Key。

[核心操作准则]
1. 问答直接：针对自然语言输入（日常问候、概念咨询、语法解释或纯文本疑问），直接给出清晰自然的中文解答；不要在桌面上搜索文件或执行任何无意义命令。
2. 纠错与修改建议：如果用户输入的代码存在语法错误、命令拼写错误或运行异常，清晰分析核心错误原因，直接给出【修改后的正确指令】和简要优化建议，严禁将原命令过度复杂化。
3. 极简命令优先：当确实需要操作本机时，优先输出单行、最少、最直接的原生 PowerShell 命令。严禁无必要的复杂化包装（严禁随意添加循环、多层管道、冗余变量、自定义 Format-Table 拼接或多余的 Write-Host 分隔线）。如果一条简单原生命令即可完成，直接给出该命令。
4. 尊重用户原意：如果用户输入本身就是一段清晰的命令，仅在需要诊断或按要求调整时处理，不要无意义地将其重写为多行复杂脚本。
"@
        }
    }
    $runtimeContext = Get-AIRuntimeContextText
    $system = "$baseSystem`n`n$runtimeContext"
    $protocol = [string]$Model.protocol
    $hasMessages = ($null -ne $Messages -and $Messages.Count -gt 0)

    $body = if ($hasMessages) {
        $protocolMessages = ConvertTo-AIProtocolMessages $Messages $protocol $system
        switch ($protocol) {
            'Anthropic' { [ordered]@{model=$Model.modelId;max_tokens=4096;system=$system;messages=$protocolMessages;stream=$true} }
            'OpenAIChat' { [ordered]@{model=$Model.modelId;messages=$protocolMessages;stream=$true} }
            'OpenAIResponses' { [ordered]@{model=$Model.modelId;instructions=$system;input=$protocolMessages;stream=$true} }
            'GeminiNative' { [ordered]@{systemInstruction=@{parts=@(@{text=$system})};contents=$protocolMessages} }
            'Ollama' { [ordered]@{model=$Model.modelId;messages=$protocolMessages;stream=$true} }
        }
    } else {
        switch ($protocol) {
            'Anthropic' { [ordered]@{model=$Model.modelId;max_tokens=4096;system=$system;messages=@(@{role='user';content=$Prompt});stream=$true} }
            'OpenAIChat' { [ordered]@{model=$Model.modelId;messages=@(@{role='system';content=$system},@{role='user';content=$Prompt});stream=$true} }
            'OpenAIResponses' { [ordered]@{model=$Model.modelId;instructions=$system;input=$Prompt;stream=$true} }
            'GeminiNative' { [ordered]@{systemInstruction=@{parts=@(@{text=$system})};contents=@(@{role='user';parts=@(@{text=$Prompt})})} }
            'Ollama' { [ordered]@{model=$Model.modelId;messages=@(@{role='system';content=$system},@{role='user';content=$Prompt});stream=$true} }
        }
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
        [Parameter()][string]$Prompt,
        [switch]$NoRender,
        [switch]$EnableTools,
        [AllowNull()][string]$SecretOverride,
        [AllowNull()][Collections.IList]$Messages = $null,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None
    )
    $endpoint = Resolve-AIRequestEndpoint $Model
    $secret = if ($Model.protocol -eq 'Ollama') { $null } elseif ($PSBoundParameters.ContainsKey('SecretOverride')) { $SecretOverride } else { Get-AISecret ([string]$Model.name) }
    if ($Model.protocol -ne 'Ollama' -and -not $secret) { throw "模型 '$($Model.name)' 没有可用 API Key。" }
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
    $toolItemMap = @{}
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
