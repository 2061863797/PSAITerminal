@{
    RootModule = 'PSAITerminal.psm1'
    ModuleVersion = '1.0.2'
    GUID = 'ac841eb9-b63e-4dd0-9974-c6e7ca4a1682'
    Author = 'LXT'
    CompanyName = 'PSAITerminal'
    Copyright = '(c) 2026 LXT. MIT License.'
    Description = '适用于 Windows PowerShell 5.1 和 PowerShell 7.4+ 的本地 AI 终端模块。'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    RequiredAssemblies = @('bin/PSAITerminal.dll')
    FunctionsToExport = @(
        'Enable-PSAITerminal', 'Disable-PSAITerminal',
        'Get-PSAITerminalMode', 'Set-PSAITerminalMode',
        'Get-PSAITerminalOption', 'Set-PSAITerminalOption',
        'Open-PSAISettings', 'Open-PSAIModelSelector',
        'New-PSAIModel', 'Get-PSAIModel', 'Set-PSAIModel',
        'Select-PSAIModel', 'Remove-PSAIModel', 'Test-PSAIModel',
        'New-PSAISession', 'Get-PSAISession', 'Select-PSAISession', 'Clear-PSAISession',
        'Start-PSAIRun', 'Get-PSAIRun', 'Resume-PSAIRun', 'Resolve-PSAIRun', 'Stop-PSAIRun',
        'Start-PSAIToolExecution', 'Complete-PSAIToolExecution', 'Start-PSAIAutoFallback',
        'Invoke-PSAI', 'Invoke-PSAIAutoCompletion', 'Show-PSAIResultExplanation',
        'Enable-PSAIPredictor', 'Disable-PSAIPredictor',
        'Get-PSAIIntegrationStatus', 'Test-PSAIConfiguration',
        'Install-PSAIProfileIntegration', 'Uninstall-PSAIProfileIntegration',
        'Show-AICliHelp'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @('Configure-PSAI')
    PrivateData = @{
        PSData = @{
            Tags = @('AI', 'Terminal', 'PowerShell', 'PSReadLine', 'Windows')
            LicenseUri = 'https://opensource.org/license/mit'
            ProjectUri = 'https://github.com/2061863797/PSAITerminal'
            ReleaseNotes = '1.0.2：强化自动模式智能诊断与自愈。命令执行失败自动给出错误根因分析与修改后的可执行指令，支持交互式一键执行；代码语法错误智能纠错；自然语言直接自然回复，杜绝繁琐工具包裹与运行失败中断。'
        }
    }
}
