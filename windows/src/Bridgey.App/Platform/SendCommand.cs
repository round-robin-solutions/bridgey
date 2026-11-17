namespace Bridgey.Platform;

/// <summary>
/// <c>Bridgey.exe --send a.jpg b.pdf</c> (Explorer's Send to adds the files after <c>--send</c>), and the same command
/// handed from a second launch to the running app: <c>send</c>, then one path per line.
/// </summary>
internal static class SendCommand
{
    private const string Prefix = "send\n";

    /// <summary>The files after <c>--send</c>, or null when there is no <c>--send</c>.</summary>
    public static IReadOnlyList<string>? Paths(IEnumerable<string> args)
    {
        var list = args.ToList();
        var at = list.IndexOf("--send");
        if (at < 0) return null;
        return list.Skip(at + 1).Where(a => !a.StartsWith("--", StringComparison.Ordinal) && a.Length > 0).Select(Path.GetFullPath).ToList();
    }

    public static string Format(IReadOnlyList<string> paths) => Prefix + string.Join('\n', paths);

    public static IReadOnlyList<string>? Parse(string command) =>
        command.StartsWith(Prefix, StringComparison.Ordinal) ? command[Prefix.Length..].Split('\n', StringSplitOptions.RemoveEmptyEntries) : null;
}
