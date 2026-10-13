using System.ComponentModel;
using System.Diagnostics;
using System.Management.Automation.Language;
using System.Runtime.InteropServices;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.RegularExpressions;

namespace PSAITerminal;

internal static class AITerminalPlatform
{
    internal static bool IsWindows => RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
}

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

        string nonEmptyValue = value!;
        StringBuilder result = new(nonEmptyValue.Length);
        foreach (char character in nonEmptyValue)
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

    public static Uri ResolveModelListEndpoint(string protocol, Uri endpoint) =>
        ResolveResource(protocol, endpoint, "models");

    public static Uri ResolveRequestEndpoint(string protocol, Uri endpoint) =>
        ResolveResource(protocol, endpoint, ParseProtocol(protocol) == AIProtocol.Anthropic ? "messages" : "chat/completions");

    private static Uri ResolveResource(string protocol, Uri endpoint, string resource)
    {
        Uri normalized = NormalizeBaseEndpoint(protocol, endpoint);
        UriBuilder builder = new(normalized);
        builder.Path = AppendPath(EnsureVersionSegment(builder.Path.TrimEnd('/')), resource);
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
        if (endpoint is null)
        {
            throw new ArgumentNullException(nameof(endpoint));
        }
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
        string resource = protocol == AIProtocol.Anthropic ? "/messages" : "/chat/completions";
        return normalized.EndsWith(resource, StringComparison.OrdinalIgnoreCase) ||
            normalized.EndsWith("/models", StringComparison.OrdinalIgnoreCase);
    }

    // 基础地址已包含版本段（/v1、/v1beta/openai、/api/v3 等）时原样使用，否则补 /v1。
    private static string EnsureVersionSegment(string path) =>
        Regex.IsMatch(path, @"(?:^|/)v\d+[a-z0-9]*(?:/|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)
            ? path
            : AppendPath(path, "v1");

    private static string AppendPath(string path, string suffix)
    {
        string left = path.TrimEnd('/');
        string right = suffix.Trim('/');
        return string.IsNullOrEmpty(left) ? "/" + right : left + "/" + right;
    }

}

public static class AITerminalSecurity
{
    private static readonly Dictionary<string, string> s_standardCommandAliases = new(StringComparer.OrdinalIgnoreCase)
    {
        ["ac"] = "Add-Content",
        ["cat"] = "Get-Content",
        ["cd"] = "Set-Location",
        ["chdir"] = "Set-Location",
        ["clc"] = "Clear-Content",
        ["cli"] = "Clear-Item",
        ["clp"] = "Clear-ItemProperty",
        ["cls"] = "Clear-Host",
        ["copy"] = "Copy-Item",
        ["cp"] = "Copy-Item",
        ["cpi"] = "Copy-Item",
        ["dir"] = "Get-ChildItem",
        ["echo"] = "Write-Output",
        ["epcsv"] = "Export-Csv",
        ["fl"] = "Format-List",
        ["foreach"] = "ForEach-Object",
        ["ft"] = "Format-Table",
        ["gc"] = "Get-Content",
        ["gci"] = "Get-ChildItem",
        ["gl"] = "Get-Location",
        ["gm"] = "Get-Member",
        ["gps"] = "Get-Process",
        ["group"] = "Group-Object",
        ["gsv"] = "Get-Service",
        ["iex"] = "Invoke-Expression",
        ["irm"] = "Invoke-RestMethod",
        ["iwr"] = "Invoke-WebRequest",
        ["kill"] = "Stop-Process",
        ["ls"] = "Get-ChildItem",
        ["measure"] = "Measure-Object",
        ["mi"] = "Move-Item",
        ["mkdir"] = "New-Item",
        ["move"] = "Move-Item",
        ["mv"] = "Move-Item",
        ["ni"] = "New-Item",
        ["popd"] = "Pop-Location",
        ["ps"] = "Get-Process",
        ["pushd"] = "Push-Location",
        ["pwd"] = "Get-Location",
        ["rd"] = "Remove-Item",
        ["del"] = "Remove-Item",
        ["erase"] = "Remove-Item",
        ["ren"] = "Rename-Item",
        ["ri"] = "Remove-Item",
        ["rm"] = "Remove-Item",
        ["rmdir"] = "Remove-Item",
        ["rni"] = "Rename-Item",
        ["sajb"] = "Start-Job",
        ["saps"] = "Start-Process",
        ["sc"] = "Set-Content",
        ["select"] = "Select-Object",
        ["set"] = "Set-Variable",
        ["si"] = "Set-Item",
        ["sl"] = "Set-Location",
        ["sort"] = "Sort-Object",
        ["sp"] = "Set-ItemProperty",
        ["spps"] = "Stop-Process",
        ["spsv"] = "Stop-Service",
        ["start"] = "Start-Process",
        ["sv"] = "Set-Variable",
        ["tee"] = "Tee-Object",
        ["type"] = "Get-Content",
        ["where"] = "Where-Object",
        ["%"] = "ForEach-Object",
        ["?"] = "Where-Object",
    };

