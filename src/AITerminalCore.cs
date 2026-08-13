using System.ComponentModel;
using System.Diagnostics;
using System.Management.Automation.Language;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace PSAITerminal;

public enum AITerminalMode
{
    Off,
    AI,
    Auto,
}

public enum AITerminalRisk
{
    Low,
    Medium,
    High,
}

public enum AIProtocol
{
    Anthropic,
    OpenAIChat,
    OpenAIResponses,
    GeminiNative,
    Ollama,
}

/// <summary>
/// 按流清理来自远端模型的终端控制序列。实例会保留跨分片状态。
/// </summary>
public sealed class AITerminalStreamingTextSanitizer
{
    private enum ParserState
    {
        Text,
        Escape,
        EscapeIntermediate,
        ControlSequence,
        OperatingSystemCommand,
        OperatingSystemCommandEscape,
        StringCommand,
        StringCommandEscape,
    }

    private ParserState _state;

    public string Sanitize(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return string.Empty;
        }

        StringBuilder result = new(value.Length);
        foreach (char character in value)
        {
            switch (_state)
            {
                case ParserState.Text:
                    if (character == '\u001b')
                    {
                        _state = ParserState.Escape;
                    }
                    else if (character == '\u009b')
                    {
                        _state = ParserState.ControlSequence;
                    }
                    else if (character == '\u009d')
                    {
                        _state = ParserState.OperatingSystemCommand;
                    }
                    else if (character is '\u0090' or '\u0098' or '\u009e' or '\u009f')
                    {
                        _state = ParserState.StringCommand;
                    }
                    else if (character is '\r' or '\n' or '\t' ||
                        (character >= ' ' && character != '\u007f' &&
                         !(character >= '\u0080' && character <= '\u009f') &&
                         !IsUnsafeUnicodeControl(character)))
                    {
                        result.Append(character);
                    }

                    break;

                case ParserState.Escape:
                    _state = character switch
                    {
                        '[' => ParserState.ControlSequence,
                        ']' => ParserState.OperatingSystemCommand,
                        'P' or 'X' or '^' or '_' => ParserState.StringCommand,
                        >= ' ' and <= '/' => ParserState.EscapeIntermediate,
                        _ => ParserState.Text,
                    };
                    break;

                case ParserState.EscapeIntermediate:
                    if (character is >= '0' and <= '~')
                    {
                        _state = ParserState.Text;
                    }

                    break;

                case ParserState.ControlSequence:
                    if (character is >= '@' and <= '~')
                    {
                        _state = ParserState.Text;
                    }

                    break;

                case ParserState.OperatingSystemCommand:
                    if (character is '\u0007' or '\u009c')
                    {
                        _state = ParserState.Text;
                    }
                    else if (character == '\u001b')
                    {
                        _state = ParserState.OperatingSystemCommandEscape;
                    }

                    break;

                case ParserState.OperatingSystemCommandEscape:
                    _state = character == '\\' ? ParserState.Text : ParserState.OperatingSystemCommand;
                    break;

                case ParserState.StringCommand:
                    if (character == '\u009c')
                    {
                        _state = ParserState.Text;
                    }
                    else if (character == '\u001b')
                    {
                        _state = ParserState.StringCommandEscape;
                    }

                    break;

                case ParserState.StringCommandEscape:
                    _state = character == '\\' ? ParserState.Text : ParserState.StringCommand;
                    break;
            }
        }

        return result.ToString();
    }

    public void Reset() => _state = ParserState.Text;

    private static bool IsUnsafeUnicodeControl(char value) =>
        (value is '\u061c' or '\u200e' or '\u200f') ||
        (value >= '\u202a' && value <= '\u202e') ||
        (value >= '\u2066' && value <= '\u2069');
}

public static class AITerminalInputRouter
{
    public static bool IsIncomplete(string? line)
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            return false;
        }

        Parser.ParseInput(line, out _, out ParseError[] errors);
        return errors.Any(static error => error.IncompleteInput);
    }

    public static bool NeedsAgent(
        string? line,
        Func<string, bool>? commandExists,
        Func<string, bool>? pathExists)
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            return false;
        }

        Ast ast = Parser.ParseInput(line, out _, out ParseError[] errors);
        if (errors.Any(static error => error.IncompleteInput))
        {
            return false;
        }

        if (errors.Length > 0)
        {
            return true;
        }

        CommandAst[] commands = ast
            .FindAll(static node => node is CommandAst, searchNestedScriptBlocks: false)
            .Cast<CommandAst>()
            .ToArray();

        if (commands.Length == 0)
        {
            return false;
        }

        foreach (CommandAst command in commands)
        {
            string? commandName = command.GetCommandName();
            if (string.IsNullOrEmpty(commandName) || commandName is "." or "&")
            {
                continue;
            }

            if (commandExists?.Invoke(commandName) != true && pathExists?.Invoke(commandName) != true)
            {
                return true;
            }
        }

        return false;
    }
}

public static class AITerminalEndpointResolver
{
    public static Uri NormalizeBaseEndpoint(string protocol, Uri endpoint)
    {
        AIProtocol parsedProtocol = ParseProtocol(protocol);
        ValidateBaseEndpoint(endpoint);

        UriBuilder builder = new(endpoint)
        {
            Fragment = string.Empty,
            Query = string.Empty,
        };

        string path = builder.Path.TrimEnd('/');
        if (IsResourcePath(parsedProtocol, path))
        {
            throw new ArgumentException("接口地址应填写基础地址，不能填写 /models、/chat/completions、/responses 或其他完整资源地址。", nameof(endpoint));
        }

        builder.Path = string.IsNullOrEmpty(path) ? "/" : path;
        return builder.Uri;
    }

