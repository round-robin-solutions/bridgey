using System.Diagnostics;
using System.IO.Compression;
using Bridgey.ViewModels;

namespace Bridgey.Platform;

/// <summary>
/// Downloads, asks and installs. Installing unpacks the checked zip next to the data folder and starts the new
/// Bridgey.exe from there with <c>--install-update</c>; that copy waits for this process to end, puts the new files in
/// place of the old ones and opens Bridgey again (<see cref="UpdateInstaller"/>).
/// </summary>
internal sealed class UpdateHost(Func<MainWindow?> window, Action quit) : IUpdateHost
{
    private static readonly HttpClient Http = new(new HttpClientHandler { AllowAutoRedirect = true }) { Timeout = TimeSpan.FromMinutes(10) };

    static UpdateHost()
    {
        Http.DefaultRequestHeaders.UserAgent.ParseAdd($"BridgeyRR-Windows/{Edition.VersionName}");
    }

    public string DownloadFolder => Path.Combine(Paths.DataFolder, "update");

    public async Task<string> FetchAsync(string url, CancellationToken cancel)
    {
        using var response = await Http.GetAsync(url, cancel);
        response.EnsureSuccessStatusCode();
        var text = await response.Content.ReadAsStringAsync(cancel);
        return text.Length <= 256 * 1024 ? text : throw new InvalidDataException("the feed is too large");
    }

    public async Task DownloadAsync(string url, string path, IProgress<double> progress, CancellationToken cancel)
    {
        using var response = await Http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancel);
        response.EnsureSuccessStatusCode();
        var total = response.Content.Headers.ContentLength ?? 0;
        if (total > UpdateLimits.MaxSize) throw new InvalidDataException("the download is too large");
        await using var input = await response.Content.ReadAsStreamAsync(cancel);
        await using var output = File.Create(path);
        var buffer = new byte[256 * 1024];
        long done = 0;
        int n;
        while ((n = await input.ReadAsync(buffer, cancel)) > 0)
        {
            done += n;
            if (done > UpdateLimits.MaxSize) throw new InvalidDataException("the download is too large");
            await output.WriteAsync(buffer.AsMemory(0, n), cancel);
            if (total > 0) progress.Report((double)done / total);
        }
    }

    public async Task<bool> ConfirmAsync(string title, string text) => window() is { } w && await w.Confirm(title, text, "Install");

    public void Install(string zipPath)
    {
        var staging = Path.Combine(DownloadFolder, "staging");
        if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
        ZipFile.ExtractToDirectory(zipPath, staging);
        // The zip holds one folder named like the app; Bridgey.exe is inside it.
        var source = Directory.GetFiles(staging, "Bridgey.exe", SearchOption.AllDirectories).Select(Path.GetDirectoryName).FirstOrDefault()
            ?? throw new InvalidDataException("the update has no Bridgey.exe");
        var target = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        // Started through the shell, so it inherits none of this process's handles and outlives it cleanly.
        var start = new ProcessStartInfo(Path.Combine(source!, "Bridgey.exe")) { UseShellExecute = true, WorkingDirectory = source };
        start.ArgumentList.Add("--install-update");
        start.ArgumentList.Add(source!);
        start.ArgumentList.Add(target);
        start.ArgumentList.Add(Environment.ProcessId.ToString());
        Process.Start(start);
        App.Log($"Update unpacked; handing over to {source}");
        File.Delete(zipPath);
        quit();
    }
}

internal static class UpdateLimits
{
    public const long MaxSize = 150L * 1024 * 1024;
}

/// <summary>
/// <c>Bridgey.exe --install-update &lt;new files&gt; &lt;install folder&gt; &lt;pid&gt;</c>, run from the unpacked update:
/// waits up to 30 s for the old Bridgey to end, copies the new files over the old ones (retrying files Windows still
/// holds), then starts Bridgey from the install folder. If a copy fails the old Bridgey starts again as it was.
/// </summary>
internal static class UpdateInstaller
{
    public static int Run(string source, string target, int pid)
    {
        Log($"Installing from {source} to {target}");
        try
        {
            using var old = Process.GetProcessById(pid);
            old.WaitForExit(30_000);
        }
        catch (ArgumentException) { }
        catch (InvalidOperationException) { }
        var ok = true;
        foreach (var file in Directory.GetFiles(source, "*", SearchOption.AllDirectories))
        {
            var relative = Path.GetRelativePath(source, file);
            var destination = Path.Combine(target, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            var copied = false;
            for (var attempt = 0; attempt < 40 && !copied; attempt++)
            {
                try
                {
                    File.Copy(file, destination, overwrite: true);
                    copied = true;
                }
                catch (IOException) { Thread.Sleep(250); }
                catch (UnauthorizedAccessException) { Thread.Sleep(250); }
            }
            if (!copied)
            {
                Log($"Could not replace {relative}");
                ok = false;
                break;
            }
        }
        Log(ok ? "Update installed" : "Update not fully installed; starting the installed Bridgey");
        try
        {
            Process.Start(new ProcessStartInfo(Path.Combine(target, "Bridgey.exe")) { UseShellExecute = true, WorkingDirectory = target });
        }
        catch (Exception e)
        {
            Log($"Starting Bridgey failed: {e.Message}");
            return 1;
        }
        return ok ? 0 : 1;
    }

    private static void Log(string line)
    {
        try
        {
            Directory.CreateDirectory(Paths.DataFolder);
            File.AppendAllText(Path.Combine(Paths.DataFolder, "update.log"), $"{DateTimeOffset.Now:O} {line}{Environment.NewLine}");
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
