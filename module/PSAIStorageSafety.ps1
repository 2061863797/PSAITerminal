#requires -Version 5.1

# 两个卸载入口共用的只读预检与精确清理规则。函数不导出。
function Get-PSAIStoredProperty($Value, [string]$Name) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) { return ,$Value[$Name] }
    $property = $Value.PSObject.Properties[$Name]
    if ($property) { return ,$property.Value }
    $null
}

function Assert-PSAISafeRemovalDirectory([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or
        ($Path -notmatch '^[A-Za-z]:[\\/]' -and $Path -notmatch '^\\\\[^\\]+\\[^\\]+(?:\\|$)')) {
        throw '清理目录必须是完整的绝对路径。'
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $root = [IO.Path]::GetPathRoot($full).TrimEnd('\','/')
    $comparison = [StringComparison]::OrdinalIgnoreCase
    if ($full.Equals($root, $comparison)) { throw "拒绝清理磁盘根目录：$full" }
    $bases = @(
        [Environment]::GetFolderPath('UserProfile'),
        [Environment]::GetFolderPath('MyDocuments'),
        [Environment]::GetFolderPath('DesktopDirectory'),
        [Environment]::GetFolderPath('LocalApplicationData'),
        [Environment]::GetFolderPath('ApplicationData')
    )
    foreach ($base in $bases) {
        if ($base -and $full.Equals([IO.Path]::GetFullPath($base).TrimEnd('\','/'), $comparison)) {
            throw "拒绝清理用户基础目录：$full"
        }
    }
    foreach ($systemPath in @($PSHOME,$env:windir,$env:ProgramFiles,[Environment]::GetEnvironmentVariable('ProgramFiles(x86)'))) {
        if (-not $systemPath) { continue }
        $systemRoot = [IO.Path]::GetFullPath($systemPath).TrimEnd('\','/')
        if ($full.Equals($systemRoot, $comparison) -or
            ($full + '\').StartsWith($systemRoot + '\', $comparison)) {
            throw "拒绝清理系统目录：$full"
        }
    }
    $ancestor = $full
    while ($ancestor) {
        try {
            $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "拒绝跟随重解析点：$ancestor" }
        } catch [Management.Automation.ItemNotFoundException] { Write-Verbose "预检路径尚不存在：$ancestor" }
        $parent = Split-Path -Path $ancestor -Parent
        if ($parent -eq $ancestor) { break }
        $ancestor = $parent
    }
    $full
}

function Assert-PSAIRemovalTree([string]$Path) {
    $full = Assert-PSAISafeRemovalDirectory $Path
    if (-not (Test-Path -LiteralPath $full)) { return }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "清理目录指向文件：$full" }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($full)
    while ($pending.Count) {
        foreach ($item in (Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "拒绝跟随重解析点：$($item.FullName)" }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
}

function Assert-PSAIStorageOutsideModule([string]$ModuleDirectory, [string[]]$StorageDirectories) {
    $moduleRoot = Assert-PSAISafeRemovalDirectory $ModuleDirectory
    foreach ($directory in $StorageDirectories) {
        $storageRoot = Assert-PSAISafeRemovalDirectory $directory
        if ($storageRoot.Equals($moduleRoot, [StringComparison]::OrdinalIgnoreCase) -or
            ($storageRoot + '\').StartsWith($moduleRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "用户数据位于待卸载模块目录内，无法保留无关文件，已停止卸载：$storageRoot"
        }
    }
}

function Assert-PSAIModuleRemoval([string]$Path) {
    $full = Assert-PSAISafeRemovalDirectory $Path
    if (-not (Test-Path -LiteralPath $full)) { return }
    Assert-PSAIRemovalTree $full
    $candidates = @($full)
    $candidates += @(Get-ChildItem -LiteralPath $full -Directory -Force | Where-Object Name -Match '^\d+\.\d+\.\d+(?:\.\d+)?$' | ForEach-Object { $_.FullName })
    $owned = $false
    foreach ($candidate in $candidates) {
        $manifestPath = Join-Path $candidate 'PSAITerminal.psd1'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
        $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
        $rootModule = Get-PSAIStoredProperty $manifest 'RootModule'
        $privateData = Get-PSAIStoredProperty $manifest 'PrivateData'
        $psData = Get-PSAIStoredProperty $privateData 'PSData'
        $projectUri = Get-PSAIStoredProperty $psData 'ProjectUri'
        if ($rootModule -is [string] -and $rootModule -eq 'PSAITerminal.psm1' -and
            $projectUri -is [string] -and $projectUri -eq 'https://github.com/2061863797/PSAITerminal') {
            $owned = $true
        }
    }
    if (-not $owned) { throw "拒绝删除无法确认归属的模块目录：$full" }
}

function Read-PSAIPurgeDocument([string]$Path, [int]$MaximumBytes) {
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -gt $MaximumBytes) { throw "清理文件类型或大小无效：$Path" }
    try { [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "无法确认清理文件归属：$Path" }
}

function Get-PSAIStoragePurgePlan([string]$ConfigDirectory, [string]$DataDirectory) {
    $configRoot = Assert-PSAISafeRemovalDirectory $ConfigDirectory
    $dataRoot = Assert-PSAISafeRemovalDirectory $DataDirectory
    Assert-PSAIRemovalTree $configRoot
    Assert-PSAIRemovalTree $dataRoot
    $files = [Collections.Generic.List[object]]::new()
    $directories = [Collections.Generic.List[string]]::new()
    $targets = [Collections.Generic.List[string]]::new()
    $configPath = Join-Path $configRoot 'config.json'
    $hasConfig = Test-Path -LiteralPath $configPath -PathType Leaf
    if ($hasConfig) {
        $config = Read-PSAIPurgeDocument $configPath 1MB
        $models = Get-PSAIStoredProperty $config 'models'
        if ((Get-PSAIStoredProperty $config 'schemaVersion') -notin @(1,2) -or
            (Get-PSAIStoredProperty $config 'mode') -notin @('Off','AI','Auto') -or
            $null -eq (Get-PSAIStoredProperty $config 'shortcuts') -or
            $null -eq (Get-PSAIStoredProperty $config 'execution') -or
            ($models -isnot [Collections.IDictionary] -and $models -isnot [pscustomobject])) {
            throw "无法确认配置文件归属：$configPath"
        }
        $names = if ($models -is [Collections.IDictionary]) { @($models.Keys) } else { @($models.PSObject.Properties | ForEach-Object { $_.Name }) }
        foreach ($name in $names) {
            if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 64 -or $name -match '[\\/:*?"<>|\x00-\x1F\x7F-\x9F]') {
                throw '配置模型名称无效，已停止凭据清理。'
            }
            $model = Get-PSAIStoredProperty $models $name
            if ((Get-PSAIStoredProperty $model 'protocol') -notin @('Anthropic','OpenAIChat','OpenAIResponses','GeminiNative','Ollama')) {
                throw '配置模型协议无效，已停止凭据清理。'
            }
            $targets.Add("PSAITerminal/Model/$name")
        }
    }
    if (Test-Path -LiteralPath $configRoot) {
        foreach ($file in (Get-ChildItem -LiteralPath $configRoot -File -Force)) {
            if ($file.Name -match '^(?:config\.json(?:\.lock|\.corrupt\.\d{14}\.json)?|\.config\.json-[a-f0-9]{32}\.tmp)$') {
                if (-not $hasConfig) { throw "无法确认缺少有效配置的清理文件：$($file.FullName)" }
                $files.Add([pscustomobject]@{Path=$file.FullName;Hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash})
            }
        }
    }
    foreach ($kind in @('sessions','runs')) {
        $directory = Join-Path $dataRoot $kind
        if (-not (Test-Path -LiteralPath $directory)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $directory -File -Force)) {
            if ($file.Name -notmatch '^(?<Id>[a-fA-F0-9]{32})\.json$') { continue }
            $id = $Matches.Id
            $document = Read-PSAIPurgeDocument $file.FullName $(if ($kind -eq 'sessions') {16MB} else {4MB})
            $version = Get-PSAIStoredProperty $document 'schemaVersion'
            $validKind = if ($kind -eq 'sessions') {
                $version -eq 1 -and $null -ne (Get-PSAIStoredProperty $document 'turns') -and
                $null -ne (Get-PSAIStoredProperty $document 'title')
            } else {
                $version -in @(1,2) -and [string](Get-PSAIStoredProperty $document 'sessionId') -match '^[a-fA-F0-9]{32}$' -and
                $null -ne (Get-PSAIStoredProperty $document 'state')
            }
            if ([string](Get-PSAIStoredProperty $document 'id') -cne $id -or -not $validKind) {
                throw "无法确认运行数据归属：$($file.FullName)"
            }
            $files.Add([pscustomobject]@{Path=$file.FullName;Hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash})
            $lockPath = $file.FullName + '.lock'
            if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
                $files.Add([pscustomobject]@{Path=$lockPath;Hash=(Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash})
            }
        }
        $directories.Add($directory)
    }
    $directories.Add($configRoot)
    if ($dataRoot -ne $configRoot) { $directories.Add($dataRoot) }
    [pscustomobject]@{Files=@($files.ToArray());Directories=@($directories.ToArray());CredentialTargets=@($targets.ToArray())}
}

function Assert-PSAIStoragePurgePlan($Plan) {
    foreach ($file in $Plan.Files) {
        [void](Assert-PSAISafeRemovalDirectory (Split-Path -Path $file.Path -Parent))
        if (-not (Test-Path -LiteralPath $file.Path)) { continue }
        if ((Get-Item -LiteralPath $file.Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or
            (Get-FileHash -LiteralPath $file.Path -Algorithm SHA256).Hash -cne $file.Hash) {
            throw "清理目标已变化，已保留剩余文件：$($file.Path)"
        }
    }
}

function Remove-PSAIStorageData($Plan) {
    Assert-PSAIStoragePurgePlan $Plan
    foreach ($file in $Plan.Files) {
        Assert-PSAIStoragePurgePlan @{Files=@($file)}
        if (Test-Path -LiteralPath $file.Path) { Remove-Item -LiteralPath $file.Path -Force -ErrorAction Stop }
    }
    foreach ($directory in $Plan.Directories) {
        [void](Assert-PSAISafeRemovalDirectory $directory)
        if ((Test-Path -LiteralPath $directory -PathType Container) -and
            @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop).Count -eq 0) {
            Remove-Item -LiteralPath $directory -Force -ErrorAction Stop
        }
    }
}

function Invoke-PSAICredentialPurge([string[]]$Targets, [string]$CoreAssemblyPath) {
    if ($Targets.Count -eq 0) { return }
    foreach ($target in $Targets) {
        if (-not $target.StartsWith('PSAITerminal/Model/', [StringComparison]::Ordinal) -or
            $target.Length -le 19 -or $target.Substring(19) -match '[\\/:*?"<>|\x00-\x1F\x7F-\x9F]') {
            throw '凭据清理目标无效。'
        }
    }
    if (-not (Test-Path -LiteralPath $CoreAssemblyPath -PathType Leaf)) { throw '凭据清理需要模块核心程序集，原文件未删除。' }
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @($Targets) -Compress)))
    $childTemplate = @'
$ErrorActionPreference = 'Stop'
Add-Type -Path '{CORE}'
# Windows PowerShell 5.1 在 UTF-8 控制台下会先向 stdin 写入 BOM；按原始字节读取，
# 避免无控制台的子进程按 ANSI 代码页解码时把 BOM 与后续字符合并。
$stdinBuffer = [IO.MemoryStream]::new()
[Console]::OpenStandardInput().CopyTo($stdinBuffer)
$bytes = $stdinBuffer.ToArray()
$offset = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
$payload = [Text.Encoding]::ASCII.GetString($bytes, $offset, $bytes.Length - $offset).Trim()
$targets = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
try {
    foreach ($target in $targets) { [PSAITerminal.PlatformCredentialStore]::Remove([string]$target) }
    exit 0
} catch { Write-Error $_ -ErrorAction Continue; exit 1 }
'@
    $childScript = $childTemplate.Replace('{CORE}', $CoreAssemblyPath.Replace("'", "''"))
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
    $hostPath = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') {'pwsh.exe'} else {'powershell.exe'})
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = [Diagnostics.ProcessStartInfo]::new()
    $process.StartInfo.FileName = $hostPath
    $process.StartInfo.Arguments = "-NoProfile -NonInteractive -EncodedCommand $encoded"
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.RedirectStandardInput = $true
    try {
        if (-not $process.Start()) { throw '无法启动凭据清理进程。' }
        $errorRead = $process.StandardError.ReadToEndAsync()
        # 目标列表经 stdin 传递，100 个长名称也不会超过 Windows 命令行长度上限。
        $process.StandardInput.Write($payload)
        $process.StandardInput.Close()
        $process.WaitForExit()
        [void]$errorRead.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'Windows 凭据清理失败，配置文件已保留，可重试。' }
    } finally { $process.Dispose() }
}
