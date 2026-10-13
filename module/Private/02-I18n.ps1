# 本地化与多语言字典。

function Get-AILanguage {
    if ($script:Config -and [string]$script:Config.language -in @('en-US','zh-CN')) {
        return [string]$script:Config.language
    }
    'en-US'
}

function Get-AIText([string]$Key, [object[]]$FormatArguments = @()) {
    # 文本表只在首次调用时构建。
    if (-not $script:AITexts) { $script:AITexts = @{
        'Settings' = @{'en-US'='PSAITerminal';'zh-CN'='PSAITerminal'}
        'CurrentMode' = @{'en-US'='Mode: {0}';'zh-CN'='当前模式：{0}'}
        'CurrentModel' = @{'en-US'='Model: {0}';'zh-CN'='当前模型：{0}'}
        'ConfigPath' = @{'en-US'='Config: {0}';'zh-CN'='配置文件：{0}'}
        'Models' = @{'en-US'='Models';'zh-CN'='模型配置'}
        'Mode' = @{'en-US'='Mode';'zh-CN'='切换模式'}
        'Appearance' = @{'en-US'='Appearance';'zh-CN'='外观'}
        'Language' = @{'en-US'='Language / 语言';'zh-CN'='语言 / Language'}
        'Help' = @{'en-US'='Help';'zh-CN'='使用帮助'}
        'Diagnostics' = @{'en-US'='Diagnostics';'zh-CN'='检查配置'}
        'Uninstall' = @{'en-US'='Uninstall PSAITerminal';'zh-CN'='卸载 PSAITerminal'}
        'Back' = @{'en-US'='Back';'zh-CN'='返回'}
        'AddModel' = @{'en-US'='Add model';'zh-CN'='新增模型'}
        'Cancel' = @{'en-US'='Cancel';'zh-CN'='取消'}
        'Current' = @{'en-US'='(current)';'zh-CN'='（当前）'}
        'CommonCommands' = @{'en-US'='Common commands';'zh-CN'='常用命令'}
        'Shortcuts' = @{'en-US'='Shortcuts';'zh-CN'='快捷键'}
        'UsageHelp' = @{'en-US'='Usage help';'zh-CN'='使用帮助'}
        'Edit' = @{'en-US'='Edit';'zh-CN'='编辑'}
        'Reject' = @{'en-US'='Reject';'zh-CN'='拒绝'}
        'DefaultPrompt' = @{'en-US'=' (default {0})';'zh-CN'='（默认{0}）'}
        'English' = @{'en-US'='English';'zh-CN'='English'}
        'Chinese' = @{'en-US'='Chinese (简体中文)';'zh-CN'='简体中文 (Chinese)'}
        'LanguageChanged' = @{'en-US'='Language changed to English.';'zh-CN'='语言已切换为中文。'}
        'InvalidNumber' = @{'en-US'='Invalid number. Please try again.';'zh-CN'='输入的序号无效，请重新输入。'}
        'SelectProtocol' = @{'en-US'='Select protocol';'zh-CN'='选择协议'}
        'SelectModel' = @{'en-US'='Select model';'zh-CN'='请选择模型'}
        'ModelId' = @{'en-US'='Model ID';'zh-CN'='模型 ID'}
        'ManualModelId' = @{'en-US'='Enter model ID manually (leave blank to cancel)';'zh-CN'='手动输入模型 ID，留空取消'}
        'LoadingModels' = @{'en-US'='Loading available models...';'zh-CN'='正在获取可用模型...'}
        'AddModelName' = @{'en-US'='Configuration name';'zh-CN'='配置名称'}
        'Endpoint' = @{'en-US'='Base endpoint';'zh-CN'='接口基础地址'}
        'ApiKey' = @{'en-US'='API key (hidden)';'zh-CN'='API Key（隐藏）'}
        'CurrentProtocol' = @{'en-US'='Current protocol';'zh-CN'='当前协议'}
        'ApiKeyStatus' = @{'en-US'='API key';'zh-CN'='API Key'}
        'ActiveStatus' = @{'en-US'='Active';'zh-CN'='当前使用'}
        'InactiveStatus' = @{'en-US'='Inactive';'zh-CN'='未使用'}
        'SetActive' = @{'en-US'='Set as active';'zh-CN'='设为当前模型'}
        'EditConfig' = @{'en-US'='Edit configuration';'zh-CN'='编辑配置'}
        'TestConnection' = @{'en-US'='Test connection';'zh-CN'='测试连接'}
        'DeleteConfig' = @{'en-US'='Delete configuration';'zh-CN'='删除配置'}
        'ChooseReplacement' = @{'en-US'='Select the active model after deletion:';'zh-CN'='请选择删除后的当前模型：'}
        'AskOnlineTest' = @{'en-US'='Test the active model too? This sends one minimal request.';'zh-CN'='同时测试当前模型？这会发送一次最小请求。'}
        'ReturnPrompt' = @{'en-US'='Press Enter to return';'zh-CN'='按 Enter 返回'}
        'SelectMode' = @{'en-US'='Select mode';'zh-CN'='请选择模式'}
        'ColorPrompt' = @{'en-US'='Use a dedicated color for AI output?';'zh-CN'='启用统一的 AI 输出颜色？'}
        'ApprovalPurpose' = @{'en-US'='Purpose';'zh-CN'='目的'}
        'ApprovalRisk' = @{'en-US'='Risk';'zh-CN'='风险'}
        'HighRiskConfirm' = @{
            'en-US'='This is a high-risk command. Execute exactly the command shown above?'
            'zh-CN'='这是高风险命令。确定执行上面显示的完整命令吗？'
        }
        'Protocol' = @{'en-US'='Protocol';'zh-CN'='协议'}
        'Model' = @{'en-US'='Model';'zh-CN'='模型'}
        'EndpointLabel' = @{'en-US'='Endpoint';'zh-CN'='地址'}
        'ModelStatus' = @{'en-US'='Status';'zh-CN'='状态'}
        'ApiKeySaved' = @{'en-US'='saved';'zh-CN'='已保存'}
        'ApiKeyMissing' = @{'en-US'='missing; edit configuration to update';'zh-CN'='缺少，请编辑配置后更新'}
        'NoModelsWarning' = @{'en-US'='No models configured.';'zh-CN'='尚未配置模型。'}
        'SelectNumber' = @{'en-US'='Enter a number';'zh-CN'='请输入序号'}
        'RemoteModelsFailed' = @{'en-US'='Unable to load the model list: {0}';'zh-CN'='自动获取模型列表失败：{0}'}
        'EnterModelManually' = @{'en-US'='Enter a model ID manually?';'zh-CN'='是否手动输入模型 ID？'}
        'NoRemoteModels' = @{'en-US'='The service returned no available generation models.';'zh-CN'='服务没有返回可用生成模型。'}
        'DuplicateModel' = @{'en-US'='A model configuration named {0} already exists.';'zh-CN'='模型配置已存在：{0}'}
        'ModelAdded' = @{'en-US'='Model configuration added and activated.';'zh-CN'='模型配置已添加并立即生效。'}
        'CredentialFallback' = @{'en-US'='Saving to the system credential store failed. Use the API key for this PowerShell session only?';'zh-CN'='系统密钥库保存失败，是否改为仅当前 PowerShell 会话使用？'}
        'ModelAddedSession' = @{'en-US'='Model configuration added; the API key is available only in this session.';'zh-CN'='模型配置已添加；API Key 仅在当前会话有效。'}
        'ModelMissing' = @{'en-US'='Model configuration not found.';'zh-CN'='模型不存在。'}
        'ChangeProtocol' = @{'en-US'='Change the protocol?';'zh-CN'='是否修改协议？'}
        'UpdateApiKey' = @{'en-US'='Update the API key?';'zh-CN'='是否更新 API Key？'}
        'NewApiKey' = @{'en-US'='New API key (hidden)';'zh-CN'='新 API Key（隐藏）'}
        'ModelUpdated' = @{'en-US'='Model configuration updated.';'zh-CN'='模型配置已更新。'}
        'ModelUpdatedSession' = @{'en-US'='Model configuration updated; the API key is available only in this session.';'zh-CN'='模型配置已更新；API Key 仅在当前会话有效。'}
        'ConfirmDeleteModel' = @{'en-US'='Delete ''{0}''?';'zh-CN'='确定删除“{0}”？'}
        'ModelDeleted' = @{'en-US'='Model configuration deleted.';'zh-CN'='模型配置已删除。'}
        'ModeChanged' = @{'en-US'='PSAITerminal mode: {0}';'zh-CN'='PSAITerminal 模式：{0}'}
        'ModeMenu' = @{'en-US'=@('Off','AI','Auto','Back');'zh-CN'=@('Off','AI','Auto','返回')}
        'UninstallConfirm' = @{'en-US'='Are you sure you want to uninstall PSAITerminal?';'zh-CN'='确定要卸载 PSAITerminal 吗？'}
        'UninstallPurgeUserDataPrompt' = @{'en-US'='Also delete verified configuration, session/Run data, and configured model credentials?';'zh-CN'='是否同时清除已确认的配置、会话/Run 数据和配置模型对应的凭据？'}
        'UninstallProfileRemoved' = @{'en-US'='Removed PSAITerminal integration from PowerShell profile.';'zh-CN'='已从 PowerShell Profile 中移除 PSAITerminal 自动加载。'}
        'UninstallExitPrompt' = @{'en-US'='Exit the current terminal session now?';'zh-CN'='是否立即退出当前终端？'}
        'UninstallComplete' = @{'en-US'='PSAITerminal has been uninstalled.';'zh-CN'='PSAITerminal 卸载完成。'}
        'LoadedGuide' = @{
            'en-US'="PSAITerminal loaded. / PSAITerminal 已加载。`nType ai to configure a model. / 输入 ai 配置模型。`nF2: AI  F3: PowerShell  F6: mode  F7: explain. / F2：AI  F3：PowerShell  F6：模式  F7：解释。"
            'zh-CN'="PSAITerminal 已加载。/ PSAITerminal loaded.`n输入 ai 配置模型。/ Type ai to configure a model.`nF2：AI  F3：PowerShell  F6：模式  F7：解释。/ F2: AI  F3: PowerShell  F6: mode  F7: explain."
        }
        'AutoApproved' = @{'en-US'='Auto-approved';'zh-CN'='已自动允许'}
        'ApprovalChoices' = @{'en-US'='[Y] Run  [A] Always allow {0} this session  [E] Edit in prompt  [N] Reject';'zh-CN'='[Y] 执行  [A] 本会话总是允许 {0}  [E] 放入命令行编辑  [N] 拒绝'}
        'ApprovalChoicesHigh' = @{'en-US'='[Y] Run  [E] Edit in prompt  [N] Reject';'zh-CN'='[Y] 执行  [E] 放入命令行编辑  [N] 拒绝'}
        'HighRiskNoDefault' = @{'en-US'='High-risk commands have no default. Enter Y, E, or N.';'zh-CN'='高风险命令没有默认选项，请输入 Y、E 或 N。'}
        'RejectReason' = @{'en-US'='Tell the AI what to do instead (press Enter to cancel the task)';'zh-CN'='告诉 AI 应该怎么改（直接回车则取消任务）'}
        'InvalidChoice' = @{'en-US'='Enter one of the letters shown.';'zh-CN'='请输入上面列出的字母。'}
        'StepSucceeded' = @{'en-US'='Succeeded';'zh-CN'='执行成功'}
        'StepFailed' = @{'en-US'='Failed';'zh-CN'='执行失败'}
        'StepFailedExit' = @{'en-US'='Failed (exit code {0})';'zh-CN'='执行失败（退出码 {0}）'}
        'NoOutput' = @{'en-US'='(no output)';'zh-CN'='（无输出）'}
        'ToolResultCommand' = @{'en-US'='Command';'zh-CN'='命令'}
        'ToolResultStatus' = @{'en-US'='Status';'zh-CN'='状态'}
        'ToolResultOutput' = @{'en-US'='Output';'zh-CN'='输出'}
        'MaxStepsReached' = @{'en-US'='Stopped after reaching the limit of {0} commands for one task.';'zh-CN'='已达到单个任务 {0} 条命令的上限，已停止。'}
        'ModelRequestFailed' = @{'en-US'='Model request failed';'zh-CN'='模型请求失败'}
        'InvalidProposal' = @{'en-US'='Invalid tool call; fix it and call the powershell tool again';'zh-CN'='工具调用无效，请修正后重新调用 powershell 工具'}
        'InvalidProposalStopped' = @{'en-US'='The model returned invalid commands twice; nothing was run';'zh-CN'='模型连续两次给出无效命令，未执行任何命令'}
        'UserEditsCommand' = @{'en-US'='The user will edit and run this command themselves; it has not run';'zh-CN'='用户选择自行编辑并执行该命令，尚未执行'}
        'CommandPlacedInInput' = @{'en-US'='Command placed in the input line; edit it and press Enter.';'zh-CN'='命令已放入输入行，修改后按回车执行。'}
        'UserRejectedWithFeedback' = @{'en-US'='The user rejected this command and gave feedback';'zh-CN'='用户拒绝了该命令，并给出反馈'}
        'UserRejected' = @{'en-US'='The user rejected this command; the task was cancelled';'zh-CN'='用户拒绝了该命令，任务已取消'}
        'CommandInHistory' = @{'en-US'='The command was added to history; press Up to recall it.';'zh-CN'='命令已加入历史记录，按 ↑ 调出。'}
        'TaskCancelled' = @{'en-US'='Task cancelled';'zh-CN'='任务已取消'}
        'NothingToExplain' = @{'en-US'='No recent command to explain.';'zh-CN'='还没有可以解释的命令。'}
        'FixTask' = @{'en-US'="This command just failed in my terminal. Briefly explain why, then propose a fix with the powershell tool.`nCommand: {0}`nError: {1}";'zh-CN'="下面这条命令刚才在终端里执行失败了。先用一两句话说明原因，再用 powershell 工具提出修正命令。`n命令：{0}`n错误：{1}"}
        'ExplainTask' = @{'en-US'='Briefly explain what this command did and what its result means: {0}';'zh-CN'='简要解释这条命令做了什么、结果说明什么：{0}'}
        'CommandFailedHint' = @{'en-US'='Command failed · press F7 to diagnose and fix';'zh-CN'='命令失败 · 按 F7 诊断修复'}
    } }
    $value = if ($script:AITexts.ContainsKey($Key)) { $script:AITexts[$Key][(Get-AILanguage)] } else { $null }
    if ($null -eq $value) { return $Key }
    if ($FormatArguments.Count -gt 0) { return $value -f $FormatArguments }
    $value
}
