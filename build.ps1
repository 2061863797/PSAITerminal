[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [switch]$Restore,
    [switch]$Package,
    [ValidatePattern('^[0-9A-Za-z]+(?:-[0-9A-Za-z]+)*$')]
    [string]$Prerelease,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$projectFile = Join-Path $projectRoot 'src/PSAITerminal.csproj'
$powerShell7ProjectFile = Join-Path $projectRoot 'src/PowerShell7/PSAITerminal.PowerShell7.csproj'
$sourceManifest = Join-Path $projectRoot 'module/PSAITerminal.psd1'
$releaseVersion = ([version](Import-PowerShellDataFile -LiteralPath $sourceManifest).ModuleVersion).ToString()
$releaseLabel = if ($Prerelease) { "$releaseVersion-$Prerelease" } else { $releaseVersion }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = "out/PSAITerminal-$releaseLabel" }
$pathComparison = [StringComparison]::OrdinalIgnoreCase
$separator = [IO.Path]::DirectorySeparatorChar
$releaseParent = [IO.Path]::GetFullPath((Join-Path $projectRoot 'out')).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
$outputRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot $OutputDirectory)).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
if ($outputRoot.Equals($releaseParent, $pathComparison) -or -not ($outputRoot + $separator).StartsWith($releaseParent + $separator, $pathComparison)) {
    throw "OutputDirectory 必须位于项目的 out 子目录中：$releaseParent"
}
$outputParent = Split-Path -Parent $outputRoot
[IO.Directory]::CreateDirectory($outputParent) | Out-Null
$stagingRoot = Join-Path $outputParent ('.staging-' + [guid]::NewGuid().ToString('N'))
$binaryDirectory = Join-Path $stagingRoot 'bin'
$previousRoot = $null

if ($Restore) {
    dotnet restore $projectFile
    if ($LASTEXITCODE -ne 0) { throw "依赖恢复失败，退出码：$LASTEXITCODE" }
    dotnet restore $powerShell7ProjectFile
    if ($LASTEXITCODE -ne 0) { throw "PowerShell 7 集成依赖恢复失败，退出码：$LASTEXITCODE" }
}

