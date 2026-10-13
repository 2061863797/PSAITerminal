# <#
# .SYNOPSIS
#     PSAITerminal - 本地 AI 增强终端模块（支持 Windows PowerShell 5.1 与 PowerShell 7.4+）
#
# .DESCRIPTION
#     模块结构索引：
#     - 本文件：模块初始化与全局状态、功能文件加载、导出与清理钩子
#     - PSAIStorageSafety.ps1：与安装/卸载脚本共用的文件、Profile 与安全清理辅助函数
#     - Private/01-Integration.ps1：官方集成（PowerShell 7 预测器与反馈接入）
#     - Private/02-I18n.ps1：本地化与多语言字典
#     - Private/03-Prompt.ps1：终端提示符（Prompt）安全包装与防重入
#     - Private/04-Config.ps1：配置管理、原子读写与并发乐观锁
#     - Private/05-Session.ps1：会话持久化、上下文组装与压缩
#     - Private/06-Secrets.ps1：凭据存储与安全脱敏（含内存密钥缓存）
#     - Private/07-Risk.ps1：命令 AST 安全分析、风险分级与审批摘要
#     - Private/08-Models.ps1：模型配置、远程模型列表与连通性测试
#     - Private/09-Transport.ps1：REST HTTP 客户端、请求体与 SSE 流式解析
#     - Private/10-Menus.ps1：交互式终端菜单、设置 UI 与模式/选项命令
#     - Private/11-Agent.ps1：Agent 任务调度、审批机制与顶层执行 Harness
#     - Private/12-ReadLine.ps1：PSReadLine 按键拦截与智能输入路由
#     - Private/13-Profile.ps1：Profile 自动加载注入、自检与卸载清理
#     发布构建会把 Private/ 按文件名顺序内联进单个 psm1，发布包文件集合不变。
# #>

#region 1. 模块初始化、环境检测与全局状态
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'PSAIStorageSafety.ps1')

$script:ModuleName = 'PSAITerminal'
# 函数可能定义在 Private/ 中，其 $PSScriptRoot 不是模块根，需要模块根时统一使用此值。
$script:ModuleRoot = $PSScriptRoot
$script:HostEdition = if ($PSVersionTable.PSEdition) { [string]$PSVersionTable.PSEdition } else { 'Desktop' }
$script:HostVersion = [version]$PSVersionTable.PSVersion
$script:IsWindowsPlatform = $env:OS -eq 'Windows_NT'
$script:OfficialIntegrationAvailable = $false
if (-not $script:IsWindowsPlatform) {
    throw 'PSAITerminal 1.0.0 仅支持 Windows。'
}
if ($script:HostEdition -eq 'Core') {
    if ($script:HostVersion -lt [version]'7.4') {
        throw "PSAITerminal 在 PowerShell Core 中要求 7.4 或更高版本；当前为 $script:HostVersion。"
    }
    $integrationAssemblyPath = Join-Path $PSScriptRoot 'bin/PSAITerminal.PowerShell7.dll'
    if (-not (Test-Path -LiteralPath $integrationAssemblyPath -PathType Leaf)) {
        throw "PowerShell 7 集成程序集不存在：$integrationAssemblyPath"
    }
    [void][Reflection.Assembly]::LoadFrom($integrationAssemblyPath)
    $script:OfficialIntegrationAvailable = $true
}
$script:ValidModes = @('Off', 'AI', 'Auto')
$script:ValidProtocols = @('Anthropic', 'OpenAIChat', 'OpenAIResponses', 'GeminiNative', 'Ollama')
$script:SessionSecrets = @{}
$script:SecretMaskingCache = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$script:SecretMaskingCacheInitialized = $false
$script:LastSubmittedCommand = $null
$script:LastCommandResult = $null
$script:PredictorEnabled = $false
$script:FeedbackEnabled = $false
$script:PSReadLineIntegrated = $false
$script:ShortcutMigrated = $false
$script:OriginalKeyBindings = @{}
$script:BoundKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:InternalHistoryLines = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$script:PendingInvocationScripts = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
$script:NextPendingInvocationId = $null
$script:OriginalAddToHistoryHandler = $null
$script:PSAIAddToHistoryHandler = $null
$script:OriginalPSConsoleHostReadLine = $null
$script:PSAIHostReadLine = $null
$script:NextReadLineAction = $null
$script:PendingAIInputBridge = $null
$script:OriginalPrompt = $null
$script:PSAIPromptWrapper = $null
$script:PromptInvocationActive = $false
$script:PromptStateVariableName = '__PSAITerminalPromptIntegrationState'
$script:PromptOwnerToken = [guid]::NewGuid().ToString('N')
$script:CurrentSession = $null
$script:ConfigLoadFailed = $false
$script:LastSecretStoreError = $null
$script:Config = $null
$script:MaximumConfigBytes = 1MB
$script:MaximumSessionBytes = 16MB
$script:MaximumRunBytes = 4MB
$script:FileLockTimeoutMilliseconds = 10000
$script:LastSessionCompressionFailureUtc = $null
#endregion