    // 不可逆、提权或执行任意代码的命令：总是需要人工确认，不能被自动允许。
    private static readonly string[] s_highRiskPrefixes =
    {
        "Remove-", "Clear-", "Stop-", "Restart-", "Uninstall-", "Disable-", "Reset-", "Dismount-", "Unregister-",
    };

    private static readonly HashSet<string> s_highRiskCommandNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "Format-Volume", "Initialize-Disk", "Invoke-Expression", "Set-ExecutionPolicy", "Set-Acl",
        "Invoke-Command", "Enter-PSSession", "Add-LocalGroupMember", "Set-LocalUser", "Set-Service",
        "bash", "bcdedit", "cipher", "cmd", "cscript", "diskpart", "format", "icacls", "mshta", "powershell",
        "pwsh", "regsvr32", "rundll32", "runas", "shutdown", "sudo", "takeown", "taskkill", "vssadmin", "wmic",
        "wscript", "wsl",
    };

    // 不改变系统状态的查询与展示命令。
    private static readonly string[] s_lowRiskPrefixes =
    {
        "Get-", "Test-", "Measure-", "Select-", "Where-", "Sort-", "Format-", "Group-", "Compare-", "Resolve-",
        "ConvertTo-", "ConvertFrom-", "Find-",
    };

    private static readonly HashSet<string> s_lowRiskCommandNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "ForEach-Object", "Out-Host", "Out-Null", "Out-String", "Write-Debug", "Write-Error", "Write-Host",
        "Write-Information", "Write-Output", "Write-Progress", "Write-Verbose", "Write-Warning", "Clear-Host",
        "Set-Location", "Push-Location", "Pop-Location",
        "hostname", "ipconfig", "netstat", "nslookup", "ping", "systeminfo", "tasklist", "tracert", "whoami",
        "where", "ver",
    };

    private static readonly Regex s_highRiskNativeArguments = new(
        @"^\s*(?:reg\s+(?:add|delete|import|restore|load|unload)\b|sc\s+(?:config|delete|stop)\b|(?:winget|choco)\s+(?:install|uninstall|upgrade)\b|git\s+(?:clean\b|reset\s+.*--hard\b|push\s+.*(?:--force\b|-f\b)|branch\s+.*-D\b))",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static readonly Regex s_lowRiskGit = new(
        @"^\s*git\s+(?:status|log|diff|show|branch)(?:\s+(?!.*(?:-d\b|-D\b|-m\b|-M\b|--delete\b|--move\b)).*)?$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static readonly HashSet<string> s_destructiveMemberNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "Delete", "Kill", "Format", "Shutdown", "DeleteSubKey", "DeleteSubKeyTree", "DeleteValue",
    };

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

    /// <summary>
    /// 只按命令文本静态分级；当前会话中的别名与函数重绑定由模块侧解析后再次调用本方法。
    /// </summary>
    public static AITerminalRisk ClassifyRisk(string? command)
    {
        command ??= string.Empty;
        ScriptBlockAst ast = Parser.ParseInput(command, out _, out ParseError[] parseErrors);
        if (parseErrors.Length > 0 ||
            ast.Find(static node => node is ExitStatementAst, true) is not null ||
            ast.Find(static node => node is InvokeMemberExpressionAst member &&
                member.Member is StringConstantExpressionAst name &&
                s_destructiveMemberNames.Contains(name.Value), true) is not null)
        {
            return AITerminalRisk.High;
        }

        AITerminalRisk risk = AITerminalRisk.Low;
        if (ast.Find(static node =>
                node is FileRedirectionAst or AssignmentStatementAst or InvokeMemberExpressionAst or
                FunctionDefinitionAst or TypeDefinitionAst, true) is not null)
        {
            risk = AITerminalRisk.Medium;
        }

        foreach (CommandAst commandAst in ast.FindAll(static node => node is CommandAst, true).Cast<CommandAst>())
        {
            AITerminalRisk commandRisk = ClassifyCommand(commandAst);
            if (commandRisk > risk)
            {
                risk = commandRisk;
            }

            if (risk == AITerminalRisk.High)
            {
                return risk;
            }
        }

        return risk;
    }

    private static AITerminalRisk ClassifyCommand(CommandAst commandAst)
    {
        string? rawName = commandAst.GetCommandName();
        if (string.IsNullOrEmpty(rawName))
        {
            // & $value、. (expression) 等动态调用无法静态确认目标。
            return AITerminalRisk.High;
        }

        string name = rawName!;
        if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
        {
            name = name.Substring(0, name.Length - 4);
        }

        if (s_standardCommandAliases.TryGetValue(name, out string? resolvedName))
        {
            name = resolvedName;
        }

        string text = commandAst.Extent.Text;
        bool hasForce = commandAst.CommandElements.Any(static element =>
            element is CommandParameterAst parameter &&
            parameter.ParameterName.Equals("Force", StringComparison.OrdinalIgnoreCase));
        bool runAs = commandAst.CommandElements.Any(static element =>
            element.Extent.Text.Equals("RunAs", StringComparison.OrdinalIgnoreCase) ||
            element.Extent.Text.Equals("'RunAs'", StringComparison.OrdinalIgnoreCase) ||
            element.Extent.Text.Equals("\"RunAs\"", StringComparison.OrdinalIgnoreCase));

        if (s_highRiskCommandNames.Contains(name) ||
            s_highRiskNativeArguments.IsMatch(text) ||
            (hasForce && (name.Equals("Copy-Item", StringComparison.OrdinalIgnoreCase) ||
                name.Equals("Move-Item", StringComparison.OrdinalIgnoreCase))) ||
            (runAs && name.Equals("Start-Process", StringComparison.OrdinalIgnoreCase)))
        {
            return AITerminalRisk.High;
        }

        if (s_lowRiskCommandNames.Contains(name) || s_lowRiskGit.IsMatch(text))
        {
            return AITerminalRisk.Low;
        }

        if (s_highRiskPrefixes.Any(prefix => name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)))
        {
            return AITerminalRisk.High;
        }

        return s_lowRiskPrefixes.Any(prefix => name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            ? AITerminalRisk.Low
            : AITerminalRisk.Medium;
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
                result = result.Replace(secret, "[REDACTED]");
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

            result = result.Substring(0, keep) + marker;
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

        string nonEmptyValue = value!;
        int count = Math.Min(remaining, nonEmptyValue.Length);
        if (count > 0 && count < nonEmptyValue.Length && char.IsHighSurrogate(nonEmptyValue[count - 1]))
        {
            count--;
        }

        _content.Append(nonEmptyValue, 0, count);
        if (count < nonEmptyValue.Length)
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
/// 通过 PowerShell 5.1 与 PowerShell 7 共同具备的异步 API 发送 HTTP 请求。
/// </summary>
public static class AITerminalHttpTransport
{
    public static HttpResponseMessage Send(
        HttpClient client,
        HttpRequestMessage request,
        HttpCompletionOption completionOption,
        CancellationToken cancellationToken)
    {
        if (client is null)
        {
            throw new ArgumentNullException(nameof(client));
        }
        if (request is null)
        {
            throw new ArgumentNullException(nameof(request));
        }

        return client.SendAsync(request, completionOption, cancellationToken).GetAwaiter().GetResult();
    }
}

/// <summary>
/// 以固定上限读取 HTTP 内容，并提供两个 PowerShell 宿主共用的可取消流读取。
/// </summary>
public static class AITerminalHttpContent
{
    private const int MaximumLineCharacters = 1024 * 1024;
    private static readonly ConditionalWeakTable<StreamReader, LineState> s_lineStates = new();

    private sealed class LineState
    {
        internal readonly char[] Buffer = new char[8192];
        internal int Offset;
        internal int Count;
        internal bool SkipLineFeed;
        internal int Reading;
    }

    public static string ReadString(HttpContent content, int maximumCharacters, CancellationToken cancellationToken)
    {
        if (content is null)
        {
            throw new ArgumentNullException(nameof(content));
        }
        if (maximumCharacters is < 1 or > 16 * 1024 * 1024)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumCharacters));
        }

        return ReadStringCoreAsync(content, maximumCharacters, cancellationToken).GetAwaiter().GetResult();
    }

    public static string? ReadLine(StreamReader reader, CancellationToken cancellationToken)
    {
        if (reader is null)
        {
            throw new ArgumentNullException(nameof(reader));
        }

        cancellationToken.ThrowIfCancellationRequested();
        return ReadLineCoreAsync(reader, cancellationToken).GetAwaiter().GetResult();
    }

    private static async Task<string?> ReadLineCoreAsync(StreamReader reader, CancellationToken cancellationToken)
    {
        LineState state = s_lineStates.GetValue(reader, static _ => new LineState());
        if (Interlocked.Exchange(ref state.Reading, 1) != 0)
        {
            throw new InvalidOperationException("同一流读取器不能并发读取行。");
        }

        try
        {
            StringBuilder result = new();
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (state.Offset == state.Count)
                {
                    state.Count = await WaitWithCancellationAsync(
                        reader.ReadAsync(state.Buffer, 0, state.Buffer.Length), cancellationToken).ConfigureAwait(false);
                    state.Offset = 0;
                    if (state.Count == 0)
                    {
                        s_lineStates.Remove(reader);
                        return result.Length == 0 ? null : result.ToString();
                    }
                }

                char character = state.Buffer[state.Offset++];
                if (state.SkipLineFeed)
                {
                    state.SkipLineFeed = false;
                    if (character == '\n') { continue; }
                }
                if (character is '\r' or '\n')
                {
                    state.SkipLineFeed = character == '\r';
                    return result.ToString();
                }
                if (result.Length >= MaximumLineCharacters)
                {
                    throw new InvalidDataException("模型流式响应的单行数据超过 1 MiB 字符上限。");
                }
                result.Append(character);
            }
        }
        catch
        {
            s_lineStates.Remove(reader);
            throw;
        }
        finally
        {
            Volatile.Write(ref state.Reading, 0);
        }
    }

    public static Stream ReadStream(HttpContent content, CancellationToken cancellationToken)
    {
        if (content is null)
        {
            throw new ArgumentNullException(nameof(content));
        }

        cancellationToken.ThrowIfCancellationRequested();
        return WaitWithCancellationAsync(content.ReadAsStreamAsync(), cancellationToken).GetAwaiter().GetResult();
    }

    private static async Task<T> WaitWithCancellationAsync<T>(Task<T> task, CancellationToken cancellationToken)
    {
        if (!cancellationToken.CanBeCanceled)
        {
            return await task.ConfigureAwait(false);
        }

        TaskCompletionSource<bool> cancellationSource = new(TaskCreationOptions.RunContinuationsAsynchronously);
        using CancellationTokenRegistration registration = cancellationToken.Register(
            static state => ((TaskCompletionSource<bool>)state!).TrySetResult(true),
            cancellationSource);
        Task completedTask = await Task.WhenAny(task, cancellationSource.Task).ConfigureAwait(false);
        if (!ReferenceEquals(completedTask, task))
        {
            ObserveAbandonedTask(task);
            cancellationToken.ThrowIfCancellationRequested();
        }

        return await task.ConfigureAwait(false);
    }

    private static void ObserveAbandonedTask<T>(Task<T> task)
    {
        _ = task.ContinueWith(
            static completedTask =>
            {
                if (completedTask.Status == TaskStatus.RanToCompletion && completedTask.Result is IDisposable disposable)
                {
                    disposable.Dispose();
                }
                else if (completedTask.IsFaulted)
                {
                    _ = completedTask.Exception;
                }
            },
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    private static async Task<string> ReadStringCoreAsync(
        HttpContent content,
        int maximumCharacters,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using Stream stream = await WaitWithCancellationAsync(
            content.ReadAsStreamAsync(),
            cancellationToken).ConfigureAwait(false);
        using StreamReader reader = new(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true, bufferSize: 8192);
        StringBuilder result = new(Math.Min(maximumCharacters, 8192));
        char[] buffer = new char[8192];
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            int read = await WaitWithCancellationAsync(
                reader.ReadAsync(buffer, 0, buffer.Length),
                cancellationToken).ConfigureAwait(false);
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
        if (string.IsNullOrEmpty(path))
        {
            throw new ArgumentException("路径不能为空。", nameof(path));
        }
        string fullPath = Path.GetFullPath(path);
        string directory = Path.GetDirectoryName(fullPath)!;
        EnsurePrivateDirectory(directory);
        string temporaryPath = Path.Combine(directory, $".{Path.GetFileName(path)}-{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporaryPath, content, new UTF8Encoding(false));
            EnsurePrivateFile(temporaryPath);
            if (File.Exists(fullPath))
            {
                File.Replace(temporaryPath, fullPath, null);
            }
            else
            {
                File.Move(temporaryPath, fullPath);
            }
            EnsurePrivateFile(fullPath);
        }
        finally
        {
            File.Delete(temporaryPath);
        }
    }

    public static IDisposable AcquireLock(string path, int timeoutMilliseconds = DefaultLockTimeoutMilliseconds)
    {
        if (string.IsNullOrEmpty(path))
        {
            throw new ArgumentException("路径不能为空。", nameof(path));
        }
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
                try { EnsurePrivateFile(lockPath); }
                catch { stream.Dispose(); throw; }
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

    private const uint SddlRevision1 = 1;
    private const uint DaclSecurityInformation = 0x00000004;
    private const uint ProtectedDaclSecurityInformation = 0x80000000;
    private const string PrivateDirectorySddl = "D:P(A;OICI;FA;;;OW)(A;OICI;FA;;;BA)";
    private const string PrivateFileSddl = "D:P(A;;FA;;;OW)(A;;FA;;;BA)";

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(
        string StringSecurityDescriptor,
        uint StringSDRevision,
        out IntPtr SecurityDescriptor,
        out uint SecurityDescriptorSize);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool SetFileSecurityW(
        string lpFileName,
        uint SecurityInformation,
        IntPtr pSecurityDescriptor);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr hMem);

    public static void EnsurePrivateDirectory(string path)
    {
        if (string.IsNullOrEmpty(path))
        {
            throw new ArgumentException("路径不能为空。", nameof(path));
        }
        string fullPath = Path.GetFullPath(path);
        Directory.CreateDirectory(fullPath);
        if (!AITerminalPlatform.IsWindows)
        {
            throw new PlatformNotSupportedException("PSAITerminal 1.0.0 仅支持 Windows。");
        }
        ApplyPrivateSecurity(fullPath, PrivateDirectorySddl);
    }

    public static void EnsurePrivateFile(string path)
    {
        if (string.IsNullOrEmpty(path))
        {
            throw new ArgumentException("路径不能为空。", nameof(path));
        }
        string fullPath = Path.GetFullPath(path);
        if (!AITerminalPlatform.IsWindows)
        {
            throw new PlatformNotSupportedException("PSAITerminal 1.0.0 仅支持 Windows。");
        }
        if (File.Exists(fullPath))
        {
            ApplyPrivateSecurity(fullPath, PrivateFileSddl);
        }
    }

    private static void ApplyPrivateSecurity(string fullPath, string sddl)
    {
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SddlRevision1, out IntPtr pSecurityDescriptor, out _))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), $"无法创建私有访问控制描述符：{fullPath}");
        }

        try
        {
            if (!SetFileSecurityW(
                fullPath,
                DaclSecurityInformation | ProtectedDaclSecurityInformation,
                pSecurityDescriptor))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), $"无法设置私有访问控制：{fullPath}");
            }
        }
        finally
        {
            LocalFree(pSecurityDescriptor);
        }
    }
}

