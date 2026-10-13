# 官方集成：PowerShell 7 预测器与反馈接入。

function Invoke-AIOfficialAddPrediction([string]$Command) {
    if ($script:OfficialIntegrationAvailable) {
        [PSAITerminal.AITerminalOfficialIntegration]::AddPrediction($Command)
    }
}

function Get-AIOfficialFeedback {
    if ($script:OfficialIntegrationAvailable) {
        return [PSAITerminal.AITerminalOfficialIntegration]::GetLastFeedback()
    }
    $null
}

function Test-AIOfficialPredictorRegistered {
    if (-not $script:OfficialIntegrationAvailable) { return $false }
    [bool][PSAITerminal.AITerminalOfficialIntegration]::PredictorRegistered
}

function Test-AIOfficialFeedbackRegistered {
    if (-not $script:OfficialIntegrationAvailable) { return $false }
    [bool][PSAITerminal.AITerminalOfficialIntegration]::FeedbackRegistered
}
