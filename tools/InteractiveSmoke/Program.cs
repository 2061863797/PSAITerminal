using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

if (!OperatingSystem.IsWindows())
{
    Console.Error.WriteLine("此冒烟测试仅支持 Windows。");
    return 2;
}

bool useProfile = args.Length == 3 && string.Equals(args[2], "--profile", StringComparison.Ordinal);
if (args.Length is < 2 or > 3 || (args.Length == 3 && !useProfile))
{
    Console.Error.WriteLine("用法：InteractiveSmoke <powershell.exe|pwsh.exe> <PSAITerminal.psd1> [--profile]");
    return 2;
}

string pwshPath = Path.GetFullPath(args[0]);
string manifestPath = Path.GetFullPath(args[1]);
if (!File.Exists(pwshPath) || !File.Exists(manifestPath))
{
    Console.Error.WriteLine("pwsh.exe 或模块清单不存在。");
    return 2;
}

string stateRoot = Path.Combine(Path.GetTempPath(), "PSAITerminal.ConPTY." + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(stateRoot);

try
{
    using var terminal = new PseudoTerminal(pwshPath, useProfile ? "-NoLogo" : "-NoLogo -NoProfile", Path.GetDirectoryName(manifestPath)!);
    terminal.WaitFor("PS ", TimeSpan.FromSeconds(15));

    if (useProfile)
    {
        terminal.Send("if(Get-Module PSAITerminal){Write-Output '__PSAI_IMPORTED__'}else{Write-Output '__PSAI_NOT_IMPORTED__'}\r");
    }
    else
    {
        string escapedManifest = manifestPath.Replace("'", "''", StringComparison.Ordinal);
        string escapedStateRoot = stateRoot.Replace("'", "''", StringComparison.Ordinal);
        terminal.Send($"$global:__PSAI_ORIGINAL_READLINE=(Get-Command PSConsoleHostReadLine -CommandType Function).Definition;$env:PSAI_CONFIG_HOME='{escapedStateRoot}\\config';$env:PSAI_DATA_HOME='{escapedStateRoot}\\data';Import-Module '{escapedManifest}' -Force;Write-Output '__PSAI_IMPORTED__'\r");
    }
    terminal.WaitFor("__PSAI_IMPORTED__", TimeSpan.FromSeconds(20));

    terminal.Send("$g=Get-Command Get-PSReadLineKeyHandler;if($g.Parameters.ContainsKey('Chord')){$a=(Get-PSReadLineKeyHandler -Chord F2).Function;$b=(Get-PSReadLineKeyHandler -Chord F3).Function}else{$h=@(Get-PSReadLineKeyHandler -Bound);$a=($h|Where-Object Key -eq F2|Select-Object -First 1).Function;$b=($h|Where-Object Key -eq F3|Select-Object -First 1).Function};Write-Output ('__PSAI_BINDINGS__'+$a+'|'+$b)\r");
    terminal.WaitFor("__PSAI_BINDINGS__PSAIForceAI|PSAIForceShell", TimeSpan.FromSeconds(10));

    if (!useProfile)
    {
        // 模式标记必须由真实 prompt 动态显示，且不能依赖预先配置模型。
        terminal.Send("& (Get-Module PSAITerminal) { $script:Config.mode='AI' }");
        terminal.Send("\u001bOR");
        terminal.WaitFor("[AI] PS ", TimeSpan.FromSeconds(10));
        terminal.Send("& (Get-Module PSAITerminal) { $script:Config.mode='Auto' }");
        terminal.Send("\u001bOR");
        terminal.WaitFor("[AUTO] PS ", TimeSpan.FromSeconds(10));
        terminal.Send("& (Get-Module PSAITerminal) { $script:Config.mode='Off' };Write-Output '__PSAI_MODE_OFF__'");
        terminal.Send("\u001bOR");
        terminal.WaitFor("__PSAI_MODE_OFF__", TimeSpan.FromSeconds(10));

        terminal.Send("& (Get-Module PSAITerminal) { $value=Read-AIChoice (Get-AIText 'SelectNumber') @(1,2) 1;Write-Output ('__PSAI_DEFAULT_CHOICE__'+$value) }\r");
        terminal.WaitFor("Enter a number (default 1):", TimeSpan.FromSeconds(10));
        terminal.Send("\r");
        terminal.WaitFor("__PSAI_DEFAULT_CHOICE__1", TimeSpan.FromSeconds(10));

        terminal.Send("& (Get-Module PSAITerminal) { $script:Config.language='zh-CN';$value=Read-AIChoice (Get-AIText 'SelectNumber') @(1,2) 1;Write-Output ('__PSAI_ZH_DEFAULT_CHOICE__'+$value);$script:Config.language='en-US' }\r");
        terminal.WaitFor("请输入序号（默认1）:", TimeSpan.FromSeconds(10));
        terminal.Send("\r");
        terminal.WaitFor("__PSAI_ZH_DEFAULT_CHOICE__1", TimeSpan.FromSeconds(10));

        // 真实打开并退出设置菜单，防止菜单提示表达式把 if 误当作命令并反复报错。
        terminal.Send("ai\r");
        terminal.WaitFor("6. Diagnostics", TimeSpan.FromSeconds(10));
        terminal.Send("0\r");
        terminal.Send("Write-Output '__PSAI_MENU_EXITED__'\r");
        terminal.WaitFor("__PSAI_MENU_EXITED__", TimeSpan.FromSeconds(10));
    }

    // F3 必须直接提交当前缓冲区，而不是再经过 Enter 路由。
    terminal.Send("Write-Output '__PSAI_F3_OK__'");
    terminal.Send("\u001bOR");
    terminal.WaitFor("__PSAI_F3_OK__", TimeSpan.FromSeconds(10));

    if (!useProfile)
    {
        // F2 使用 xterm/ConPTY 的 SS3 Q 序列。未配置模型时应进入 AI 路径并给出明确错误。
        terminal.Send("PSAI_F2_PROBE");
        terminal.Send("\u001bOQ");
        terminal.WaitFor("尚未配置活动模型", TimeSpan.FromSeconds(15));

        terminal.Send("Remove-Module PSAITerminal;if((Get-Command PSConsoleHostReadLine -CommandType Function).Definition -ceq $global:__PSAI_ORIGINAL_READLINE){Write-Output '__PSAI_READLINE_RESTORED__'}else{Write-Output '__PSAI_READLINE_NOT_RESTORED__'}\r");
        terminal.WaitFor("__PSAI_READLINE_RESTORED__", TimeSpan.FromSeconds(10));
    }

    terminal.Send("exit\r");
    terminal.WaitForExit(TimeSpan.FromSeconds(10));

    string transcript = terminal.GetTranscript();
    string clean = TerminalText.Strip(transcript);
    if ((!useProfile && !clean.Contains("PSAI_F2_PROBE", StringComparison.Ordinal)) ||
        clean.Contains(". (Invoke-PSAI)", StringComparison.Ordinal) ||
        clean.Contains("Invoke-PSAI -PendingInvocation", StringComparison.Ordinal) ||
        clean.Contains("New-AITopLevelHarnessScript", StringComparison.Ordinal) ||
        clean.Contains("Start-PSAIToolExecution", StringComparison.Ordinal) ||
        clean.Contains("The term 'if' is not recognized", StringComparison.Ordinal) ||
        clean.Contains("while ($null -ne", StringComparison.Ordinal))
    {
        throw new InvalidOperationException("交互终端没有保留原始输入，或显示了内部调度命令/Harness 源码。\n" + clean);
    }

    Console.WriteLine(useProfile
        ? "ConPTY Profile 冒烟测试通过：模块已自动加载，F2/F3 已注册，F3 已真实触发。"
        : "ConPTY 交互冒烟测试通过：F2/F3、设置菜单、AI/Auto 模式标记与中英文默认选择均已验证，原始输入完整保留，内部调度命令未显示。");
    return 0;
}
catch (Exception exception)
{
    Console.Error.WriteLine(exception.Message);
    return 1;
}
finally
{
    try { Directory.Delete(stateRoot, recursive: true); }
    catch { }
}

static class TerminalText
{
    internal static string Strip(string value)
    {
        // 仅用于测试日志归一化；产品中的有状态清洗器另有完整测试。
        return System.Text.RegularExpressions.Regex.Replace(
            value,
            "(?:\\u001B\\][^\\u0007]*(?:\\u0007|\\u001B\\\\))|(?:\\u001B\\[[0-?]*[ -/]*[@-~])|(?:\\u001B[()][0-2A-Z])|[\\u0000-\\u0008\\u000B\\u000C\\u000E-\\u001A]",
            string.Empty);
    }
}

sealed class PseudoTerminal : IDisposable
{
    private const int ExtendedStartupInfoPresent = 0x00080000;
    private const int StartUseStdHandles = 0x00000100;
    private static readonly IntPtr ProcThreadAttributePseudoConsole = (IntPtr)0x00020016;

    private readonly object _gate = new();
    private readonly StringBuilder _transcript = new();
    private readonly FileStream _input;
    private readonly FileStream _output;
    private readonly Task _reader;
    private readonly IntPtr _process;
    private readonly IntPtr _pseudoConsole;
    private readonly IntPtr _attributeList;
    private bool _disposed;

    public PseudoTerminal(string executable, string arguments, string workingDirectory)
    {
        Check(Native.CreatePipe(out IntPtr inputRead, out IntPtr inputWrite, IntPtr.Zero, 0));
        Check(Native.CreatePipe(out IntPtr outputRead, out IntPtr outputWrite, IntPtr.Zero, 0));

        int hr = Native.CreatePseudoConsole(new Coord(160, 40), inputRead, outputWrite, 0, out _pseudoConsole);
        if (hr < 0) { Marshal.ThrowExceptionForHR(hr); }

        _attributeList = AllocateAttributeList(_pseudoConsole);
        var startup = new StartupInfoEx
        {
            // 显式清空标准句柄，避免测试宿主自己的控制台句柄泄漏给子进程。
            StartupInfo = new StartupInfo { cb = Marshal.SizeOf<StartupInfoEx>(), Flags = StartUseStdHandles },
            AttributeList = _attributeList,
        };

        string commandLine = $"\"{executable}\" {arguments}";
        Check(Native.CreateProcess(
            null,
            new StringBuilder(commandLine),
            IntPtr.Zero,
            IntPtr.Zero,
            false,
            ExtendedStartupInfoPresent,
            IntPtr.Zero,
            workingDirectory,
            ref startup,
            out ProcessInformation processInformation));

        _process = processInformation.Process;
        Native.CloseHandle(processInformation.Thread);
        Native.CloseHandle(inputRead);
        Native.CloseHandle(outputWrite);

        _input = new FileStream(new SafeFileHandle(inputWrite, ownsHandle: true), FileAccess.Write, 4096, isAsync: false);
        _output = new FileStream(new SafeFileHandle(outputRead, ownsHandle: true), FileAccess.Read, 4096, isAsync: false);
        _reader = Task.Run(ReadOutput);
    }

    public void Send(string text)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(text);
        _input.Write(bytes);
        _input.Flush();
    }

    public void WaitFor(string marker, TimeSpan timeout)
    {
        DateTime deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            lock (_gate)
            {
                if (TerminalText.Strip(_transcript.ToString()).Contains(marker, StringComparison.Ordinal)) { return; }
            }

            Thread.Sleep(25);
        }

        throw new TimeoutException($"等待终端输出超时：{marker}\n{GetTranscript()}");
    }

    public void WaitForExit(TimeSpan timeout)
    {
        uint result = Native.WaitForSingleObject(_process, checked((uint)timeout.TotalMilliseconds));
        if (result != 0) { throw new TimeoutException("等待 pwsh.exe 退出超时。"); }
        _reader.Wait(TimeSpan.FromSeconds(2));
    }

    public string GetTranscript()
    {
        lock (_gate) { return _transcript.ToString(); }
    }

    private void ReadOutput()
    {
        using var reader = new StreamReader(_output, new UTF8Encoding(false, true), detectEncodingFromByteOrderMarks: false, bufferSize: 4096, leaveOpen: true);
        var buffer = new char[2048];
        try
        {
            while (true)
            {
                int count = reader.Read(buffer, 0, buffer.Length);
                if (count == 0) { return; }
                lock (_gate) { _transcript.Append(buffer, 0, count); }
            }
        }
        catch (IOException) when (_disposed) { }
        catch (ObjectDisposedException) when (_disposed) { }
    }

    public void Dispose()
    {
        if (_disposed) { return; }
        _disposed = true;
        _input.Dispose();
        Native.ClosePseudoConsole(_pseudoConsole);
        _output.Dispose();
        _reader.Wait(TimeSpan.FromSeconds(2));
        Native.CloseHandle(_process);
        Native.DeleteProcThreadAttributeList(_attributeList);
        Marshal.FreeHGlobal(_attributeList);
    }

    private static IntPtr AllocateAttributeList(IntPtr pseudoConsole)
    {
        IntPtr size = IntPtr.Zero;
        Native.InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
        IntPtr list = Marshal.AllocHGlobal(size);
        try
        {
            Check(Native.InitializeProcThreadAttributeList(list, 1, 0, ref size));
            Check(Native.UpdateProcThreadAttribute(
                list,
                0,
                ProcThreadAttributePseudoConsole,
                pseudoConsole,
                (IntPtr)IntPtr.Size,
                IntPtr.Zero,
                IntPtr.Zero));
            return list;
        }
        catch
        {
            Marshal.FreeHGlobal(list);
            throw;
        }
    }

    private static void Check(bool success)
    {
        if (!success) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
    }
}

