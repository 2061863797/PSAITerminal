# 模型增删改查、SessionOnly 回滚与持久化。
# 由 tests/run.ps1 在同一作用域内按文件名顺序点源执行，依赖其中的 $module、$testRoot 等状态，不能单独运行。

# 模型 CRUD、SessionOnly 回滚和持久化。
New-PSAIModel -Name local -Protocol OpenAIChat -Endpoint http://127.0.0.1:11434 -ModelId qwen3 | Out-Null
Assert-Equal $false (Get-PSAIModel -Name local).HasSecret '本机接口可以不配置 API Key。'
Assert-Throws { New-PSAIModel -Name remote -Protocol OpenAIChat -Endpoint https://api.example.com -ModelId m } '必须提供 API Key' '远程接口必须提供 API Key。'
Assert-Equal 1 @((Get-PSAIModel)).Count '新增模型后应立即可见。'
Assert-Equal 'local' (Get-PSAIModel -Name local).Name '新增模型名称不一致。'
Assert-Throws { Get-PSAIModel -Name missing } '模型不存在' '查询不存在模型必须明确报错。'
Assert-Throws { Set-PSAIModel -Name local -Protocol Anthropic } '必须同时提供新的接口地址' '协议切换不应复用旧地址。'

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

$probeKey = New-FixtureSecureString 'probe-secret'
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

$sessionKey = New-FixtureSecureString 'session-only-secret'
$secureModelName = 'secure-' + [guid]::NewGuid().ToString('N')
New-PSAIModel -Name $secureModelName -Protocol OpenAIChat -Endpoint http://127.0.0.1:12345 -ModelId mock -ApiKey $sessionKey -SessionOnly | Out-Null
$originalConfigPath = & $module { $script:ConfigPath }
& $module { $script:ConfigPath = $script:ConfigDirectory }
Assert-Throws { Set-PSAIModel -Name $secureModelName -ModelId changed } 'already exists|文件|directory|目录|access|访问|目标|另一个 PowerShell' '应人为触发保存失败以验证回滚。'
& $module { param($path) $script:ConfigPath=$path } $originalConfigPath
Assert-Equal $true (& $module { param($name) $script:SessionSecrets.ContainsKey($name) } $secureModelName) '回滚后密钥仍应是仅当前会话。'
Assert-Equal $null ([PSAITerminal.PlatformCredentialStore]::Get("PSAITerminal/Model/$secureModelName")) 'SessionOnly 密钥不能被回滚写入系统密钥库。'
Set-PSAIModel -Name $secureModelName -Protocol Anthropic -Endpoint http://127.0.0.1:11434 | Out-Null
Assert-Equal $false (& $module { param($name) $script:SessionSecrets.ContainsKey($name) } $secureModelName) '切换协议且未提供新密钥时必须删除旧协议密钥。'
$localRequest = [Net.Http.HttpRequestMessage]::new()
try {
    & $module { param($request) Add-AIAuthenticationHeaders $request 'OpenAIChat' $null } $localRequest
    Assert-Equal $null $localRequest.Headers.Authorization '没有密钥时不能发送 Authorization 头。'
} finally { $localRequest.Dispose() }
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
