@{
    RootModule = 'PSAITerminal.psm1'
    ModuleVersion = '1.0.3'
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
            ReleaseNotes = '1.0.3：深度重塑交互架构与路由。自然语言二分类（自由沟通纯文本 vs 操作指令六要素）；错误诊断与自愈闭环；统一三项批准菜单；单步完结保护杜绝文件探测发散；按 F7 解释；目标导向自主规划与障碍说明。'
        }
    }
}
