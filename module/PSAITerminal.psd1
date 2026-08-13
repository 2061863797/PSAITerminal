@{
    RootModule = 'PSAITerminal.psm1'
    ModuleVersion = '0.5.2'
    GUID = 'ac841eb9-b63e-4dd0-9974-c6e7ca4a1682'
    Author = 'LXT'
    CompanyName = 'PSAITerminal'
    Copyright = '(c) 2026 LXT. MIT License.'
    Description = '适用于 Windows 官方 PowerShell 的本地 AI 终端模块。'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
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
        'Install-PSAIProfileIntegration', 'Uninstall-PSAIProfileIntegration'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @('Configure-PSAI')
    PrivateData = @{
        PSData = @{
            Tags = @('AI', 'Terminal', 'PowerShell', 'PSReadLine', 'Windows')
            LicenseUri = 'https://opensource.org/license/mit'
            ProjectUri = 'https://github.com/2061863797/PSAITerminal'
            ReleaseNotes = '0.5.2：修复 PSReadLine 快捷键卸载参数，完善安全说明、Windows CI 和发布校验。'
        }
    }
}
