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

# 从模块源码（主 psm1 与 Private/*.ps1）中取出函数定义文本，供探针脚本单独加载待测函数。
function Get-PSAISourceFunctionText([Parameter(Mandatory)][string]$Name) {
    $moduleDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'module'
    $sourceFiles = @(Join-Path $moduleDirectory 'PSAITerminal.psm1') +
        @(Get-ChildItem -LiteralPath (Join-Path $moduleDirectory 'Private') -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object FullName)
    foreach ($sourceFile in $sourceFiles) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($sourceFile, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw "模块源码解析失败：$sourceFile" }
        $node = $ast.Find({ param($candidate)
            $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq $Name
        }, $false)
        if ($node) { return $node.Extent.Text }
    }
    throw "模块源码中找不到函数：$Name"
}
