using System.Diagnostics;
using System.IO.Compression;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Capturing;
using FlaUI.Core.Tools;
using FlaUI.UIA3;
using Xunit;

// One desktop: UI tests take turns (screenshots, the keyboard and the notification centre are shared).
[assembly: CollectionBehavior(CollectionBehavior.CollectionPerAssembly)]

namespace Bridgey.UiTests;

/// <summary>
/// Self-update end to end on this desktop: a copy of the published app checks a local test feed, finds a newer build
/// (this build's zip with a marker file, signed by the scripted peer's test key), asks, downloads, checks it, hands over
/// to the unpacked update, which replaces the installed files and opens Bridgey again.
///
/// BRIDGEY_UPDATE_ZIP: the x64 zip from build-windows.ps1. A normal install never reads the test feed overrides.
/// </summary>
public sealed class UpdateTests : IDisposable
{
    private static readonly TimeSpan Long = TimeSpan.FromSeconds(60);
    private readonly string _exe = Environment.GetEnvironmentVariable("BRIDGEY_APP_EXE")!;
    private readonly string _peerExe = Environment.GetEnvironmentVariable("BRIDGEY_PEER_EXE")!;
    private readonly string _zip = Environment.GetEnvironmentVariable("BRIDGEY_UPDATE_ZIP")!;
    private readonly string _shots = Environment.GetEnvironmentVariable("BRIDGEY_SCREENSHOTS") is { Length: > 0 } s ? s : Path.GetTempPath();
    private readonly string _root = Path.Combine(Path.GetTempPath(), "bridgey-ui-update-" + Guid.NewGuid().ToString("N")[..8]);
    private readonly UIA3Automation _automation = new();
    private TcpListener? _server;
    private readonly List<Process> _started = new();

    [Fact]
    public void SelfUpdateFromATestFeed()
    {
        var install = Path.Combine(_root, "install");
        var data = Path.Combine(_root, "data");
        CopyFolder(Path.GetDirectoryName(_exe)!, install);
        Directory.CreateDirectory(data);

        // The update: this build's zip with a marker, signed by the test key.
        var update = Path.Combine(_root, "update.zip");
        File.Copy(_zip, update);
        using (var archive = ZipFile.Open(update, ZipArchiveMode.Update))
        {
            var top = archive.Entries.First().FullName.Split('/')[0];
            using var writer = new StreamWriter(archive.CreateEntry($"{top}/update-marker.txt").Open());
            writer.Write("installed by the self-update test");
        }
        var signer = Process.Start(new ProcessStartInfo(_peerExe) { ArgumentList = { "--sign-update", update }, RedirectStandardOutput = true, UseShellExecute = false })!;
        var signed = JsonDocument.Parse(signer.StandardOutput.ReadToEnd()).RootElement;
        signer.WaitForExit();
        var bytes = File.ReadAllBytes(update);
        var port = Serve(update);
        var feed = JsonSerializer.Serialize(new Dictionary<string, object>
        {
            ["schema"] = 1, ["app"] = "in.roundrobin.bridgey", ["channel"] = "beta", ["version"] = "1.0.0-beta.99", ["build"] = 999_999_999,
            ["windows"] = new Dictionary<string, object>
            {
                ["version"] = "1.0.0-beta.99", ["build"] = 999_999_999, ["minimumOsBuild"] = 19041,
                ["x64"] = new Dictionary<string, object>
                {
                    ["url"] = $"http://127.0.0.1:{port}/update.zip", ["sha256"] = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(),
                    ["size"] = bytes.Length, ["edSignature"] = signed.GetProperty("signature").GetString()!,
                },
            },
        });
        File.WriteAllText(Path.Combine(_root, "beta.json"), feed);
        File.WriteAllText(Path.Combine(data, "settings.json"), JsonSerializer.Serialize(new Dictionary<string, object>
        {
            ["deviceName"] = "Bridgey CI PC", ["theme"] = "Light", ["setupDone"] = true, ["startAtSignIn"] = false, ["updateChannel"] = "beta", ["autoUpdateCheck"] = false,
        }));

        var start = new ProcessStartInfo(Path.Combine(install, "Bridgey.exe")) { UseShellExecute = false };
        start.Environment["BRIDGEY_DATA_DIR"] = data;
        start.Environment["BRIDGEY_PORT"] = "42463";
        start.Environment["BRIDGEY_DISCOVERY"] = "0";
        start.Environment["BRIDGEY_UPDATE_FEED_BASE"] = $"http://127.0.0.1:{port}/channels";
        start.Environment["BRIDGEY_UPDATE_TRUSTED_PREFIX"] = $"http://127.0.0.1:{port}/";
        start.Environment["BRIDGEY_UPDATE_PUBLIC_KEY"] = signed.GetProperty("publicKey").GetString()!;
        using var app = Application.Launch(start);
        _started.Add(Process.GetProcessById(app.ProcessId));
        var window = app.GetMainWindow(_automation, Long) ?? throw new InvalidOperationException("no window");
        try
        {
            Click(window, "NavSettings");
            var list = Find(window, "SettingsSections");
            var updates = Retry.WhileNull(() => list.FindFirstDescendant(c => c.ByName("Updates")), Long).Result!;
            (updates.Patterns.SelectionItem.IsSupported ? updates : updates.Parent).Patterns.SelectionItem.Pattern.Select();
            Click(window, "CheckUpdates");
            WaitFor(() => Find(window, "UpdateStatus").Name == "Bridgey 1.0 Beta 99 is ready.", "the update offered");
            Thread.Sleep(700);
            Capture.Element(window).ToFile(Path.Combine(_shots, "settings-updates-light.png"));
            Click(window, "InstallUpdate");
            var install_ = Retry.WhileNull(() => window.FindFirstDescendant(c => c.ByControlType(FlaUI.Core.Definitions.ControlType.Button).And(c.ByName("Install"))), Long).Result
                ?? throw new InvalidOperationException("the confirmation did not appear");
            Thread.Sleep(500);
            Capture.Element(window).ToFile(Path.Combine(_shots, "update-confirm-light.png"));
            install_.Patterns.Invoke.Pattern.Invoke();
        }
        catch
        {
            try { Capture.Screen().ToFile(Path.Combine(_shots, "update-failure.png")); } catch (Exception) { }
            throw;
        }

        // The old Bridgey ends, the update replaces its files and Bridgey opens again from the install folder.
        WaitFor(() => app.HasExited, "the old Bridgey to close");
        WaitFor(() => File.Exists(Path.Combine(install, "update-marker.txt")), "the new files in the install folder");
        var relaunched = WaitFor(() => Process.GetProcessesByName("Bridgey").FirstOrDefault(p => SafePath(p)?.StartsWith(install, StringComparison.OrdinalIgnoreCase) == true), "Bridgey opening again");
        _started.Add(relaunched);
        var log = File.ReadAllText(Path.Combine(data, "update.log"));
        Assert.Contains("Update installed", log);
        using var again = Application.Attach(relaunched);
        var newWindow = again.GetMainWindow(_automation, Long);
        if (newWindow is not null)
        {
            Thread.Sleep(1000);
            Capture.Element(newWindow).ToFile(Path.Combine(_shots, "updated-light.png"));
        }
    }

