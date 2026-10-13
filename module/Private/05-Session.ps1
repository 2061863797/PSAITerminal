# 会话持久化与上下文组装：按模型上下文窗口截取最近的轮次，不调用模型做摘要。

function New-AISessionObject([string]$Title) {
    $now = [DateTime]::UtcNow.ToString('O')
    [ordered]@{
        schemaVersion = 1
        revision = 0L
        id = [guid]::NewGuid().ToString('N')
        title = if ([string]::IsNullOrWhiteSpace($Title)) { '新会话' } else { (Protect-AIText $Title 120) }
        createdUtc = $now
        updatedUtc = $now
        turns = @()
        inputTokens = 0L
        outputTokens = 0L
    }
}

function Get-AISessionPath([string]$Id) {
    if ($Id -notmatch '^[a-fA-F0-9]{32}$') { throw '会话 ID 无效。' }
    Join-Path $script:SessionDirectory "$Id.json"
}

function Save-AISession([Collections.IDictionary]$Session = $script:CurrentSession, [switch]$LockHeld,
    [switch]$RevisionAlreadyValidated) {
    if (-not $Session) { return }
    if ($RevisionAlreadyValidated -and -not $LockHeld) {
        throw '只有在持有会话文件锁时才能跳过修订号复核。'
    }
    $path = Get-AISessionPath ([string]$Session.id)
    if (-not $LockHeld) {
        return Invoke-AIWithFileLock $path { Save-AISession $Session -LockHeld }
    }

    $previousUpdatedUtc = $Session.updatedUtc
    $previousRevision = Get-AIRevision $Session '会话'
    try {
        if (-not $RevisionAlreadyValidated) {
            $storedRevision = Get-AIStoredRevision $path '会话' $script:MaximumSessionBytes
            if (($storedRevision -ge 0 -and $storedRevision -ne $previousRevision) -or
                ($storedRevision -lt 0 -and $previousRevision -ne 0)) {
                throw '会话已被另一个 PowerShell 进程修改。请重试当前操作。'
            }
        }
        if ($Session.turns -isnot [Collections.IList] -or $Session.turns -is [string] -or $Session.turns.Count -gt 2000) {
            throw '会话 turns 必须是最多包含 2000 项的数组。'
        }
        $Session.revision = $previousRevision + 1
        $Session.updatedUtc = [DateTime]::UtcNow.ToString('O')
        $json = $Session | ConvertTo-Json -Depth 50
        Assert-AISerializedSize $json $script:MaximumSessionBytes '会话文件'
        [PSAITerminal.AITerminalAtomicFile]::WriteAllText($path, $json)
    } catch {
        $Session.updatedUtc = $previousUpdatedUtc
        $Session.revision = $previousRevision
        throw
    }
}