    public static Uri ResolveModelListEndpoint(string protocol, Uri endpoint)
    {
        AIProtocol parsedProtocol = ParseProtocol(protocol);
        Uri normalized = NormalizeBaseEndpoint(protocol, endpoint);
        UriBuilder builder = new(normalized);
        string path = builder.Path.TrimEnd('/');

        builder.Path = parsedProtocol switch
        {
            AIProtocol.OpenAIChat or AIProtocol.OpenAIResponses or AIProtocol.Anthropic =>
                AppendPath(EnsureVersionSuffix(path, "v1"), "models"),
            AIProtocol.GeminiNative => AppendPath(EnsureVersionSuffix(path, "v1beta"), "models"),
            AIProtocol.Ollama => AppendPath(EnsureVersionSuffix(path, "api"), "tags"),
            _ => throw new ArgumentOutOfRangeException(nameof(protocol)),
        };

        if (parsedProtocol == AIProtocol.GeminiNative)
        {
            builder.Query = "pageSize=1000";
        }

        return builder.Uri;
    }

    public static Uri ResolveRequestEndpoint(string protocol, Uri endpoint, string? modelId = null)
    {
        AIProtocol parsedProtocol = ParseProtocol(protocol);
        Uri normalized = NormalizeBaseEndpoint(protocol, endpoint);
        UriBuilder builder = new(normalized);
        string path = builder.Path.TrimEnd('/');

        builder.Path = parsedProtocol switch
        {
            AIProtocol.OpenAIChat => AppendPath(EnsureVersionSuffix(path, "v1"), "chat/completions"),
            AIProtocol.OpenAIResponses => AppendPath(EnsureVersionSuffix(path, "v1"), "responses"),
            AIProtocol.Anthropic => AppendPath(EnsureVersionSuffix(path, "v1"), "messages"),
            AIProtocol.Ollama => AppendPath(EnsureVersionSuffix(path, "api"), "chat"),
            AIProtocol.GeminiNative => ResolveGeminiPath(path, modelId),
            _ => throw new ArgumentOutOfRangeException(nameof(protocol)),
        };

        if (parsedProtocol == AIProtocol.GeminiNative)
        {
            builder.Query = "alt=sse";
        }

        return builder.Uri;
    }

    public static AIProtocol ParseProtocol(string protocol)
    {
        if (!Enum.TryParse(protocol, ignoreCase: true, out AIProtocol parsed))
        {
            throw new ArgumentException($"不支持的模型协议：{protocol}", nameof(protocol));
        }

        return parsed;
    }

    private static void ValidateBaseEndpoint(Uri endpoint)
    {
        ArgumentNullException.ThrowIfNull(endpoint);
        if (!AITerminalSecurity.IsEndpointAllowed(endpoint))
        {
            throw new ArgumentException("接口地址只允许 HTTPS；HTTP 仅允许本机环回地址，且不能包含用户名或密码。", nameof(endpoint));
        }

        if (!string.IsNullOrEmpty(endpoint.Query) || !string.IsNullOrEmpty(endpoint.Fragment))
        {
            throw new ArgumentException("接口基础地址不能包含查询参数或片段。", nameof(endpoint));
        }
    }

    private static bool IsResourcePath(AIProtocol protocol, string path)
    {
        string normalized = path.TrimEnd('/');
        return protocol switch
        {
            AIProtocol.OpenAIChat => normalized.EndsWith("/chat/completions", StringComparison.OrdinalIgnoreCase) ||
                normalized.EndsWith("/models", StringComparison.OrdinalIgnoreCase),
            AIProtocol.OpenAIResponses => normalized.EndsWith("/responses", StringComparison.OrdinalIgnoreCase) ||
                normalized.EndsWith("/models", StringComparison.OrdinalIgnoreCase),
            AIProtocol.Anthropic => normalized.EndsWith("/messages", StringComparison.OrdinalIgnoreCase) ||
                normalized.EndsWith("/models", StringComparison.OrdinalIgnoreCase),
            AIProtocol.GeminiNative => normalized.Contains(":streamGenerateContent", StringComparison.OrdinalIgnoreCase) ||
                normalized.EndsWith("/models", StringComparison.OrdinalIgnoreCase),
            AIProtocol.Ollama => normalized.EndsWith("/api/chat", StringComparison.OrdinalIgnoreCase) ||
                normalized.EndsWith("/api/tags", StringComparison.OrdinalIgnoreCase),
            _ => false,
        };
    }

