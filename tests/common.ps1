# 回归测试共用的断言、合成数据与模拟服务。只定义函数，没有副作用，可被各测试脚本点源。

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message`n预期：$Expected`n实际：$Actual" }
}

function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw $Message }
}

function Assert-Match([AllowNull()][string]$Value, [string]$Pattern, [string]$Message) {
    if ($Value -notmatch $Pattern) { throw "$Message`n实际：$Value" }
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    try { & $Action; throw $Message }
    catch { if ($_.Exception.Message -eq $Message -or $_.Exception.Message -notmatch $Pattern) { throw } }
}

function New-FixtureSecureString {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText','',Justification='仅使用固定合成测试值，不读取真实密钥。')]
    param([ValidateSet('probe-secret','session-only-secret')][string]$Value)
    ConvertTo-SecureString $Value -AsPlainText -Force
}

function Start-AIMockServer([string[]]$Responses) {
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = ([Net.IPEndPoint]$probe.LocalEndpoint).Port
    $probe.Stop()
    $responseJson = ConvertTo-Json -InputObject @($Responses) -Compress
    $jobStarter = if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) { 'Start-ThreadJob' } else { 'Start-Job' }
    $job = & $jobStarter -ArgumentList $port,$responseJson -ScriptBlock {
        param($Port, $ResponseJson)
        $responses = [Collections.Generic.List[string]]::new()
        foreach ($decodedResponse in ($ResponseJson | ConvertFrom-Json)) { $responses.Add([string]$decodedResponse) }
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        'READY'
        try {
            foreach ($payload in $responses) {
                $client = $listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $buffer = [byte[]]::new(2097152)
                    $total = 0; $headerEnd = -1; $contentLength = 0
                    while ($total -lt $buffer.Length) {
                        $read = $stream.Read($buffer, $total, $buffer.Length - $total)
                        if ($read -le 0) { break }
                        $total += $read
                        if ($headerEnd -lt 0) {
                            $headerText = [Text.Encoding]::ASCII.GetString($buffer, 0, $total)
                            $headerEnd = $headerText.IndexOf("`r`n`r`n", [StringComparison]::Ordinal)
                            if ($headerEnd -ge 0 -and $headerText -match '(?im)^Content-Length:\s*(\d+)') { $contentLength = [int]$Matches[1] }
                        }
                        if ($headerEnd -ge 0 -and $total -ge ($headerEnd + 4 + $contentLength)) { break }
                    }
                    $statusCode = 200; $statusText = 'OK'; $responsePayload = [string]$payload; $extraHeaders = ''
                    $splitLength = 0; $splitDelayMilliseconds = 0
                    # 像真实服务一样校验请求：messages 必须是非空 JSON 数组，否则返回 400。
                    $requestError = $null
                    if ($headerEnd -ge 0 -and $contentLength -gt 0) {
                        $bodyLength = [Math]::Min($contentLength, $total - $headerEnd - 4)
                        try {
                            $requestJson = [Text.Encoding]::UTF8.GetString($buffer, $headerEnd + 4, $bodyLength) | ConvertFrom-Json -ErrorAction Stop
                            if ($requestJson.PSObject.Properties['messages'] -and
                                ($requestJson.messages -isnot [array] -or $requestJson.messages.Count -eq 0)) {
                                $requestError = 'messages: Input should be a valid non-empty list'
                            }
                        } catch { $requestError = "request body is not valid JSON: $($_.Exception.Message)" }
                    }
                    if ($requestError) {
                        $responsePayload = "__STATUS_400__{`"error`":{`"message`":`"$($requestError.Replace('"', "'"))`"}}"
                    }
                    if ($responsePayload -match '^__STATUS_(\d{3})__(.*)$') {
                        $statusCode = [int]$Matches[1]
                        $statusText = if ($statusCode -eq 429) { 'Too Many Requests' } else { 'Test Error' }
                        $responsePayload = $Matches[2]
                    } elseif ($responsePayload -match '^__REDIRECT__(.+)$') {
                        $statusCode = 302; $statusText = 'Found'; $extraHeaders = "Location: $($Matches[1])`r`n"; $responsePayload = ''
                    } elseif ($responsePayload -match '(?s)^__SPLIT_(\d+)_(\d+)__(.*)$') {
                        $splitDelayMilliseconds = [int]$Matches[1]
                        $splitLength = [int]$Matches[2]
                        $responsePayload = $Matches[3]
                    }
                    $body = [Text.Encoding]::UTF8.GetBytes($responsePayload)
                    if ($splitLength -lt 0 -or $splitLength -gt $body.Length) { throw '分段响应位置无效。' }
                    $header = [Text.Encoding]::ASCII.GetBytes(
                        "HTTP/1.1 $statusCode $statusText`r`n${extraHeaders}Content-Type: text/event-stream`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
                    $stream.Write($header, 0, $header.Length)
                    if ($splitLength -gt 0) {
                        $stream.Write($body, 0, $splitLength)
                        $stream.Flush()
                        Start-Sleep -Milliseconds $splitDelayMilliseconds
                        $stream.Write($body, $splitLength, $body.Length - $splitLength)
                    } else {
                        $stream.Write($body, 0, $body.Length)
                    }
                    $stream.Flush()
                    $client.Client.Shutdown([Net.Sockets.SocketShutdown]::Send)
                } finally { $client.Dispose() }
            }
        } finally { $listener.Stop() }
    }
    for ($index=0; $index -lt 100; $index++) {
        Start-Sleep -Milliseconds 20
        $output = Receive-Job $job -Keep | Out-String
        if ($output -match 'READY') { return [pscustomobject]@{Port=$port;Job=$job} }
        if ($job.State -in @('Failed','Completed')) { throw "模拟服务启动失败：$output" }
    }
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    throw '模拟服务启动超时。'
}

