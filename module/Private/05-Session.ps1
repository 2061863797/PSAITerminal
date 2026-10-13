# 会话持久化、上下文组装与压缩。

function New-AISessionObject([string]$Title) {
    $now = [DateTime]::UtcNow.ToString('O')
    [ordered]@{
        schemaVersion = 1
        revision = 0L
        id = [guid]::NewGuid().ToString('N')
        title = if ([string]::IsNullOrWhiteSpace($Title)) { '新会话' } else { (Protect-AIText $Title 120) }
        createdUtc = $now
        updatedUtc = $now
        summary = ''
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
        if ($session.summary -isnot [string] -or $session.summary.Length -gt 65536) { throw '会话摘要无效。' }
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
        $session.summary = Protect-AIText ([string]$session.summary) 16384
        if (Test-AIMapContains $session 'compactedTurnCount') {
            Assert-AIIntegerValue $session.compactedTurnCount 0 $session.turns.Count '会话已压缩 Turn 数'
        }
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
        $latest.summary = ''
        $latest.turns = @()
        $latest.inputTokens = 0L
        $latest.outputTokens = 0L
        [void]$latest.Remove('compactedTurnCount')
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

function Get-AISessionContextText([int]$MaximumCharacters = 131072) {
    if (-not $script:CurrentSession) { return '' }
    $parts = [Collections.Generic.List[string]]::new()
    if ($script:CurrentSession.summary) { $parts.Add("较早对话摘要：`n$($script:CurrentSession.summary)") }
    $start = if (Test-AIMapContains $script:CurrentSession 'compactedTurnCount') { [int]$script:CurrentSession.compactedTurnCount } else { 0 }
    $turns = @($script:CurrentSession.turns)
    for ($index=$start; $index -lt $turns.Count; $index++) {
        $turn = $turns[$index]
        if (-not (Test-AITurnMeaningfulForContext $turn)) { continue }
        $label = switch ([string]$turn.role) { 'user' {'用户'} 'assistant' {'AI'} 'tool' {'工具结果'} default {[string]$turn.role} }
        $content = Format-AICompactTurnContent ([string]$turn.content)
        $content = [regex]::Replace($content, '(?i)\b[a-f0-9]{32}\b', '[ID]')
        $parts.Add("[$label/$($turn.kind)] $content")
    }
    $value = Protect-AIText ($parts -join "`n`n") -1
    if ($value.Length -le $MaximumCharacters) { return $value }
    $marker = "[较早上下文已省略，完整内容仍保存在会话文件中]`n"
    $keep = [Math]::Max(0, $MaximumCharacters - $marker.Length)
    $startIndex = $value.Length - $keep
    if ($startIndex -gt 0 -and [char]::IsLowSurrogate($value[$startIndex])) { $startIndex++ }
    $marker + $value.Substring($startIndex)
}

function Compress-AISessionIfNeeded([Collections.IDictionary]$Model, [Threading.CancellationToken]$CancellationToken) {
    if (-not $script:CurrentSession) { return }
    if ($script:LastSessionCompressionFailureUtc) {
        $elapsedSeconds = ([DateTime]::UtcNow - $script:LastSessionCompressionFailureUtc).TotalSeconds
        if ($elapsedSeconds -ge 0 -and $elapsedSeconds -lt 300) { return }
    }
    $turns = @($script:CurrentSession.turns)
    $recentCount = [int]$script:Config.execution.recentTurns
    if ($turns.Count -le $recentCount) { return }
    $window = [int]$Model.contextWindow
    $thresholdCharacters = [int]([Math]::Max(4096, $window * 4 * ([int]$script:Config.execution.contextBudgetPercent / 100.0)))
    $context = Get-AISessionContextText ([Math]::Min(1048576, $thresholdCharacters + 1))
    if ($context.Length -le $thresholdCharacters) { return }

    $targetCount = $turns.Count - $recentCount
    $alreadyCompacted = if (Test-AIMapContains $script:CurrentSession 'compactedTurnCount') { [int]$script:CurrentSession.compactedTurnCount } else { 0 }
    if ($targetCount -le $alreadyCompacted) { return }
    $source = [Collections.Generic.List[string]]::new()
    if ($script:CurrentSession.summary) { $source.Add("已有摘要：$($script:CurrentSession.summary)") }
    for ($index=$alreadyCompacted; $index -lt $targetCount; $index++) {
        $t = $turns[$index]
        if (Test-AITurnMeaningfulForContext $t) {
            $source.Add("$($t.role)：$($t.content)")
        }
    }
    $summaryPrompt = "把下面本地终端会话压缩为简洁事实摘要。保留用户目标、关键路径、已执行命令、结果、错误、未完成事项和明确偏好；不要补充不存在的信息；不要调用工具。`n`n$(Protect-AIText ($source -join "`n") 60000)"
    $previousSummary = [string]$script:CurrentSession.summary
    $hadCompactedTurnCount = Test-AIMapContains $script:CurrentSession 'compactedTurnCount'
    $previousCompactedTurnCount = if ($hadCompactedTurnCount) { [int]$script:CurrentSession.compactedTurnCount } else { 0 }
    $previousInputTokens = [long]$script:CurrentSession.inputTokens
    $previousOutputTokens = [long]$script:CurrentSession.outputTokens
    try {
        $summaryResult = Invoke-AIModelText -Model $Model -Prompt $summaryPrompt -NoRender -CancellationToken $CancellationToken
        $script:CurrentSession.summary = Protect-AIText $summaryResult.Text 16384
        $script:CurrentSession.compactedTurnCount = $targetCount
        Add-AISessionUsageValues $script:CurrentSession ([long]$summaryResult.InputTokens) ([long]$summaryResult.OutputTokens)
        Save-AISession
        $script:LastSessionCompressionFailureUtc = $null
    } catch {
        $script:LastSessionCompressionFailureUtc = [DateTime]::UtcNow
        $script:CurrentSession.summary = $previousSummary
        if ($hadCompactedTurnCount) { $script:CurrentSession.compactedTurnCount = $previousCompactedTurnCount }
        else { [void]$script:CurrentSession.Remove('compactedTurnCount') }
        $script:CurrentSession.inputTokens = $previousInputTokens
        $script:CurrentSession.outputTokens = $previousOutputTokens
        Write-Warning "会话自动压缩失败，本次继续使用最近上下文：$($_.Exception.Message)"
    }
}

function Get-AISessionMessages([string]$Instruction, [int]$MaximumCharacters = 131072) {
    $messages = [Collections.Generic.List[object]]::new()
    if (-not $script:CurrentSession) {
        if ($Instruction) {
            $messages.Add([ordered]@{ role = 'user'; content = (Protect-AIText $Instruction 65536) })
        }
        return $messages
    }

    $hasSummary = (Test-AIMapContains $script:CurrentSession 'summary') -and (-not [string]::IsNullOrWhiteSpace([string]$script:CurrentSession['summary']))
    if ($hasSummary) {
        $summaryText = [string]$script:CurrentSession['summary']
        $summaryLabel = if ((Get-AILanguage) -eq 'en-US') {
            "Previous session facts summary:`n$summaryText"
        } else {
            "较早对话摘要：`n$summaryText"
        }
        $ackText = if ((Get-AILanguage) -eq 'en-US') { "Understood. I will follow the earlier context." } else { "已了解上述历史会话事实。" }
        $messages.Add([ordered]@{ role = 'user'; content = (Protect-AIText $summaryLabel 16384) })
        $messages.Add([ordered]@{ role = 'assistant'; content = $ackText })
    }

    $start = if (Test-AIMapContains $script:CurrentSession 'compactedTurnCount') { [int]$script:CurrentSession['compactedTurnCount'] } else { 0 }
    $turns = if (Test-AIMapContains $script:CurrentSession 'turns') { @($script:CurrentSession['turns']) } else { @() }
    for ($index = $start; $index -lt $turns.Count; $index++) {
        $turn = $turns[$index]
        if (-not (Test-AITurnMeaningfulForContext $turn)) { continue }
        $rawRole = [string]$turn.role
        $role = if ($rawRole -eq 'assistant') { 'assistant' } else { 'user' }
        $content = Format-AICompactTurnContent ([string]$turn.content)
        $content = [regex]::Replace($content, '(?i)\b[a-f0-9]{32}\b', '[ID]')

        $prefix = if ($rawRole -eq 'tool') {
            if ((Get-AILanguage) -eq 'en-US') { "[Tool Result] " } else { "[工具结果] " }
        } else { '' }
        $safeContent = Protect-AIText "$prefix$content" -1
        $messages.Add([ordered]@{ role = $role; content = $safeContent })
    }

    if ($Instruction) {
        $messages.Add([ordered]@{ role = 'user'; content = (Protect-AIText $Instruction 65536) })
    }

    $totalChars = 0
    foreach ($m in $messages) { $totalChars += [string]$m.content.Length }
    while ($totalChars -gt $MaximumCharacters -and $messages.Count -gt 2) {
        $removed = $messages[0]
        $messages.RemoveAt(0)
        $totalChars -= [string]$removed.content.Length
    }

    $messages
}

function Invoke-AISessionModel([Collections.IDictionary]$Model, [string]$Instruction, [switch]$EnableTools,
    [switch]$NoRender, [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None) {
    Compress-AISessionIfNeeded $Model $CancellationToken
    $messages = Get-AISessionMessages -Instruction $Instruction
    Invoke-AIModelText -Model $Model -Messages $messages -EnableTools:$EnableTools -NoRender:$NoRender -CancellationToken $CancellationToken
}
