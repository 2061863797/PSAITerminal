#requires -Version 5.1
param([Parameter(Mandatory)][string]$AssemblyPath)
$ErrorActionPreference = 'Stop'
Add-Type -Path $AssemblyPath
$cases = @(
    @('解释一下进程和线程的区别', 'Consultation'),
    @('帮我结束这个进程好吗', 'Operation'),
    @('你好', 'Consultation'),
    @('查 IP', 'Operation'),
    @('创建一个含有说明文件的压缩包', 'Operation'),
    @('这个怎么办？', 'Clarify'),
    @('可以吗', 'Clarify'),
    @('你还能做什么', 'Consultation'),
    @('你能做什么', 'Consultation'),
    @('怎么用', 'Consultation'),
    @('了解原理', 'Consultation'),
    @('执行操作', 'Operation'),
    @('找到我电脑上的密钥', 'Operation'),
    @('删除电脑所有文件', 'Operation'),
    @('清空回收站', 'Operation'),
    @('搜索桌面的图片', 'Operation')
)
foreach ($case in $cases) {
    $actual = [PSAITerminal.AITerminalInputRouter]::ClassifyIntent($case[0])
    if ($actual -ne $case[1]) { throw "意图分流错误：$($case[0]) => $actual" }
}
# 仅加载待测函数，不初始化模块，不接触真实配置或凭据。
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot '../module/PSAITerminal.psm1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw '模块语法解析失败。' }
$functionAst = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'ConvertTo-AIIntentInvocationLine'
}, $false)
. ([scriptblock]::Create($functionAst.Extent.Text))
function Get-AILanguage { 'zh-CN' }
function Test-AIAutoRoute($Line) { $false }
function New-AIPendingInvocationLine($Text) { $script:pendingCount++; $Text }
function ConvertTo-AIInvocationLine($Text, [switch]$Agent) { "Agent=$Agent;$Text" }
$script:pendingCount = 0
$script:NextPendingInvocationId=$null
$clarification = ConvertTo-AIIntentInvocationLine '这个怎么办？'
if ($script:pendingCount -ne 0 -or $clarification -notmatch '^Write-Host ') {
    throw '澄清不能创建待执行调用。'
}
if ((ConvertTo-AIIntentInvocationLine '解释一下进程和线程的区别') -notmatch '^Agent=False;') {
    throw '咨询不能进入工具执行路径。'
}
if ((ConvertTo-AIIntentInvocationLine '帮我结束这个进程好吗') -notmatch '^Agent=True;') {
    throw '操作不能被语气词误判为咨询。'
}
Write-Output "意图分流检查通过：$($PSVersionTable.PSVersion) / $([IntPtr]::Size * 8) 位"
