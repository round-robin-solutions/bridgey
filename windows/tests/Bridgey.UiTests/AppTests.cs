using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Capturing;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;
using FlaUI.UIA3;
using Xunit;

namespace Bridgey.UiTests;

/// <summary>
/// The published app on this desktop: first run, Home, pairing, Settings and the notification area menu in light and
/// dark, then a real protocol 2 pairing with the scripted peer and clipboard text both ways.
///
/// BRIDGEY_APP_EXE: the published Bridgey.exe. BRIDGEY_PEER_EXE: rust/client's peer example.
/// BRIDGEY_SCREENSHOTS: where the PNGs go.
/// </summary>
public sealed partial class AppTests : IDisposable
{
    private const ushort AppPort = 42458;
    private const ushort PeerPort = 42470;
    private const string PeerName = "Test phone";
    private const string FromPeer = "Hello from the test phone";
    private const string FromPc = "Hello from Windows";
    private static readonly TimeSpan Long = TimeSpan.FromSeconds(45);

    private readonly string _exe = Required("BRIDGEY_APP_EXE");
    private readonly string _peerExe = Required("BRIDGEY_PEER_EXE");
    private readonly string _shots = Environment.GetEnvironmentVariable("BRIDGEY_SCREENSHOTS") is { Length: > 0 } s ? s : Path.Combine(Path.GetTempPath(), "bridgey-screenshots");
    private readonly string _data = Path.Combine(Path.GetTempPath(), "bridgey-ui-" + Guid.NewGuid().ToString("N")[..8]);
    private readonly UIA3Automation _automation = new();
    private Application? _app;
    private Process? _peer;
    private readonly BlockingCollection<JsonElement> _peerEvents = new();
    private readonly List<string> _peerLog = new();

    private static string Required(string name) =>
        Environment.GetEnvironmentVariable(name) is { Length: > 0 } v ? v : throw new InvalidOperationException($"{name} is not set");

    [Fact]
    public void ScreensAndPairingInLightAndDark()
    {
        Directory.CreateDirectory(_shots);
        try
        {
            // First run.
            var window = Launch("Light", setupDone: false);
            Find(window, "SetupContinue");
            Shot(window, "setup-light");
            Quit();
            window = Launch("Dark", setupDone: false);
            Find(window, "SetupContinue");
            Shot(window, "setup-dark");
            Quit();

            // The peer is on this machine and publishes itself, like a phone on the same network.
            StartPeer();

            foreach (var theme in new[] { "Light", "Dark" })
            {
                var t = theme.ToLowerInvariant();
                window = Launch(theme, setupDone: true);
                Find(window, "HomeStatus");
                if (theme == "Light") Shot(window, "home-empty-light");

                Click(window, "NavSettings");
                Find(window, "SettingsTitle");
                Shot(window, $"settings-{t}");
                SelectSection(window, "General");
                Shot(window, $"settings-general-{t}");
                SelectSection(window, "About");
                Assert.Contains("1.0", Find(window, "ShortVersion").Name);
                Shot(window, $"settings-about-{t}");

                Click(window, "NavPair");
                Find(window, "PairAddress");
                Wait.UntilInputIsProcessed(TimeSpan.FromSeconds(3));
                Shot(window, $"pairing-{t}");

                TrayMenu(window, $"tray-menu-{t}");

                if (theme == "Light") PairWithPeer(window);
                else
                {
                    // The pairing from the light run is kept (DPAPI-protected) and reconnects.
                    Click(window, "NavHome");
                    WaitFor(() => Find(window, "HomeStatus").Name == $"Connected to {PeerName}", "the dark run reconnects to the peer");
                }
                Click(window, "NavHome");
                Wait.UntilInputIsProcessed(TimeSpan.FromSeconds(2));
                Shot(window, $"home-paired-{t}");
                Quit();
            }
        }
        catch
        {
            TryShot("failure");
            throw;
        }
    }

