#requires -Version 5.1
param([string]$ModulePath = (Join-Path $PSScriptRoot '../out/PSAITerminal-1.0.4/PSAITerminal.psd1'))
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('PSAI.Reliability.'+[guid]::NewGuid().ToString('N'))
$previousConfig=$env:PSAI_CONFIG_HOME; $previousData=$env:PSAI_DATA_HOME
$env:PSAI_CONFIG_HOME=Join-Path $testRoot 'config'; $env:PSAI_DATA_HOME=Join-Path $testRoot 'data'
try {
    Import-Module $ModulePath -Force
    $module=Get-Module PSAITerminal
    New-PSAIModel -Name fixture -Protocol Ollama -Endpoint http://127.0.0.1:11434 -ModelId fixture -Capabilities @{streaming=$false;toolCalling=$true;usage=$false} | Out-Null
    Select-PSAIModel fixture | Out-Null
    & $module {
        function Assert-Reliability($Condition, $Message) { if (-not $Condition) { throw $Message } }
        function Assert-Rejected([scriptblock]$Action) {
            $rejected=$false
            try { & $Action | Out-Null } catch { $rejected=$true }
            Assert-Reliability $rejected '预期拒绝，但操作被接受。'
        }
        $script:TestResponses=[Collections.Queue]::new()
        $script:TestRequests=[Collections.ArrayList]::new()
        $script:TestChoices=[Collections.Queue]::new()
        function script:Invoke-AISessionModel($Model,$Instruction,[switch]$EnableTools,[switch]$NoRender,$CancellationToken) {
            [void]$Model; [void]$NoRender; [void]$CancellationToken
            [void]$script:TestRequests.Add(@{tools=[bool]$EnableTools;instruction=$Instruction})
            if ($script:TestResponses.Count -eq 0) { throw '测试禁止额外模型请求。' }
            $script:TestResponses.Dequeue()
        }
        function script:Read-Host($Prompt) {
            [void]$Prompt
            if ($script:TestChoices.Count) { return $script:TestChoices.Dequeue() }
            ''
        }
        function Add-Response($Arguments, [string]$Text='') {
            $calls=@()
            if ($Arguments) { $calls=@(@{name='powershell';arguments=$Arguments}) }
            $script:TestResponses.Enqueue([pscustomobject]@{Text=$Text;ToolCalls=$calls;InputTokens=0L;OutputTokens=0L})
        }
        function New-Proposal($Plan,[int]$Index=1,[string]$Role='Operation',[string]$Command='Get-Date') {
            [ordered]@{purpose='测试目的';command=$Command;expectedOutcome='测试预期';sideEffects='测试副作用';rollbackHint='测试回滚';
                plan=$Plan;stepIndex=$Index;stepRole=$Role;afterSuccess=$(if ($Role -eq 'Cleanup' -or $Index -lt $Plan.steps.Count) {'Observe'} else {'Complete'})}
        }
        function Invoke-ReliabilityStep($Ticket,[bool]$Success=$true,[string]$Output='实际输出') {
            Start-PSAIToolExecution -RunId $Ticket.RunId -StepId $Ticket.StepId -Command $Ticket.Command -ApprovalDigest $Ticket.ApprovalDigest -ApprovalRevision $Ticket.ApprovalRevision
            Complete-PSAIToolExecution -RunId $Ticket.RunId -StepId $Ticket.StepId -Succeeded $Success -Output $Output -ExitCode $(if($Success){0}else{7})
        }
        $single=[ordered]@{mode='Single';steps=@('查询');completionCondition='返回查询结果'}
        $multi=[ordered]@{mode='Multi';steps=@('创建文件','验证产物');completionCondition='文件与校验结果正确'}
        # 咨询必须走实际公开问答入口且不带工具；澄清根本不请求模型。
        Add-Response $null '概念解释'
        $line=ConvertTo-AIIntentInvocationLine '解释一下进程和线程的区别'
        . ([scriptblock]::Create($line)) | Out-Null
        Assert-Reliability (-not $script:TestRequests[0].tools) '咨询错误地携带工具。'
        $before=$script:TestRequests.Count
        $line=ConvertTo-AIIntentInvocationLine '这个怎么办？'
        . ([scriptblock]::Create($line)) | Out-Null
        Assert-Reliability ($script:TestRequests.Count -eq $before -and -not $script:NextPendingInvocationId) '澄清创建了模型请求或待执行调用。'
        $script:Config.mode='AI'
        Assert-Reliability ((ConvertTo-AISubmittedLine 'Get-Date') -eq '. (Invoke-PSAI)') 'AI 模式的合法 Shell 必须先交给 AI。'
        Assert-Reliability ($script:LastSubmittedCommand.Command -eq 'Get-Date') 'AI 必须保留合法 Shell 原文。'
        $null=ConvertTo-AIIntentInvocationLine '$x = )'
        $pending=[string]$script:PendingInvocationScripts[$script:NextPendingInvocationId]
        Assert-Reliability ($pending -match '诊断' -and $pending -match 'Start-PSAIRun') '语法错误必须进入诊断任务。'
        $script:PendingInvocationScripts.Clear(); $script:NextPendingInvocationId=$null
        foreach ($protocol in @('OpenAIChat','OpenAIResponses','Anthropic','GeminiNative','Ollama')) {
            $body=[ordered]@{}; Add-AIToolsToRequestBody $body $protocol
            Assert-Reliability (($body | ConvertTo-Json -Depth 30) -match 'completionCondition') "$protocol 缺少规划协议。"
        }
        Add-Response (New-Proposal $single)
        $step=Start-PSAIRun '查 IP'
        $before=$script:TestRequests.Count
        $null=Invoke-ReliabilityStep $step
        Assert-Reliability ($script:TestRequests.Count -eq $before) '单步成功不能追加模型请求。'
        Assert-Reliability ((Import-AIRun $step.RunId).state -eq 'Completed') '单步没有完成。'
        Add-Response $null 'F7 主动解释'
        Show-PSAIResultExplanation
        Assert-Reliability ($script:TestRequests.Count -eq $before+1 -and -not $script:TestRequests[$before].tools) 'F7 必须主动请求且不带工具。'
        Add-Response (New-Proposal $multi)
        $step=Start-PSAIRun '创建一个包含说明文件且校验正确的压缩包'
        Add-Response (New-Proposal $multi 2 'Verify')
        $next=Invoke-ReliabilityStep $step
        Assert-Reliability ($next -and (Import-AIRun $step.RunId).state -eq 'AwaitingApproval') '复合目标不能在首步提前结束。'
        # 最终验证失败 -> 清理 -> 重试原验证；失败记录不能在清理后丢失。
        Add-Response (New-Proposal $multi 2 'Cleanup') '校验失败，需要清理部分产物。'
        $cleanup=Invoke-ReliabilityStep $next $false '校验失败'
        $failed=Import-AIRun $step.RunId
        Assert-Reliability ($failed.phase -eq 'Cleanup' -and $failed.lastFailure.exitCode -eq 7 -and $failed.lastFailure.output -eq '校验失败') '真实失败信息未持久化。'
        Add-Response (New-Proposal $multi 2 'Retry') '清理成功，重试原验证。'
        $retry=Invoke-ReliabilityStep $cleanup
        Assert-Reliability ($retry -and (Import-AIRun $step.RunId).phase -eq 'Retry') '清理成功不能结束原任务。'
        $before=$script:TestRequests.Count
        $null=Invoke-ReliabilityStep $retry
        Assert-Reliability ((Import-AIRun $step.RunId).state -eq 'Completed' -and $script:TestRequests.Count -eq $before) '最终重试成功应直接结束。'
        # 清理失败必须暂停，显式恢复后才允许模型提出另一条需批准的命令。
        Add-Response (New-Proposal $single)
        $step=Start-PSAIRun '执行可恢复任务'
        Add-Response (New-Proposal $single 1 'Cleanup') '分析失败副作用。'
        $cleanup=Invoke-ReliabilityStep $step $false
        $before=$script:TestRequests.Count
        $null=Invoke-ReliabilityStep $cleanup $false '清理也失败'
        $paused=Import-AIRun $step.RunId
        Assert-Reliability ($paused.state -eq 'Paused' -and $paused.lastResult.output -eq '清理也失败' -and $script:TestRequests.Count -eq $before) '清理失败不得自动继续。'
        # 新进程导入同一记录，验证恢复阶段不是仅存于内存。
        $probeManifest=Join-Path $ExecutionContext.SessionState.Module.ModuleBase 'PSAITerminal.psd1'
        $probeCode="`$ErrorActionPreference='Stop'; `$env:PSAI_CONFIG_HOME='$($env:PSAI_CONFIG_HOME)'; `$env:PSAI_DATA_HOME='$($env:PSAI_DATA_HOME)'; Import-Module '$probeManifest'; & (Get-Module PSAITerminal) { `$r=Import-AIRun '$($step.RunId)'; if (`$r.phase -ne 'Cleanup' -or `$r.state -ne 'Paused') { throw '跨进程状态丢失' } }"
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeCode))
        & (Join-Path $PSHOME $(if($PSVersionTable.PSEdition -eq 'Desktop'){'powershell.exe'}else{'pwsh.exe'})) -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
        Assert-Reliability ($LASTEXITCODE -eq 0) '恢复阶段跨进程读取失败。'
        Add-Response (New-Proposal $single 1 'Retry') '用户已显式恢复，重新尝试。'
        $retry=Resume-PSAIRun $step.RunId
        $null=Invoke-ReliabilityStep $retry
        # 拒绝、上限、无效规划的有限修复。
        Add-Response (New-Proposal $single); $script:TestChoices.Enqueue('3')
        $null=Start-PSAIRun '拒绝任务'
        Assert-Reliability ((Get-PSAIRun | Where-Object Task -eq '拒绝任务').State -eq 'Cancelled') '拒绝必须取消任务。'
        $oldLimit=$script:Config.execution.maxAgentSteps; $script:Config.execution.maxAgentSteps=1
        Add-Response (New-Proposal $single); $step=Start-PSAIRun '上限任务'
        Assert-Rejected { Invoke-ReliabilityStep $step $false }
        Assert-Reliability ((Import-AIRun $step.RunId).state -eq 'Failed') '恢复也必须计入步骤上限。'
        $script:Config.execution.maxAgentSteps=$oldLimit
        $bad=New-Proposal $multi; $bad.afterSuccess='Complete'
        Add-Response $bad; Add-Response $bad
        $before=$script:TestRequests.Count
        Assert-Rejected { Start-PSAIRun '无效规划' }
        Assert-Reliability ($script:TestRequests.Count -eq $before+2) '无效规划只能修复一次。'
        Add-Response $bad; Add-Response (New-Proposal $single)
        $repaired=Start-PSAIRun '首次无效后修复计划'
        Assert-Reliability ((Import-AIRun $repaired.RunId).plan.mode -eq 'Single') '无效首次计划不能阻挡合法修正。'
        # 磁盘篡改说明、计划、角色，以及内存篡改命令均不能执行。
        foreach ($field in @('purpose','plan','stepRole','command')) {
            Add-Response (New-Proposal $single); $step=Start-PSAIRun '批准绑定'
            $r=Import-AIRun $step.RunId
            if ($field -eq 'plan') { $r.plan.completionCondition='被修改的完成条件'; $r.pendingProposal.plan=$r.plan }
            elseif ($field -eq 'stepRole') { $r.pendingProposal.stepRole='Verify' }
            elseif ($field -eq 'command') { $step.Command='Get-Location' }
            else { $r.pendingProposal.purpose='被修改的说明' }
            if ($field -ne 'command') {
                # 模拟不增加修订号的磁盘修改，确保不是只依赖 revision 拦截。
                [PSAITerminal.AITerminalAtomicFile]::WriteAllText((Get-AIRunPath $r.id), ($r | ConvertTo-Json -Depth 30))
            }
            Assert-Rejected { Start-PSAIToolExecution -RunId $step.RunId -StepId $step.StepId -Command $step.Command -ApprovalDigest $step.ApprovalDigest -ApprovalRevision $step.ApprovalRevision }
        }
        # 旧记录可查看，但未完成任务必须重新规划，不得复用批准。
        Add-Response (New-Proposal $single); $step=Start-PSAIRun '旧任务'
        $legacy=Import-AIRun $step.RunId; $legacy.schemaVersion=1; Save-AIRun $legacy
        Assert-Rejected { Start-PSAIToolExecution -RunId $step.RunId -StepId $step.StepId -Command $step.Command -ApprovalDigest $step.ApprovalDigest -ApprovalRevision $step.ApprovalRevision }
        Add-Response (New-Proposal $single)
        $new=Resume-PSAIRun $step.RunId
        Assert-Reliability ($new.StepId -ne $step.StepId -and (Import-AIRun $new.RunId).schemaVersion -eq 2) '旧任务必须重新规划和批准。'
        Start-PSAIToolExecution -RunId $new.RunId -StepId $new.StepId -Command $new.Command -ApprovalDigest $new.ApprovalDigest -ApprovalRevision $new.ApprovalRevision
        Assert-Rejected { Resume-PSAIRun $new.RunId }
        $null=Resolve-PSAIRun $new.RunId -Outcome Succeeded -Output '用户确认成功'
        Assert-Reliability ((Import-AIRun $new.RunId).state -eq 'Completed') '显式确认结果后才能完成。'
        # 三个风险等级实际渲染六要素，高风险明确二次确认。
        foreach ($command in @('Get-Date','Set-Location .','Remove-Item test.txt')) {
            Add-Response (New-Proposal $single 1 'Operation' $command)
            $script:TestChoices.Enqueue('1')
            if ((Get-AICommandRisk $command) -eq 'High') { $script:TestChoices.Enqueue('y') }
            $screen=@(Start-PSAIRun '六要素检查' 6>&1)
            $rendered=($screen | Out-String)
            foreach ($label in @('ApprovalPurpose','ApprovalCommand','ApprovalExpected','ApprovalSideEffects','ApprovalRollback','ApprovalRisk')) {
                Assert-Reliability ($rendered.Contains((Get-AIText $label))) "风险审批缺少 $label。"
            }
            Assert-Reliability ($script:TestChoices.Count -eq 0) '高风险二次确认未发生。'
        }
        # 真正经过编辑菜单，旧说明必须替换，说明请求不能启用工具。
        Add-Response (New-Proposal $single)
        Add-Response $null '{"purpose":"新目的","expectedOutcome":"新预期","sideEffects":"新副作用","rollbackHint":"新回滚"}'
        foreach ($choice in @('2','Get-Location','1')) { $script:TestChoices.Enqueue($choice) }
        $before=$script:TestRequests.Count
        $edited=Start-PSAIRun '编辑检查'
        Assert-Reliability ($edited.Command -eq 'Get-Location' -and -not $script:TestRequests[$before+1].tools) '编辑请求必须禁用工具并绑定新命令。'
        $saved=Import-AIRun $edited.RunId
        Assert-Reliability ($saved.pendingProposal.rollbackHint -eq '新回滚') '旧回滚说明不能残留。'
        Add-Response (New-Proposal $single)
        Add-Response $null '{"purpose":{}}'
        foreach ($choice in @('2','Get-Location','1','3')) { $script:TestChoices.Enqueue($choice) }
        $none=Start-PSAIRun '编辑失败检查'
        Assert-Reliability (-not $none -and (Get-PSAIRun | Where-Object Task -eq '编辑失败检查').State -eq 'Cancelled') '说明失败后选择批准不能执行，必须可拒绝。'
        # 多步观察阶段无工具回答不能伪装为整体完成。
        Add-Response (New-Proposal $multi); $step=Start-PSAIRun '中途文本结束检查'
        Add-Response $null '已经完成'
        $null=Invoke-ReliabilityStep $step
        Assert-Reliability ((Import-AIRun $step.RunId).state -eq 'Paused') '模型声称完成不能跳过剩余计划。'
        Assert-Reliability ($script:TestResponses.Count -eq 0) '有预期的模型请求未发生。'
    }
    Write-Output "交互可靠性回归通过：$($PSVersionTable.PSVersion) / $([IntPtr]::Size*8) 位"
} finally {
    Remove-Module PSAITerminal -ErrorAction SilentlyContinue
    $env:PSAI_CONFIG_HOME=$previousConfig; $env:PSAI_DATA_HOME=$previousData
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'PSAI.Reliability.*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