    private static string EnsureVersionSuffix(string path, string versionSegment)
    {
        string normalized = path.TrimEnd('/');
        string suffix = "/" + versionSegment;
        return normalized.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)
            ? normalized
            : AppendPath(normalized, versionSegment);
    }

    private static string AppendPath(string path, string suffix)
    {
        string left = path.TrimEnd('/');
        string right = suffix.Trim('/');
        return string.IsNullOrEmpty(left) ? "/" + right : left + "/" + right;
    }

    private static string ResolveGeminiPath(string path, string? modelId)
    {
        if (string.IsNullOrWhiteSpace(modelId))
        {
            throw new ArgumentException("Gemini Native 请求必须提供模型 ID。", nameof(modelId));
        }

        string normalizedModel = modelId.StartsWith("models/", StringComparison.OrdinalIgnoreCase)
            ? modelId[7..]
            : modelId;
        if (!Regex.IsMatch(normalizedModel, "^[A-Za-z0-9._-]+$", RegexOptions.CultureInvariant))
        {
            throw new ArgumentException("Gemini Native 模型 ID 无效。", nameof(modelId));
        }

        return AppendPath(EnsureVersionSuffix(path, "v1beta"), $"models/{normalizedModel}:streamGenerateContent");
    }
}

public static class AITerminalSecurity
{
    private static readonly Dictionary<string, string> s_standardCommandAliases = new(StringComparer.OrdinalIgnoreCase)
    {
        ["ac"] = "Add-Content",
        ["clc"] = "Clear-Content",
        ["cli"] = "Clear-Item",
        ["clp"] = "Clear-ItemProperty",
        ["cp"] = "Copy-Item",
        ["copy"] = "Copy-Item",
        ["cpi"] = "Copy-Item",
        ["cpp"] = "Copy-ItemProperty",
        ["epcsv"] = "Export-Csv",
        ["mi"] = "Move-Item",
        ["move"] = "Move-Item",
        ["mv"] = "Move-Item",
        ["mp"] = "Move-ItemProperty",
        ["mkdir"] = "New-Item",
        ["nal"] = "New-Alias",
        ["ndr"] = "New-PSDrive",
        ["ni"] = "New-Item",
        ["ren"] = "Rename-Item",
        ["rni"] = "Rename-Item",
        ["sal"] = "Set-Alias",
        ["sc"] = "Set-Content",
        ["set"] = "Set-Variable",
        ["si"] = "Set-Item",
        ["sp"] = "Set-ItemProperty",
        ["sv"] = "Set-Variable",
        ["tee"] = "Tee-Object",
    };