function Import-AISession([string]$Id) {
    $path = Get-AISessionPath $Id
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        [PSAITerminal.AITerminalAtomicFile]::EnsurePrivateFile($path)
        $sessionFile = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($sessionFile.Length -gt 16MB) { throw '会话文件超过 16 MiB 上限。' }
        $session = ConvertFrom-AIJson (Read-PSAITextFile $path -Utf8Only)
        Assert-AIIntegerValue $session.schemaVersion 1 1 '会话版本'
        $session.revision = Get-AIRevision $session '会话'
        if ([string]$session.id -ne $Id -or $session.id -notmatch '^[a-fA-F0-9]{32}$') { throw '会话 ID 不一致。' }
        if ($session.turns -isnot [Collections.IList] -or $session.turns -is [string] -or $session.turns.Count -gt 2000) {
            throw '会话 turns 必须是最多包含 2000 项的数组。'
        }
        foreach ($dateName in @('createdUtc','updatedUtc')) {
            $parsedDate = [datetime]::MinValue
            if (-not [datetime]::TryParse([string]$session[$dateName], [ref]$parsedDate)) { throw "会话 $dateName 无效。" }
        }
        if ($session.title -isnot [string] -or $session.title.Length -gt 120) { throw '会话标题无效。' }

        foreach ($tokenName in @('inputTokens','outputTokens')) {
            $tokenValue = $session[$tokenName]
            $isInteger = $tokenValue -is [sbyte] -or $tokenValue -is [byte] -or $tokenValue -is [int16] -or
                $tokenValue -is [uint16] -or $tokenValue -is [int32] -or $tokenValue -is [uint32] -or
                $tokenValue -is [int64] -or $tokenValue -is [uint64]
            if (-not $isInteger -or [decimal]$tokenValue -lt 0 -or [decimal]$tokenValue -gt [long]::MaxValue) {
                throw "会话 $tokenName 无效。"
            }
        }
        for ($index = 0; $index -lt $session.turns.Count; $index++) {
            $turn = $session.turns[$index]
            if ($turn -isnot [Collections.IDictionary] -or [string]$turn.id -notmatch '^[a-fA-F0-9]{32}$') {
                throw "会话 Turn $index 无效。"
            }
            if ($turn.role -isnot [string] -or [string]::IsNullOrWhiteSpace($turn.role) -or $turn.role.Length -gt 32 -or
                $turn.kind -isnot [string] -or [string]::IsNullOrWhiteSpace($turn.kind) -or $turn.kind.Length -gt 64 -or
                $turn.content -isnot [string]) {
                throw "会话 Turn $index 的字段无效。"
            }
            $turnDate = [datetime]::MinValue
            if (-not [datetime]::TryParse([string]$turn.createdUtc, [ref]$turnDate)) { throw "会话 Turn $index 的时间无效。" }
            if ($turn.metadata -isnot [Collections.IDictionary]) { throw "会话 Turn $index 的 metadata 无效。" }
            Assert-AIModelParameters $turn.metadata "turns[$index].metadata"
            $turn.role = Protect-AIText ([string]$turn.role) 32
            $turn.kind = Protect-AIText ([string]$turn.kind) 64
            $turn.content = Protect-AIText ([string]$turn.content) 65536
        }
        $session.title = Protect-AIText ([string]$session.title) 120
        # 1.0.x 的摘要字段不再使用。
        foreach ($legacyKey in @('summary','compactedTurnCount')) { if (Test-AIMapContains $session $legacyKey) { [void]$session.Remove($legacyKey) } }
        $session
    } catch {
        Write-Warning "无法读取会话 $Id：$($_.Exception.Message)"
        $null
    }
}

function Initialize-AISessionState {
    [PSAITerminal.AITerminalAtomicFile]::EnsurePrivateDirectory($script:SessionDirectory)

    $envVarName = "__PSAI_SESSION_PID_$PID"
    $procSessionId = [Environment]::GetEnvironmentVariable($envVarName, 'Process')
    $isSameProcess = (-not [string]::IsNullOrWhiteSpace($procSessionId))

    $session = $null
    if ($isSameProcess) {
        $session = Import-AISession $procSessionId
    }

    # 打开新终端时自动开启全新会话，清除上下文包袱，避免跨进程/跨历史会话污染
    if (-not $session) {
        $sessionTitle = if ((Get-AILanguage) -eq 'en-US') { 'Terminal Session' } else { '终端会话' }
        $session = New-AISessionObject $sessionTitle
        Save-AISession $session
    }

    [Environment]::SetEnvironmentVariable($envVarName, [string]$session.id, 'Process')
    $script:CurrentSession = $session
}

function Add-AISessionUsageValues([Collections.IDictionary]$Session, [long]$InputTokens, [long]$OutputTokens) {
    if ($InputTokens -lt 0 -or $OutputTokens -lt 0) { throw '模型 Token 用量不能为负数。' }
    $newInputTokens = [decimal][long]$Session.inputTokens + [decimal]$InputTokens
    $newOutputTokens = [decimal][long]$Session.outputTokens + [decimal]$OutputTokens
    if ($newInputTokens -gt [long]::MaxValue -or $newOutputTokens -gt [long]::MaxValue) {
        throw '会话 Token 用量超过 Int64 上限。'
    }
    $Session.inputTokens = [long]$newInputTokens
    $Session.outputTokens = [long]$newOutputTokens
}