/// <summary>
/// 把文本作为按键写入控制台输入缓冲区，使下一次 PSReadLine 读取时显示为已输入、可编辑的内容。
/// </summary>
public static class AITerminalConsoleInput
{
    private const int StandardInputHandle = -10;
    private const ushort KeyEventType = 0x0001;
    private const ushort VirtualKeyReturn = 0x0D;
    private const uint ShiftPressed = 0x0010;

    public static bool TryWrite(string? text)
    {
        if (!AITerminalPlatform.IsWindows || string.IsNullOrEmpty(text))
        {
            return false;
        }

        IntPtr handle = GetStdHandle(StandardInputHandle);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1))
        {
            return false;
        }

        List<InputRecord> records = new();
        foreach (char raw in text!.Replace("\r\n", "\n"))
        {
            // 换行用 Shift+Enter 续行而不是提交；制表符换成空格，避免触发补全。
            bool newline = raw is '\n' or '\r';
            char character = newline ? '\r' : raw == '\t' ? ' ' : raw;
            ushort virtualKey = newline ? VirtualKeyReturn : (ushort)0;
            uint controlState = newline ? ShiftPressed : 0;
            records.Add(new InputRecord { EventType = KeyEventType, KeyDown = 1, RepeatCount = 1, VirtualKeyCode = virtualKey, UnicodeChar = character, ControlKeyState = controlState });
            records.Add(new InputRecord { EventType = KeyEventType, KeyDown = 0, RepeatCount = 1, VirtualKeyCode = virtualKey, UnicodeChar = character, ControlKeyState = controlState });
        }

        InputRecord[] buffer = records.ToArray();
        return WriteConsoleInput(handle, buffer, (uint)buffer.Length, out uint written) && written == buffer.Length;
    }

    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    private struct InputRecord
    {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public int KeyDown;
        [FieldOffset(8)] public ushort RepeatCount;
        [FieldOffset(10)] public ushort VirtualKeyCode;
        [FieldOffset(12)] public ushort VirtualScanCode;
        [FieldOffset(14)] public char UnicodeChar;
        [FieldOffset(16)] public uint ControlKeyState;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int standardHandle);

    [DllImport("kernel32.dll", EntryPoint = "WriteConsoleInputW", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool WriteConsoleInput(IntPtr consoleInput, InputRecord[] buffer, uint length, out uint written);
}

public static class PlatformCredentialStore
{
    public static string BackendName => AITerminalPlatform.IsWindows
        ? "Windows Credential Manager"
        : "不可用";

    public static bool IsAvailable => AITerminalPlatform.IsWindows && WindowsCredentialStore.IsAvailable;

    public static void Set(string target, string secret)
    {
        if (AITerminalPlatform.IsWindows)
        {
            WindowsCredentialStore.Set(target, secret);
        }
        else
        {
            throw new PlatformNotSupportedException("当前操作系统没有可用的 PSAITerminal 密钥库实现。");
        }
    }

    public static string? Get(string target)
    {
        return AITerminalPlatform.IsWindows && WindowsCredentialStore.IsAvailable
            ? WindowsCredentialStore.Get(target)
            : null;
    }

    public static void Remove(string target)
    {
        if (AITerminalPlatform.IsWindows && WindowsCredentialStore.IsAvailable)
        {
            WindowsCredentialStore.Remove(target);
        }
    }
}

public static class WindowsCredentialStore
{
    private const uint GenericCredential = 1;
    private const uint PersistSession = 1;
    private const uint PersistLocalMachine = 2;
    private const int ErrorNotFound = 1168;
    private const int ErrorNoSuchLogonSession = 1312;

    public static bool IsAvailable
    {
        get
        {
            if (!AITerminalPlatform.IsWindows) { return false; }
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
        if (string.IsNullOrWhiteSpace(target)) { throw new ArgumentException("目标名称不能为空。", nameof(target)); }
        if (secret is null) { throw new ArgumentNullException(nameof(secret)); }

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
                int error = Marshal.GetLastWin32Error();
                if (error != ErrorNoSuchLogonSession)
                {
                    throw new Win32Exception(error);
                }

                // 某些受限/网络登录会话没有本机持久凭据集，但仍支持当前会话凭据。
                // 保留加密的 Credential Manager 存储，避免把密钥降级写入配置或明文。
                credential.Persist = PersistSession;
                if (!CredWrite(ref credential, 0))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
        }
        finally
        {
            Array.Clear(bytes, 0, bytes.Length);
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
        if (string.IsNullOrWhiteSpace(target)) { throw new ArgumentException("目标名称不能为空。", nameof(target)); }
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
        if (string.IsNullOrWhiteSpace(target)) { throw new ArgumentException("目标名称不能为空。", nameof(target)); }
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
        if (!AITerminalPlatform.IsWindows)
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
