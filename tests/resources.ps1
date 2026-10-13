#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ModulePath)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('PSAI.Resources.'+[guid]::NewGuid().ToString('N'))
$previousConfig=$env:PSAI_CONFIG_HOME;$previousData=$env:PSAI_DATA_HOME
$env:PSAI_CONFIG_HOME=Join-Path $testRoot 'config';$env:PSAI_DATA_HOME=Join-Path $testRoot 'data'
try {
    Import-Module $ModulePath
    $module=Get-Module PSAITerminal
    $compiler=@{Path=(Join-Path $PSScriptRoot 'fixtures/TrackingHttp.cs')}
    if($PSVersionTable.PSEdition -eq 'Desktop'){$compiler.ReferencedAssemblies=@('System.dll','System.Core.dll','System.Net.Http.dll')}
    Add-Type @compiler
    $delayed=[PSAITerminalTests.DelayedReader]::new()
    $cancellation=[Threading.CancellationTokenSource]::new()
    try {
        $cancellation.CancelAfter(100)
        $cancelled=$false
        try {[void][PSAITerminal.AITerminalHttpContent]::ReadLine($delayed,$cancellation.Token)}
        catch {$cancelled=$_.Exception.GetBaseException() -is [OperationCanceledException]}
        if(-not $cancelled){throw '等待流读取时未响应取消。'}
        $delayed.Pending.SetResult(0)
    }finally{$delayed.Dispose();$cancellation.Dispose()}
    & $module {
        $originalClient=(Get-Command New-AIHttpClient -CommandType Function).ScriptBlock
        $model=@{name='resource-fixture';protocol='OpenAIChat';endpoint='http://127.0.0.1:1';modelId='fixture';parameters=@{};capabilities=@{streaming=$true;toolCalling=$true;usage=$false}}
        try {
            function script:New-AIHttpClient($Endpoint) {
                [void]$Endpoint
                [Net.Http.HttpClient]::new($script:ResourceHandler,$true)
            }
            foreach($mode in @('BodyFailure','Cancel','OverLimit')){
                $script:ResourceHandler=[PSAITerminalTests.TrackingHandler]::new($mode)
                $cancellation=[Threading.CancellationTokenSource]::new()
                if($mode -eq 'Cancel'){$cancellation.CancelAfter(100)}
                $failure=$null
                try {$null=Invoke-AIModelText -Model $model -Prompt fixture -CancellationToken $cancellation.Token -NoRender}
                catch {$failure=$_.Exception}
                finally{$cancellation.Dispose()}
                if($null -eq $failure){throw "$mode 进入了成功返回状态。"}
                if(-not $script:ResourceHandler.Disposed -or -not $script:ResourceHandler.Content.Disposed){throw "$mode 未清理 HTTP 资源。"}
                if($mode -eq 'BodyFailure' -and $failure.ToString() -notmatch 'fixture-body-failure'){throw '正文获取错误丢失。'}
                if($mode -eq 'OverLimit'){
                    if($failure.ToString() -notmatch '1 MiB' -or -not $script:ResourceHandler.Content.Stream.Disposed){throw '超限时未清理正文流。'}
                }
                if($mode -eq 'Cancel'){
                    if($failure.ToString() -notmatch 'cancel|取消'){throw '流取消错误丢失。'}
                    $lateStream=[PSAITerminalTests.TrackingStream]::new([byte[]]@())
                    $script:ResourceHandler.Content.Pending.SetResult($lateStream)
                    $deadline=[DateTime]::UtcNow.AddSeconds(2)
                    while(-not $lateStream.Disposed -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 10}
                    if(-not $lateStream.Disposed){throw '取消后迟到的正文流未被清理。'}
                }
            }
        }finally{
            Set-Item -Path function:script:New-AIHttpClient -Value $originalClient
            Remove-Variable ResourceHandler -Scope Script -ErrorAction SilentlyContinue
        }
    }
    "原生资源回归通过：$($PSVersionTable.PSVersion) / $([IntPtr]::Size*8) 位"
}finally{
    Remove-Module PSAITerminal -ErrorAction SilentlyContinue
    $env:PSAI_CONFIG_HOME=$previousConfig;$env:PSAI_DATA_HOME=$previousData
    $fullRoot=[IO.Path]::GetFullPath($testRoot)
    if(-not $fullRoot.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){throw '临时清理路径越界'}
    if(Test-Path -LiteralPath $fullRoot){Remove-Item -LiteralPath $fullRoot -Recurse -Force -ErrorAction Stop}
}