    private void PairWithPeer(Window window)
    {
        var address = Find(window, "PairAddress").AsTextBox();
        address.Text = $"127.0.0.1:{PeerPort}";
        Click(window, "PairByAddress");
        var codeText = WaitFor(() => window.FindFirstDescendant(c => c.ByAutomationId("PairingCode"))?.Name is { Length: > 0 } n ? n : null, "the code on this PC");
        var peerCode = PeerEvent("code");
        Assert.Equal(peerCode.GetProperty("code").GetString(), codeText.Replace(" ", ""));
        Shot(window, "pairing-code-light");
        Click(window, "ConfirmCode");
        PeerEvent("connected");
        Click(window, "PairedHome");
        WaitFor(() => Find(window, "HomeStatus").Name == $"Connected to {PeerName}", "Home shows the peer connected");

        // Peer to PC: the text lands on the Windows clipboard and in Activity.
        PeerEvent("sending");
        WaitFor(() => ClipboardText() == FromPeer ? "ok" : null, "the peer's text on the Windows clipboard");

        // PC to peer: type, send, and the peer receives it.
        var draft = Find(window, "Draft").AsTextBox();
        draft.Text = FromPc;
        Click(window, "SendDraft");
        var received = PeerEvent("clipboard");
        Assert.Equal(FromPc, received.GetProperty("text").GetString());
    }

    private Window Launch(string theme, bool setupDone)
    {
        Directory.CreateDirectory(_data);
        File.WriteAllText(Path.Combine(_data, "settings.json"), JsonSerializer.Serialize(new Dictionary<string, object>
        {
            ["deviceName"] = "Bridgey CI PC",
            ["theme"] = theme,
            ["setupDone"] = setupDone,
            ["startAtSignIn"] = false,
        }));
        var start = new ProcessStartInfo(_exe) { UseShellExecute = false };
        start.Environment["BRIDGEY_DATA_DIR"] = _data;
        start.Environment["BRIDGEY_PORT"] = AppPort.ToString();
        _app = Application.Launch(start);
        var window = _app.GetMainWindow(_automation, Long) ?? throw new InvalidOperationException("Bridgey's window did not open");
        window.Focus();
        return window;
    }

    private void Quit()
    {
        if (_app is null) return;
        var quit = new ProcessStartInfo(_exe, "--quit") { UseShellExecute = false };
        quit.Environment["BRIDGEY_DATA_DIR"] = _data;
        Process.Start(quit)?.WaitForExit(10_000);
        for (var i = 0; i < 40 && !_app.HasExited; i++) Thread.Sleep(250);
        if (!_app.HasExited) _app.Kill();
        _app.Dispose();
        _app = null;
        Thread.Sleep(500);
    }

    private AutomationElement Find(Window window, string id) =>
        Retry.WhileNull(() => window.FindFirstDescendant(c => c.ByAutomationId(id)), Long, TimeSpan.FromMilliseconds(250)).Result
        ?? throw new InvalidOperationException($"{id} not found");

    private void Click(Window window, string id)
    {
        var element = Find(window, id);
        if (element.Patterns.Invoke.IsSupported) element.Patterns.Invoke.Pattern.Invoke();
        else if (element.Patterns.SelectionItem.IsSupported) element.Patterns.SelectionItem.Pattern.Select();
        else element.Click();
        Wait.UntilInputIsProcessed(TimeSpan.FromSeconds(1));
    }

    private void SelectSection(Window window, string title)
    {
        var list = Find(window, "SettingsSections");
        var item = Retry.WhileNull(() => list.FindFirstDescendant(c => c.ByName(title)), Long).Result ?? throw new InvalidOperationException($"{title} section not found");
        var row = item.Patterns.SelectionItem.IsSupported ? item : item.Parent;
        if (row.Patterns.SelectionItem.IsSupported) row.Patterns.SelectionItem.Pattern.Select();
        else row.Click();
        WaitFor(() => Find(window, "SettingsTitle").Name == title ? "ok" : null, $"the {title} section");
    }