#region 2-13. 功能实现（源码位于 Private/，构建时按文件名顺序内联到发布版 psm1）
# <PSAI:PRIVATE-BEGIN>
foreach ($privateScript in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -File | Sort-Object Name)) {
    . $privateScript.FullName
}
# <PSAI:PRIVATE-END>
#endregion

#region 14. 模块导出与清理钩子
Initialize-AIState
Initialize-AISessionState

if ($script:OfficialIntegrationAvailable -and $script:Config.integrations.feedbackProvider) {
    [PSAITerminal.AITerminalOfficialIntegration]::RegisterFeedback(); $script:FeedbackEnabled = $true
}
if ($script:OfficialIntegrationAvailable -and $script:Config.integrations.predictor) {
    [PSAITerminal.AITerminalOfficialIntegration]::RegisterPredictor(); $script:PredictorEnabled = $true
}
Register-AIPSReadLineIntegration
Register-AIPromptIntegration
if ($script:Config.activeModel -and $Host.Name -eq 'ConsoleHost' -and
    -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) {
    $configuredModel = $script:Config.models[[string]$script:Config.activeModel]
    if ($configuredModel -and $configuredModel.protocol -ne 'Ollama' -and -not (Get-AISecret ([string]$configuredModel.name))) {
        $detail = if ($script:LastSecretStoreError) { "系统密钥库无法读取：$script:LastSecretStoreError" }
            else { '缺少 API Key' }
        Write-Warning "PSAITerminal 模型 '$($configuredModel.name)' $detail。输入 ai，在模型详情中选择【编辑配置】后更新。"
    }
}
if (-not $script:ConfigLoadFailed -and -not [bool]$script:Config.onboardingShown -and $Host.Name -eq 'ConsoleHost' -and
    -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) {
    Write-AIColoredHost (Get-AIText 'LoadedGuide') DarkCyan
    $script:Config.onboardingShown = $true
}
$ExecutionContext.SessionState.Module.OnRemove = {
    Unregister-AIPSReadLineIntegration
    Unregister-AIPromptIntegration
    if ($script:OfficialIntegrationAvailable) {
        [PSAITerminal.AITerminalOfficialIntegration]::UnregisterAll()
    }
}

Set-Alias -Name Configure-PSAI -Value Open-PSAISettings -Scope Script

Export-ModuleMember -Function @(
    'Enable-PSAITerminal','Disable-PSAITerminal','Get-PSAITerminalMode','Set-PSAITerminalMode',
    'Get-PSAITerminalOption','Set-PSAITerminalOption','Open-PSAISettings','Open-PSAIModelSelector',
    'New-PSAIModel','Get-PSAIModel','Set-PSAIModel','Select-PSAIModel','Remove-PSAIModel','Test-PSAIModel',
    'New-PSAISession','Get-PSAISession','Select-PSAISession','Clear-PSAISession',
    'Start-PSAIRun','Get-PSAIRun','Resume-PSAIRun','Resolve-PSAIRun','Stop-PSAIRun',
    'Start-PSAIToolExecution','Complete-PSAIToolExecution','Start-PSAIAutoFallback',
    'Invoke-PSAI','Invoke-PSAIAutoCompletion','Show-PSAIResultExplanation','Enable-PSAIPredictor','Disable-PSAIPredictor',
    'Get-PSAIIntegrationStatus','Test-PSAIConfiguration','Install-PSAIProfileIntegration','Uninstall-PSAIProfileIntegration',
    'Uninstall-PSAITerminal',
    'Show-AICliHelp'
) -Alias @('Configure-PSAI')
#endregion