try {
    dotnet build $projectFile --configuration $Configuration --no-restore
    if ($LASTEXITCODE -ne 0) { throw "编译失败，退出码：$LASTEXITCODE" }
    dotnet build $powerShell7ProjectFile --configuration $Configuration --no-restore
    if ($LASTEXITCODE -ne 0) { throw "PowerShell 7 集成编译失败，退出码：$LASTEXITCODE" }

    New-Item -ItemType Directory -Path $binaryDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot "src/bin/$Configuration/netstandard2.0/PSAITerminal.dll") -Destination $binaryDirectory -Force
    Copy-Item -LiteralPath (Join-Path $projectRoot "src/PowerShell7/bin/$Configuration/net8.0/PSAITerminal.PowerShell7.dll") -Destination $binaryDirectory -Force
    $publishFiles = [ordered]@{
        'module/PSAITerminal.psd1' = 'PSAITerminal.psd1'
        'module/PSAITerminal.psm1' = 'PSAITerminal.psm1'
        'LICENSE' = 'LICENSE'
        'README.md' = 'README.md'
        'CHANGELOG.md' = 'CHANGELOG.md'
        'Install-PSAITerminal.ps1' = 'Install-PSAITerminal.ps1'
        'Uninstall-PSAITerminal.ps1' = 'Uninstall-PSAITerminal.ps1'
    }
    foreach ($entry in $publishFiles.GetEnumerator()) {
        $sourcePath = Join-Path $projectRoot $entry.Key
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "发布源文件不存在：$sourcePath" }
        Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $stagingRoot $entry.Value) -Force
    }
    foreach ($helpCulture in @('zh-CN','en-US')) {
        $helpSource = Join-Path $projectRoot "module/$helpCulture"
        if (Test-Path -LiteralPath $helpSource) {
            Copy-Item -LiteralPath $helpSource -Destination $stagingRoot -Recurse -Force
        }
    }

    $manifestPath = Join-Path $stagingRoot 'PSAITerminal.psd1'
    if ($Prerelease) {
        $manifestText = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8)
        $anchor = '        PSData = @{'
        if ($manifestText.IndexOf($anchor, [StringComparison]::Ordinal) -lt 0 -or
            $manifestText.IndexOf($anchor, [StringComparison]::Ordinal) -ne $manifestText.LastIndexOf($anchor, [StringComparison]::Ordinal)) {
            throw '无法唯一定位发布清单的 PSData 区块。'
        }
        $lineBreak = if ($manifestText.Contains("`r`n")) { "`r`n" } else { "`n" }
        $manifestText = $manifestText.Replace($anchor, "$anchor$lineBreak            Prerelease = '$Prerelease'")
        [IO.File]::WriteAllText($manifestPath, $manifestText, [Text.UTF8Encoding]::new($true))
    }
    $manifest = Test-ModuleManifest -Path $manifestPath
    if ($manifest.Version -ne [version]$releaseVersion) { throw "发布清单版本不正确：$($manifest.Version)" }
    $manifestPrerelease = [string]$manifest.PrivateData.PSData.Prerelease
    if ($manifestPrerelease -ne [string]$Prerelease) { throw "发布清单预览标签不正确：$manifestPrerelease" }
    $assemblyVersion = [Reflection.AssemblyName]::GetAssemblyName((Join-Path $binaryDirectory 'PSAITerminal.dll')).Version
    if ($assemblyVersion -ne [version]"$releaseVersion.0") { throw "程序集版本不正确：$assemblyVersion" }
    $integrationAssemblyVersion = [Reflection.AssemblyName]::GetAssemblyName((Join-Path $binaryDirectory 'PSAITerminal.PowerShell7.dll')).Version
    if ($integrationAssemblyVersion -ne [version]"$releaseVersion.0") { throw "PowerShell 7 集成程序集版本不正确：$integrationAssemblyVersion" }

    if (Test-Path -LiteralPath $outputRoot) {
        if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) { throw "输出路径不是目录：$outputRoot" }
        $previousRoot = "$outputRoot.previous.$([guid]::NewGuid().ToString('N'))"
        Move-Item -LiteralPath $outputRoot -Destination $previousRoot
    }
    Move-Item -LiteralPath $stagingRoot -Destination $outputRoot
    if ($previousRoot) {
        try { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        catch { Write-Warning "旧发布目录清理失败，请手动删除：$previousRoot" }
    }

    Write-Host "模块已生成：$outputRoot"
    if ($Package) {
        $archive = Join-Path $outputParent ((Split-Path -Leaf $outputRoot) + '.zip')
        if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
        Compress-Archive -LiteralPath $outputRoot -DestinationPath $archive
        Write-Host "发布包已生成：$archive"
        $compressCommand = Get-Command Compress-PSResource -ErrorAction SilentlyContinue
        if (-not $compressCommand) { throw '缺少 Compress-PSResource。请安装 Microsoft.PowerShell.PSResourceGet 1.2.0 或更高版本。' }
        $galleryStage = Join-Path $outputParent ('.gallery-' + [guid]::NewGuid().ToString('N'))
        $galleryModuleRoot = Join-Path $galleryStage 'PSAITerminal'
        $galleryPackage = Join-Path $outputParent "PSAITerminal.$releaseLabel.nupkg"
        try {
            [IO.Directory]::CreateDirectory($galleryStage) | Out-Null
            Copy-Item -LiteralPath $outputRoot -Destination $galleryModuleRoot -Recurse
            if (Test-Path -LiteralPath $galleryPackage) { Remove-Item -LiteralPath $galleryPackage -Force }
            Compress-PSResource -Path $galleryModuleRoot -DestinationPath $outputParent
            if (-not (Test-Path -LiteralPath $galleryPackage -PathType Leaf)) { throw "Gallery 包未生成：$galleryPackage" }
            Write-Host "Gallery 包已生成：$galleryPackage"
        } finally {
            if (Test-Path -LiteralPath $galleryStage) { Remove-Item -LiteralPath $galleryStage -Recurse -Force }
        }
    }
} catch {
    if (-not (Test-Path -LiteralPath $outputRoot) -and $previousRoot -and (Test-Path -LiteralPath $previousRoot)) {
        Move-Item -LiteralPath $previousRoot -Destination $outputRoot
    }
    throw
} finally {
    if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
}