function Update-AISessionUsage([long]$InputTokens, [long]$OutputTokens) {
    if ($InputTokens -lt 0 -or $OutputTokens -lt 0) { throw '模型 Token 用量不能为负数。' }
    if (-not $script:CurrentSession -or ($InputTokens -eq 0 -and $OutputTokens -eq 0)) { return }
    $sessionId = [string]$script:CurrentSession.id
    $path = Get-AISessionPath $sessionId
    Invoke-AIWithFileLock $path {
        $latest = Import-AISession $sessionId
        if (-not $latest) { throw "会话不存在或无法读取：$sessionId" }
        Add-AISessionUsageValues $latest $InputTokens $OutputTokens
        Save-AISession $latest -LockHeld -RevisionAlreadyValidated
        $script:CurrentSession = $latest
    }
}

function Add-AISessionTurn([string]$Role, [string]$Content, [string]$Kind = 'message', [hashtable]$Metadata = @{},
    [long]$InputTokens = 0, [long]$OutputTokens = 0) {
    if (-not $script:CurrentSession) { return }
    $safeContent = Protect-AIText $Content 65536
    $turn = [ordered]@{
        id = [guid]::NewGuid().ToString('N')
        role = $Role
        kind = $Kind
        content = $safeContent
        createdUtc = [DateTime]::UtcNow.ToString('O')
        metadata = $Metadata
    }
    $sessionId = [string]$script:CurrentSession.id
    $path = Get-AISessionPath $sessionId
    Invoke-AIWithFileLock $path {
        $latest = Import-AISession $sessionId
        if (-not $latest) { throw "会话不存在或无法读取：$sessionId" }
        if ($latest.turns.Count -ge 2000) { throw '会话已达到 2000 个 Turn 上限，请新建会话后继续。' }
        $latest.turns = @($latest.turns) + @($turn)
        Add-AISessionUsageValues $latest $InputTokens $OutputTokens
        Save-AISession $latest -LockHeld -RevisionAlreadyValidated
        $script:CurrentSession = $latest
        $turn
    }
}

function New-PSAISession {
    [CmdletBinding()] param([string]$Title = '新会话', [switch]$NoSelect)
    $session = New-AISessionObject $Title
    Save-AISession $session
    if (-not $NoSelect -or -not $script:CurrentSession) {
        $script:CurrentSession = $session
        [Environment]::SetEnvironmentVariable("__PSAI_SESSION_PID_$PID", [string]$session.id, 'Process')
    }
    [pscustomobject]$session
}

function Get-PSAISession {
    [CmdletBinding()] param([string]$Id)
    $sessions = if ($Id) { @((Import-AISession $Id)) } else {
        @(Get-ChildItem -LiteralPath $script:SessionDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue |
            ForEach-Object { Import-AISession $_.BaseName })
    }
    $sessions | Where-Object { $_ } | Sort-Object updatedUtc -Descending | ForEach-Object {
        [pscustomobject]@{
            Id = $_.id; Title = $_.title; CreatedUtc = [datetime]$_.createdUtc; UpdatedUtc = [datetime]$_.updatedUtc
            TurnCount = @($_.turns).Count; Active = ([string]$_.id -eq [string]$script:CurrentSession.id)
            InputTokens = [long]$_.inputTokens; OutputTokens = [long]$_.outputTokens
        }
    }
}

function Select-PSAISession {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Id)
    $session = Import-AISession $Id
    if (-not $session) { throw "会话不存在：$Id" }
    $script:CurrentSession = $session
    [Environment]::SetEnvironmentVariable("__PSAI_SESSION_PID_$PID", [string]$session.id, 'Process')
    Get-PSAISession -Id $Id
}

