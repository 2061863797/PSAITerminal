# 新安装、配置迁移、确定性路由与 Harness 调度行。
# 由 tests/run.ps1 在同一作用域内按文件名顺序点源执行，依赖其中的 $module、$testRoot 等状态，不能单独运行。

# 新安装、配置迁移和确定性路由。
Assert-Equal $false (Test-Path -LiteralPath (Join-Path $env:PSAI_CONFIG_HOME 'config.json')) '模块导入不能隐式写入共享配置。'
Set-PSAITerminalOption -Language en-US | Out-Null
$config = Get-Content -LiteralPath (Join-Path $env:PSAI_CONFIG_HOME 'config.json') -Raw | ConvertFrom-Json
Assert-Equal 3 $config.schemaVersion '配置必须写为 schemaVersion 3。'
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
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets','',Justification='局部交互测试桩，测试结束即移除。')]
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
$menuUninstallProbe = & $module {
    $prompts = [Collections.Generic.List[string]]::new()
    function Read-Host {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets','',Justification='局部菜单测试桩，测试结束即移除。')]
        param([Parameter(ValueFromRemainingArguments)]$Arguments)
        $prompt = ($Arguments -join ' ')
        $prompts.Add($prompt)
        if ($prompts.Count -eq 1) { return '7' }
        if ($prompts.Count -eq 2) { return 'n' }
        return '0'
    }
    try {
        Open-PSAISettings 6>$null
        [pscustomobject]@{Count=$prompts.Count;Prompts=($prompts -join '|')}
    } finally { Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue }
}
Assert-True ($menuUninstallProbe.Count -ge 2) '设置菜单选择 7 必须进入卸载确认，且用户取消后能安全返回。'
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
    finally { Remove-PSReadLineKeyHandler -Chord F12 -ErrorAction SilentlyContinue; [void]$script:BoundKeys.Remove('F12'); [void]$script:OriginalKeyBindings.Remove('F12') }
}
Assert-Equal $true $keyProbe.Registered '未占用快捷键应能注册。'
Assert-Equal 'PSAITest' $keyProbe.Function '注册后应能从 PSReadLine 查询到处理器。'
$conflictProbe = & $module {
    Set-PSReadLineKeyHandler -Key F12 -Function AcceptLine
    try {
        $registered = Set-AIPSAIKeyHandler F12 'PSAIConflict' {} @()
        [pscustomobject]@{Registered=$registered;Function=(Get-AIPSReadLineKeyHandler F12).Function}
    } finally { Remove-PSReadLineKeyHandler -Chord F12 -ErrorAction SilentlyContinue }
} 3>$null
Assert-Equal $false $conflictProbe.Registered '默认不得覆盖已有快捷键。'
Assert-Equal 'AcceptLine' $conflictProbe.Function '冲突处理器必须保持不变。'

$defaultBindingProbe = & $module {
    Set-PSReadLineKeyHandler -Key F12 -Function AcceptLine
    try {
        $registered = Set-AIPSAIKeyHandler F12 'PSAITestDefaultBinding' {} @('AcceptLine')
        [pscustomobject]@{Registered=$registered;Function=(Get-AIPSReadLineKeyHandler F12).Function}
    } finally { Remove-PSReadLineKeyHandler -Chord F12 -ErrorAction SilentlyContinue; [void]$script:BoundKeys.Remove('F12'); [void]$script:OriginalKeyBindings.Remove('F12') }
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
Assert-Equal '. (Invoke-PSAI)' $submittedLineProbe.AI 'F2/ForceAI 必须保留显式交给 AI 的语义。'
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
