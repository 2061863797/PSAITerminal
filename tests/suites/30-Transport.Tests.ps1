# 地址与控制字符、风险分级、工具 Schema 与 SSE 流解析。
# 由 tests/run.ps1 在同一作用域内按文件名顺序点源执行，依赖其中的 $module、$testRoot 等状态，不能单独运行。

# 地址、控制字符、风险和工具 Schema。
$cases = @(
    @('OpenAIChat','https://api.example.com','https://api.example.com/v1/chat/completions'),
    @('OpenAIChat','https://api.example.com/v1','https://api.example.com/v1/chat/completions'),
    @('OpenAIResponses','https://api.example.com/openai','https://api.example.com/openai/v1/responses'),
    @('OpenAIResponses','https://api.example.com/openai/v1/','https://api.example.com/openai/v1/responses')
)
foreach ($case in $cases) {
    $actual = [PSAITerminal.AITerminalEndpointResolver]::ResolveRequestEndpoint($case[0],[uri]$case[1]).AbsoluteUri
    Assert-Equal $case[2] $actual 'OpenAI 地址解析错误。'
}
$sanitizer = [PSAITerminal.AITerminalStreamingTextSanitizer]::new()
$escapeCharacter = [char]27
$clean = $sanitizer.Sanitize("ok$($escapeCharacter)]0;bad") + $sanitizer.Sanitize("title`aEND")
Assert-Equal 'okEND' $clean '跨分片 OSC 控制序列必须被清理。'
$sanitizer.Reset(); Assert-Equal 'AB' ($sanitizer.Sanitize("A$([char]0x9b)31mB")) 'C1 CSI 不能残留参数文本。'
$sanitizer.Reset(); $charsetClean=$sanitizer.Sanitize("A$($escapeCharacter)(")+$sanitizer.Sanitize('BB'); Assert-Equal 'AB' $charsetClean '跨分片 ESC 中间序列必须整体移除。'
$env:NO_COLOR='1'; try { Assert-Equal $false (& $module { Test-AIColorEnabled }) 'NO_COLOR 必须关闭模块颜色。' } finally { Remove-Item Env:NO_COLOR }
$protected = [PSAITerminal.AITerminalSecurity]::ProtectText("Authorization: Bearer secret$($escapeCharacter)[31m",[string[]]@('secret'),65536)
Assert-True ($protected -notmatch 'secret|\x1b') '保存前必须脱敏并移除 ANSI。'
$truncated = [PSAITerminal.AITerminalSecurity]::ProtectText(('x' * 70000),$null,65536)
Assert-True ($truncated.Length -le 65536 -and $truncated.EndsWith('[输出已截断]')) '步骤输出必须在 64 KiB 内安全截断。'
Assert-Equal 'High' ([string][PSAITerminal.AITerminalSecurity]::ClassifyRisk('powershell','Remove-Item x')) '删除命令必须为高风险。'
Assert-Equal 'High' ([string][PSAITerminal.AITerminalSecurity]::ClassifyRisk('powershell','cp source target')) 'Copy-Item 标准别名必须按高风险处理。'
Assert-Equal 'High' ([string][PSAITerminal.AITerminalSecurity]::ClassifyRisk('powershell','ni target')) 'New-Item 标准别名必须按写操作评为高风险。'
Assert-Equal 'High' ([string][PSAITerminal.AITerminalSecurity]::ClassifyRisk('powershell','custom-command target')) '未知命令必须使用保守的高风险等级。'
Assert-Equal 'High' ([string][PSAITerminal.AITerminalSecurity]::ClassifyRisk('powershell','Write-EventLog -LogName Application -Source X -EventId 1 -Message X')) '非白名单 Write 命令不能被误判为只读。'
Assert-Equal 'High' ([string][PSAITerminal.AITerminalSecurity]::ClassifyRisk('powershell','git clean -fdx')) '未知原生命令必须默认为高风险。'
Assert-Equal 'High' ([string][PSAITerminal.AITerminalSecurity]::ClassifyRisk('powershell','$env:PATH = ''changed''')) '变量和环境赋值必须按写操作评为高风险。'
Assert-Equal 'Low' ([string][PSAITerminal.AITerminalSecurity]::ClassifyRisk('powershell','Get-Date')) '已知只读 Cmdlet 应保持低风险。'
$customAliasRisk = & $module {
    Set-Alias -Name Get-PSAIReviewDelete -Value Remove-Item -Scope Local
    try { [string](Get-AICommandRisk 'Get-PSAIReviewDelete target') }
    finally { Remove-Item Alias:\Get-PSAIReviewDelete -ErrorAction SilentlyContinue }
}
Assert-Equal 'High' $customAliasRisk '当前会话中的自定义别名必须解析到真实命令后分级。'
$shadowedFunctionRisk = & $module {
    function Get-PSAIReviewDate { Get-Date }
    try { [string](Get-AICommandRisk 'Get-PSAIReviewDate') }
    finally { Remove-Item Function:\Get-PSAIReviewDate -ErrorAction SilentlyContinue }
}
Assert-Equal 'High' $shadowedFunctionRisk '名称像只读命令的函数也必须按高风险处理。'