[StructLayout(LayoutKind.Sequential)]
readonly struct Coord
{
    public readonly short X;
    public readonly short Y;
    public Coord(short x, short y) { X = x; Y = y; }
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
struct StartupInfo
{
    public int cb;
    public string? Reserved;
    public string? Desktop;
    public string? Title;
    public int X;
    public int Y;
    public int XSize;
    public int YSize;
    public int XCountChars;
    public int YCountChars;
    public int FillAttribute;
    public int Flags;
    public short ShowWindow;
    public short Reserved2;
    public IntPtr Reserved2Pointer;
    public IntPtr StdInput;
    public IntPtr StdOutput;
    public IntPtr StdError;
}

[StructLayout(LayoutKind.Sequential)]
struct StartupInfoEx
{
    public StartupInfo StartupInfo;
    public IntPtr AttributeList;
}

[StructLayout(LayoutKind.Sequential)]
readonly struct ProcessInformation
{
    public readonly IntPtr Process;
    public readonly IntPtr Thread;
    public readonly uint ProcessId;
    public readonly uint ThreadId;
}

static class Native
{
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool CreatePipe(out IntPtr readPipe, out IntPtr writePipe, IntPtr attributes, uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern int CreatePseudoConsole(Coord size, IntPtr input, IntPtr output, uint flags, out IntPtr pseudoConsole);

    [DllImport("kernel32.dll")]
    internal static extern void ClosePseudoConsole(IntPtr pseudoConsole);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool InitializeProcThreadAttributeList(IntPtr attributeList, int attributeCount, int flags, ref IntPtr size);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool UpdateProcThreadAttribute(IntPtr attributeList, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previousValue, IntPtr returnSize);

    [DllImport("kernel32.dll")]
    internal static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

    [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool CreateProcess(
        string? applicationName,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
        int creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref StartupInfoEx startupInfo,
        out ProcessInformation processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
}
