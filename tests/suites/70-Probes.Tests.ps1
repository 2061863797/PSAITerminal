# 在独立宿主进程中运行整改与原生资源探针。
# 由 tests/run.ps1 在同一作用域内按文件名顺序点源执行，依赖其中的 $module、$testRoot 等状态，不能单独运行。

$probeHost = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' })
& $probeHost -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testsRoot 'hardening.ps1') -ModulePath $modulePath
if ($LASTEXITCODE -ne 0) { throw '整改回归失败。' }
& $probeHost -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testsRoot 'resources.ps1') -ModulePath $modulePath
if ($LASTEXITCODE -ne 0) { throw '原生资源回归失败。' }
