@{
    Severity = @('Error', 'Warning')

    # PSAITerminal 是交互式终端模块，Write-Host 用于独立着色的 UI 输出。
    # 内部 New-/Set- 辅助函数并非用户可直接调用的状态变更 Cmdlet。
    # 现有公开函数名属于兼容 API；所有含中文的 PowerShell 运行文件统一使用 UTF-8 BOM。
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSingularNouns'
    )
}