function Clear-PSAISession {
    [CmdletBinding(SupportsShouldProcess)] param([string]$Id)
    if (-not $PSBoundParameters.ContainsKey('Id')) { $Id = [string](Get-PSAIStoredProperty $script:CurrentSession 'id') }
    if (-not $Id) { return }
    $session = Import-AISession $Id
    if (-not $session) { throw "会话不存在：$Id" }
    if (-not $PSCmdlet.ShouldProcess($Id, '清空 AI 会话上下文')) { return }
    $path = Get-AISessionPath $Id
    Invoke-AIWithFileLock $path {
        $latest = Import-AISession $Id
        if (-not $latest) { throw "会话不存在或无法读取：$Id" }
        $latest.turns = @()
        $latest.inputTokens = 0L
        $latest.outputTokens = 0L
        Save-AISession $latest -LockHeld
        if ($Id -eq $script:CurrentSession.id) { $script:CurrentSession = $latest }
        $msg = if ((Get-AILanguage) -eq 'en-US') { "PSAITerminal session context cleared." } else { "PSAITerminal 会话上下文已清空。" }
        Write-AIColoredHost "✓ $msg" Green
    }
}

function Format-AICompactTurnContent([string]$Content, [int]$MaxLines = 50, [int]$MaxChars = 3000) {
    if ([string]::IsNullOrEmpty($Content)) { return $Content }
    if ($Content.Length -le $MaxChars) { return $Content }
    $lines = $Content -split "\r?\n"
    if ($lines.Length -le $MaxLines) { return $Content }
    $head = $lines[0..24] -join "`n"
    $tail = $lines[($lines.Length - 25)..($lines.Length - 1)] -join "`n"
    $omitted = $lines.Length - 50
    $note = if ((Get-AILanguage) -eq 'en-US') {
        "[... Middle $omitted lines omitted for context efficiency, full output preserved in session file ...]"
    } else {
        "[... 为优化上下文效率已省略中间 $omitted 行输出，完整日志保存在本地会话文件中 ...]"
    }
    "$head`n`n$note`n`n$tail"
}

# 1.0.x 会话中的 tool_proposal 轮次只是审批记录，不进入上下文。
function Test-AITurnMeaningfulForContext($Turn) {
    $Turn -and [string]$Turn.kind -ne 'tool_proposal'
}

# 上下文预算按模型窗口估算（每 Token 约 2 个字符，中英文混合时偏保守），超出时丢弃最早的轮次。
function Get-AISessionMessages([Collections.IDictionary]$Model, [string]$Instruction) {
    $window = if ($Model -and $Model.contextWindow) { [int]$Model.contextWindow } else { 32768 }
    $maximumCharacters = [Math]::Min(262144, [Math]::Max(16384, $window * 2))
    $messages = [Collections.Generic.List[object]]::new()
    $turns = if ($script:CurrentSession) { @($script:CurrentSession.turns) } else { @() }
    $toolPrefix = if ((Get-AILanguage) -eq 'en-US') { '[Tool Result] ' } else { '[工具结果] ' }
    foreach ($turn in $turns) {
        if (-not (Test-AITurnMeaningfulForContext $turn)) { continue }
        $role = if ([string]$turn.role -eq 'assistant') { 'assistant' } else { 'user' }
        $content = Format-AICompactTurnContent ([string]$turn.content)
        if ([string]$turn.role -eq 'tool') { $content = $toolPrefix + $content }
        $messages.Add([ordered]@{ role = $role; content = (Protect-AIText $content -1) })
    }
    if ($Instruction) { $messages.Add([ordered]@{ role = 'user'; content = (Protect-AIText $Instruction 65536) }) }

    $totalCharacters = 0
    foreach ($message in $messages) { $totalCharacters += ([string]$message.content).Length }
    while ($totalCharacters -gt $maximumCharacters -and $messages.Count -gt 1) {
        $totalCharacters -= ([string]$messages[0].content).Length
        $messages.RemoveAt(0)
    }
    $messages
}

function Invoke-AISessionModel([Collections.IDictionary]$Model, [string]$Instruction, [switch]$EnableTools,
    [switch]$NoRender, [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None) {
    $messages = Get-AISessionMessages $Model $Instruction
    Invoke-AIModelText -Model $Model -Messages $messages -EnableTools:$EnableTools -NoRender:$NoRender -CancellationToken $CancellationToken
}