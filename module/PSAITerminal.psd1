@{
    RootModule = 'PSAITerminal.psm1'
    ModuleVersion = '2.0.1'
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
        'Invoke-PSAI',
        'Get-PSAIIntegrationStatus', 'Test-PSAIConfiguration',
        'Install-PSAIProfileIntegration', 'Uninstall-PSAIProfileIntegration',
        'Uninstall-PSAITerminal', 'Show-AICliHelp'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @('Configure-PSAI')
    PrivateData = @{
        PSData = @{
            Tags = @('AI', 'Terminal', 'PowerShell', 'PSReadLine', 'Windows')
            LicenseUri = 'https://opensource.org/license/mit'
            ProjectUri = 'https://github.com/2061863797/PSAITerminal'
            ReleaseNotes = '2.0.1：修复新终端第一次请求必定失败、Anthropic 执行命令后下一轮请求失败；修复中文引号截断任务；堵住 reg.exe、完整路径、-f 缩写、Start-Process 启动 shell 等绕过高风险确认的写法；免确认列表不再放行重定向、赋值和 .NET 调用，git 等工具按子命令匹配；修复终端使用较久后 F7 取不到报错原文。'
        }
    }
}
