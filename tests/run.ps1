Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$releaseVersion = ([version](Import-PowerShellDataFile -LiteralPath (Join-Path $root 'module/PSAITerminal.psd1')).ModuleVersion).ToString()
$releaseLabel = if ([string]::IsNullOrWhiteSpace($env:PSAI_RELEASE_LABEL)) {
    $releaseVersion
} else {
    [string]$env:PSAI_RELEASE_LABEL
}
if ($releaseLabel -ne $releaseVersion -and
    $releaseLabel -notmatch ('^' + [regex]::Escape($releaseVersion) + '-[0-9A-Za-z]+(?:-[0-9A-Za-z]+)*$')) {
    throw "测试发布标签无效：$releaseLabel"
}
$moduleOutput = Join-Path $root "out/PSAITerminal-$releaseLabel"
$modulePath = Join-Path $moduleOutput 'PSAITerminal.psd1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("PSAITerminal.Tests." + [guid]::NewGuid().ToString('N'))
$env:PSAI_CONFIG_HOME = Join-Path $testRoot 'config'
$env:PSAI_DATA_HOME = Join-Path $testRoot 'data'
$isWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
[void][IO.Directory]::CreateDirectory($testRoot)

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

try {
    if (-not (Test-Path -LiteralPath $modulePath)) { throw "测试模块不存在：$modulePath" }
    Import-Module $modulePath -Force
    $module = Get-Module PSAITerminal
    $helpNames = @((Get-Help about_PSAITerminal -ErrorAction Stop).Name)
    Assert-True ($helpNames -contains 'about_PSAITerminal') '发布包必须提供可发现的简体中文帮助主题。'
    $readme = [IO.File]::ReadAllText((Join-Path $moduleOutput 'README.md'), [Text.Encoding]::UTF8)
    $moduleSource = [IO.File]::ReadAllText((Join-Path $moduleOutput 'PSAITerminal.psm1'), [Text.Encoding]::UTF8)
    Assert-Match $readme '\| Windows \| `<Documents>/PowerShell/PSAITerminal` \| `%LOCALAPPDATA%/PowerShell/PSAITerminal` \|' 'Windows 文档必须使用实际的 PSAITerminal 配置目录名。'
    Assert-True $readme.Contains("当前 ``$releaseVersion`` 发布仅支持 Windows PowerShell 5.1") '文档必须明确当前版本的双宿主 Windows 支持范围。'
    Assert-Equal $false $readme.Contains('适用于 Windows、Linux 和 macOS') '文档不能把未验收的平台列为当前支持范围。'
    Assert-Match $readme '不是自动回滚功能' '文档必须明确说明 AI 的回滚提示不会自动恢复系统状态。'
    Assert-Equal $false $moduleSource.Contains('foreach ($payload in (Read-AIStreamPayloads') '流式响应不能先在括号中完整缓冲。'

    $credentialTarget = 'PSAITerminal/Test/' + [guid]::NewGuid().ToString('N')
    $credentialValue = 'cross-platform-secret-' + [guid]::NewGuid().ToString('N')
    try {
        if ([PSAITerminal.PlatformCredentialStore]::IsAvailable) {
            $credentialPersisted = $false
            try {
                [PSAITerminal.PlatformCredentialStore]::Set($credentialTarget, $credentialValue)
                $credentialPersisted = $true
            } catch {
                Assert-Match $_.Exception.Message 'Credential|登录会话|密钥|凭据' 'Windows 凭据管理器不可写时必须返回明确错误。'
            }
            if ($credentialPersisted) {
                Assert-Equal $credentialValue ([PSAITerminal.PlatformCredentialStore]::Get($credentialTarget)) '平台密钥库必须原样读取已保存密钥。'
                [PSAITerminal.PlatformCredentialStore]::Remove($credentialTarget)
                Assert-Equal $null ([PSAITerminal.PlatformCredentialStore]::Get($credentialTarget)) '平台密钥库删除后不能再返回密钥。'
            }
        } else {
            Assert-Throws { [PSAITerminal.PlatformCredentialStore]::Set($credentialTarget, $credentialValue) } '.+' '密钥库不可用时持久保存必须明确失败。'
            Assert-Equal $null ([PSAITerminal.PlatformCredentialStore]::Get($credentialTarget)) '密钥库不可用时读取应安全返回空。'
        }
    } finally {
        try { [PSAITerminal.PlatformCredentialStore]::Remove($credentialTarget) } catch {}
    }

    $limitedContent = [Net.Http.StringContent]::new('12345')
    try {
        Assert-Equal '12345' ([PSAITerminal.AITerminalHttpContent]::ReadString($limitedContent, 5, [Threading.CancellationToken]::None)) '有限 HTTP 读取应返回完整短响应。'
    } finally { $limitedContent.Dispose() }
    $oversizedContent = [Net.Http.StringContent]::new('123456')
    try {
        Assert-Throws { [PSAITerminal.AITerminalHttpContent]::ReadString($oversizedContent, 5, [Threading.CancellationToken]::None) } '超过 5 个字符' 'HTTP 内容超过上限时必须失败。'
    } finally { $oversizedContent.Dispose() }

    $lineBytes = [Text.Encoding]::UTF8.GetBytes("alpha`nbeta")
    $lineStream = [IO.MemoryStream]::new($lineBytes)
    $lineReader = [IO.StreamReader]::new($lineStream)
    try {
        Assert-Equal 'alpha' ([PSAITerminal.AITerminalHttpContent]::ReadLine($lineReader, [Threading.CancellationToken]::None)) '兼容流读取必须返回第一行。'
        Assert-Equal 'beta' ([PSAITerminal.AITerminalHttpContent]::ReadLine($lineReader, [Threading.CancellationToken]::None)) '兼容流读取必须返回末行。'
        $lineCancellation = [Threading.CancellationTokenSource]::new()
        try {
            $lineCancellation.Cancel()
            Assert-Throws { [PSAITerminal.AITerminalHttpContent]::ReadLine($lineReader, $lineCancellation.Token) } 'cancel|取消|canceled' '兼容流读取必须响应取消令牌。'
        } finally { $lineCancellation.Dispose() }
    } finally { $lineReader.Dispose(); $lineStream.Dispose() }

    $streamContent = [Net.Http.StringContent]::new('stream-ok')
    $contentStream = $null
    $contentReader = $null
    try {
        $contentStream = [PSAITerminal.AITerminalHttpContent]::ReadStream($streamContent, [Threading.CancellationToken]::None)
        $contentReader = [IO.StreamReader]::new($contentStream)
        Assert-Equal 'stream-ok' $contentReader.ReadToEnd() '兼容 HTTP 流入口必须返回完整内容。'
    } finally {
        if ($contentReader) { $contentReader.Dispose() }
        elseif ($contentStream) { $contentStream.Dispose() }
        $streamContent.Dispose()
    }

    $sendClient = [Net.Http.HttpClient]::new()
    $sendRequest = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, 'http://127.0.0.1:1/')
    $sendCancellation = [Threading.CancellationTokenSource]::new()
    try {
        $sendCancellation.Cancel()
        Assert-Throws {
            [void][PSAITerminal.AITerminalHttpTransport]::Send(
                $sendClient, $sendRequest, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $sendCancellation.Token)
        } 'cancel|取消|canceled' '兼容 HTTP 发送入口必须在两个宿主中可调用并响应取消令牌。'
    } finally { $sendCancellation.Dispose(); $sendRequest.Dispose(); $sendClient.Dispose() }

    $collector = [PSAITerminal.AITerminalBoundedTextCollector]::new(64)
    $collector.Append('a' * 200)
    $boundedText = $collector.GetText()
    Assert-True ($boundedText.Length -le 64 -and $boundedText.EndsWith('[输出已截断]')) '有界输出收集器必须在收集过程中限制内存并标记截断。'
    $exactCollector = [PSAITerminal.AITerminalBoundedTextCollector]::new(64)
    $exactCollector.Append('b' * 64)
    Assert-Equal ('b' * 64) $exactCollector.GetText() '刚好达到上限的输出不能被提前截断。'
    $exactCollector.Append('c')
    Assert-True ($exactCollector.GetText().Length -le 64 -and $exactCollector.GetText().EndsWith('[输出已截断]')) '超过上限后必须为截断标记腾出空间。'

    $lockTarget = Join-Path $testRoot 'lock-probe/state.json'
    $firstLock = [PSAITerminal.AITerminalAtomicFile]::AcquireLock($lockTarget, 1000)
    try {
        Assert-Throws { [PSAITerminal.AITerminalAtomicFile]::AcquireLock($lockTarget, 50).Dispose() } '等待文件锁超时' '同一路径的第二个写入者必须等待或明确超时。'
    } finally { $firstLock.Dispose() }

    # 新安装、配置迁移和确定性路由。
    $config = Get-Content -LiteralPath (Join-Path $env:PSAI_CONFIG_HOME 'config.json') -Raw | ConvertFrom-Json
    Assert-Equal 2 $config.schemaVersion '配置必须写为 schemaVersion 2。'
    Assert-Equal 'en-US' $config.language '新安装必须默认使用英文界面。'
    Assert-Equal 'en-US' (Get-PSAITerminalOption).Language '公开设置必须返回当前界面语言。'
    Set-PSAITerminalOption -Language zh-CN | Out-Null
    Assert-Equal 'zh-CN' ((Get-Content -LiteralPath (Join-Path $env:PSAI_CONFIG_HOME 'config.json') -Raw | ConvertFrom-Json).language) '语言修改必须立即持久化，不需要额外保存。'
    Set-PSAITerminalOption -Language en-US | Out-Null
    $moduleSource = Get-Content -LiteralPath (Join-Path $moduleOutput 'PSAITerminal.psm1') -Raw
    Assert-Equal $false ([regex]::IsMatch($moduleSource, '(?<!\$)\(\s*if\b')) 'if 语句作为参数时必须使用 $() 子表达式，不能放入普通圆括号。'
    $menuEntryProbe = & $module {
        $prompts = [Collections.Generic.List[string]]::new()
        function Read-Host {
            param([Parameter(ValueFromRemainingArguments)]$Arguments)
            $prompts.Add(($Arguments -join ' '))
            '0'
        }
        try {
            Open-PSAISettings 6>$null
            Open-AILanguageMenu 6>$null
            [pscustomobject]@{Count=$prompts.Count;Prompts=($prompts -join '|')}
        } finally { Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue }
    }
    Assert-Equal 2 $menuEntryProbe.Count '设置和语言菜单入口必须各读取一次选择后正常返回。'
    Assert-Match $menuEntryProbe.Prompts 'Enter a number.*Select language' '菜单必须把本地化提示作为字符串传给 Read-Host。'
    $configLimitProbe = & $module {
        $previousLimit = $script:MaximumConfigBytes
        $previousRevision = Get-AIRevision $script:Config '配置'
        try {
            $script:MaximumConfigBytes = [int](Get-Item -LiteralPath $script:ConfigPath).Length + 32
            $script:Config['limitProbe'] = 'x' * 1024
            $message = try { Save-AIConfig; '' } catch { $_.Exception.Message }
            [pscustomobject]@{
                Message=$message
                Language=[string]$script:Config.language
                Revision=Get-AIRevision $script:Config '配置'
                PreviousRevision=$previousRevision
            }
        } finally {
            $null = $script:Config.Remove('limitProbe')
            $script:MaximumConfigBytes = $previousLimit
        }
    }
    Assert-Match $configLimitProbe.Message '配置文件超过 \d+ 字节上限' '配置写入端必须执行与读取端对称的大小限制。'
    Assert-Equal 'en-US' $configLimitProbe.Language '配置写入越界后必须回滚内存状态。'
    Assert-Equal $configLimitProbe.PreviousRevision $configLimitProbe.Revision '配置写入越界后必须回滚内存修订号。'
    Assert-Equal 0 @((Get-PSAIModel)).Count '新配置不应自带默认模型。'
    Assert-Equal 1 @((Get-PSAISession)).Count '首次导入应创建一个持久会话。'
    Assert-Equal 'F2' (Get-PSAITerminalOption).Shortcuts.forceAI '强制 AI 快捷键应为 F2。'
    Assert-Equal 'F3' (Get-PSAITerminalOption).Shortcuts.forceShell '强制 Shell 快捷键应为 F3。'
    Assert-Equal (Join-Path $env:PSAI_CONFIG_HOME 'config.json') (Get-PSAITerminalOption).ConfigPath '诊断与设置必须公开当前实际配置路径。'
    $promptPrefixes = & $module {
        $originalMode = $script:Config.mode
        try {
            $script:Config.mode = 'AI'; $ai = Get-AIPromptPrefix
            $script:Config.mode = 'Auto'; $auto = Get-AIPromptPrefix
            $script:Config.mode = 'Off'; $off = Get-AIPromptPrefix
            [pscustomobject]@{AI=$ai;Auto=$auto;Off=$off}
        } finally { $script:Config.mode = $originalMode }
    }
    Assert-Equal '[AI] ' $promptPrefixes.AI 'AI 模式提示符必须在原提示符前显示模式。'
    Assert-Equal '[AUTO] ' $promptPrefixes.Auto 'Auto 模式提示符必须在原提示符前显示模式。'
    Assert-Equal '' $promptPrefixes.Off 'Off 模式不能增加提示符标记。'
    $promptStatus = & $module {
        $previousPrompt = $script:OriginalPrompt
        $previousMode = $script:Config.mode
        try {
            $script:Config.mode = 'Off'
            $script:OriginalPrompt = { if ($?) { 'success' } else { 'failure' } }
            Write-Error 'prompt-status-probe' -ErrorAction Ignore
            Invoke-AIWrappedPrompt
        } finally {
            $script:OriginalPrompt = $previousPrompt
            $script:Config.mode = $previousMode
        }
    }
    Assert-Equal 'failure' $promptStatus 'Prompt 包装器必须把上一条命令的失败状态传给原 Prompt。'
    Assert-Throws { & $module { Resolve-AIStorageOverride 'relative-config' 'PSAI_CONFIG_HOME' } } '必须是完整的绝对路径' '配置覆盖目录必须拒绝相对路径。'
    $absoluteOverride = & $module { param($path) Resolve-AIStorageOverride $path 'PSAI_CONFIG_HOME' } (Join-Path $testRoot 'absolute-config')
    Assert-Equal ([IO.Path]::GetFullPath((Join-Path $testRoot 'absolute-config'))) $absoluteOverride '配置覆盖目录必须规范化为绝对路径。'
    $diagnostics = @(Test-PSAIConfiguration)
    Assert-Equal '' ([string](($diagnostics | Where-Object Check -eq 'PSReadLine').Action)) '诊断通过时不应继续显示无关修复动作。'
    Assert-Equal $null (Get-Alias ai -ErrorAction SilentlyContinue) 'ai 必须是可被 F3 绕过的 PSReadLine 元命令，不能导出全局 Alias。'
    $keyProbe = & $module {
        $registered = Set-AIPSAIKeyHandler F12 'PSAITest' {} @()
        try { $handler = Get-AIPSReadLineKeyHandler F12; [pscustomobject]@{Registered=$registered;Function=$handler.Function} }
        finally { Remove-PSReadLineKeyHandler -Key F12 -ErrorAction SilentlyContinue; [void]$script:BoundKeys.Remove('F12'); [void]$script:OriginalKeyBindings.Remove('F12') }
    }
    Assert-Equal $true $keyProbe.Registered '未占用快捷键应能注册。'
    Assert-Equal 'PSAITest' $keyProbe.Function '注册后应能从 PSReadLine 查询到处理器。'
    $conflictProbe = & $module {
        Set-PSReadLineKeyHandler -Key F12 -Function AcceptLine
        try {
            $registered = Set-AIPSAIKeyHandler F12 'PSAIConflict' {} @()
            [pscustomobject]@{Registered=$registered;Function=(Get-AIPSReadLineKeyHandler F12).Function}
        } finally { Remove-PSReadLineKeyHandler -Key F12 -ErrorAction SilentlyContinue }
    } 3>$null
    Assert-Equal $false $conflictProbe.Registered '默认不得覆盖已有快捷键。'
    Assert-Equal 'AcceptLine' $conflictProbe.Function '冲突处理器必须保持不变。'

    $defaultBindingProbe = & $module {
        Set-PSReadLineKeyHandler -Key F12 -Function AcceptLine
        try {
            $registered = Set-AIPSAIKeyHandler F12 'PSAITestDefaultBinding' {} @('AcceptLine')
            [pscustomobject]@{Registered=$registered;Function=(Get-AIPSReadLineKeyHandler F12).Function}
        } finally { Remove-PSReadLineKeyHandler -Key F12 -ErrorAction SilentlyContinue; [void]$script:BoundKeys.Remove('F12'); [void]$script:OriginalKeyBindings.Remove('F12') }
    }
    Assert-Equal $true $defaultBindingProbe.Registered 'PSAITerminal 应能替换明确允许的 PSReadLine 默认绑定。'
    Assert-Equal 'PSAITestDefaultBinding' $defaultBindingProbe.Function '替换默认绑定后应注册 PSAITerminal 处理器。'

    $submittedLineProbe = & $module {
        $script:Config.mode = 'AI'
        $script:NextReadLineAction = 'ForceShell'
        $shellLine = ConvertTo-AISubmittedLine "  Write-Output '原文'  "
        $script:NextReadLineAction = 'ForceAI'
        $aiLine = ConvertTo-AISubmittedLine "  完全保留 大小写 '和引号'  "
        [pscustomobject]@{Shell=$shellLine;AI=$aiLine;Last=$script:LastSubmittedCommand.Command}
    }
    Assert-Equal "  Write-Output '原文'  " $submittedLineProbe.Shell '强制 Shell 必须逐字返回用户提交的原文。'
    Assert-Equal "  完全保留 大小写 '和引号'  " $submittedLineProbe.Last '交给 AI 时必须逐字保存用户提交的原文。'
    Assert-Equal '. (Invoke-PSAI)' $submittedLineProbe.AI '读取完成后才可返回不可见的内部调度命令。'
    & $module { $script:Config.mode = 'Off'; $script:PendingInvocationScripts.Clear(); $script:NextPendingInvocationId=$null }

    $routeDirectoryQuestion = & $module { param($line) Test-AIAutoRoute $line } "$testRoot 这个目录里有什么"
    Assert-Equal $true $routeDirectoryQuestion '目录路径加自然语言应交给 AI。'
    $testScript = Join-Path $testRoot 'sample.ps1'
    Set-Content -LiteralPath $testScript -Value "'ok'" -Encoding utf8
    Assert-Equal $false (& $module { param($line) Test-AIAutoRoute $line } $testScript) '存在的脚本路径应直接执行。'

    # 内部 Harness 必须通过短的一次性调度行执行，不能把实现源码泄露到终端。
    $pendingDispatch = & $module { New-AIPendingInvocationLine '$PendingScopeProbe=314; function Invoke-PendingScopeProbe { 271 }' }
    $pendingId = & $module { [string]$script:NextPendingInvocationId }
    Assert-Equal '. (Invoke-PSAI)' $pendingDispatch '终端只能显示固定的公开调度命令。'
    Assert-True ($pendingDispatch.Length -lt 100) '内部调度行应保持简短。'
    Assert-Equal $false $pendingDispatch.Contains("`n") '内部调度行不能包含多行 Harness 源码。'
    Assert-Equal $false $pendingDispatch.Contains('PendingScopeProbe=314') '内部调度行不能泄露待执行脚本。'
    Assert-Equal $false $pendingDispatch.Contains('PendingInvocation') '内部调度行不能显示内部参数名。'
    Assert-Equal $false ($pendingDispatch -match '[a-f0-9]{32}') '内部调度行不能显示一次性令牌。'
    . ([scriptblock]::Create($pendingDispatch))
    Assert-Equal 314 $PendingScopeProbe '一次性调度必须保留调用者顶层变量。'
    Assert-Equal 271 (Invoke-PendingScopeProbe) '一次性调度必须保留调用者顶层函数。'
    Assert-Throws { & $module { param($id) Get-AIPendingInvocationScript $id } $pendingId } '不存在或已经执行' '内部调度令牌不能重复执行。'

    # Auto 包装必须捕获终止错误，并保持顶层状态。
    $wrappedSuccess = & $module { ConvertTo-AIAutoShellLine '$AutoScopeProbe=91; Get-Date | Out-Null' }
    $tokens=$null; $parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseInput($wrappedSuccess,[ref]$tokens,[ref]$parseErrors)
    Assert-Equal 0 @($parseErrors).Count 'Auto 顶层包装必须是有效 PowerShell。'
    . ([scriptblock]::Create($wrappedSuccess))
    Assert-Equal 91 $AutoScopeProbe 'Auto 包装必须保留普通变量赋值。'
    $latest = & $module { $script:LastCommandResult }
    Assert-Equal $true $latest.Succeeded '成功命令的真实状态应被记录。'

    $wrappedFailure = & $module { ConvertTo-AIAutoShellLine "throw 'auto-boom'" }
    $fallbackError = $null
    try { . ([scriptblock]::Create($wrappedFailure)) 2>$null } catch { $fallbackError = $_.Exception.Message }
    $failed = & $module { $script:LastCommandResult }
    Assert-Equal $false $failed.Succeeded '终止错误不能跳过 Auto 完成处理。'
    Assert-Match $failed.Error 'auto-boom' 'Auto 应保存真实终止错误。'
    Assert-Match $fallbackError '尚未配置活动模型' '失败后必须立即尝试交给 AI。'

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

    $normalizedArguments = [ordered]@{purpose='读取日期';command='Get-Date';expectedOutcome='显示日期';sideEffects='无';rollbackHint='无需回滚'} | ConvertTo-Json -Compress
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

    # 模型 CRUD、SessionOnly 回滚和持久化。
    New-PSAIModel -Name local -Protocol Ollama -Endpoint http://127.0.0.1:11434 -ModelId qwen3 | Out-Null
    Assert-Equal 1 @((Get-PSAIModel)).Count '新增模型后应立即可见。'
    Assert-Equal 'local' (Get-PSAIModel -Name local).Name '新增模型名称不一致。'
    Assert-Throws { Get-PSAIModel -Name missing } '模型不存在' '查询不存在模型必须明确报错。'
    Assert-Throws { Set-PSAIModel -Name local -Protocol OpenAIChat } '必须同时提供新的接口地址' '协议切换不应复用旧地址。'

    Assert-Throws { & $module {
        $candidate=Copy-AIConfig;$candidate.shortcuts.forceShell=$candidate.shortcuts.forceAI;Assert-AIConfigCandidate $candidate
    } } '快捷键重复' '重复快捷键必须在保存前被拒绝。'
    Assert-Throws { & $module {
        $candidate=Copy-AIConfig;$candidate.integrations.enterRouting='false';Assert-AIConfigCandidate $candidate
    } } '必须是布尔值' '字符串形式的布尔值不能被误判为开启。'
    Assert-Throws { & $module {
        $candidate=Copy-AIConfig;$candidate.execution.maxAgentSteps='12';Assert-AIConfigCandidate $candidate
    } } '必须是整数' '字符串形式的数字不能混入配置。'
    Assert-Throws { & $module {
        $candidate=Copy-AIConfig;$candidate.execution.maxAgentSteps=12.5;Assert-AIConfigCandidate $candidate
    } } '必须是整数' '小数不能被截断后误判为有效配置。'
    Assert-Throws { & $module {
        Assert-AIModelParameters @{response_format=[pscustomobject]@{type='json_object'}}
    } } '只能使用 JSON' '模型参数必须拒绝不可持久化的 PowerShell 对象。'

    $transactionConfigPath = & $module { $script:ConfigPath }
    $originalMaxSteps = (Get-PSAITerminalOption).Execution.maxAgentSteps
    & $module { $script:ConfigPath=$script:ConfigDirectory }
    Assert-Throws { Set-PSAITerminalMode Auto } 'already exists|文件|directory|目录|access|访问|目标|另一个 PowerShell' '模式写盘失败必须明确报错。'
    Assert-Equal 'Off' (Get-PSAITerminalMode) '模式写盘失败后必须恢复内存状态。'
    Assert-Throws { Set-PSAITerminalOption -MaxAgentSteps 99 } 'already exists|文件|directory|目录|access|访问|目标|另一个 PowerShell' '选项写盘失败必须明确报错。'
    Assert-Equal $originalMaxSteps (Get-PSAITerminalOption).Execution.maxAgentSteps '选项写盘失败后必须恢复内存状态。'
    & $module { param($path) $script:ConfigPath=$path } $transactionConfigPath

    $probeKey = ConvertTo-SecureString 'probe-secret' -AsPlainText -Force
    $server = Start-AIMockServer @('__STATUS_404__{"error":"models unsupported"}',$openAIStream)
    try {
        New-PSAIModel -Name generationOnly -Protocol OpenAIChat -Endpoint "http://127.0.0.1:$($server.Port)" `
            -ModelId mock -ApiKey $probeKey -SessionOnly | Out-Null
        $connection = Test-PSAIModel -Name generationOnly
        $serverFailure = if (-not $connection.Success) {
            "服务器状态：$($server.Job.State)；原因：$($server.Job.ChildJobs[0].JobStateInfo.Reason)；输出：$(Receive-Job $server.Job -Keep 2>&1 | Out-String)"
        } else { '' }
        Assert-Equal $true $connection.Success "模型列表不可用时，真实生成成功仍应通过连接测试。生成错误：$($connection.Error)；$serverFailure"
        Assert-Equal $false $connection.ModelListAvailable '连接测试必须如实报告模型列表不可用。'
        Assert-Match $connection.Warning '无法获取模型列表' '模型列表失败原因应作为非阻断警告返回。'
        Remove-PSAIModel -Name generationOnly -Confirm:$false
    } finally { Stop-AIMockServer $server }

    $sessionKey = ConvertTo-SecureString 'session-only-secret' -AsPlainText -Force
    $secureModelName = 'secure-' + [guid]::NewGuid().ToString('N')
    New-PSAIModel -Name $secureModelName -Protocol OpenAIChat -Endpoint http://127.0.0.1:12345 -ModelId mock -ApiKey $sessionKey -SessionOnly | Out-Null
    $originalConfigPath = & $module { $script:ConfigPath }
    & $module { $script:ConfigPath = $script:ConfigDirectory }
    Assert-Throws { Set-PSAIModel -Name $secureModelName -ModelId changed } 'already exists|文件|directory|目录|access|访问|目标|另一个 PowerShell' '应人为触发保存失败以验证回滚。'
    & $module { param($path) $script:ConfigPath=$path } $originalConfigPath
    Assert-Equal $true (& $module { param($name) $script:SessionSecrets.ContainsKey($name) } $secureModelName) '回滚后密钥仍应是仅当前会话。'
    Assert-Equal $null ([PSAITerminal.PlatformCredentialStore]::Get("PSAITerminal/Model/$secureModelName")) 'SessionOnly 密钥不能被回滚写入系统密钥库。'
    Set-PSAIModel -Name $secureModelName -Protocol Ollama -Endpoint http://127.0.0.1:11434 | Out-Null
    Assert-Equal $false (& $module { param($name) $script:SessionSecrets.ContainsKey($name) } $secureModelName) '切换到 Ollama 必须删除旧协议密钥。'
    $ollamaRequest = [Net.Http.HttpRequestMessage]::new()
    try {
        & $module { param($request) Add-AIAuthenticationHeaders $request 'Ollama' 'must-not-send' } $ollamaRequest
        Assert-Equal $null $ollamaRequest.Headers.Authorization 'Ollama 请求不能携带旧 Bearer 密钥。'
    } finally { $ollamaRequest.Dispose() }
    Remove-PSAIModel -Name $secureModelName -Confirm:$false

    $firstSessionId = (Get-PSAISession | Where-Object Active).Id
    & $module { Add-AISessionTurn 'user' '持久化探针' 'message' | Out-Null }
    Remove-Module PSAITerminal
    Import-Module $modulePath -Force
    $module = Get-Module PSAITerminal
    Assert-Equal $firstSessionId (Get-PSAISession | Where-Object Active).Id '重载后应恢复活动会话。'
    Assert-True ((Get-PSAISession -Id $firstSessionId).TurnCount -gt 0) '会话轮次必须持久化。'

    $sessionConcurrency = & $module {
        $originalSession = $script:CurrentSession
        $session = New-AISessionObject '并发合并测试'
        Save-AISession $session
        $stale = Import-AISession $session.id
        try {
            $script:CurrentSession = $stale
            Add-AISessionTurn 'user' 'terminal-A' 'message' | Out-Null
            $script:CurrentSession = $stale
            Add-AISessionTurn 'user' 'terminal-B' 'message' | Out-Null
            $reloaded = Import-AISession $session.id
            [pscustomobject]@{Count=@($reloaded.turns).Count;Contents=(@($reloaded.turns.content) -join ',')}
        } finally { $script:CurrentSession = $originalSession }
    }
    Assert-Equal 2 $sessionConcurrency.Count '基于旧内存快照追加 Turn 时必须在锁内合并最新会话。'
    Assert-Equal 'terminal-A,terminal-B' $sessionConcurrency.Contents '并发合并不能丢失先写入的 Turn。'

    $sessionUsage = & $module {
        $originalSession = $script:CurrentSession
        $session = New-AISessionObject 'Turn 与 Token 原子写入测试'
        Save-AISession $session
        try {
            $script:CurrentSession = Import-AISession $session.id
            $previousRevision = [long]$script:CurrentSession.revision
            Add-AISessionTurn 'assistant' '计费响应' 'message' @{} -InputTokens 12 -OutputTokens 7 | Out-Null
            $reloaded = Import-AISession $session.id
            [pscustomobject]@{
                RevisionDelta = [long]$reloaded.revision - $previousRevision
                TurnCount = @($reloaded.turns).Count
                InputTokens = [long]$reloaded.inputTokens
                OutputTokens = [long]$reloaded.outputTokens
            }
        } finally { $script:CurrentSession = $originalSession }
    }
    Assert-Equal 1 $sessionUsage.RevisionDelta '追加响应 Turn 和 Token 用量必须只提交一次会话修订。'
    Assert-Equal 1 $sessionUsage.TurnCount '原子写入不能重复追加响应 Turn。'
    Assert-Equal 12 $sessionUsage.InputTokens '输入 Token 必须与响应 Turn 一起持久化。'
    Assert-Equal 7 $sessionUsage.OutputTokens '输出 Token 必须与响应 Turn 一起持久化。'

    $sessionLimit = & $module {
        $session = New-AISessionObject '上限测试'
        Save-AISession $session
        $createdUtc = [DateTime]::UtcNow.ToString('O')
        $session.turns = @(for ($index=0; $index -lt 2001; $index++) {
            [ordered]@{id=('a' * 32);role='user';kind='message';content='x';createdUtc=$createdUtc;metadata=@{}}
        })
        $message = try { Save-AISession $session; '' } catch { $_.Exception.Message }
        $reloaded = Import-AISession $session.id
        [pscustomobject]@{Message=$message;ReloadedCount=@($reloaded.turns).Count}
    }
    Assert-Match $sessionLimit.Message '最多包含 2000' '写入端必须拒绝读取端无法接受的会话 Turn 数。'
    Assert-Equal 0 $sessionLimit.ReloadedCount '越界写入失败后必须保留原有可读取会话。'
    $sessionSizeLimit = & $module {
        $session = New-AISessionObject '大小上限测试'
        Save-AISession $session
        $path = Get-AISessionPath $session.id
        $previousRevision = Get-AIRevision $session '会话'
        $previousLimit = $script:MaximumSessionBytes
        try {
            $script:MaximumSessionBytes = [int](Get-Item -LiteralPath $path).Length + 32
            $session.turns = @([ordered]@{
                id=[guid]::NewGuid().ToString('N');role='user';kind='message';content=('x' * 1024)
                createdUtc=[DateTime]::UtcNow.ToString('O');metadata=@{}
            })
            $message = try { Save-AISession $session; '' } catch { $_.Exception.Message }
        } finally { $script:MaximumSessionBytes = $previousLimit }
        $reloaded = Import-AISession $session.id
        [pscustomobject]@{
            Message=$message
            ReloadedCount=@($reloaded.turns).Count
            Revision=Get-AIRevision $session '会话'
            PreviousRevision=$previousRevision
        }
    }
    Assert-Match $sessionSizeLimit.Message '会话文件超过 \d+ 字节上限' '会话写入端必须在替换旧文件前检查 UTF-8 字节数。'
    Assert-Equal 0 $sessionSizeLimit.ReloadedCount '会话大小越界后必须保留原有可读取文件。'
    Assert-Equal $sessionSizeLimit.PreviousRevision $sessionSizeLimit.Revision '会话大小越界后必须回滚内存修订号。'

    # 上下文达到预算后应自动摘要，并保留最近轮次。
    New-PSAISession -Title '压缩测试' | Out-Null
    & $module { 1..10 | ForEach-Object { Add-AISessionTurn 'user' ("第 $_ 轮 " + ('x' * 900)) 'message' | Out-Null } }
    Set-PSAITerminalOption -ContextBudgetPercent 50 -RecentTurns 2 | Out-Null
    $summaryResponse = [ordered]@{message=@{content='保留目标与关键结果的压缩摘要。'};done=$true} | ConvertTo-Json -Compress
    $server = Start-AIMockServer @($summaryResponse)
    try {
        Set-PSAIModel -Name local -Endpoint ([uri]"http://127.0.0.1:$($server.Port)") -ContextWindow 1024 | Out-Null
        & $module { $model=Get-AIActiveModel; Compress-AISessionIfNeeded $model ([Threading.CancellationToken]::None) }
        $compression = & $module { [pscustomobject]@{Count=[int]$script:CurrentSession.compactedTurnCount;Summary=[string]$script:CurrentSession.summary} }
        Assert-Equal 8 $compression.Count '压缩后应保留最近 2 个 Turn。'
        Assert-Match $compression.Summary '压缩摘要' '压缩摘要必须持久化。'
    } finally { Stop-AIMockServer $server }

    # 原生工具调用、多步骤观察和 Run 检查点。
    $toolArguments = [ordered]@{purpose='读取日期';command='Get-Date';expectedOutcome='显示当前日期';sideEffects='无';rollbackHint='无需回滚'}
    $invalidToolArguments = [ordered]@{purpose='读取日期';command='Get-Date';expectedOutcome='显示当前日期';sideEffects='无'}
    $invalidToolResponse = [ordered]@{message=@{tool_calls=@(@{id='call-invalid';function=@{name='powershell';arguments=$invalidToolArguments}})};done=$true} | ConvertTo-Json -Depth 20 -Compress
    $toolResponse = [ordered]@{message=@{tool_calls=@(@{id='call-1';function=@{name='powershell';arguments=$toolArguments}})};done=$true} | ConvertTo-Json -Depth 20 -Compress
    $finalResponse = [ordered]@{message=@{content='任务已完成。'};done=$true} | ConvertTo-Json -Depth 10 -Compress
    $proposalServer = Start-AIMockServer @($invalidToolResponse,$toolResponse)
    $finalServer = Start-AIMockServer @($finalResponse)
    try {
        Set-PSAIModel -Name local -Endpoint ([uri]"http://127.0.0.1:$($proposalServer.Port)") -Capabilities @{streaming=$true;toolCalling=$true;usage=$false} | Out-Null
        New-PSAIModel -Name alternate -Protocol Ollama -Endpoint ([uri]"http://127.0.0.1:$($finalServer.Port)") -ModelId qwen3 `
            -Capabilities @{streaming=$true;toolCalling=$true;usage=$false} | Out-Null
        function global:Read-Host { param([Parameter(ValueFromRemainingArguments)]$Arguments) '' }
        try { $step = Start-PSAIRun -Task '告诉我当前日期' }
        finally { Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue }
        Assert-True ($null -ne $step) '模型工具调用应产生待执行步骤。'
        Assert-Match ([string]$step.ApprovalDigest) '^[a-f0-9]{64}$' '待执行步骤必须绑定已批准命令的 SHA-256 摘要。'
        Assert-True ([long]$step.ApprovalRevision -gt 0) '待执行步骤必须绑定批准时的 Run 修订号。'
        Select-PSAIModel alternate | Out-Null
        Start-PSAIToolExecution -RunId $step.RunId -StepId $step.StepId `
            -ApprovalDigest $step.ApprovalDigest -ApprovalRevision $step.ApprovalRevision
        $next = Complete-PSAIToolExecution -RunId $step.RunId -StepId $step.StepId -Succeeded $true -Output '2026-08-11'
        Assert-Equal $null $next '模型总结后不应继续产生工具步骤。'
        Assert-Equal 'Completed' (Get-PSAIRun -Id $step.RunId).State 'Run 应完成执行、观察和总结循环。'
        Assert-Equal 'alternate' (Get-PSAIModel | Where-Object Active).Name '模型切换应在下一步骤生效且保持同一 Run。'
        Remove-PSAIModel -Name alternate -ReplacementModel local -Confirm:$false
    } finally {
        Stop-AIMockServer $proposalServer; Stop-AIMockServer $finalServer
        Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
    }

    $interruptedId = & $module {
        $id=[guid]::NewGuid().ToString('N')
        $run=[ordered]@{schemaVersion=1;id=$id;sessionId=$script:CurrentSession.id;task='中断测试';state='ExecutingTool';stepCount=1;maxSteps=2
            pendingProposal=[ordered]@{id='call-interrupted';stepId=[guid]::NewGuid().ToString('N');purpose='读取日期';command='Get-Date';expectedOutcome='显示日期';sideEffects='无';rollbackHint='无需回滚';risk='Low'}
            events=@();createdUtc=[DateTime]::UtcNow.ToString('O');updatedUtc=[DateTime]::UtcNow.ToString('O')}
        Save-AIRun $run; $id
    }
    Assert-Throws { Resume-PSAIRun -Id $interruptedId } '避免重复执行' '执行中断的 Run 不能自动重放命令。'
    Stop-PSAIRun -Id $interruptedId | Out-Null

    $invalidRunId = & $module {
        $id=[guid]::NewGuid().ToString('N')
        $run=[ordered]@{schemaVersion=1;id=$id;sessionId=$script:CurrentSession.id;task='损坏测试';state='UnknownState';stepCount=0;maxSteps=2
            pendingProposal=$null;events=@();createdUtc=[DateTime]::UtcNow.ToString('O');updatedUtc=[DateTime]::UtcNow.ToString('O')}
        Save-AIRun $run; $id
    }
    Assert-Throws { Get-PSAIRun -Id $invalidRunId } 'Run 状态无效' '损坏的 Run 状态必须在恢复前被拒绝。'

    $runConcurrency = & $module {
        $id = [guid]::NewGuid().ToString('N')
        $run = [ordered]@{
            schemaVersion=1;revision=0L;id=$id;sessionId=$script:CurrentSession.id;task='并发状态测试'
            state='AwaitingApproval';stepCount=1;maxSteps=2
            pendingProposal=[ordered]@{id='call-concurrent';stepId=[guid]::NewGuid().ToString('N');purpose='读取日期';command='Get-Date';expectedOutcome='显示日期';sideEffects='无';rollbackHint='无需回滚';risk='Low'}
            events=@();createdUtc=[DateTime]::UtcNow.ToString('O');updatedUtc=[DateTime]::UtcNow.ToString('O')
        }
        Save-AIRun $run
        $first = Import-AIRun $id
        $stale = Import-AIRun $id
        Set-AIRunState $first 'ExecutingTool' @{stepId=$first.pendingProposal.stepId}
        $message = try { Set-AIRunState $stale 'ExecutingTool' @{stepId=$stale.pendingProposal.stepId}; '' }
            catch { $_.Exception.Message }
        $reloaded = Import-AIRun $id
        [pscustomobject]@{Message=$message;State=$reloaded.state;EventCount=@($reloaded.events).Count}
    }
    Assert-Match $runConcurrency.Message '另一个 PowerShell 进程修改' '旧 Run 快照不能重复领取同一工具步骤。'
    Assert-Equal 'ExecutingTool' $runConcurrency.State '第一个成功领取者必须保留 ExecutingTool 状态。'
    Assert-Equal 1 $runConcurrency.EventCount '并发冲突不能重复写入状态事件。'

    $approvalBinding = & $module {
        $id = [guid]::NewGuid().ToString('N')
        $run = [ordered]@{
            schemaVersion=1;revision=0L;id=$id;sessionId=$script:CurrentSession.id;task='批准绑定测试'
            state='AwaitingApproval';stepCount=1;maxSteps=2
            pendingProposal=[ordered]@{id='call-binding';stepId=[guid]::NewGuid().ToString('N');purpose='读取日期';command='Get-Date';expectedOutcome='显示日期';sideEffects='无';rollbackHint='无需回滚';risk='Low'}
            events=@();createdUtc=[DateTime]::UtcNow.ToString('O');updatedUtc=[DateTime]::UtcNow.ToString('O')
        }
        Save-AIRun $run
        $oldApproval = Set-AIProposalApproval $run $run.pendingProposal (Get-AICommandRisk $run.pendingProposal.command)
        $oldStep = [pscustomobject]@{
            RunId=$id;StepId=$run.pendingProposal.stepId;Command=$run.pendingProposal.command
            ApprovalDigest=$oldApproval.Digest;ApprovalRevision=$oldApproval.Revision
        }
        $edited = Import-AIRun $id
        Remove-AIProposalApproval $edited.pendingProposal
        $edited.pendingProposal.command = 'Get-Location'
        $edited.pendingProposal.purpose = '读取当前位置'
        Add-AIRunEvent $edited 'ProposalEdited' @{stepId=$edited.pendingProposal.stepId}
        $newApproval = Set-AIProposalApproval $edited $edited.pendingProposal (Get-AICommandRisk $edited.pendingProposal.command)
        [pscustomobject]@{
            Old=$oldStep
            New=[pscustomobject]@{RunId=$id;StepId=$edited.pendingProposal.stepId;Command=$edited.pendingProposal.command;ApprovalDigest=$newApproval.Digest;ApprovalRevision=$newApproval.Revision}
        }
    }
    $expiredApprovalMessage = try {
        Start-PSAIToolExecution -RunId $approvalBinding.Old.RunId -StepId $approvalBinding.Old.StepId `
            -ApprovalDigest $approvalBinding.Old.ApprovalDigest -ApprovalRevision $approvalBinding.Old.ApprovalRevision
        ''
    } catch { $_.Exception.Message }
    Assert-Match $expiredApprovalMessage '批准已过期' '命令在批准后发生变化时必须拒绝旧执行票据。'
    Assert-Equal 'AwaitingApproval' (Get-PSAIRun -Id $approvalBinding.New.RunId).State '拒绝旧执行票据后不能改变 Run 状态。'
    Start-PSAIToolExecution -RunId $approvalBinding.New.RunId -StepId $approvalBinding.New.StepId `
        -ApprovalDigest $approvalBinding.New.ApprovalDigest -ApprovalRevision $approvalBinding.New.ApprovalRevision
    $approvedRun = Get-PSAIRun -Id $approvalBinding.New.RunId
    $approvedCommand = & $module { param($id) [string](Import-AIRun $id).pendingProposal.command } $approvalBinding.New.RunId
    Assert-Equal 'ExecutingTool' $approvedRun.State '只有与当前命令和修订号一致的执行票据才能领取步骤。'
    Assert-Equal 'Get-Location' $approvedCommand '领取后记录的命令必须与用户最终批准的命令完全一致。'
    Stop-PSAIRun -Id $approvalBinding.New.RunId | Out-Null

    $highRiskInteraction = & $module {
        $id = [guid]::NewGuid().ToString('N')
        $run = [ordered]@{
            schemaVersion=1;revision=0L;id=$id;sessionId=$script:CurrentSession.id;task='高风险确认测试'
            state='AwaitingApproval';stepCount=1;maxSteps=2
            pendingProposal=[ordered]@{id='call-high-risk';stepId=[guid]::NewGuid().ToString('N');purpose='删除测试文件';command='Remove-Item test.txt';expectedOutcome='文件消失';sideEffects='删除文件';rollbackHint='从备份恢复';risk='High'}
            events=@();createdUtc=[DateTime]::UtcNow.ToString('O');updatedUtc=[DateTime]::UtcNow.ToString('O')
        }
        Save-AIRun $run
        $responses = [Collections.Generic.Queue[string]]::new()
        foreach ($response in @('1','','3')) { $responses.Enqueue($response) }
        $prompts = [Collections.Generic.List[string]]::new()
        function Read-Host { param([Parameter(Position=0)]$Prompt) $prompts.Add([string]$Prompt); $responses.Dequeue() }
        try { $ticket = Show-AIToolApproval $run $run.pendingProposal ([Threading.CancellationToken]::None) }
        finally { Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue }
        $reloaded = Import-AIRun $id
        [pscustomobject]@{
            TicketIsNull=($null -eq $ticket);State=$reloaded.state
            FirstPrompt=$prompts[0];ConfirmationPrompt=$prompts[1];PromptCount=$prompts.Count
        }
    }
    Assert-True ($highRiskInteraction.FirstPrompt -notmatch '(?i)default|默认') '高风险菜单不得提供回车默认执行。'
    Assert-Match $highRiskInteraction.ConfirmationPrompt '(?i)high-risk|高风险' '高风险执行必须经过第二次明确确认。'
    Assert-Equal $true $highRiskInteraction.TicketIsNull '高风险二次确认按回车时必须默认拒绝执行。'
    Assert-Equal 'Cancelled' $highRiskInteraction.State '用户随后拒绝高风险命令时 Run 必须取消。'

    $runSizeLimit = & $module {
        $id = [guid]::NewGuid().ToString('N')
        $run = [ordered]@{
            schemaVersion=1;revision=0L;id=$id;sessionId=$script:CurrentSession.id;task='大小上限测试'
            state='Created';stepCount=0;maxSteps=2;pendingProposal=$null;events=@()
            createdUtc=[DateTime]::UtcNow.ToString('O');updatedUtc=[DateTime]::UtcNow.ToString('O')
        }
        Save-AIRun $run
        $path = Get-AIRunPath $id
        $previousRevision = Get-AIRevision $run 'Run'
        $previousLimit = $script:MaximumRunBytes
        try {
            $script:MaximumRunBytes = [int](Get-Item -LiteralPath $path).Length + 32
            $run.task = 'x' * 1024
            $message = try { Save-AIRun $run; '' } catch { $_.Exception.Message }
        } finally { $script:MaximumRunBytes = $previousLimit }
        $reloaded = Import-AIRun $id
        [pscustomobject]@{
            Message=$message
            State=$reloaded.state
            Revision=Get-AIRevision $run 'Run'
            PreviousRevision=$previousRevision
        }
    }
    Assert-Match $runSizeLimit.Message 'Run 检查点超过 \d+ 字节上限' 'Run 写入端必须在替换旧检查点前检查 UTF-8 字节数。'
    Assert-Equal 'Created' $runSizeLimit.State 'Run 大小越界后必须保留原有检查点。'
    Assert-Equal $runSizeLimit.PreviousRevision $runSizeLimit.Revision 'Run 大小越界后必须回滚内存修订号。'

    $blockedRunDirectory = Join-Path $testRoot 'blocked-run-directory'
    Set-Content -LiteralPath $blockedRunDirectory -Value 'not a directory'
    $runRollback = & $module {
        param($blockedPath)
        $originalDirectory=$script:RunDirectory
        $run=[ordered]@{schemaVersion=1;id=[guid]::NewGuid().ToString('N');sessionId=$script:CurrentSession.id;task='回滚测试';state='Created';stepCount=0;maxSteps=2
            pendingProposal=$null;events=@();createdUtc=[DateTime]::UtcNow.ToString('O');updatedUtc=[DateTime]::UtcNow.ToString('O')}
        try { $script:RunDirectory=$blockedPath; Set-AIRunState $run 'CallingModel' } catch {}
        finally { $script:RunDirectory=$originalDirectory }
        [pscustomobject]@{State=$run.state;EventCount=@($run.events).Count}
    } $blockedRunDirectory
    Assert-Equal 'Created' $runRollback.State 'Run 写盘失败后必须恢复原状态。'
    Assert-Equal 0 $runRollback.EventCount 'Run 写盘失败后不能残留未保存事件。'

    # 顶层 Agent 包装必须保留调用者作用域并准确记录失败。
    $successHarness = & $module { New-AITopLevelHarnessScript "[pscustomobject]@{RunId='r1';StepId='s1';ApprovalDigest=('a'*64);ApprovalRevision=1;Command='`$HarnessScopeProbe=42; function Invoke-HarnessProbe { 99 }; Get-Date | Out-Null'}" }
    $nonTerminatingHarness = & $module { New-AITopLevelHarnessScript "[pscustomobject]@{RunId='r2';StepId='s2';ApprovalDigest=('b'*64);ApprovalRevision=2;Command='Write-Error ''harness-probe'' -ErrorAction Continue; Get-Date | Out-Null'}" }
    $nativeFailureCommand = if ($isWindowsHost) { 'cmd /c exit 7' } else { "sh -c 'exit 7'" }
    $nativeMixedLiteral = "'" + ($nativeFailureCommand + '; Get-Date | Out-Null').Replace("'", "''") + "'"
    $nativeMixedHarness = & $module { param($literal) New-AITopLevelHarnessScript ("[pscustomobject]@{RunId='r3';StepId='s3';ApprovalDigest=('c'*64);ApprovalRevision=3;Command=$literal}") } $nativeMixedLiteral
    $formatHarness = & $module { New-AITopLevelHarnessScript "[pscustomobject]@{RunId='r4';StepId='s4';ApprovalDigest=('d'*64);ApprovalRevision=4;Command='Get-Date | Select-Object DateTime | Format-Table -AutoSize'}" }
    Assert-Match $successHarness 'AITerminalBoundedTextCollector' 'Agent Harness 必须边执行边写入有界输出收集器。'
    Assert-Match $successHarness 'PSNativeCommandUseErrorActionPreference = \$true' 'Agent Harness 必须把原生命令非零退出转换为可累计错误。'
    Assert-Match $successHarness 'Out-String -Stream' 'Agent Harness 必须整体渲染格式化记录，不能逐对象破坏 Format-Table 序列。'
    Assert-Equal $false $successHarness.Contains('@(. ([scriptblock]::Create') 'Agent Harness 不能先把全部命令输出缓存到数组。'
    Remove-Module PSAITerminal
    function global:Start-PSAIToolExecution {
        param($RunId,$StepId,$ApprovalDigest,[long]$ApprovalRevision)
        [void]$RunId; [void]$StepId; [void]$ApprovalDigest; [void]$ApprovalRevision
    }
    function global:Complete-PSAIToolExecution {
        param($RunId,$StepId,[bool]$Succeeded,$Output)
        [void]$RunId; [void]$StepId
        Set-Variable -Name HarnessObservedSuccess -Scope Global -Value $Succeeded
        Set-Variable -Name HarnessObservedOutput -Scope Global -Value $Output
    }
    try {
        $nativePreferenceVariable = Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
        $nativePreferenceBefore = if ($nativePreferenceVariable) { [bool]$nativePreferenceVariable.Value } else { $null }
        $lastExitCodeVariableBefore = Get-Variable LASTEXITCODE -ErrorAction SilentlyContinue
        $lastExitCodeBefore = if ($lastExitCodeVariableBefore) { [int]$lastExitCodeVariableBefore.Value } else { $null }
        . ([scriptblock]::Create($successHarness))
        Assert-Equal 42 $HarnessScopeProbe 'Agent 顶层包装必须保留普通变量。'
        Assert-Equal 99 (Invoke-HarnessProbe) 'Agent 顶层包装必须保留函数定义。'
        Assert-Equal $true $HarnessObservedSuccess '成功状态必须在 Out-Host 前记录。'
        . ([scriptblock]::Create($nonTerminatingHarness)) 2>$null
        Assert-Equal $false $HarnessObservedSuccess '前面的非终止错误不能被后续成功语句覆盖。'
        . ([scriptblock]::Create($nativeMixedHarness)) 2>$null
        Assert-Equal $false $HarnessObservedSuccess '前面的原生命令非零退出不能被后续成功语句覆盖。'
        . ([scriptblock]::Create($formatHarness))
        Assert-Equal $true $HarnessObservedSuccess 'Format-Table 输出不能导致 Agent 命令被误判为失败。'
        Assert-Match $HarnessObservedOutput 'DateTime' 'Format-Table 的文本输出必须进入有界收集器。'
        if ($nativePreferenceVariable) {
            Assert-Equal $nativePreferenceBefore ([bool](Get-Variable PSNativeCommandUseErrorActionPreference).Value) 'Harness 必须恢复用户原有的原生命令错误偏好。'
        } else {
            Assert-Equal $null (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) '5.1 Harness 不能创建宿主不支持的原生命令错误偏好。'
        }
        if ($PSVersionTable.PSVersion -lt [version]'7.3') {
            $lastExitCodeVariableAfter = Get-Variable LASTEXITCODE -ErrorAction SilentlyContinue
            Assert-Equal ($null -ne $lastExitCodeVariableBefore) ($null -ne $lastExitCodeVariableAfter) '5.1 Harness 必须恢复 LASTEXITCODE 是否存在的原状态。'
            if ($lastExitCodeVariableBefore) {
                Assert-Equal $lastExitCodeBefore ([int]$lastExitCodeVariableAfter.Value) '5.1 Harness 必须恢复用户原有的 LASTEXITCODE。'
            }
        }
    } finally {
        Remove-Item Function:\Start-PSAIToolExecution,Function:\Complete-PSAIToolExecution -ErrorAction SilentlyContinue
        Remove-Item Function:\Invoke-HarnessProbe -ErrorAction SilentlyContinue
        Remove-Variable HarnessObservedSuccess,HarnessObservedOutput,HarnessScopeProbe -Scope Global -ErrorAction SilentlyContinue
    }

    # v1 配置迁移以及损坏配置不被导入过程覆盖。
    $legacyRoot = Join-Path $testRoot 'legacy'
    Remove-Item Env:PSAI_CONFIG_HOME,Env:PSAI_DATA_HOME -ErrorAction SilentlyContinue
    $env:PSAI_CONFIG_HOME = Join-Path $legacyRoot 'config'; $env:PSAI_DATA_HOME = Join-Path $legacyRoot 'data'
    [void][IO.Directory]::CreateDirectory($env:PSAI_CONFIG_HOME)
    $legacy = @{schemaVersion=1;shortcutPresetVersion=3;shortcuts=@{cycleMode='F6';forceAI='Ctrl+Enter';forceShell='Ctrl+Shift+Enter';explainLast='F7'}}
    $legacy | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $env:PSAI_CONFIG_HOME 'config.json') -Encoding utf8
    Import-Module $modulePath -Force
    Assert-Equal 'F2' (Get-PSAITerminalOption).Shortcuts.forceAI '旧快捷键应迁移到 F2。'
    Assert-Equal 'F3' (Get-PSAITerminalOption).Shortcuts.forceShell '旧快捷键应迁移到 F3。'
    Remove-Module PSAITerminal

    $corruptRoot = Join-Path $testRoot 'corrupt'
    $env:PSAI_CONFIG_HOME = Join-Path $corruptRoot 'config'; $env:PSAI_DATA_HOME = Join-Path $corruptRoot 'data'
    [void][IO.Directory]::CreateDirectory($env:PSAI_CONFIG_HOME)
    $corruptPath = Join-Path $env:PSAI_CONFIG_HOME 'config.json'
    $corruptText = '{not-json'
    Set-Content -LiteralPath $corruptPath -Value $corruptText -NoNewline
    Import-Module $modulePath -Force -WarningAction SilentlyContinue
    Assert-Equal $corruptText (Get-Content -LiteralPath $corruptPath -Raw) '损坏配置不能在导入期间被覆盖。'
    Assert-True (@(Get-ChildItem -LiteralPath $env:PSAI_CONFIG_HOME -Filter 'config.json.corrupt.*.json').Count -eq 1) '损坏配置应创建旁路备份。'

    # 发布安装器必须尊重调用进程的自定义 PSModulePath，并支持按名称导入和安全卸载。
    Remove-Module PSAITerminal
    $originalModulePath = $env:PSModulePath
    $installRoot = Join-Path $testRoot 'installer/CustomModules'
    $testProfile = Join-Path $testRoot 'installer/Microsoft.PowerShell_profile.ps1'
    $installResult = & (Join-Path $moduleOutput 'Install-PSAITerminal.ps1') `
        -ModuleRoot $installRoot -ProfilePath $testProfile
    Assert-True (Test-Path -LiteralPath $installResult.InstalledPath) '安装器必须创建版本化模块目录。'
    Assert-Equal ([IO.Path]::GetFullPath($testProfile)) $installResult.ProfilePath '安装器必须返回实际写入的 Profile 路径。'
    $profileContent = Get-Content -LiteralPath $testProfile -Raw
    Assert-Match $profileContent ([regex]::Escape("Import-Module PSAITerminal -MinimumVersion '$releaseVersion'")) '安装器必须写入带最低版本的自动加载区块。'
    Assert-Match $profileContent ([regex]::Escape("`$__psaiModuleRoot = '$installRoot'")) '安装器必须把实际模块根写入自动加载区块。'
    & (Join-Path $moduleOutput 'Install-PSAITerminal.ps1') -ModuleRoot $installRoot -ProfilePath $testProfile | Out-Null
    $repeatedProfileContent = Get-Content -LiteralPath $testProfile -Raw
    Assert-Equal 1 @([regex]::Matches($repeatedProfileContent, 'PSAITerminal 自动加载（开始）')).Count '重复安装不能重复写入 Profile 区块。'
    Assert-True $repeatedProfileContent.Contains('$($_.Exception.Message)') '重复安装必须保留 Profile 区块中的 PowerShell 表达式，不能把它当成正则替换语法。'
    # 兼容旧版正则替换已经生成的嵌套区块：修复前保留原文件备份，用户内容只保留一份。
    $profilePattern = '(?ms)^# PSAITerminal 自动加载（开始）\r?\n.*?^# PSAITerminal 自动加载（结束）\r?\n?'
    $corruptProfileContent = "# 用户内容（前）`n$repeatedProfileContent# 用户内容（后）`n"
    for ($corruptionIndex = 0; $corruptionIndex -lt 3; $corruptionIndex++) {
        $corruptProfileContent = [regex]::Replace(
            $corruptProfileContent,
            $profilePattern,
            $repeatedProfileContent + [Environment]::NewLine)
    }
    Set-Content -LiteralPath $testProfile -Value $corruptProfileContent -NoNewline -Encoding utf8
    $repairInstall = & (Join-Path $moduleOutput 'Install-PSAITerminal.ps1') -ModuleRoot $installRoot -ProfilePath $testProfile
    $repairedProfileContent = Get-Content -LiteralPath $testProfile -Raw
    Assert-Equal 1 @([regex]::Matches($repairedProfileContent, 'PSAITerminal 自动加载（开始）')).Count '安装器必须合并旧版生成的嵌套 Profile 区块。'
    Assert-Equal 1 @([regex]::Matches($repairedProfileContent, '# 用户内容（前）')).Count '修复 Profile 时不能重复用户原有内容。'
    Assert-Equal 1 @([regex]::Matches($repairedProfileContent, '# 用户内容（后）')).Count '修复 Profile 时不能丢失用户原有内容。'
    Assert-True ([string]$repairInstall.ProfileBackupPath -and (Test-Path -LiteralPath $repairInstall.ProfileBackupPath)) '修复损坏 Profile 前必须创建备份。'
    Assert-Equal $corruptProfileContent (Get-Content -LiteralPath $repairInstall.ProfileBackupPath -Raw) 'Profile 备份必须保存修复前的原始内容。'
    Set-Content -LiteralPath (Join-Path $repairInstall.InstalledPath 'old-stale.txt') -Value 'stale' -NoNewline -Encoding utf8
    Assert-Throws { & (Join-Path $moduleOutput 'Install-PSAITerminal.ps1') -ModuleRoot $installRoot -ProfilePath $testProfile } '内容不同' '安装器必须拒绝带有额外残留文件的同版本目录。'
    Remove-Item -LiteralPath (Join-Path $repairInstall.InstalledPath 'old-stale.txt') -Force
    Assert-Throws { & (Join-Path $moduleOutput 'Install-PSAITerminal.ps1') -ModuleRoot $installRoot -ProfilePath '.\relative.ps1' } '完整的 .ps1' '安装器必须拒绝相对 Profile 路径。'
    Assert-Throws { & (Join-Path $moduleOutput 'Install-PSAITerminal.ps1') -ModuleRoot $installRoot -NoProfileIntegration -ProfilePath $testProfile } '不能同时使用' '安装器必须拒绝矛盾的 Profile 参数。'
    $env:PSModulePath = $originalModulePath
    $env:PSAI_CONFIG_HOME = Join-Path $testRoot 'installer/config'
    $env:PSAI_DATA_HOME = Join-Path $testRoot 'installer/data'
    . $testProfile
    $installedModule = Get-Module PSAITerminal
    $installComparison = if ($isWindowsHost) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $installPrefix = [IO.Path]::GetFullPath($installRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    Assert-True ([IO.Path]::GetFullPath($installedModule.Path).StartsWith($installPrefix, $installComparison)) '安装后必须能从自定义 PSModulePath 按名称导入。'
    Assert-True (@($env:PSModulePath -split [IO.Path]::PathSeparator) -contains [IO.Path]::GetFullPath($installRoot)) 'Profile 必须在宿主缺少用户模块路径时补回实际模块根。'
    Assert-True (Test-Path -LiteralPath (Join-Path $installedModule.ModuleBase 'Uninstall-PSAITerminal.ps1')) '发布目录必须包含卸载脚本。'
    Assert-True (Test-Path -LiteralPath (Join-Path $installedModule.ModuleBase 'zh-CN/about_PSAITerminal.help.txt')) '发布目录必须包含简体中文帮助主题。'
    Assert-True (Test-Path -LiteralPath (Join-Path $installedModule.ModuleBase 'en-US/about_PSAITerminal.help.txt')) '发布目录必须包含英文帮助主题。'
    Set-Content -LiteralPath (Join-Path $installedModule.ModuleBase 'loaded-stale.txt') -Value 'stale' -NoNewline -Encoding utf8
    $loadedForceInstall = & (Join-Path $moduleOutput 'Install-PSAITerminal.ps1') `
        -ModuleRoot $installRoot -ProfilePath $testProfile -Force
    Assert-Equal $null (Get-Module PSAITerminal) '带 -Force 升级时必须先从当前会话移除正在使用的目标版本。'
    Assert-Equal $true $loadedForceInstall.RestartRequired '替换已加载模块后必须明确要求重启 PowerShell。'
    Assert-True ([string]$loadedForceInstall.BackupPath -and (Test-Path -LiteralPath $loadedForceInstall.BackupPath)) '替换已加载版本前必须保留原目录备份。'
    Assert-Equal $false (Test-Path -LiteralPath (Join-Path $loadedForceInstall.InstalledPath 'loaded-stale.txt')) '强制升级后的目标目录不能保留旧文件。'
    & (Join-Path $moduleOutput 'Uninstall-PSAITerminal.ps1') -ModuleRoot $installRoot -ProfilePath $testProfile | Out-Null
    Assert-Equal $false (Test-Path -LiteralPath (Join-Path $installRoot 'PSAITerminal')) '卸载器必须只删除指定模块目录。'
    Assert-True (Test-Path -LiteralPath $env:PSAI_CONFIG_HOME) '卸载器默认必须保留用户配置。'
    Assert-Equal $false ((Get-Content -LiteralPath $testProfile -Raw) -match 'PSAITerminal 自动加载') '卸载器必须移除自己的 Profile 区块。'
    $env:PSModulePath = $originalModulePath

    # Both 只能使用两个标准用户目录；测试通过专用文档根隔离，绝不触碰真实安装目录。
    $env:PSAI_TEST_DOCUMENTS_HOME = Join-Path $testRoot 'installer/both-documents'
    $env:PSAI_TEST_MODE = '1'
    try {
        Assert-Throws {
            & (Join-Path $moduleOutput 'Install-PSAITerminal.ps1') -TargetHost Both `
                -ModuleRoot (Join-Path $testRoot 'invalid-root') -NoProfileIntegration
        } '不能与' 'Both 必须拒绝自定义模块根，避免安装目标歧义。'
        $providerType = [Type]::GetType('System.Text.CodePagesEncodingProvider, System.Text.Encoding.CodePages', $false)
        if ($providerType) {
            $provider = $providerType.GetProperty('Instance').GetValue($null, $null)
            [Text.Encoding]::RegisterProvider($provider)
        }
        $ansiEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
        foreach ($hostDirectory in @('WindowsPowerShell','PowerShell')) {
            $profilePath = Join-Path $env:PSAI_TEST_DOCUMENTS_HOME "$hostDirectory/Microsoft.PowerShell_profile.ps1"
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $profilePath))
            $profileEncoding = if ($hostDirectory -eq 'WindowsPowerShell') { $ansiEncoding } else { New-Object Text.UTF8Encoding($false) }
            [IO.File]::WriteAllText($profilePath, "legacy café - $hostDirectory`r`n", $profileEncoding)
        }
        & (Join-Path $moduleOutput 'Install-PSAITerminal.ps1') -TargetHost Both | Out-Null
        foreach ($hostDirectory in @('WindowsPowerShell','PowerShell')) {
            $bothPath = Join-Path $env:PSAI_TEST_DOCUMENTS_HOME "$hostDirectory/Modules/PSAITerminal/$releaseVersion"
            Assert-True (Test-Path -LiteralPath $bothPath -PathType Container) "Both 未安装到隔离的 $hostDirectory 标准目录。"
            $profilePath = Join-Path $env:PSAI_TEST_DOCUMENTS_HOME "$hostDirectory/Microsoft.PowerShell_profile.ps1"
            $profileText = [IO.File]::ReadAllText($profilePath, [Text.Encoding]::UTF8)
            Assert-Match $profileText ([regex]::Escape("legacy café - $hostDirectory")) "Both 安装不能破坏 $hostDirectory Profile 的原始编码内容。"
            Assert-Equal 1 @([regex]::Matches($profileText, 'PSAITerminal 自动加载（开始）')).Count "Both 安装必须只写入一个 $hostDirectory Profile 区块。"
            $expectedModuleRoot = Join-Path $env:PSAI_TEST_DOCUMENTS_HOME "$hostDirectory/Modules"
            Assert-Match $profileText ([regex]::Escape("`$__psaiModuleRoot = '$expectedModuleRoot'")) "Both 必须把 $hostDirectory 的实际模块根写入对应 Profile。"
        }
        & (Join-Path $moduleOutput 'Uninstall-PSAITerminal.ps1') -TargetHost Both | Out-Null
        foreach ($hostDirectory in @('WindowsPowerShell','PowerShell')) {
            $bothBase = Join-Path $env:PSAI_TEST_DOCUMENTS_HOME "$hostDirectory/Modules/PSAITerminal"
            Assert-Equal $false (Test-Path -LiteralPath $bothBase) "Both 卸载未清理隔离的 $hostDirectory 模块目录。"
            $profilePath = Join-Path $env:PSAI_TEST_DOCUMENTS_HOME "$hostDirectory/Microsoft.PowerShell_profile.ps1"
            $profileText = [IO.File]::ReadAllText($profilePath, [Text.Encoding]::UTF8)
            Assert-Match $profileText ([regex]::Escape("legacy café - $hostDirectory")) "Both 卸载不能删除 $hostDirectory Profile 的用户内容。"
            Assert-Equal $false ($profileText -match 'PSAITerminal 自动加载') "Both 卸载必须移除 $hostDirectory Profile 区块。"
        }
    } finally {
        Remove-Item Env:PSAI_TEST_DOCUMENTS_HOME -ErrorAction SilentlyContinue
        Remove-Item Env:PSAI_TEST_MODE -ErrorAction SilentlyContinue
    }

    Write-Host 'PSAITerminal 完整回归测试通过。' -ForegroundColor Green
} finally {
    Remove-Item Function:\Read-Host,Function:\Start-PSAIToolExecution,Function:\Complete-PSAIToolExecution -ErrorAction SilentlyContinue
    Remove-Module PSAITerminal -ErrorAction SilentlyContinue
    Remove-Item Env:PSAI_CONFIG_HOME,Env:PSAI_DATA_HOME -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