function Stop-AIMockServer($Server) {
    if (-not $Server) { return }
    if ($Server.Port) {
        try {
            $closer = [Net.Sockets.TcpClient]::new()
            $async = $closer.BeginConnect([Net.IPAddress]::Loopback, [int]$Server.Port, $null, $null)
            [void]$async.AsyncWaitHandle.WaitOne(50)
            $closer.Dispose()
        } catch { Write-Verbose '测试服务器已关闭，不需要建立清理连接。' }
    }
    Stop-Job $Server.Job -ErrorAction SilentlyContinue
    Remove-Job $Server.Job -Force -ErrorAction SilentlyContinue
}

function Start-AIStallingServer {
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $probe.Start(); $port = ([Net.IPEndPoint]$probe.LocalEndpoint).Port; $probe.Stop()
    $jobStarter = if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) { 'Start-ThreadJob' } else { 'Start-Job' }
    $job = & $jobStarter -ArgumentList $port -ScriptBlock {
        param($Port)
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
        $listener.Start(); 'READY'
        try {
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $buffer = [byte[]]::new(65536)
                $total = 0
                $headerEnd = -1
                while ($headerEnd -lt 0 -and $total -lt $buffer.Length) {
                    $read = $stream.Read($buffer, $total, $buffer.Length - $total)
                    if ($read -le 0) { break }
                    $total += $read
                    $requestText = [Text.Encoding]::ASCII.GetString($buffer, 0, $total)
                    $headerEnd = $requestText.IndexOf("`r`n`r`n", [StringComparison]::Ordinal)
                }
                if ($headerEnd -lt 0) { throw '停滞服务未收到完整请求头。' }
                if ($requestText -match '(?im)^Expect:\s*100-continue') {
                    $continue = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
                    $stream.Write($continue, 0, $continue.Length)
                }
                $headers = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/event-stream`r`nConnection: close`r`n`r`n")
                $stream.Write($headers, 0, $headers.Length)
                $stream.Flush()
                Start-Sleep -Seconds 3
            } finally { $client.Dispose() }
        }
        finally { $listener.Stop() }
    }
    for ($index=0; $index -lt 100; $index++) {
        Start-Sleep -Milliseconds 20
        if ((Receive-Job $job -Keep | Out-String) -match 'READY') { return [pscustomobject]@{Port=$port;Job=$job} }
    }
    Stop-AIMockServer ([pscustomobject]@{Job=$job}); throw '停滞服务启动超时。'
}

# 生成 OpenAI 兼容的流式响应，供模拟服务返回文本或一次 powershell 工具调用。
function ConvertTo-AIMockSse([string]$Text, $ToolArguments, [string]$ToolCallId = 'call-1') {
    $delta = [ordered]@{}
    if ($Text) { $delta.content = $Text }
    if ($null -ne $ToolArguments) {
        $arguments = if ($ToolArguments -is [string]) { $ToolArguments } else { $ToolArguments | ConvertTo-Json -Depth 20 -Compress }
        $delta.tool_calls = @(@{index=0;id=$ToolCallId;function=@{name='powershell';arguments=$arguments}})
    }
    $finish = if ($null -ne $ToolArguments) { 'tool_calls' } else { 'stop' }
    $chunk = @{choices=@(@{delta=$delta;finish_reason=$finish})} | ConvertTo-Json -Depth 20 -Compress
    "data: $chunk`r`n`r`ndata: [DONE]`r`n`r`n"
}

# 生成 Anthropic Messages 流式响应：文本块或一次 powershell tool_use。
function ConvertTo-AIMockAnthropicSse([string]$Text, $ToolArguments) {
    $events = [Collections.Generic.List[object]]::new()
    $events.Add(@{type='message_start';message=@{usage=@{input_tokens=1;output_tokens=0}}})
    if ($Text) {
        $events.Add(@{type='content_block_start';index=0;content_block=@{type='text';text=''}})
        $events.Add(@{type='content_block_delta';index=0;delta=@{type='text_delta';text=$Text}})
    }
    if ($null -ne $ToolArguments) {
        $events.Add(@{type='content_block_start';index=1;content_block=@{type='tool_use';id='toolu_1';name='powershell';input=@{}}})
        $events.Add(@{type='content_block_delta';index=1;delta=@{type='input_json_delta';partial_json=($ToolArguments | ConvertTo-Json -Depth 20 -Compress)}})
    }
    $events.Add(@{type='message_delta';usage=@{output_tokens=1}})
    $events.Add(@{type='message_stop'})
    ($events | ForEach-Object { "event: $($_.type)`r`ndata: $($_ | ConvertTo-Json -Depth 20 -Compress)`r`n`r`n" }) -join ''
}