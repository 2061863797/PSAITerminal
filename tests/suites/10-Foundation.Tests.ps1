# 发布包文档、帮助主题与 C# 基础组件（凭据库、HTTP 内容、有界收集器、文件锁）。
# 由 tests/run.ps1 在同一作用域内按文件名顺序点源执行，依赖其中的 $module、$testRoot 等状态，不能单独运行。

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
    try { [PSAITerminal.PlatformCredentialStore]::Remove($credentialTarget) }
    catch { Write-Verbose "合成测试凭据清理失败：$($_.Exception.Message)" }
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