    private static readonly HashSet<string> s_highRiskCommandNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "Clear-Content", "Clear-Disk", "Format-Volume", "Install-Module", "Install-Package",
        "Install-Script", "Out-File", "Restart-Computer", "Restart-Service", "Set-Acl",
        "Set-Content", "Set-ExecutionPolicy", "Stop-Computer", "Stop-Process", "Stop-Service",
        "Uninstall-Module", "Uninstall-Package", "Uninstall-Script", "Update-Module",
        "Update-Package", "Update-Script", "Invoke-Expression", "Start-Process", "bash",
        "bash.exe", "cmd", "cmd.exe", "cscript", "cscript.exe", "del", "erase", "iex",
        "node", "node.exe", "powershell", "powershell.exe", "python", "python.exe", "python3",
        "python3.exe", "pwsh", "pwsh.exe", "kill", "rd", "ri", "rmdir", "rm", "saps",
        "sc", "spps", "spsv", "start", "wscript", "wscript.exe", "wsl", "wsl.exe",
    };

    private static readonly HashSet<string> s_lowRiskCommandNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "Out-Host", "Out-Null", "Out-String", "Write-Debug", "Write-Error", "Write-Host",
        "Write-Information", "Write-Output", "Write-Progress", "Write-Verbose", "Write-Warning",
    };

    private static readonly HashSet<string> s_mediumRiskCommandNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "Pop-Location", "Push-Location", "Set-Location",
    };

    private static readonly Regex s_highRiskNativeCommand = new(
        @"^\s*(?:(?:sudo|chmod|chown|taskkill|shutdown|diskpart|bcdedit|takeown|icacls|msiexec(?:\.exe)?)\b|reg(?:\.exe)?\s+(?:add|delete|import|restore|load|unload)\b|sc(?:\.exe)?\s+(?:config|delete|stop)\b|(?:winget|choco)\s+(?:install|uninstall|upgrade)\b)",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private const string SecretNamePattern =
        "(?:api[-_]?key|subscription[-_]?key|access[-_]?token|refresh[-_]?token|id[-_]?token|session[-_]?token|token|password|passwd|pwd|client[-_]?secret|secret|private[-_]?key|connection[-_]?string|credential|access[-_]?key[-_]?id|secret[-_]?access[-_]?key|x[-_]amz[-_]?(?:signature|credential|security[-_]?token)|x[-_]goog[-_]?(?:signature|credential)|account[-_]?key|sas[-_]?token|signature|sig)";

    private static readonly Regex s_quotedAuthorization = new(
        "(?<prefix>\\b(?:proxy[-_]?authorization|authorization)\\b[\"']?\\s*[:=]\\s*)(?<quote>[\"'])(?:\\\\.|`.|(?:\\k<quote>){2}|(?!\\k<quote>)[^\\\\`\\r\\n])*\\k<quote>",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static readonly Regex s_authorization = new(
        "(?<prefix>\\b(?:proxy[-_]?authorization|authorization)\\b[\"']?\\s*[:=]\\s*)[^\\r\\n;}\"']+",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static readonly Regex s_quotedSecretAssignment = new(
        "(?<prefix>(?<![A-Za-z0-9_])" + SecretNamePattern + "[\"']?\\s*[:=]\\s*)(?<quote>[\"'])(?:\\\\.|`.|(?:\\k<quote>){2}|(?!\\k<quote>)[^\\\\`\\r\\n])*\\k<quote>",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static readonly Regex s_secretAssignment = new(
        "(?<prefix>(?<![A-Za-z0-9_])" + SecretNamePattern + "[\"']?\\s*[:=]\\s*)[^\\s,;}\\]\\[&\"']+",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static readonly Regex s_ansi = new(
        @"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])",
        RegexOptions.CultureInvariant);

    public static AITerminalRisk ClassifyRisk(string toolName, string? command)
    {
        if (!string.Equals(toolName, "powershell", StringComparison.OrdinalIgnoreCase))
        {
            return toolName switch
            {
                "read_file" or "list_directory" or "system_info" => AITerminalRisk.Low,
                "copy_file" or "download_http" or "upload_http" or "upload_s3" => AITerminalRisk.High,
                _ => AITerminalRisk.Medium,
            };
        }

        command ??= string.Empty;
        ScriptBlockAst ast = Parser.ParseInput(command, out _, out ParseError[] parseErrors);
        if (parseErrors.Length > 0 ||
            ast.Find(static node => node is RedirectionAst or ExitStatementAst or InvokeMemberExpressionAst or
                FunctionDefinitionAst or TypeDefinitionAst or AssignmentStatementAst, true) is not null)
        {
            return AITerminalRisk.High;
        }

        bool mediumRisk = false;
        foreach (CommandAst commandAst in ast.FindAll(static node => node is CommandAst, true).Cast<CommandAst>())
        {
            string? commandName = commandAst.GetCommandName();
            if (string.IsNullOrEmpty(commandName))
            {
                return AITerminalRisk.High;
            }

            if (s_standardCommandAliases.TryGetValue(commandName, out string? resolvedName))
            {
                commandName = resolvedName;
            }

            bool forceOverwrite =
                (commandName.Equals("Copy-Item", StringComparison.OrdinalIgnoreCase) ||
                 commandName.Equals("Move-Item", StringComparison.OrdinalIgnoreCase)) &&
                commandAst.CommandElements.Any(static element =>
                    element.Extent.Text.Equals("-Force", StringComparison.OrdinalIgnoreCase));

            if (s_mediumRiskCommandNames.Contains(commandName))
            {
                mediumRisk = true;
                continue;
            }

            if (s_highRiskCommandNames.Contains(commandName) ||
                commandName.StartsWith("Remove-", StringComparison.OrdinalIgnoreCase) ||
                commandName.StartsWith("Clear-", StringComparison.OrdinalIgnoreCase) ||
                commandName.StartsWith("Disable-", StringComparison.OrdinalIgnoreCase) ||
                commandName.StartsWith("Uninstall-", StringComparison.OrdinalIgnoreCase) ||
                commandName.StartsWith("Install-", StringComparison.OrdinalIgnoreCase) ||
                commandName.StartsWith("Invoke-", StringComparison.OrdinalIgnoreCase) ||
                commandName.StartsWith("Set-", StringComparison.OrdinalIgnoreCase) ||
                commandName.StartsWith("New-", StringComparison.OrdinalIgnoreCase) ||
                commandName.StartsWith("Add-", StringComparison.OrdinalIgnoreCase) ||
                commandName.StartsWith("Update-", StringComparison.OrdinalIgnoreCase) ||
                commandName.StartsWith("Move-", StringComparison.OrdinalIgnoreCase) ||
                commandName.StartsWith("Copy-", StringComparison.OrdinalIgnoreCase) ||
                commandName.StartsWith("Rename-", StringComparison.OrdinalIgnoreCase) ||
                (commandName.StartsWith("Write-", StringComparison.OrdinalIgnoreCase) &&
                 !s_lowRiskCommandNames.Contains(commandName)) ||
                commandName.Equals("Copy-Item", StringComparison.OrdinalIgnoreCase) ||
                commandName.Equals("Move-Item", StringComparison.OrdinalIgnoreCase) ||
                commandName.Equals("Export-Csv", StringComparison.OrdinalIgnoreCase) ||
                commandName.Equals("Tee-Object", StringComparison.OrdinalIgnoreCase) ||
                s_highRiskNativeCommand.IsMatch(commandAst.Extent.Text) ||
                forceOverwrite)
            {
                return AITerminalRisk.High;
            }

            bool knownReadOnlyCommand = s_lowRiskCommandNames.Contains(commandName) ||
                commandName.StartsWith("Get-", StringComparison.OrdinalIgnoreCase) ||
                commandName.StartsWith("Test-", StringComparison.OrdinalIgnoreCase) ||
                commandName.StartsWith("Measure-", StringComparison.OrdinalIgnoreCase) ||
                commandName.StartsWith("Select-", StringComparison.OrdinalIgnoreCase) ||
                commandName.StartsWith("Where-", StringComparison.OrdinalIgnoreCase) ||
                commandName.StartsWith("Sort-", StringComparison.OrdinalIgnoreCase) ||
                commandName.StartsWith("Format-", StringComparison.OrdinalIgnoreCase);
            if (!knownReadOnlyCommand)
            {
                return AITerminalRisk.High;
            }
        }

        return mediumRisk ? AITerminalRisk.Medium : AITerminalRisk.Low;
    }

    public static string? ProtectText(string? text, IEnumerable<string>? secrets, int maximumCharacters)
    {
        if (text is null)
        {
            return null;
        }

        AITerminalStreamingTextSanitizer sanitizer = new();
        string result = s_ansi.Replace(sanitizer.Sanitize(text), string.Empty);
        if (secrets is not null)
        {
            foreach (string secret in secrets.Where(static value => !string.IsNullOrEmpty(value)))
            {
                result = result.Replace(secret, "[REDACTED]", StringComparison.Ordinal);
            }
        }

        const string quotedReplacement = "${prefix}${quote}[REDACTED]${quote}";
        const string replacement = "${prefix}[REDACTED]";
        result = s_quotedAuthorization.Replace(result, quotedReplacement);
        result = s_authorization.Replace(result, replacement);
        result = s_quotedSecretAssignment.Replace(result, quotedReplacement);
        result = s_secretAssignment.Replace(result, replacement);

        if (maximumCharacters >= 0 && result.Length > maximumCharacters)
        {
            const string marker = "\n[输出已截断]";
            int keep = Math.Max(0, maximumCharacters - marker.Length);
            if (keep > 0 && keep < result.Length && char.IsHighSurrogate(result[keep - 1]))
            {
                keep--;
            }

            result = result[..keep] + marker;
        }

        return result;
    }

    public static bool IsEndpointAllowed(Uri? endpoint)
    {
        if (endpoint is null || !endpoint.IsAbsoluteUri || !string.IsNullOrEmpty(endpoint.UserInfo))
        {
            return false;
        }

        if (endpoint.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return endpoint.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) && endpoint.IsLoopback;
    }
}

/// <summary>
/// 在保留截断标记空间的前提下按流收集有限文本。
/// </summary>
public sealed class AITerminalBoundedTextCollector
{
    private const string TruncationMarker = "\n[输出已截断]";
    private readonly int _maximumCharacters;
    private readonly StringBuilder _content;
    private bool _truncated;

    public AITerminalBoundedTextCollector(int maximumCharacters)
    {
        if (maximumCharacters < TruncationMarker.Length)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumCharacters));
        }

        _maximumCharacters = maximumCharacters;
        _content = new StringBuilder(Math.Min(maximumCharacters, 8192));
    }

    public void Append(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return;
        }

        if (_truncated)
        {
            return;
        }

        int remaining = _maximumCharacters - _content.Length;
        if (remaining <= 0)
        {
            MarkTruncated();
            return;
        }

        int count = Math.Min(remaining, value.Length);
        if (count > 0 && count < value.Length && char.IsHighSurrogate(value[count - 1]))
        {
            count--;
        }

        _content.Append(value, 0, count);
        if (count < value.Length)
        {
            MarkTruncated();
        }
    }

    public string GetText() => _truncated ? _content.ToString() + TruncationMarker : _content.ToString();

    private void MarkTruncated()
    {
        _truncated = true;
        int contentLimit = _maximumCharacters - TruncationMarker.Length;
        if (_content.Length <= contentLimit)
        {
            return;
        }

        _content.Length = contentLimit;
        if (_content.Length > 0 && char.IsHighSurrogate(_content[_content.Length - 1]))
        {
            _content.Length--;
        }
    }
}