$bodyRows = & $module {
    foreach ($protocol in $script:ValidProtocols) {
        $model = @{protocol=$protocol;modelId='model';parameters=@{}}
        $body = New-AIRequestBody $model 'hello' -EnableTools
        $systemText = if ($protocol -eq 'OpenAIChat') { [string]$body.messages[0].content } else { '' }
        [pscustomobject]@{Protocol=$protocol;HasTools=($null -ne $body.tools);SystemText=$systemText}
    }
}
Assert-Equal 5 @($bodyRows | Where-Object HasTools).Count '五种协议都必须生成原生工具定义。'
Assert-Match ([string]($bodyRows | Where-Object Protocol -eq 'OpenAIChat').SystemText) 'Reply in English' '默认英文设置也必须要求模型使用英文回答。'
$chineseSystemText = & $module {
    $previousLanguage = $script:Config.language
    try {
        $script:Config.language = 'zh-CN'
        $model = @{protocol='OpenAIChat';modelId='model';parameters=@{}}
        [string](New-AIRequestBody $model '你好').messages[0].content
    } finally { $script:Config.language = $previousLanguage }
}
Assert-Match $chineseSystemText '简体中文' '切换中文后必须要求模型使用简体中文回答。'
Assert-Throws { & $module { ConvertFrom-AIToolCall @{name='powershell';arguments=@{purpose='p';command='exit';expectedOutcome='e';sideEffects='s';rollbackHint='r'}} } } '不能包含 exit' 'Agent 控制流命令必须被拒绝。'

# SSE id 字段、无空行兼容和 OpenAI 流解析。
$openAIStream = "id:1`r`ndata: {`"choices`":[{`"delta`":{`"content`":`"he`"},`"finish_reason`":null}]}`r`nid:2`r`ndata: {`"choices`":[{`"delta`":{`"content`":`"llo`"},`"finish_reason`":`"stop`"}]}`r`n"
$server = Start-AIMockServer @($openAIStream)
try {
    $streamResult = & $module { param($port)
        $model=[ordered]@{name='mock';protocol='OpenAIChat';endpoint="http://127.0.0.1:$port";modelId='mock';parameters=@{};capabilities=@{streaming=$true;toolCalling=$true;usage=$false}}
        Invoke-AIModelText -Model $model -Prompt hi -NoRender -SecretOverride key
    } $server.Port
    Assert-Equal 'hello' $streamResult.Text 'SSE id 字段不应被当作 JSON 解析。'
} finally { Stop-AIMockServer $server }