    /// <summary>Opens the notification area menu through a second launch (<c>--tray-menu</c>) and captures it.</summary>
    private void TrayMenu(Window window, string name)
    {
        var bounds = window.BoundingRectangle;
        Mouse.Position = new System.Drawing.Point(bounds.X + bounds.Width / 2, bounds.Y + bounds.Height / 3);
        var open = new ProcessStartInfo(_exe, "--tray-menu") { UseShellExecute = false };
        open.Environment["BRIDGEY_DATA_DIR"] = _data;
        Process.Start(open)?.WaitForExit(10_000);
        var desktop = _automation.GetDesktop();
        var menu = Retry.WhileNull(() => desktop.FindFirstChild(c => c.ByClassName("#32768")), TimeSpan.FromSeconds(10)).Result;
        Assert.NotNull(menu);
        Assert.NotNull(menu!.FindFirstDescendant(c => c.ByName("Quit Bridgey")));
        Thread.Sleep(400);
        var r = menu.BoundingRectangle;
        Capture.Rectangle(new System.Drawing.Rectangle(r.X - 8, r.Y - 8, r.Width + 16, r.Height + 16)).ToFile(Path.Combine(_shots, name + ".png"));
        Keyboard.Press(VirtualKeyShort.ESCAPE);
        Wait.UntilInputIsProcessed(TimeSpan.FromSeconds(1));
    }

    private void Shot(Window window, string name)
    {
        // Let page and panel animations finish first.
        Thread.Sleep(700);
        Capture.Element(window).ToFile(Path.Combine(_shots, name + ".png"));
    }

    private void TryShot(string name)
    {
        try { Capture.Screen().ToFile(Path.Combine(_shots, name + ".png")); }
        catch (Exception) { }
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

    private void StartPeer()
    {
        var start = new ProcessStartInfo(_peerExe)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            ArgumentList = { "--name", PeerName, "--port", PeerPort.ToString(), "--allow", "--discover", "--send", FromPeer, "--seconds", "900" },
        };
        _peer = Process.Start(start) ?? throw new InvalidOperationException("peer did not start");
        _peer.OutputDataReceived += (_, e) =>
        {
            if (string.IsNullOrEmpty(e.Data)) return;
            lock (_peerLog) _peerLog.Add(e.Data);
            try { _peerEvents.Add(JsonDocument.Parse(e.Data).RootElement.Clone()); }
            catch (JsonException) { }
        };
        _peer.ErrorDataReceived += (_, e) =>
        {
            if (!string.IsNullOrEmpty(e.Data)) lock (_peerLog) _peerLog.Add("stderr: " + e.Data);
        };
        _peer.BeginOutputReadLine();
        _peer.BeginErrorReadLine();
        PeerEvent("ready");
    }

    private JsonElement PeerEvent(string kind)
    {
        var deadline = DateTime.UtcNow + Long;
        while (DateTime.UtcNow < deadline)
        {
            if (_peerEvents.TryTake(out var e, 250) && e.GetProperty("event").GetString() == kind) return e;
        }
        string log;
        lock (_peerLog) log = string.Join("\n", _peerLog);
        throw new TimeoutException($"The peer never reported {kind}. Its output:\n{log}");
    }

    private static string? ClipboardText()
    {
        if (!OpenClipboard(0)) return null;
        try
        {
            var handle = GetClipboardData(13 /* CF_UNICODETEXT */);
            if (handle == 0) return null;
            var pointer = GlobalLock(handle);
            try { return Marshal.PtrToStringUni(pointer); }
            finally { GlobalUnlock(handle); }
        }
        finally { CloseClipboard(); }
    }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool OpenClipboard(nint owner);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseClipboard();

    [LibraryImport("user32.dll")]
    private static partial nint GetClipboardData(uint format);

    [LibraryImport("kernel32.dll")]
    private static partial nint GlobalLock(nint handle);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GlobalUnlock(nint handle);

    public void Dispose()
    {
        try { Quit(); }
        catch (Exception) { }
        if (_peer is { HasExited: false }) _peer.Kill();
        _peer?.Dispose();
        _automation.Dispose();
        try { Directory.Delete(_data, true); }
        catch (Exception) { }
    }
}