    private static string? SafePath(Process p)
    {
        try { return p.MainModule?.FileName; }
        catch (Exception) { return null; }
    }

    /// <summary>A tiny HTTP server for the feed and the zip; returns its port.</summary>
    private int Serve(string zip)
    {
        _server = new TcpListener(IPAddress.Loopback, 0);
        _server.Start();
        var port = ((IPEndPoint)_server.LocalEndpoint).Port;
        new Thread(() =>
        {
            while (true)
            {
                TcpClient client;
                try { client = _server.AcceptTcpClient(); }
                catch (Exception) { return; }
                using (client)
                using (var stream = client.GetStream())
                {
                    var reader = new StreamReader(stream, Encoding.ASCII, leaveOpen: true);
                    var request = reader.ReadLine() ?? "";
                    while (!string.IsNullOrEmpty(reader.ReadLine())) { }
                    var path = request.Split(' ').ElementAtOrDefault(1) ?? "";
                    byte[] body = path switch
                    {
                        "/channels/beta.json" => File.ReadAllBytes(Path.Combine(_root, "beta.json")),
                        "/update.zip" => File.ReadAllBytes(zip),
                        _ => [],
                    };
                    var status = body.Length > 0 ? "200 OK" : "404 Not Found";
                    var head = Encoding.ASCII.GetBytes($"HTTP/1.1 {status}\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n");
                    stream.Write(head);
                    stream.Write(body);
                }
            }
        }) { IsBackground = true }.Start();
        return port;
    }

    private static void CopyFolder(string from, string to)
    {
        foreach (var dir in Directory.GetDirectories(from, "*", SearchOption.AllDirectories)) Directory.CreateDirectory(dir.Replace(from, to));
        Directory.CreateDirectory(to);
        foreach (var file in Directory.GetFiles(from, "*", SearchOption.AllDirectories)) File.Copy(file, file.Replace(from, to), overwrite: true);
    }

    private AutomationElement Find(Window window, string id) =>
        Retry.WhileNull(() => window.FindFirstDescendant(c => c.ByAutomationId(id)), Long, TimeSpan.FromMilliseconds(250)).Result ?? throw new InvalidOperationException($"{id} not found");

    private void Click(Window window, string id)
    {
        var element = Find(window, id);
        if (element.Patterns.Invoke.IsSupported) element.Patterns.Invoke.Pattern.Invoke();
        else if (element.Patterns.SelectionItem.IsSupported) element.Patterns.SelectionItem.Pattern.Select();
        else element.Click();
        FlaUI.Core.Input.Wait.UntilInputIsProcessed(TimeSpan.FromSeconds(1));
    }

    private static T WaitFor<T>(Func<T?> probe, string what) where T : class
    {
        var deadline = DateTime.UtcNow + Long;
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                if (probe() is { } found) return found;
            }
            catch (Exception) { }
            Thread.Sleep(250);
        }
        throw new TimeoutException($"Timed out waiting for {what}");
    }

    private static void WaitFor(Func<bool> probe, string what) => WaitFor(() => probe() ? "ok" : null, what);

    public void Dispose()
    {
        _server?.Stop();
        foreach (var p in _started)
        {
            try { if (!p.HasExited) p.Kill(); }
            catch (Exception) { }
        }
        _automation.Dispose();
    }
}
