using System.Collections.Concurrent;
using System.Management.Automation.Subsystem;
using System.Management.Automation.Subsystem.Feedback;
using System.Management.Automation.Subsystem.Prediction;

namespace PSAITerminal;

public sealed class AITerminalFeedbackSnapshot
{
    internal AITerminalFeedbackSnapshot(string commandLine, string error, string currentLocation)
    {
        CommandLine = commandLine;
        Error = error;
        CurrentLocation = currentLocation;
    }

    public string CommandLine { get; }

    public string Error { get; }

    public string CurrentLocation { get; }
}

public static class AITerminalOfficialIntegration
{
    private static readonly object s_sync = new();
    private static readonly AITerminalPredictor s_predictor = new();
    private static readonly AITerminalFeedbackProvider s_feedback = new();
    private static bool s_predictorRegistered;
    private static bool s_feedbackRegistered;

    public static bool PredictorRegistered
    {
        get { lock (s_sync) { return s_predictorRegistered; } }
    }

    public static bool FeedbackRegistered
    {
        get { lock (s_sync) { return s_feedbackRegistered; } }
    }

    public static void RegisterPredictor()
    {
        lock (s_sync)
        {
            if (s_predictorRegistered)
            {
                return;
            }

            SubsystemManager.RegisterSubsystem<ICommandPredictor, AITerminalPredictor>(s_predictor);
            s_predictorRegistered = true;
        }
    }

    public static void UnregisterPredictor()
    {
        lock (s_sync)
        {
            if (!s_predictorRegistered)
            {
                return;
            }

            SubsystemManager.UnregisterSubsystem<ICommandPredictor>(s_predictor.Id);
            s_predictorRegistered = false;
        }
    }

    public static void RegisterFeedback()
    {
        lock (s_sync)
        {
            if (s_feedbackRegistered)
            {
                return;
            }

            SubsystemManager.RegisterSubsystem<IFeedbackProvider, AITerminalFeedbackProvider>(s_feedback);
            s_feedbackRegistered = true;
        }
    }

    public static void UnregisterFeedback()
    {
        lock (s_sync)
        {
            if (!s_feedbackRegistered)
            {
                return;
            }

            SubsystemManager.UnregisterSubsystem<IFeedbackProvider>(s_feedback.Id);
            s_feedbackRegistered = false;
        }
    }

    public static void AddPrediction(string command)
    {
        s_predictor.Add(command);
    }

    public static AITerminalFeedbackSnapshot? GetLastFeedback()
    {
        return s_feedback.LastSnapshot;
    }

    public static void UnregisterAll()
    {
        UnregisterPredictor();
        UnregisterFeedback();
        s_predictor.Clear();
        s_feedback.Clear();
    }
}

public sealed class AITerminalPredictor : ICommandPredictor
{
    private const int MaximumSuggestions = 20;
    private readonly ConcurrentQueue<string> _suggestions = new();

    public Guid Id { get; } = new("fc70c63d-8114-4ec8-9154-c3bfa1bd0765");

    public string Name => "PSAITerminal";

    public string Description => "显示当前会话中已生成或接受的 AI 命令，不执行网络请求。";

    public Dictionary<string, string>? FunctionsToDefine => null;

    internal void Add(string command)
    {
        if (string.IsNullOrWhiteSpace(command))
        {
            return;
        }

        string normalized = command.Trim();
        if (_suggestions.Contains(normalized, StringComparer.Ordinal))
        {
            return;
        }

        _suggestions.Enqueue(normalized);
        while (_suggestions.Count > MaximumSuggestions)
        {
            _suggestions.TryDequeue(out _);
        }
    }

    internal void Clear()
    {
        while (_suggestions.TryDequeue(out _))
        {
        }
    }

    public SuggestionPackage GetSuggestion(
        PredictionClient client,
        PredictionContext context,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        string input = context.InputAst.Extent.Text ?? string.Empty;
        List<PredictiveSuggestion> suggestions = _suggestions
            .Reverse()
            .Where(value => value.StartsWith(input, StringComparison.OrdinalIgnoreCase) &&
                !value.Equals(input, StringComparison.Ordinal))
            .Take(5)
            .Select(value => new PredictiveSuggestion(value, "PSAITerminal 当前会话建议"))
            .ToList();
        return new SuggestionPackage(suggestions);
    }

    public bool CanAcceptFeedback(PredictionClient client, PredictorFeedbackKind feedback) => true;

    public void OnSuggestionDisplayed(PredictionClient client, uint session, int countOrIndex)
    {
    }

    public void OnSuggestionAccepted(PredictionClient client, uint session, string acceptedSuggestion)
    {
        Add(acceptedSuggestion);
    }

    public void OnCommandLineAccepted(PredictionClient client, IReadOnlyList<string> history)
    {
    }

    public void OnCommandLineExecuted(PredictionClient client, string commandLine, bool success)
    {
    }
}

public sealed class AITerminalFeedbackProvider : IFeedbackProvider
{
    private AITerminalFeedbackSnapshot? _lastSnapshot;

    public Guid Id { get; } = new("8baf6d90-5afe-492a-8ea7-aa76aa9c10ef");

    public string Name => "PSAITerminal";

    public string Description => "为失败命令提供显式 AI 解释入口。";

    public Dictionary<string, string>? FunctionsToDefine => null;

    public FeedbackTrigger Trigger => FeedbackTrigger.CommandNotFound | FeedbackTrigger.Error;

    internal AITerminalFeedbackSnapshot? LastSnapshot => Volatile.Read(ref _lastSnapshot);

    internal void Clear() => Volatile.Write(ref _lastSnapshot, null);

    public FeedbackItem? GetFeedback(FeedbackContext context, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        string commandLine = AITerminalSecurity.ProtectText(context.CommandLine, null, 4096) ?? string.Empty;
        string error = AITerminalSecurity.ProtectText(context.LastError?.ToString(), null, 4096) ?? string.Empty;
        string location = context.CurrentLocation?.Path ?? string.Empty;
        Volatile.Write(ref _lastSnapshot, new AITerminalFeedbackSnapshot(commandLine, error, location));

        return new FeedbackItem(
            "PSAITerminal：按 F7 可解释最近一次命令。",
            new List<string>(),
            "不会自动请求模型。",
            FeedbackDisplayLayout.Landscape);
    }
}