$firstStreamEvent = "data: {`"choices`":[{`"delta`":{`"content`":`"he`"},`"finish_reason`":null}]}`r`n`r`n"
$lastStreamEvent = "data: {`"choices`":[{`"delta`":{`"content`":`"llo`"},`"finish_reason`":`"stop`"}]}`r`n`r`n"
$splitLength = [Text.Encoding]::UTF8.GetByteCount($firstStreamEvent)
$server = Start-AIMockServer @("__SPLIT_700_${splitLength}__$firstStreamEvent$lastStreamEvent")
try {
    $streamTiming = & $module { param($port)
        $originalWriter = (Get-Command Write-AIStreamText -CommandType Function).ScriptBlock
        $script:StreamProbeTimes = [Collections.Generic.List[long]]::new()
        $script:StreamProbeStopwatch = [Diagnostics.Stopwatch]::StartNew()
        try {
            Set-Item -Path function:Write-AIStreamText -Value {
                param([string]$Text, [switch]$First)
                [void]$Text; [void]$First
                $script:StreamProbeTimes.Add($script:StreamProbeStopwatch.ElapsedMilliseconds)
            }
            $model=[ordered]@{name='mock';protocol='OpenAIChat';endpoint="http://127.0.0.1:$port";modelId='mock';parameters=@{};capabilities=@{streaming=$true;toolCalling=$true;usage=$false}}
            $result = Invoke-AIModelText -Model $model -Prompt hi -SecretOverride key
            [pscustomobject]@{
                Text = $result.Text
                FirstRenderMilliseconds = $script:StreamProbeTimes[0]
                TotalMilliseconds = $script:StreamProbeStopwatch.ElapsedMilliseconds
            }
        } finally {
            Set-Item -Path function:Write-AIStreamText -Value $originalWriter
            Remove-Variable -Name StreamProbeTimes,StreamProbeStopwatch -Scope Script -ErrorAction SilentlyContinue
        }
    } $server.Port
    Assert-Equal 'hello' $streamTiming.Text '分段流式响应必须保持完整文本。'
    Assert-True (($streamTiming.TotalMilliseconds - $streamTiming.FirstRenderMilliseconds) -ge 350) '首段文本必须在服务器发送完成事件前渲染。'
} finally { Stop-AIMockServer $server }

$server = Start-AIMockServer @('__STATUS_429__{"error":"rate"}',$openAIStream)
try {
    $retried = & $module { param($port)
        $model=[ordered]@{name='mock';protocol='OpenAIChat';endpoint="http://127.0.0.1:$port";modelId='mock';parameters=@{};capabilities=@{streaming=$true;toolCalling=$true;usage=$false}}
        Invoke-AIModelText -Model $model -Prompt hi -NoRender -SecretOverride key
    } $server.Port
    Assert-True ($null -ne $retried.PSObject.Properties['Text']) "429 重试必须只返回模型结果对象。实际类型：$($retried.GetType().FullName)；内容：$($retried | Out-String)"
    Assert-Equal 'hello' $retried.Text '429 应在流开始前重试并成功。'
} finally { Stop-AIMockServer $server }

$server = Start-AIMockServer @("data: not-json`r`n`r`n")
try {
    Assert-Throws { & $module { param($port)
        $model=[ordered]@{name='mock';protocol='OpenAIChat';endpoint="http://127.0.0.1:$port";modelId='mock';parameters=@{};capabilities=@{streaming=$true;toolCalling=$true;usage=$false}}
        Invoke-AIModelText -Model $model -Prompt hi -NoRender -SecretOverride key
    } $server.Port } '无法解析的流数据' '畸形流必须明确失败。'
} finally { Stop-AIMockServer $server }

$unusedProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$unusedProbe.Start(); $unusedPort = ([Net.IPEndPoint]$unusedProbe.LocalEndpoint).Port; $unusedProbe.Stop()
$redirectSource = Start-AIMockServer @("__REDIRECT__http://127.0.0.1:$unusedPort/v1/chat/completions")
try {
    Assert-Throws { & $module { param($port)
        $model=[ordered]@{name='mock';protocol='OpenAIChat';endpoint="http://127.0.0.1:$port";modelId='mock';parameters=@{};capabilities=@{streaming=$true;toolCalling=$true;usage=$false}}
        Invoke-AIModelText -Model $model -Prompt hi -NoRender -SecretOverride key
    } $redirectSource.Port } 'HTTP 302' '带凭据的模型请求不能自动跟随重定向。'
} finally { Stop-AIMockServer $redirectSource }

$singlePlan = [ordered]@{mode='Single';steps=@('读取日期');completionCondition='显示日期'}
$normalizedArguments = [ordered]@{purpose='读取日期';command='Get-Date';expectedOutcome='显示日期';sideEffects='无';rollbackHint='无需回滚';plan=$singlePlan;stepIndex=1;stepRole='Operation';afterSuccess='Complete'} | ConvertTo-Json -Depth 10 -Compress
$responsesAdded = @{type='response.output_item.added';item=@{type='function_call';id='item-1';call_id='call-1';name='powershell';arguments=''}} | ConvertTo-Json -Compress
$responsesDone = @{type='response.function_call_arguments.done';item_id='item-1';arguments=$normalizedArguments} | ConvertTo-Json -Compress
$responsesCompleted = @{type='response.completed';response=@{usage=@{input_tokens=2;output_tokens=3}}} | ConvertTo-Json -Compress
$anthropicStart = @{type='content_block_start';index=0;content_block=@{type='tool_use';id='call-1';name='powershell';input=@{}}} | ConvertTo-Json -Compress
$anthropicDelta = @{type='content_block_delta';index=0;delta=@{type='input_json_delta';partial_json=$normalizedArguments}} | ConvertTo-Json -Compress
$anthropicStop = @{type='message_stop'} | ConvertTo-Json -Compress
$geminiPayload = @{candidates=@(@{finishReason='STOP';content=@{parts=@(@{functionCall=@{name='powershell';args=($normalizedArguments | ConvertFrom-Json)}})}});usageMetadata=@{promptTokenCount=2;candidatesTokenCount=3}} | ConvertTo-Json -Depth 20 -Compress
$protocolFixtures = @(
    @{Protocol='OpenAIResponses';Payload="data: $responsesAdded`r`n`r`ndata: $responsesDone`r`n`r`ndata: $responsesCompleted`r`n`r`n"},
    @{Protocol='Anthropic';Payload="data: $anthropicStart`r`n`r`ndata: $anthropicDelta`r`n`r`ndata: $anthropicStop`r`n`r`n"},
    @{Protocol='GeminiNative';Payload="data: $geminiPayload`r`n`r`n"}
)
foreach ($fixture in $protocolFixtures) {
    $server = Start-AIMockServer @([string]$fixture.Payload)
    try {
        try {
            $toolResult = & $module { param($port,$protocol)
                $model=[ordered]@{name='mock';protocol=$protocol;endpoint="http://127.0.0.1:$port";modelId='mock';parameters=@{};capabilities=@{streaming=$true;toolCalling=$true;usage=$false}}
                Invoke-AIModelText -Model $model -Prompt hi -NoRender -EnableTools -SecretOverride key
            } $server.Port $fixture.Protocol
        } catch { throw "$($fixture.Protocol) 流解析失败：$($_.Exception.Message)`n$($_.ScriptStackTrace)" }
        Assert-Equal 1 @($toolResult.ToolCalls).Count "$($fixture.Protocol) 必须解析原生工具调用。"
        try { $proposal = & $module { param($call) ConvertFrom-AIToolCall $call } $toolResult.ToolCalls[0] }
        catch { throw "$($fixture.Protocol) 工具参数解析失败：$($_.Exception.Message)；原始参数：$($toolResult.ToolCalls[0].arguments)" }
        Assert-Equal 'Get-Date' $proposal.command "$($fixture.Protocol) 工具参数归一化失败。"
    } finally { Stop-AIMockServer $server }
}

$server = Start-AIStallingServer
try {
    $cancellation = [Threading.CancellationTokenSource]::new(150)
    try {
        Assert-Throws { & $module { param($port,$token)
            $model=[ordered]@{name='mock';protocol='OpenAIChat';endpoint="http://127.0.0.1:$port";modelId='mock';parameters=@{};capabilities=@{streaming=$true;toolCalling=$true;usage=$false}}
            Invoke-AIModelText -Model $model -Prompt hi -NoRender -SecretOverride key -CancellationToken $token
        } $server.Port $cancellation.Token } 'cancel|取消|canceled' '模型请求必须响应取消令牌。'
    } finally { $cancellation.Dispose() }
} finally { Stop-AIMockServer $server }

$waitMethods = @([PSAITerminal.AITerminalHttpContent].GetMethods([Reflection.BindingFlags]'NonPublic,Static') |
    Where-Object Name -eq 'WaitWithCancellationAsync')
Assert-Equal 1 $waitMethods.Count '取消清理测试必须找到唯一的底层等待方法。'
$waitMethod = $waitMethods[0]
$genericWaitMethod = $waitMethod.MakeGenericMethod([type[]]@([IO.MemoryStream]))
$completion = [Threading.Tasks.TaskCompletionSource[IO.MemoryStream]]::new(
    [Threading.Tasks.TaskCreationOptions]::RunContinuationsAsynchronously)
$abandonedStream = [IO.MemoryStream]::new([byte[]](1,2,3))
$cancelledWait = [Threading.CancellationTokenSource]::new()
try {
    $cancelledWait.Cancel()
    $waitTask = $genericWaitMethod.Invoke($null, [object[]]@($completion.Task, $cancelledWait.Token))
    Assert-Throws { $waitTask.GetAwaiter().GetResult() } 'cancel|取消|canceled' '底层异步读取必须立即响应取消令牌。'
    $completion.SetResult($abandonedStream)
    for ($index = 0; $index -lt 100 -and $abandonedStream.CanRead; $index++) { Start-Sleep -Milliseconds 10 }
    Assert-Equal $false $abandonedStream.CanRead '取消后才完成的底层流必须由观察任务释放。'
} finally {
    $cancelledWait.Dispose()
    $abandonedStream.Dispose()
}
