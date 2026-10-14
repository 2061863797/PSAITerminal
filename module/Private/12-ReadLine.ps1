# PSReadLine 按键拦截与智能输入路由。

function Set-AICurrentBuffer([string]$Text) {
    $current = $null; $cursor = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$current, [ref]$cursor)
    [Microsoft.PowerShell.PSConsoleReadLine]::Replace(0, ([string]$current).Length, $Text)
}

function Get-AICurrentBuffer {
    $line = $null; $cursor = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    [string]$line
}

function Test-AIAutoRoute([string]$Line) {
    $commandExists = [Func[string,bool]]{
        param($name)
        [bool](Get-Command -Name ([WildcardPattern]::Escape($name)) -ErrorAction SilentlyContinue)
    }
    $pathExists = [Func[string,bool]]{
        param($name)
        if (-not (Test-Path -LiteralPath $name -PathType Leaf)) { return $false }
        [IO.Path]::GetExtension($name) -in @('.ps1','.psm1','.cmd','.bat','.exe','.com')
    }
    [PSAITerminal.AITerminalInputRouter]::NeedsAgent($Line, $commandExists, $pathExists)
}

function ConvertTo-AISubmittedLine([string]$Line) {
    $action = [string]$script:NextReadLineAction
    $script:NextReadLineAction = $null
    if ($action -eq 'Explain') { return ConvertTo-AIExplainLine }
    if ($action -eq 'ForceShell' -or [string]::IsNullOrWhiteSpace($Line)) { return $Line }

    $trimmed = $Line.Trim()
    if ($trimmed -match '^(?i:ai)$') { return 'Open-PSAISettings' }
    if ($trimmed -match '^(?i:ai)\s+(?:help|\?|--help|-h)$') { return 'Show-AICliHelp' }
    if ($trimmed -match '^(?i:ai)\s+(?:clear|reset)$') { return 'Clear-PSAISession' }
    if ($trimmed -match '^(?i:ai)\s+new(?:\s+(.+))?$') {
        $title = if ($Matches[1]) { $Matches[1].Trim() } else { '新会话' }
        return "New-PSAISession -Title $(ConvertTo-AISingleQuotedLiteral $title)"
    }
    if ($trimmed -match '^(?i:ai)\s+mode(?:\s+(Off|AI|Auto))?$') {
        if ($Matches[1]) { return "Set-PSAITerminalMode -Mode '$($Matches[1])'" }
        return 'Get-PSAITerminalMode'
    }
    if ($trimmed -match '^(?i:ai)\s+(.+)$') { return ConvertTo-AIAgentLine $Matches[1].Trim() }
    if ($action -eq 'ForceAI') { return ConvertTo-AIAgentLine $Line }
    switch ([string]$script:Config.mode) {
        'AI' { return ConvertTo-AIAgentLine $Line }
        'Auto' {
            # 只区分“可执行的 PowerShell”和“其他输入”；命令原样执行，不做包装。
            if (-not [PSAITerminal.AITerminalInputRouter]::IsIncomplete($Line) -and (Test-AIAutoRoute $Line)) {
                return ConvertTo-AIAgentLine $Line
            }
        }
    }
    $Line
}
function Invoke-AIEnterHandler {
    param([switch]$ForceAI)
    $line = Get-AICurrentBuffer
    if ($line -and ($ForceAI -or $script:Config.mode -eq 'AI') -and
        [PSAITerminal.AITerminalInputRouter]::IsIncomplete($line)) {
        # 注释只用于通过原生编辑器的续行判定，原文由宿主读取层消费一次。
        $bridge = (@($line -split '\r\n|\n|\r' | ForEach-Object { '# ' + $_ }) -join "`n")
        $script:PendingAIInputBridge = @{Original=$line;Submitted=$bridge}
        [Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory($line)
        [void]$script:InternalHistoryLines.Add($bridge)
        Set-AICurrentBuffer $bridge
        $script:NextReadLineAction = 'ForceAI'
    }
    [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
}

function Invoke-AIHostReadLine([bool]$LastRunStatus) {
    if (-not $script:OriginalPSConsoleHostReadLine) {
        throw 'PSAITerminal 无法找到宿主原始输入读取函数。'
    }
    if ($LastRunStatus) { $null = $true }
    else { Write-Error 'PSAITerminal input status preservation' -ErrorAction Ignore }
    if ($script:NextInputBuffer) {
        # Agent 选择“放入命令行”时，把命令写入控制台输入缓冲区，由用户修改后自行回车；不可用时放入历史记录。
        $text = [string]$script:NextInputBuffer
        $script:NextInputBuffer = $null
        if (-not [PSAITerminal.AITerminalConsoleInput]::TryWrite($text)) {
            [Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory($text)
            Write-AIColoredHost (Get-AIText 'CommandInHistory') DarkGray
        }
    }
    try { $line = & $script:OriginalPSConsoleHostReadLine }
    catch { $script:PendingAIInputBridge=$null; $script:NextReadLineAction=$null; throw }
    $bridge = $script:PendingAIInputBridge
    $script:PendingAIInputBridge = $null
    if ($bridge) {
        if ($line -ceq $bridge.Submitted) { $line = $bridge.Original }
        else { $script:NextReadLineAction=$null; [void]$script:InternalHistoryLines.Remove($bridge.Submitted) }
    }
    ConvertTo-AISubmittedLine $line
}

function Get-AIPSReadLineKeyHandler([string]$Key) {
    $command = Get-Command Get-PSReadLineKeyHandler -ErrorAction SilentlyContinue
    if (-not $command) { return $null }
    if ($command.Parameters.ContainsKey('Chord')) {
        return Get-PSReadLineKeyHandler -Chord $Key -ErrorAction SilentlyContinue
    }
    @(Get-PSReadLineKeyHandler -Bound -ErrorAction SilentlyContinue | Where-Object {
        @([string]$_.Key -split ',\s*') -contains $Key
    }) | Select-Object -First 1
}

function Set-AIPSAIKeyHandler([string]$Key, [string]$Description, [scriptblock]$Handler,
    [string[]]$ReplaceableFunctions, [switch]$Force) {
    if (-not $Key) { return $false }
    $current = Get-AIPSReadLineKeyHandler $Key
    if ($current -and $current.Function -notlike 'PSAI*' -and $current.Function -notin $ReplaceableFunctions -and -not $Force) {
        Write-Warning "快捷键 $Key 已由 '$($current.Function)' 使用，PSAITerminal 未覆盖。"
        return $false
    }
    if (-not (Test-AIMapContains $script:OriginalKeyBindings $Key)) {
        $script:OriginalKeyBindings[$Key] = if ($current) { [string]$current.Function } else { $null }
    }
    Set-PSReadLineKeyHandler -Key $Key -BriefDescription $Description -LongDescription $Description -ScriptBlock $Handler
    [void]$script:BoundKeys.Add($Key)
    $true
}

function Register-AIPSReadLineIntegration {
    param([switch]$Force)
    if ($script:PSReadLineIntegrated -or $Host.Name -ne 'ConsoleHost' -or
        [Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return }
    if (-not (Get-Module PSReadLine) -and -not (Import-Module PSReadLine -ErrorAction SilentlyContinue -PassThru)) { return }

    $readLineCommand = Get-Command PSConsoleHostReadLine -CommandType Function -ErrorAction SilentlyContinue
    if (-not $readLineCommand) { return }
    $state = Get-AIPromptIntegrationState
    if ($state -and $state.PSObject.Properties['ReadLineWrapper'] -and
        (Test-AISamePromptScriptBlock $readLineCommand.ScriptBlock $state.ReadLineWrapper)) {
        $script:OriginalPSConsoleHostReadLine = $state.OriginalReadLine
    } else {
        $script:OriginalPSConsoleHostReadLine = $readLineCommand.ScriptBlock
    }
    $script:PSAIHostReadLine = [scriptblock]::Create(@'
[System.Diagnostics.DebuggerHidden()]
param()
$lastRunStatus = $?
Microsoft.PowerShell.Core\Set-StrictMode -Off
$state = [AppDomain]::CurrentDomain.GetData('__PSAITerminalPromptIntegrationState')
$module = if ($state -and $state.Owner) { $state.Owner } else { Get-Module PSAITerminal | Select-Object -Last 1 }
if (-not $module) { throw 'PSAITerminal 输入路由的活动模块实例不存在。' }
& $module { param($status) Invoke-AIHostReadLine $status } $lastRunStatus
'@)
    Set-Item -LiteralPath Function:\global:PSConsoleHostReadLine -Value $script:PSAIHostReadLine

    if ($script:ShortcutMigrated) {
        $shiftEnter = Get-AIPSReadLineKeyHandler 'Shift+Enter'
        if (-not $shiftEnter -or $shiftEnter.Function -eq 'PSAIForceAI') {
            Set-PSReadLineKeyHandler -Key 'Shift+Enter' -Function AddLine
        }
        foreach ($legacyKey in @('Alt+A','Alt+S','Alt+M','Alt+E','Alt+Enter','Ctrl+Shift+I','Ctrl+Shift+E','Ctrl+Shift+,','Ctrl+Shift+M')) {
            $legacyHandler = Get-AIPSReadLineKeyHandler $legacyKey
            if ($legacyHandler -and $legacyHandler.Function -like 'PSAI*') { Remove-PSReadLineKeyHandler -Chord $legacyKey }
        }
    }

    $script:OriginalAddToHistoryHandler = (Get-PSReadLineOption).AddToHistoryHandler
    $script:PSAIAddToHistoryHandler = [Func[string,object]]{
        param([string]$line)
        if ($script:InternalHistoryLines.Remove($line)) { return [Microsoft.PowerShell.AddToHistoryOption]::SkipAdding }
        if ($script:OriginalAddToHistoryHandler) { return $script:OriginalAddToHistoryHandler.Invoke($line) }
        [Microsoft.PowerShell.AddToHistoryOption]::MemoryAndFile
    }
    Set-PSReadLineOption -AddToHistoryHandler $script:PSAIAddToHistoryHandler

    if ([bool]$script:Config.integrations.enterRouting) {
        [void](Set-AIPSAIKeyHandler Enter 'PSAIEnter' { Invoke-AIEnterHandler } @('AcceptLine') -Force:$Force)
    }
    [void](Set-AIPSAIKeyHandler $script:Config.shortcuts.cycleMode 'PSAICycleMode' {
        $next = switch ([string]$script:Config.mode) { 'Off' {'AI'} 'AI' {'Auto'} default {'Off'} }
        if ($next -ne 'Off' -and -not $script:Config.activeModel) {
            Set-AICurrentBuffer 'Open-PSAISettings'
        } else {
            Set-AICurrentBuffer "Set-PSAITerminalMode $next"
        }
        $script:NextReadLineAction = 'ForceShell'
        [void]$script:InternalHistoryLines.Add((Get-AICurrentBuffer))
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    } @() -Force:$Force)
    [void](Set-AIPSAIKeyHandler $script:Config.shortcuts.forceAI 'PSAIForceAI' {
        if (Get-AICurrentBuffer) { $script:NextReadLineAction = 'ForceAI' }
        Invoke-AIEnterHandler -ForceAI
    } @('SwitchPredictionView') -Force:$Force)
    [void](Set-AIPSAIKeyHandler $script:Config.shortcuts.forceShell 'PSAIForceShell' {
        if (Get-AICurrentBuffer) { $script:NextReadLineAction = 'ForceShell' }
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    } @('CharacterSearch') -Force:$Force)
    if ($script:Config.shortcuts.openSettings) {
        [void](Set-AIPSAIKeyHandler $script:Config.shortcuts.openSettings 'PSAISettings' {
            Set-AICurrentBuffer 'Open-PSAISettings'; $script:NextReadLineAction = 'ForceShell'; [void]$script:InternalHistoryLines.Add('Open-PSAISettings'); [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
        } @() -Force:$Force)
    }
    if ($script:Config.shortcuts.selectModel) {
        [void](Set-AIPSAIKeyHandler $script:Config.shortcuts.selectModel 'PSAIModels' {
            Set-AICurrentBuffer 'Open-PSAIModelSelector'; $script:NextReadLineAction = 'ForceShell'; [void]$script:InternalHistoryLines.Add('Open-PSAIModelSelector'); [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
        } @() -Force:$Force)
    }
    [void](Set-AIPSAIKeyHandler $script:Config.shortcuts.explainLast 'PSAIExplain' {
        Set-AICurrentBuffer '# PSAI F7'; $script:NextReadLineAction = 'Explain'; [void]$script:InternalHistoryLines.Add('# PSAI F7'); [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    } @() -Force:$Force)
    $script:PSReadLineIntegrated = $true
}

function Unregister-AIPSReadLineIntegration {
    if (-not $script:PSReadLineIntegrated) { return }
    foreach ($key in @($script:BoundKeys)) {
        $current = Get-AIPSReadLineKeyHandler $key
        if (-not $current -or $current.Function -notlike 'PSAI*') { continue }
        $original = $script:OriginalKeyBindings[$key]
        if ($original) { Set-PSReadLineKeyHandler -Key $key -Function $original }
        else { Remove-PSReadLineKeyHandler -Chord $key -ErrorAction SilentlyContinue }
    }
    $currentHistoryHandler = (Get-PSReadLineOption).AddToHistoryHandler
    if ([object]::ReferenceEquals($currentHistoryHandler, $script:PSAIAddToHistoryHandler)) {
        Set-PSReadLineOption -AddToHistoryHandler $script:OriginalAddToHistoryHandler
    }
    $currentReadLine = Get-Command PSConsoleHostReadLine -CommandType Function -ErrorAction SilentlyContinue
    if ($script:OriginalPSConsoleHostReadLine -and $currentReadLine -and
        [object]::ReferenceEquals($currentReadLine.ScriptBlock, $script:PSAIHostReadLine)) {
        Set-Item -LiteralPath Function:\global:PSConsoleHostReadLine -Value $script:OriginalPSConsoleHostReadLine
    }
    $script:BoundKeys.Clear()
    $script:OriginalKeyBindings.Clear()
    $script:InternalHistoryLines.Clear()
    $script:PendingInvocationScripts.Clear()
    $script:NextPendingInvocationId = $null
    $script:NextReadLineAction = $null
    $script:PSAIHostReadLine = $null
    $script:OriginalPSConsoleHostReadLine = $null
    $script:PSAIAddToHistoryHandler = $null
    $script:OriginalAddToHistoryHandler = $null
    $script:PSReadLineIntegrated = $false
}

function Get-AIShortcutStatus {
    $definitions = @(
        [pscustomobject]@{Action='交给 AI';Key=[string]$script:Config.shortcuts.forceAI;Expected='PSAIForceAI'},
        [pscustomobject]@{Action='强制 Shell';Key=[string]$script:Config.shortcuts.forceShell;Expected='PSAIForceShell'},
        [pscustomobject]@{Action='切换模式';Key=[string]$script:Config.shortcuts.cycleMode;Expected='PSAICycleMode'},
        [pscustomobject]@{Action='解释命令';Key=[string]$script:Config.shortcuts.explainLast;Expected='PSAIExplain'}
    )
    foreach ($definition in $definitions) {
        $actual = $null
        try {
            $handler = Get-AIPSReadLineKeyHandler $definition.Key
            if ($handler) { $actual = [string]$handler.Function }
        } catch { Write-Verbose "无法检查快捷键 $($definition.Key)：$($_.Exception.Message)" }
        [pscustomobject]@{
            Action = $definition.Action
            Key = $definition.Key
            Expected = $definition.Expected
            Actual = $actual
            Active = ($actual -eq $definition.Expected)
        }
    }
}
