#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$tokens=$null; $errors=$null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../module/PSAITerminal.psm1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw '模块解析失败。' }
foreach ($name in @('Get-AIApprovalDigest','Remove-AIProposalApproval','Assert-AIProposalExplanation','Update-AIProposalExplanation')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $false)
    . ([scriptblock]::Create($node.Extent.Text))
}
function Test-AIMapContains($Map, $Key) { $Map.Contains($Key) }
function Get-AIActiveModel { @{} }
function Protect-AIText($Text, $Limit) { $Text }
function Update-AISessionUsage($InputTokens, $OutputTokens) { }
function ConvertFrom-AIJson($Text) {
    $object = ConvertFrom-Json $Text
    $map = [ordered]@{}
    foreach ($property in $object.PSObject.Properties) { $map[$property.Name] = $property.Value }
    $map
}
function Add-AIRunEvent($Run, $Type, $Data) {
    if ($Type -eq 'ExplanationInvalidated' -and ($Run.pendingProposal.explanationReady -or $Run.pendingProposal.Contains('approvalDigest'))) {
        throw '请求前必须持久化撤销批准与说明。'
    }
}
function Invoke-AISessionModel($Model, $Instruction, [switch]$NoRender, $CancellationToken, [switch]$EnableTools) {
    if ($EnableTools) { throw '编辑说明请求不能启用工具。' }
    $script:requests++
    if ($script:fail) { throw '模拟请求失败' }
    [pscustomobject]@{Text=$script:response;ToolCalls=@();InputTokens=1;OutputTokens=1}
}
$proposal = [ordered]@{stepId='step';command='Get-Date';purpose='旧目的';expectedOutcome='旧预期';sideEffects='旧副作用';rollbackHint='旧回滚';approvalDigest='old'}
$run = @{pendingProposal=$proposal}
$script:requests=0
$script:fail=$true
Update-AIProposalExplanation $run $proposal ([Threading.CancellationToken]::None)
foreach ($field in @('purpose','expectedOutcome','sideEffects','rollbackHint')) {
    if ($proposal[$field] -ne '无法评估') { throw '失败不能保留旧说明。' }
}
$blocked=$false
try { Assert-AIProposalExplanation $proposal } catch { $blocked=$true }
if (-not $blocked) { throw '说明失败必须禁止批准。' }
$script:fail=$false
$script:response='{"purpose":"新目的","expectedOutcome":"新预期","sideEffects":"新副作用","rollbackHint":"新回滚"}'
Update-AIProposalExplanation $run $proposal ([Threading.CancellationToken]::None)
Assert-AIProposalExplanation $proposal
if ($script:requests -ne 2 -or $proposal.rollbackHint -ne '新回滚') { throw '编辑后必须请求新说明。' }
$json=$script:response
$fence=[string]::new([char]96,3)
$script:response="$fence"+"json`n$json`n$fence"
Update-AIProposalExplanation $run $proposal ([Threading.CancellationToken]::None)
Assert-AIProposalExplanation $proposal
foreach ($invalid in @("额外说明`n$($script:response)","$($script:response)`n额外说明", "$($script:response)`n$($script:response)")) {
    $script:response=$invalid
    Update-AIProposalExplanation $run $proposal ([Threading.CancellationToken]::None)
    if ($proposal.explanationReady) { throw '说明中额外内容或多个代码块必须拒绝。' }
}
$script:response=$json
Update-AIProposalExplanation $run $proposal ([Threading.CancellationToken]::None)
$digest = Get-AIApprovalDigest 'run' 'step' $proposal.command $proposal
foreach ($field in @('purpose','expectedOutcome','sideEffects','rollbackHint','explanationReady')) {
    $before = $proposal[$field]
    $proposal[$field] = 'changed'
    if ((Get-AIApprovalDigest 'run' 'step' $proposal.command $proposal) -eq $digest) { throw "批准未绑定 $field。" }
    $proposal[$field] = $before
}
$script:response='{"purpose":{},"expectedOutcome":"预期","sideEffects":"副作用","rollbackHint":"回滚"}'
Update-AIProposalExplanation $run $proposal ([Threading.CancellationToken]::None)
if ($proposal.explanationReady) { throw '无效字段类型必须拒绝。' }
Write-Output "审批说明检查通过：$($PSVersionTable.PSVersion) / $([IntPtr]::Size * 8) 位"
