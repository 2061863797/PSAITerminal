# 本地化与多语言字典。

function Get-AILanguage {
    if ($script:Config -and [string]$script:Config.language -in @('en-US','zh-CN')) {
        return [string]$script:Config.language
    }
    'en-US'
}

function Get-AIText([string]$Key, [object[]]$FormatArguments = @()) {
    $texts = @{
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
        'Used' = @{'en-US'='Active';'zh-CN'='当前使用'}
        'Unused' = @{'en-US'='Inactive';'zh-CN'='未使用'}
        'CommonCommands' = @{'en-US'='Common commands';'zh-CN'='常用命令'}
        'Shortcuts' = @{'en-US'='Shortcuts';'zh-CN'='快捷键'}
        'UsageHelp' = @{'en-US'='Usage help';'zh-CN'='使用帮助'}
        'Execute' = @{'en-US'='Execute';'zh-CN'='执行'}
        'Edit' = @{'en-US'='Edit';'zh-CN'='编辑'}
        'Reject' = @{'en-US'='Reject';'zh-CN'='拒绝'}
        'Terminate' = @{'en-US'='Terminate';'zh-CN'='终止'}
        'DefaultPrompt' = @{'en-US'=' (default {0})';'zh-CN'='（默认{0}）'}
        'English' = @{'en-US'='English';'zh-CN'='English'}
        'Chinese' = @{'en-US'='Chinese (简体中文)';'zh-CN'='简体中文 (Chinese)'}
        'LanguageChanged' = @{'en-US'='Language changed to English.';'zh-CN'='语言已切换为中文。'}
        'EnterNumber' = @{'en-US'='Enter a number';'zh-CN'='请输入序号'}
        'InvalidNumber' = @{'en-US'='Invalid number. Please try again.';'zh-CN'='输入的序号无效，请重新输入。'}
        'SelectProtocol' = @{'en-US'='Select protocol';'zh-CN'='选择协议'}
        'NoModels' = @{'en-US'='No models configured.';'zh-CN'='尚未配置模型。'}
        'SelectModel' = @{'en-US'='Select model';'zh-CN'='请选择模型'}
        'ModelId' = @{'en-US'='Model ID';'zh-CN'='模型 ID'}
        'ManualModelId' = @{'en-US'='Enter model ID manually (leave blank to cancel)';'zh-CN'='手动输入模型 ID，留空取消'}
        'LoadingModels' = @{'en-US'='Loading available models...';'zh-CN'='正在获取可用模型...'}
        'AddModelName' = @{'en-US'='Configuration name';'zh-CN'='配置名称'}
        'Endpoint' = @{'en-US'='Base endpoint';'zh-CN'='接口基础地址'}
        'ApiKey' = @{'en-US'='API key (hidden)';'zh-CN'='API Key（隐藏）'}
        'CurrentProtocol' = @{'en-US'='Current protocol';'zh-CN'='当前协议'}
        'CurrentModelLabel' = @{'en-US'='Model';'zh-CN'='模型'}
        'Address' = @{'en-US'='Endpoint';'zh-CN'='地址'}
        'Status' = @{'en-US'='Status';'zh-CN'='状态'}
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
        'ModeOff' = @{'en-US'='Off';'zh-CN'='Off'}
        'ModeAI' = @{'en-US'='AI';'zh-CN'='AI'}
        'ModeAuto' = @{'en-US'='Auto';'zh-CN'='Auto'}
        'SelectMode' = @{'en-US'='Select mode';'zh-CN'='请选择模式'}
        'ColorPrompt' = @{'en-US'='Use a dedicated color for AI output?';'zh-CN'='启用统一的 AI 输出颜色？'}
        'ApprovalPurpose' = @{'en-US'='Purpose';'zh-CN'='目的'}
        'ApprovalCommand' = @{'en-US'='Command';'zh-CN'='命令'}
        'ApprovalExpected' = @{'en-US'='Expected result';'zh-CN'='预期'}
        'ApprovalSideEffects' = @{'en-US'='Side effects';'zh-CN'='副作用'}
        'ApprovalRollback' = @{'en-US'='Rollback';'zh-CN'='回滚'}
        'ApprovalRisk' = @{'en-US'='Risk';'zh-CN'='风险'}
        'ApprovalNotice' = @{
            'en-US'='AI-generated descriptions may be inaccurate. Verify the complete command before approving.'
            'zh-CN'='目的、预期和副作用由 AI 生成，可能不准确；批准前请核对完整命令。'
        }
        'HighRiskConfirm' = @{
            'en-US'='This is a high-risk command. Execute exactly the command shown above?'
            'zh-CN'='这是高风险命令。确定执行上面显示的完整命令吗？'
        }
        'ApprovalMenu' = @{'en-US'=@('Approve & Execute','Edit Command','Reject');'zh-CN'=@('批准执行','编辑命令','拒绝执行')}
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
        'EditedCommand' = @{'en-US'='Enter the complete edited command';'zh-CN'='请输入修改后的完整命令'}
        'ModeChanged' = @{'en-US'='PSAITerminal mode: {0}';'zh-CN'='PSAITerminal 模式：{0}'}
        'ModeMenu' = @{'en-US'=@('Off','AI','Auto','Back');'zh-CN'=@('Off','AI','Auto','返回')}
        'HelpCommands' = @{'en-US'='Common commands';'zh-CN'='常用命令'}
        'HelpShortcuts' = @{'en-US'='Shortcuts';'zh-CN'='快捷键'}
        'HelpBack' = @{'en-US'='Back';'zh-CN'='返回'}
        'UninstallConfirm' = @{'en-US'='Are you sure you want to uninstall PSAITerminal?';'zh-CN'='确定要卸载 PSAITerminal 吗？'}
        'UninstallPurgeUserDataPrompt' = @{'en-US'='Also delete verified configuration, session/Run data, and configured model credentials?';'zh-CN'='是否同时清除已确认的配置、会话/Run 数据和配置模型对应的凭据？'}
        'UninstallProfileRemoved' = @{'en-US'='Removed PSAITerminal integration from PowerShell profile.';'zh-CN'='已从 PowerShell Profile 中移除 PSAITerminal 自动加载。'}
        'UninstallExitPrompt' = @{'en-US'='Exit the current terminal session now?';'zh-CN'='是否立即退出当前终端？'}
        'UninstallComplete' = @{'en-US'='PSAITerminal has been uninstalled.';'zh-CN'='PSAITerminal 卸载完成。'}
        'LoadedGuide' = @{
            'en-US'="PSAITerminal loaded. / PSAITerminal 已加载。`nType ai to configure a model. / 输入 ai 配置模型。`nF2: AI  F3: PowerShell  F6: mode  F7: explain. / F2：AI  F3：PowerShell  F6：模式  F7：解释。"
            'zh-CN'="PSAITerminal 已加载。/ PSAITerminal loaded.`n输入 ai 配置模型。/ Type ai to configure a model.`nF2：AI  F3：PowerShell  F6：模式  F7：解释。/ F2: AI  F3: PowerShell  F6: mode  F7: explain."
        }
    }
    $value = if ($texts.ContainsKey($Key)) { $texts[$Key][(Get-AILanguage)] } else { $null }
    if ($null -eq $value) { return $Key }
    if ($FormatArguments.Count -gt 0) { return $value -f $FormatArguments }
    $value
}
