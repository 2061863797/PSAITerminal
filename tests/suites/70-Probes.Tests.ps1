# 在独立宿主进程中运行意图、审批、可靠性、整改与资源探针。
# 由 tests/run.ps1 在同一作用域内按文件名顺序点源执行，依赖其中的 $module、$testRoot 等状态，不能单独运行。

$probeHost = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' })
& $probeHost -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testsRoot 'intent-probe.ps1') -AssemblyPath (Join-Path $moduleOutput 'bin/PSAITerminal.dll')
if ($LASTEXITCODE -ne 0) { throw '意图分流回归失败。' }
& $probeHost -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testsRoot 'approval-probe.ps1')
if ($LASTEXITCODE -ne 0) { throw '审批说明回归失败。' }
& $probeHost -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testsRoot 'reliability.ps1') -ModulePath $modulePath
if ($LASTEXITCODE -ne 0) { throw '交互可靠性回归失败。' }
& $probeHost -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testsRoot 'hardening.ps1') -ModulePath $modulePath
if ($LASTEXITCODE -ne 0) { throw '整改回归失败。' }
& $probeHost -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testsRoot 'resources.ps1') -ModulePath $modulePath
if ($LASTEXITCODE -ne 0) { throw '原生资源回归失败。' }