/// <summary>
/// 以固定上限读取 HTTP 内容，避免错误页或模型列表造成无界内存占用。
/// </summary>
public static class AITerminalHttpContent
{
    public static string ReadString(HttpContent content, int maximumCharacters, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(content);
        if (maximumCharacters is < 1 or > 16 * 1024 * 1024)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumCharacters));
        }

        return ReadStringCoreAsync(content, maximumCharacters, cancellationToken).GetAwaiter().GetResult();
    }

    private static async Task<string> ReadStringCoreAsync(
        HttpContent content,
        int maximumCharacters,
        CancellationToken cancellationToken)
    {
        await using Stream stream = await content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using StreamReader reader = new(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true, bufferSize: 8192);
        StringBuilder result = new(Math.Min(maximumCharacters, 8192));
        char[] buffer = new char[8192];
        while (true)
        {
            int read = await reader.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                return result.ToString();
            }

            if (result.Length + read > maximumCharacters)
            {
                throw new InvalidDataException($"HTTP 响应超过 {maximumCharacters} 个字符上限。");
            }

            result.Append(buffer, 0, read);
        }
    }
}

public static class AITerminalAtomicFile
{
    private const int DefaultLockTimeoutMilliseconds = 10000;

    public static void WriteAllText(string path, string content)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        string fullPath = Path.GetFullPath(path);
        string directory = Path.GetDirectoryName(fullPath)!;
        EnsurePrivateDirectory(directory);
        string temporaryPath = Path.Combine(directory, $".{Path.GetFileName(path)}-{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporaryPath, content, new UTF8Encoding(false));
            EnsurePrivateFile(temporaryPath);
            File.Move(temporaryPath, fullPath, overwrite: true);
            EnsurePrivateFile(fullPath);
        }
        finally
        {
            File.Delete(temporaryPath);
        }
    }

    public static IDisposable AcquireLock(string path, int timeoutMilliseconds = DefaultLockTimeoutMilliseconds)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        if (timeoutMilliseconds is < 1 or > 60000)
        {
            throw new ArgumentOutOfRangeException(nameof(timeoutMilliseconds));
        }

        string fullPath = Path.GetFullPath(path);
        string directory = Path.GetDirectoryName(fullPath)!;
        EnsurePrivateDirectory(directory);
        string lockPath = fullPath + ".lock";
        Stopwatch stopwatch = Stopwatch.StartNew();
        while (true)
        {
            try
            {
                FileStream stream = new(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                EnsurePrivateFile(lockPath);
                return stream;
            }
            catch (IOException exception)
            {
                if (stopwatch.ElapsedMilliseconds >= timeoutMilliseconds)
                {
                    throw new TimeoutException($"等待文件锁超时：{fullPath}", exception);
                }

                Thread.Sleep(25);
            }
        }
    }

    public static void EnsurePrivateDirectory(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        string fullPath = Path.GetFullPath(path);
        Directory.CreateDirectory(fullPath);
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(fullPath, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
    }

    public static void EnsurePrivateFile(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        string fullPath = Path.GetFullPath(path);
        if (!OperatingSystem.IsWindows() && File.Exists(fullPath))
        {
            File.SetUnixFileMode(fullPath, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
    }
}

public static class PlatformCredentialStore
{
    public static string BackendName => OperatingSystem.IsWindows()
        ? "Windows Credential Manager"
        : OperatingSystem.IsMacOS()
            ? "macOS Keychain"
            : OperatingSystem.IsLinux()
                ? "Linux Secret Service"
                : "不可用";

    public static bool IsAvailable => (OperatingSystem.IsWindows() && WindowsCredentialStore.IsAvailable) ||
        (OperatingSystem.IsMacOS() && MacOSKeychainStore.IsAvailable) ||
        (OperatingSystem.IsLinux() && LinuxSecretServiceStore.IsAvailable);

    public static void Set(string target, string secret)
    {
        if (OperatingSystem.IsWindows())
        {
            WindowsCredentialStore.Set(target, secret);
        }
        else if (OperatingSystem.IsMacOS())
        {
            MacOSKeychainStore.Set(target, secret);
        }
        else if (OperatingSystem.IsLinux())
        {
            LinuxSecretServiceStore.Set(target, secret);
        }
        else
        {
            throw new PlatformNotSupportedException("当前操作系统没有可用的 PSAITerminal 密钥库实现。");
        }
    }

    public static string? Get(string target)
    {
        if (OperatingSystem.IsWindows())
        {
            return WindowsCredentialStore.IsAvailable ? WindowsCredentialStore.Get(target) : null;
        }

        if (OperatingSystem.IsMacOS())
        {
            return MacOSKeychainStore.IsAvailable ? MacOSKeychainStore.Get(target) : null;
        }

        return OperatingSystem.IsLinux() && LinuxSecretServiceStore.IsAvailable
            ? LinuxSecretServiceStore.Get(target)
            : null;
    }

    public static void Remove(string target)
    {
        if (OperatingSystem.IsWindows() && WindowsCredentialStore.IsAvailable)
        {
            WindowsCredentialStore.Remove(target);
        }
        else if (OperatingSystem.IsMacOS() && MacOSKeychainStore.IsAvailable)
        {
            MacOSKeychainStore.Remove(target);
        }
        else if (OperatingSystem.IsLinux() && LinuxSecretServiceStore.IsAvailable)
        {
            LinuxSecretServiceStore.Remove(target);
        }
    }
}

internal static class LinuxSecretServiceStore
{
    private const int TimeoutMilliseconds = 15000;

    internal static bool IsAvailable => FindSecretTool() is not null;

    internal static void Set(string target, string secret)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(target);
        ArgumentNullException.ThrowIfNull(secret);
        string tool = FindSecretTool() ?? throw new PlatformNotSupportedException(
            "Linux Secret Service 不可用。请安装 libsecret-tools 并启动桌面密钥环，或使用 -SessionOnly。"
        );
        ProcessResult result = Run(tool,
            ["store", "--label=PSAITerminal", "application", "PSAITerminal", "target", target],
            secret);
        ThrowOnFailure(result, "保存 Linux Secret Service 密钥");
    }

    internal static string? Get(string target)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(target);
        string? tool = FindSecretTool();
        if (tool is null)
        {
            return null;
        }

        ProcessResult result = Run(tool,
            ["lookup", "application", "PSAITerminal", "target", target],
            null);
        if (result.ExitCode != 0 && string.IsNullOrWhiteSpace(result.Error))
        {
            return null;
        }

        ThrowOnFailure(result, "读取 Linux Secret Service 密钥");
        return result.Output.TrimEnd('\r', '\n');
    }

    internal static void Remove(string target)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(target);
        string? tool = FindSecretTool();
        if (tool is null)
        {
            return;
        }

        ProcessResult result = Run(tool,
            ["clear", "application", "PSAITerminal", "target", target],
            null);
        if (result.ExitCode != 0 && string.IsNullOrWhiteSpace(result.Error))
        {
            return;
        }

        ThrowOnFailure(result, "删除 Linux Secret Service 密钥");
    }

    private static string? FindSecretTool()
    {
        string executable = "secret-tool";
        string? path = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrWhiteSpace(path))
        {
            return null;
        }

        foreach (string directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                string candidate = Path.Combine(directory.Trim(), executable);
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
            catch (Exception exception) when (exception is ArgumentException or NotSupportedException)
            {
            }
        }

        return null;
    }

    private static ProcessResult Run(string executable, IReadOnlyList<string> arguments, string? standardInput)
    {
        ProcessStartInfo startInfo = new(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
        };
        foreach (string argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using Process process = new() { StartInfo = startInfo };
        try
        {
            process.Start();
        }
        catch (Exception exception) when (exception is Win32Exception or InvalidOperationException)
        {
            throw new PlatformNotSupportedException("无法启动 secret-tool。请安装 libsecret-tools，或使用 -SessionOnly。", exception);
        }

        Task<string> outputTask = process.StandardOutput.ReadToEndAsync();
        Task<string> errorTask = process.StandardError.ReadToEndAsync();
        if (standardInput is not null)
        {
            process.StandardInput.Write(standardInput);
        }

        process.StandardInput.Close();
        if (!process.WaitForExit(TimeoutMilliseconds))
        {
            try { process.Kill(entireProcessTree: true); } catch { }
            throw new TimeoutException("Linux Secret Service 操作在 15 秒内没有完成。");
        }

        Task.WaitAll(outputTask, errorTask);
        return new ProcessResult(process.ExitCode, outputTask.Result, errorTask.Result);
    }

    private static void ThrowOnFailure(ProcessResult result, string operation)
    {
        if (result.ExitCode == 0)
        {
            return;
        }

        string detail = result.Error.Trim();
        if (detail.Length > 2048)
        {
            detail = detail[..2048];
        }

        throw new InvalidOperationException(string.IsNullOrEmpty(detail)
            ? $"{operation}失败，secret-tool 退出码：{result.ExitCode}。"
            : $"{operation}失败：{detail}");
    }

    private readonly record struct ProcessResult(int ExitCode, string Output, string Error);
}

