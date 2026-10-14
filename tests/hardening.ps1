#requires -Version 5.1
[CmdletBinding()]
param([string]$ModulePath)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
if([string]::IsNullOrWhiteSpace($ModulePath)){$ModulePath=Join-Path $PSScriptRoot '../out/PSAITerminal-2.0.1/PSAITerminal.psd1'}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('PSAI.Hardening.'+[guid]::NewGuid().ToString('N'))
$previousConfig=$env:PSAI_CONFIG_HOME; $previousData=$env:PSAI_DATA_HOME
$profileHost=$PROFILE.CurrentUserCurrentHost; $profileAll=$PROFILE.CurrentUserAllHosts
$env:PSAI_CONFIG_HOME=Join-Path $testRoot 'config'; $env:PSAI_DATA_HOME=Join-Path $testRoot 'data'
$credentialNames=@(('hardening-'+[guid]::NewGuid().ToString('N')),('unconfigured-'+[guid]::NewGuid().ToString('N')))
$exitVariable=Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
$exitExisted=$null -ne $exitVariable
$exitValue=if($exitExisted){$exitVariable.Value}else{$null}
function Assert-Hardening($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-HardeningThrows([scriptblock]$Action,[string]$Pattern) {
    $exception=$null
    try { & $Action | Out-Null } catch { $exception=$_.Exception }
    Assert-Hardening ($null -ne $exception -and $exception.ToString() -match $Pattern) "应拒绝操作：$Pattern；实际：$exception"
    $exception
}
function Invoke-IsolatedHost([string]$Code) {
    $Code = "$" + "ProgressPreference='SilentlyContinue';" + $Code
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
    $hostPath=Join-Path $PSHOME $(if($PSVersionTable.PSEdition -eq 'Core'){'pwsh.exe'}else{'powershell.exe'})
    $process=[Diagnostics.Process]::new()
    $process.StartInfo=[Diagnostics.ProcessStartInfo]::new()
    $process.StartInfo.FileName=$hostPath
    $process.StartInfo.Arguments="-NoProfile -NonInteractive -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $process.StartInfo.UseShellExecute=$false;$process.StartInfo.CreateNoWindow=$true
    $process.StartInfo.RedirectStandardOutput=$true;$process.StartInfo.RedirectStandardError=$true
    try {
        if(-not $process.Start()){throw '无法启动隔离子进程。'}
        $outputRead=$process.StandardOutput.ReadToEndAsync();$errorRead=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $outputText=$outputRead.GetAwaiter().GetResult();$errorText=$errorRead.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0){throw "隔离子进程失败：$($process.ExitCode)；$outputText；$errorText"}
    }finally{$process.Dispose()}
}
try {
    Import-Module $ModulePath -Force
    $module=Get-Module PSAITerminal
    $package=$module.ModuleBase
    . (Join-Path $package 'PSAIStorageSafety.ps1')
    $configFile=Join-Path $env:PSAI_CONFIG_HOME 'config.json'
    Assert-Hardening (-not (Test-Path -LiteralPath $configFile)) '首次导入不得持久修改共享配置。'
    Set-PSAITerminalOption -Language en-US | Out-Null
    & $module {
        $previousSession=$script:CurrentSession
        try{$script:CurrentSession=$null;Clear-PSAISession -Confirm:$false}
        finally{$script:CurrentSession=$previousSession}
    }

    # 第二进程导入、新建和切换不修改配置；显式配置修改仍拒绝陈旧修订号。
    $before=(Get-FileHash -LiteralPath $configFile).Hash
    $childTemplate=@'
$ErrorActionPreference='Stop'
Import-Module '{MANIFEST}'
$before=[IO.File]::ReadAllText('{CONFIG}')
$one=New-PSAISession -Title 'parallel-one'
$two=New-PSAISession -Title 'parallel-two'
Select-PSAISession $one.Id | Out-Null
$active=@(Get-PSAISession | Where-Object Active)
if($active.Count -ne 1 -or $active[0].Id -ne $one.Id){throw '当前会话没有独立生效'}
Clear-PSAISession -Confirm:$false
if([IO.File]::ReadAllText('{CONFIG}') -cne $before){throw '会话操作改写了共享配置'}
'@
    $code=$childTemplate.Replace('{MANIFEST}',([IO.Path]::GetFullPath($ModulePath)).Replace("'","''")).Replace('{CONFIG}',$configFile.Replace("'","''"))
    Invoke-IsolatedHost $code
    Assert-Hardening ((Get-FileHash -LiteralPath $configFile).Hash -ceq $before) '第二进程隐式修改了配置。'
    Set-PSAITerminalOption -MaxAgentSteps 9 | Out-Null
    Invoke-IsolatedHost ("Import-Module '"+([IO.Path]::GetFullPath($ModulePath)).Replace("'","''")+"'; Set-PSAITerminalOption -MaxAgentSteps 10 | Out-Null")
    $null=Assert-HardeningThrows { Set-PSAITerminalOption -MaxAgentSteps 11 } '另一个 PowerShell'
    & $module { Initialize-AIState }

    & $module {
        function Assert-Local($Condition,$Message){if(-not $Condition){throw $Message}}
        function Assert-Rejected([scriptblock]$Action){
            $rejected=$false
            try{& $Action | Out-Null}catch{$rejected=$true}
            Assert-Local $rejected '无效提议被接受。'
        }
        foreach($arguments in @(@{purpose='缺少命令'},@{command='   '},@{command=42},'not-json')){
            Assert-Rejected { ConvertFrom-AIToolCall @{name='powershell';arguments=$arguments} }
        }
        Assert-Rejected { ConvertFrom-AIToolCall @{name='other';arguments=@{command='Get-Date'}} }
        foreach($command in @("Write-Output 'password=fixture-value'",('x'*16385))){
            $proposalArguments=@{command=$command;purpose='敏感'}
            Assert-Rejected { ConvertFrom-AIToolCall @{name='powershell';arguments=$proposalArguments} }
            Assert-Local ($proposalArguments.command -ceq $command) '拒绝敏感命令时不能改写原文。'
        }
        $script:Config.mode='AI'
        foreach($line in @('Get-Date','if ($true) {',"'未闭合", '请问什么是进程')){
            $dispatch=ConvertTo-AISubmittedLine $line
            Assert-Local ($dispatch -eq '. (Invoke-PSAI)') 'AI 普通输入未交给 AI。'
            $pending=[string]$script:PendingInvocationScripts[[string]$script:NextPendingInvocationId]
            Assert-Local $pending.Contains("'" + $line.Replace("'","''") + "'") 'AI 输入原文丢失。'
            $script:PendingInvocationScripts.Clear();$script:NextPendingInvocationId=$null
        }
        $script:NextReadLineAction='ForceShell'
        Assert-Local ((ConvertTo-AISubmittedLine 'if ($true) {') -ceq 'if ($true) {') 'F3 必须保留原生续行。'
        $script:Config.mode='Auto'
        Assert-Local ((ConvertTo-AISubmittedLine '这个怎么办？') -eq '. (Invoke-PSAI)') 'Auto 自然语言必须交给 AI，由模型决定回答还是提议命令。'
        $script:PendingInvocationScripts.Clear();$script:NextPendingInvocationId=$null
        foreach($alias in @('dir','ls','gci','gc','cat','type','select','where','sort','measure')){
            Assert-Local ((Get-AICommandRisk "$alias .") -eq 'Low') "只读别名 $alias 被误判。"
        }
    }
    $originalAlias=(Get-Alias dir -Scope Global).Definition
    try {
        Set-Alias -Name dir -Value Remove-Item -Scope Global -Option AllScope
        Assert-Hardening ((& $module {Get-AICommandRisk 'dir fixture'}) -eq 'High') '重绑定别名必须重新解析风险。'
        Set-Item -LiteralPath Function:\global:Get-Date -Value { 'fixture-shadow' }
        Assert-Hardening ((& $module {Get-AICommandRisk 'Get-Date'}) -eq 'High') '宿主函数覆盖只读 Cmdlet 后必须为高风险。'
    } finally {
        Set-Alias -Name dir -Value $originalAlias -Scope Global -Option AllScope
        Remove-Item -LiteralPath Function:\global:Get-Date -ErrorAction SilentlyContinue
    }

    # 在读取过程中限制单行内存，覆盖缓冲边界、CR/LF 与无换行末行。
    $crlf=[string][char]13+[char]10
    foreach($text in @(('x'*1MB),(('x'*8191)+$crlf+'末行'+$crlf+[char]10+'结束'),('甲'+[char]13+'乙'+[char]10+'丙'))){
        $reader=[IO.StreamReader]::new([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($text)))
        try {
            $lines=[Collections.Generic.List[string]]::new()
            while($null -ne ($line=[PSAITerminal.AITerminalHttpContent]::ReadLine($reader,[Threading.CancellationToken]::None))){$lines.Add($line)}
            $expected=[regex]::Split($text,'\r\n|\r|\n')
            Assert-Hardening (($lines -join '|') -ceq ($expected -join '|')) '跨缓冲换行或末行读取错误。'
        }finally{$reader.Dispose()}
    }
    $stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('x'*2MB))
    $reader=[IO.StreamReader]::new($stream)
    try {
        $null=Assert-HardeningThrows { [PSAITerminal.AITerminalHttpContent]::ReadLine($reader,[Threading.CancellationToken]::None) } '1 MiB'
        Assert-Hardening ($stream.Position -le 1MB+16384) '读取器在发现超限前消费了整个大行。'
    }finally{$reader.Dispose()}
    $reader=[IO.StreamReader]::new([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('x'*(1MB+1))))
    try {$null=Assert-HardeningThrows { [PSAITerminal.AITerminalHttpContent]::ReadLine($reader,[Threading.CancellationToken]::None) } '1 MiB'}
    finally{$reader.Dispose()}

    # Win32 描述符转换和 DACL 设置失败保留原始错误码。
    $apply=[PSAITerminal.AITerminalAtomicFile].GetMethod('ApplyPrivateSecurity',[Reflection.BindingFlags]'Static,NonPublic')
    foreach($sddl in @('invalid-sddl','D:P(A;;FA;;;OW)')){
        $exception=Assert-HardeningThrows { $apply.Invoke($null,[object[]]@([string](Join-Path $testRoot 'missing.file'),[string]$sddl)) } '私有访问控制'
        Assert-Hardening ($exception.GetBaseException() -is [ComponentModel.Win32Exception] -and $exception.GetBaseException().NativeErrorCode -ne 0) 'Win32 错误码丢失。'
    }
    $lockTarget=Join-Path $testRoot 'lock/state.json'
    [PSAITerminal.AITerminalAtomicFile]::EnsurePrivateDirectory((Split-Path -Parent $lockTarget))
    $lockFile=$lockTarget+'.lock'
    [IO.File]::WriteAllText($lockFile,'fixture')
    $acl=Get-Acl -LiteralPath $lockFile
    $ownerRights=[Security.Principal.SecurityIdentifier]::new('S-1-3-4')
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($ownerRights,[Security.AccessControl.FileSystemRights]::ChangePermissions,[Security.AccessControl.AccessControlType]::Deny))
    Set-Acl -LiteralPath $lockFile -AclObject $acl
    $null=Assert-HardeningThrows { [PSAITerminal.AITerminalAtomicFile]::AcquireLock($lockTarget,100).Dispose() } '私有访问控制'
    $released=[IO.File]::Open($lockFile,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $released.Dispose()
    Remove-Item -LiteralPath $lockFile -Force -ErrorAction Stop

    # 凭据均为本次生成的合成测试目标；普通卸载保留，Purge 仅清理配置中的名称。
    New-PSAIModel -Name $credentialNames[0] -Protocol OpenAIChat -Endpoint http://127.0.0.1:11434 -ModelId fixture | Out-Null
    foreach($name in $credentialNames){[PSAITerminal.PlatformCredentialStore]::Set("PSAITerminal/Model/$name",'hardening-fixture')}
    [IO.File]::WriteAllText((Join-Path $env:PSAI_CONFIG_HOME 'unrelated.txt'),'keep')
    [IO.File]::WriteAllText((Join-Path $env:PSAI_DATA_HOME 'unrelated.txt'),'keep')
    $PROFILE.CurrentUserCurrentHost=Join-Path $testRoot 'profile.ps1'
    $PROFILE.CurrentUserAllHosts=Join-Path $testRoot 'all-profile.ps1'
    [IO.File]::WriteAllText($PROFILE.CurrentUserCurrentHost,'# fixture profile')
    $hash=(Get-FileHash -LiteralPath $configFile).Hash
    Uninstall-PSAITerminal -PurgeUserData -Force -WhatIf | Out-Null
    Assert-Hardening ((Get-FileHash -LiteralPath $configFile).Hash -ceq $hash) '模块卸载 WhatIf 修改了配置。'
    foreach($dangerous in @('.', 'C:\', [Environment]::GetFolderPath('UserProfile'),[Environment]::GetFolderPath('DesktopDirectory'))){
        $null=Assert-HardeningThrows { Get-PSAIStoragePurgePlan $dangerous $env:PSAI_DATA_HOME } '拒绝|绝对路径'
    }
    $link=Join-Path $env:PSAI_CONFIG_HOME 'linked'
    $linkTarget=Join-Path $testRoot 'link-target';[void][IO.Directory]::CreateDirectory($linkTarget)
    New-Item -ItemType Junction -Path $link -Target $linkTarget | Out-Null
    try {$null=Assert-HardeningThrows { Get-PSAIStoragePurgePlan $env:PSAI_CONFIG_HOME $env:PSAI_DATA_HOME } '重解析点'}
    finally{Remove-Item -LiteralPath $link -Force -ErrorAction Stop}
    $plan=Get-PSAIStoragePurgePlan $env:PSAI_CONFIG_HOME $env:PSAI_DATA_HOME
    $unknownModule=Join-Path $testRoot 'unknown-module';[void][IO.Directory]::CreateDirectory($unknownModule)
    [IO.File]::WriteAllText((Join-Path $unknownModule 'PSAITerminal.psd1'), "@{RootModule='PSAITerminal.psm1'}")
    $null=Assert-HardeningThrows { Assert-PSAIModuleRemoval $unknownModule } '拒绝删除无法确认归属'
    $null=Assert-HardeningThrows { Invoke-PSAICredentialPurge $plan.CredentialTargets (Join-Path $testRoot 'missing.dll') } '核心程序集'
    Assert-Hardening ((Get-FileHash -LiteralPath $configFile).Hash -ceq $hash) '凭据失败时必须保留配置。'
    $badAssembly=Join-Path $testRoot 'invalid.dll'
    [IO.File]::WriteAllText($badAssembly,'invalid-assembly-fixture')
    $null=Assert-HardeningThrows { Invoke-PSAICredentialPurge $plan.CredentialTargets $badAssembly } '凭据清理失败'
    Assert-Hardening ((Get-FileHash -LiteralPath $configFile).Hash -ceq $hash) '凭据子进程失败时必须保留配置。'
    $lockedConfig=[IO.File]::Open($configFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try { $null=Assert-HardeningThrows { Remove-PSAIStorageData $plan } 'access|访问|process|进程' }
    finally { $lockedConfig.Dispose() }
    Assert-Hardening (Test-Path -LiteralPath $configFile) '删除失败不能返回成功或丢失配置。'
    $bulkId=[guid]::NewGuid().ToString('N')
    $bulkTargets=@(1..100 | ForEach-Object { 'PSAITerminal/Model/b-'+$bulkId+'-'+('模'*23)+('{0:d3}' -f $_) })
    Invoke-PSAICredentialPurge $bulkTargets (Join-Path $package 'bin/PSAITerminal.dll')
    foreach($purge in @($false,$true)){
        $moduleRoot=Join-Path $testRoot $(if($purge){'purge-modules'}else{'normal-modules'})
        $installed=Join-Path $moduleRoot 'PSAITerminal'
        [void][IO.Directory]::CreateDirectory($moduleRoot)
        Copy-Item -LiteralPath $package -Destination $installed -Recurse
        $outerConfig=$env:PSAI_CONFIG_HOME
        try {
            $env:PSAI_CONFIG_HOME=Join-Path $installed 'user-data'
            $null=Assert-HardeningThrows { & (Join-Path $package 'Uninstall-PSAITerminal.ps1') -ModuleRoot $moduleRoot -NoProfileIntegration -PurgeUserData:$purge -Force } '用户数据位于'
        }finally{$env:PSAI_CONFIG_HOME=$outerConfig}
        Assert-Hardening (Test-Path -LiteralPath $installed) '用户数据重叠必须在写入前停止卸载。'
        $confirmTemplate=@'
$ErrorActionPreference='Stop'
try {
    & '{SCRIPT}' -ModuleRoot '{ROOT}' -NoProfileIntegration -Force -Confirm
    throw 'Force 绕过了显式 Confirm'
} catch {
    if($_.Exception.Message -notmatch 'NonInteractive|非交互'){throw}
}
if(-not (Test-Path -LiteralPath (Join-Path '{ROOT}' 'PSAITerminal'))){throw '确认失败却删除了模块'}
exit 0
'@
        Invoke-IsolatedHost ($confirmTemplate.Replace('{SCRIPT}',(Join-Path $package 'Uninstall-PSAITerminal.ps1').Replace("'","''")).Replace('{ROOT}',$moduleRoot.Replace("'","''")))
        Assert-Hardening (Test-Path -LiteralPath $installed) 'Force 显式 Confirm 不得绕过审批。'
        & (Join-Path $package 'Uninstall-PSAITerminal.ps1') -ModuleRoot $moduleRoot -NoProfileIntegration -PurgeUserData:$purge -Force -WhatIf | Out-Null
        Assert-Hardening (Test-Path -LiteralPath $installed) '独立卸载 WhatIf 删除了模块。'
        $result=& (Join-Path $package 'Uninstall-PSAITerminal.ps1') -ModuleRoot $moduleRoot -NoProfileIntegration -PurgeUserData:$purge -Force
        Assert-Hardening ($result.ModuleRemoved -and $result.CredentialsPurged -eq $purge -and $result.UserDataPurged -eq $purge) '卸载结果与实际状态不符。'
        Assert-Hardening (([PSAITerminal.PlatformCredentialStore]::Get("PSAITerminal/Model/$($credentialNames[1])")) -eq 'hardening-fixture') '删除了未配置的测试凭据。'
        $value=[PSAITerminal.PlatformCredentialStore]::Get("PSAITerminal/Model/$($credentialNames[0])")
        Assert-Hardening (($purge -and $null -eq $value) -or (-not $purge -and $value -eq 'hardening-fixture')) '普通卸载/Purge 凭据语义错误。'
    }
    Assert-Hardening (-not (Test-Path -LiteralPath $configFile)) 'Purge 未删除已确认配置。'
    foreach($directory in @($env:PSAI_CONFIG_HOME,$env:PSAI_DATA_HOME)){
        Assert-Hardening (Test-Path -LiteralPath (Join-Path $directory 'unrelated.txt')) 'Purge 删除了无关文件。'
    }
    Write-Output "整改回归通过：$($PSVersionTable.PSVersion) / $([IntPtr]::Size*8) 位"
}finally{
    foreach($name in $credentialNames){
        if('PSAITerminal.PlatformCredentialStore' -as [type]){[PSAITerminal.PlatformCredentialStore]::Remove("PSAITerminal/Model/$name")}
    }
    Remove-Module PSAITerminal -ErrorAction SilentlyContinue
    $env:PSAI_CONFIG_HOME=$previousConfig;$env:PSAI_DATA_HOME=$previousData
    $PROFILE.CurrentUserCurrentHost=$profileHost;$PROFILE.CurrentUserAllHosts=$profileAll
    if($exitExisted){Set-Variable LASTEXITCODE $exitValue -Scope Global}
    else{Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue}
    $fullRoot=[IO.Path]::GetFullPath($testRoot)
    if(-not $fullRoot.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){throw '临时清理路径越界'}
    if(Test-Path -LiteralPath $fullRoot){Remove-Item -LiteralPath $fullRoot -Recurse -Force -ErrorAction Stop}
}