internal static class MacOSKeychainStore
{
    private const string SecurityFramework = "/System/Library/Frameworks/Security.framework/Security";
    private const string CoreFoundationFramework = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";
    private const int Success = 0;
    private const int ItemNotFound = -25300;
    private static readonly byte[] s_service = Encoding.UTF8.GetBytes("PSAITerminal");

    internal static bool IsAvailable
    {
        get
        {
            byte[] account = Encoding.UTF8.GetBytes("PSAITerminal/AvailabilityProbe");
            IntPtr passwordData = IntPtr.Zero;
            IntPtr item = IntPtr.Zero;
            try
            {
                int status = SecKeychainFindGenericPassword(IntPtr.Zero,
                    (uint)s_service.Length, s_service, (uint)account.Length, account,
                    out _, out passwordData, out item);
                return status is Success or ItemNotFound;
            }
            catch (DllNotFoundException)
            {
                return false;
            }
            finally
            {
                if (passwordData != IntPtr.Zero) { SecKeychainItemFreeContent(IntPtr.Zero, passwordData); }
                if (item != IntPtr.Zero) { CFRelease(item); }
                Array.Clear(account);
            }
        }
    }

    internal static void Set(string target, string secret)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(target);
        ArgumentNullException.ThrowIfNull(secret);
        byte[] account = Encoding.UTF8.GetBytes(target);
        byte[] password = Encoding.UTF8.GetBytes(secret);
        IntPtr passwordData = IntPtr.Zero;
        IntPtr item = IntPtr.Zero;
        try
        {
            int status = SecKeychainFindGenericPassword(IntPtr.Zero,
                (uint)s_service.Length, s_service, (uint)account.Length, account,
                out _, out passwordData, out item);
            if (status == Success)
            {
                if (passwordData != IntPtr.Zero)
                {
                    SecKeychainItemFreeContent(IntPtr.Zero, passwordData);
                    passwordData = IntPtr.Zero;
                }

                ThrowOnFailure(SecKeychainItemModifyAttributesAndData(item, IntPtr.Zero,
                    (uint)password.Length, password), "更新 macOS Keychain 密钥");
                return;
            }

            if (status != ItemNotFound)
            {
                ThrowOnFailure(status, "查找 macOS Keychain 密钥");
            }

            ThrowOnFailure(SecKeychainAddGenericPassword(IntPtr.Zero,
                (uint)s_service.Length, s_service, (uint)account.Length, account,
                (uint)password.Length, password, out item), "保存 macOS Keychain 密钥");
        }
        finally
        {
            if (passwordData != IntPtr.Zero) { SecKeychainItemFreeContent(IntPtr.Zero, passwordData); }
            if (item != IntPtr.Zero) { CFRelease(item); }
            Array.Clear(account);
            Array.Clear(password);
        }
    }

    internal static string? Get(string target)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(target);
        byte[] account = Encoding.UTF8.GetBytes(target);
        IntPtr passwordData = IntPtr.Zero;
        IntPtr item = IntPtr.Zero;
        try
        {
            int status = SecKeychainFindGenericPassword(IntPtr.Zero,
                (uint)s_service.Length, s_service, (uint)account.Length, account,
                out uint passwordLength, out passwordData, out item);
            if (status == ItemNotFound) { return null; }
            ThrowOnFailure(status, "读取 macOS Keychain 密钥");
            byte[] password = new byte[passwordLength];
            try
            {
                Marshal.Copy(passwordData, password, 0, password.Length);
                return Encoding.UTF8.GetString(password);
            }
            finally
            {
                Array.Clear(password);
            }
        }
        finally
        {
            if (passwordData != IntPtr.Zero) { SecKeychainItemFreeContent(IntPtr.Zero, passwordData); }
            if (item != IntPtr.Zero) { CFRelease(item); }
            Array.Clear(account);
        }
    }

    internal static void Remove(string target)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(target);
        byte[] account = Encoding.UTF8.GetBytes(target);
        IntPtr passwordData = IntPtr.Zero;
        IntPtr item = IntPtr.Zero;
        try
        {
            int status = SecKeychainFindGenericPassword(IntPtr.Zero,
                (uint)s_service.Length, s_service, (uint)account.Length, account,
                out _, out passwordData, out item);
            if (status == ItemNotFound) { return; }
            ThrowOnFailure(status, "查找 macOS Keychain 密钥");
            if (passwordData != IntPtr.Zero)
            {
                SecKeychainItemFreeContent(IntPtr.Zero, passwordData);
                passwordData = IntPtr.Zero;
            }

            ThrowOnFailure(SecKeychainItemDelete(item), "删除 macOS Keychain 密钥");
        }
        finally
        {
            if (passwordData != IntPtr.Zero) { SecKeychainItemFreeContent(IntPtr.Zero, passwordData); }
            if (item != IntPtr.Zero) { CFRelease(item); }
            Array.Clear(account);
        }
    }

    private static void ThrowOnFailure(int status, string operation)
    {
        if (status != Success)
        {
            throw new InvalidOperationException($"{operation}失败，OSStatus：{status}。");
        }
    }

    [DllImport(SecurityFramework)]
    private static extern int SecKeychainAddGenericPassword(IntPtr keychain,
        uint serviceNameLength, byte[] serviceName, uint accountNameLength, byte[] accountName,
        uint passwordLength, byte[] passwordData, out IntPtr itemRef);

    [DllImport(SecurityFramework)]
    private static extern int SecKeychainFindGenericPassword(IntPtr keychainOrArray,
        uint serviceNameLength, byte[] serviceName, uint accountNameLength, byte[] accountName,
        out uint passwordLength, out IntPtr passwordData, out IntPtr itemRef);

    [DllImport(SecurityFramework)]
    private static extern int SecKeychainItemModifyAttributesAndData(IntPtr itemRef,
        IntPtr attributes, uint length, byte[] data);

    [DllImport(SecurityFramework)]
    private static extern int SecKeychainItemDelete(IntPtr itemRef);

    [DllImport(SecurityFramework)]
    private static extern int SecKeychainItemFreeContent(IntPtr attributes, IntPtr data);

    [DllImport(CoreFoundationFramework)]
    private static extern void CFRelease(IntPtr value);
}

public static class WindowsCredentialStore
{
    private const uint GenericCredential = 1;
    private const uint PersistLocalMachine = 2;
    private const int ErrorNotFound = 1168;

    public static bool IsAvailable
    {
        get
        {
            if (!OperatingSystem.IsWindows()) { return false; }
            try
            {
                _ = Get("PSAITerminal/AvailabilityProbe");
                return true;
            }
            catch (Win32Exception)
            {
                return false;
            }
        }
    }

    public static void Set(string target, string secret)
    {
        EnsureWindows();
        ArgumentException.ThrowIfNullOrWhiteSpace(target);
        ArgumentNullException.ThrowIfNull(secret);

        byte[] bytes = Encoding.Unicode.GetBytes(secret);
        IntPtr blob = Marshal.AllocCoTaskMem(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            NativeCredential credential = new()
            {
                Type = GenericCredential,
                TargetName = target,
                CredentialBlob = blob,
                CredentialBlobSize = (uint)bytes.Length,
                Persist = PersistLocalMachine,
                UserName = Environment.UserName,
            };

            if (!CredWrite(ref credential, 0))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
        finally
        {
            Array.Clear(bytes);
            for (int index = 0; index < bytes.Length; index++)
            {
                Marshal.WriteByte(blob, index, 0);
            }

            Marshal.FreeCoTaskMem(blob);
        }
    }

    public static string? Get(string target)
    {
        EnsureWindows();
        ArgumentException.ThrowIfNullOrWhiteSpace(target);
        if (!CredRead(target, GenericCredential, 0, out IntPtr pointer))
        {
            int error = Marshal.GetLastWin32Error();
            if (error == ErrorNotFound)
            {
                return null;
            }

            throw new Win32Exception(error);
        }

        try
        {
            NativeCredential credential = Marshal.PtrToStructure<NativeCredential>(pointer);
            return Marshal.PtrToStringUni(credential.CredentialBlob, (int)credential.CredentialBlobSize / 2);
        }
        finally
        {
            CredFree(pointer);
        }
    }

    public static void Remove(string target)
    {
        EnsureWindows();
        ArgumentException.ThrowIfNullOrWhiteSpace(target);
        if (CredDelete(target, GenericCredential, 0))
        {
            return;
        }

        int error = Marshal.GetLastWin32Error();
        if (error != ErrorNotFound)
        {
            throw new Win32Exception(error);
        }
    }

    private static void EnsureWindows()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("WindowsCredentialStore 仅能在 Windows 上使用。");
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NativeCredential
    {
        internal uint Flags;
        internal uint Type;
        internal string? TargetName;
        internal string? Comment;
        internal System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        internal uint CredentialBlobSize;
        internal IntPtr CredentialBlob;
        internal uint Persist;
        internal uint AttributeCount;
        internal IntPtr Attributes;
        internal string? TargetAlias;
        internal string? UserName;
    }

    [DllImport("advapi32", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref NativeCredential credential, uint flags);

    [DllImport("advapi32", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, uint type, uint flags);

    [DllImport("advapi32")]
    private static extern void CredFree(IntPtr credential);
}
