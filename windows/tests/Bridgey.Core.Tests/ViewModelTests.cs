using Bridgey.ViewModels;
using Xunit;

namespace Bridgey.Tests;

internal sealed class FakeClient : IBridgeyClient
{
    public string DeviceId => "00000000-0000-4000-8000-000000000001";
    public event Action<BridgeyEvent>? EventReceived;
    public Snapshot State = new();
    public readonly List<string> Calls = new();
    public readonly List<(string Device, string Text)> Sent = new();
    private ulong _next = 100;

    public void Emit(BridgeyEvent e) => EventReceived?.Invoke(e);

    public Snapshot Snapshot() => State;
    public void SetDeviceName(string name) => Calls.Add($"name {name}");
    public void AllowPairing(TimeSpan duration) => Calls.Add($"allow {duration.TotalSeconds}");
    public ulong Pair(string? deviceId, string? host, ushort port)
    {
        Calls.Add($"pair {deviceId} {host} {port}");
        return 7;
    }
    public void ConfirmPairing(ulong pairing, bool accept) => Calls.Add($"confirm {pairing} {accept}");
    public void CancelPairing(ulong pairing) => Calls.Add($"cancel {pairing}");
    public void Forget(string deviceId) => Calls.Add($"forget {deviceId}");
    public ulong SendClipboard(string deviceId, string text)
    {
        Sent.Add((deviceId, text));
        return ++_next;
    }
    public ulong Ping(string deviceId) => ++_next;
    public void SetFeature(string? deviceId, string key, bool on) => Calls.Add($"feature {deviceId} {key} {on}");
    public void AddDiscovered(string? deviceId, string? name, string? platform, string host, ushort port) { }
    public void NetworkChanged() { }
    public readonly List<(string Device, string Path)> Files = new();
    public int FileError;
    public void SetReceiveDir(string? folder) => Calls.Add($"receive {folder}");
    public ulong SendFile(string deviceId, string path)
    {
        if (FileError != 0) throw new BridgeyException(FileError);
        Files.Add((deviceId, path));
        return ++_next;
    }
    public void CancelTransfer(ulong request) => Calls.Add($"cancel-transfer {request}");
    public void SetBattery(int? level, bool charging) => Calls.Add($"battery {level} {charging}");
    public void Find(string deviceId, bool ring) => Calls.Add($"find {deviceId} {ring}");
    public void FindStopped(string deviceId) => Calls.Add($"find-stopped {deviceId}");
    public void DismissNotification(string deviceId, string notificationId) => Calls.Add($"dismiss {deviceId} {notificationId}");
    public void NotificationAction(string deviceId, string notificationId, string token, string? reply) => Calls.Add($"action {notificationId} {token} {reply}");
    public void SetCodes(bool sms, bool email) => Calls.Add($"codes {sms} {email}");
    public void CodesLinkRequest(string deviceId) => Calls.Add($"link {deviceId}");
    public void CodesAdvertiseResult(string deviceId, string serviceUuid, bool ok, string? reason) => Calls.Add($"advertised {serviceUuid} {ok} {reason}");
    public void SetPresence(PresenceState state, uint idleSeconds) => Calls.Add($"presence {state} {idleSeconds}");
    public ulong SendLink(string deviceId, string url)
    {
        Calls.Add($"link-send {url}");
        return ++_next;
    }
    public void SetLinksOpen(bool on) => Calls.Add($"links-open {on}");
    public void MediaResult(string deviceId, string requestId, bool accepted) => Calls.Add($"media-result {requestId} {accepted}");
    public void SetMediaState(string? json) => Calls.Add($"media-state {(json is null ? "none" : json.Contains("\"title\":\"Song\"") ? "song" : "other")}");
    public void SetConnect(bool on, string? controlUrl) => Calls.Add($"connect {on} {controlUrl}");
    /// <summary>Phone commands (area, device, JSON), and what each op answers (default: ok).</summary>
    public readonly List<(PhoneArea Area, string Device, string Command)> PhoneCommands = new();
    public readonly Dictionary<string, string> PhoneAnswers = new();
    public string Phone(PhoneArea area, string deviceId, string command)
    {
        PhoneCommands.Add((area, deviceId, command));
        var op = System.Text.Json.Nodes.JsonNode.Parse(command)?["op"]?.GetValue<string>() ?? "";
        return PhoneAnswers.TryGetValue(op, out var answer) ? answer : "{\"ok\":true}";
    }
    /// <summary>Frames the fake hands out for <see cref="ScreenFrame"/>, then the end of the stream.</summary>
    public readonly Queue<byte[]> ScreenFrames = new();
    public int ScreenFrame(ulong stream, uint timeoutMs, byte[] buffer, out int length, out long captureMicros, out uint flags)
    {
        captureMicros = 0;
        flags = 0;
        length = 0;
        if (!ScreenFrames.TryDequeue(out var frame)) return BridgeyException.NotConnected;
        if (frame.Length > buffer.Length)
        {
            length = frame.Length;
            return BridgeyException.TooLarge;
        }
        frame.CopyTo(buffer, 0);
        length = frame.Length;
        flags = 1;
        return 1;
    }
    public void Dispose() { }
}

internal sealed class FakeFiles : IFileService
{
    public readonly List<string> Opened = new();
    public void Open(string path) => Opened.Add("open " + path);
    public void ShowInFolder(string path) => Opened.Add("folder " + path);
}

internal sealed class FakeClipboard : IClipboardService
{
    public string? Text;
    public void SetText(string text) => Text = text;
}

internal sealed class FakeAlerts : IAlertService
{
    public readonly List<string> Pings = new();
    public readonly List<string> Received = new();
    public string? RingingFor;
    public void Ping(string deviceName) => Pings.Add(deviceName);
    public void FileReceived(string deviceName, string fileName, string path) => Received.Add($"{fileName} from {deviceName} at {path}");
    public void StartRinging(string deviceName) => RingingFor = deviceName;
    public void StopRinging() => RingingFor = null;
}

public sealed class ViewModelTests
{
    private const string Phone = "11111111-1111-4111-8111-111111111111";
    private const string On = """{"clipboard":true,"ping":true}""";

    private readonly FakeClient _client = new();
    private readonly FakeClipboard _clipboard = new();
    private readonly FakeAlerts _alerts = new();
    private readonly FakeFiles _files = new();
    private readonly AppSettings _settings = new();

    private MainViewModel Model()
    {
        _client.State.Devices.Add(new SnapshotDevice { DeviceId = Phone, Name = "Pixel 9", Platform = "android", Local = new() { ["clipboard"] = true, ["ping"] = true } });
        return new MainViewModel(_client, new SettingsViewModel(_settings, _ => { }, "Test PC"), new InlineDispatcher(), _clipboard, _alerts, _files);
    }

    private static BridgeyEvent E(BridgeyEventKind kind, ulong id = 0, string? device = Phone, string? name = null, string? text = null, string? extra = null, int status = 0) =>
        new(kind, status, id, device, name, text, extra);

    private MainViewModel Connected()
    {
        var model = Model();
        _client.Emit(E(BridgeyEventKind.Connected, name: "Pixel 9"));
        _client.Emit(E(BridgeyEventKind.Features, text: On, extra: On));
        return model;
    }

    [Fact]
    public void ConnectedDeviceIsReadyForClipboardOnlyWhenBothSidesAllowIt()
    {
        var model = Model();
        var device = Assert.Single(model.Devices);
        Assert.False(device.IsConnected);
        Assert.Equal("No devices connected", model.StatusText);
        _client.Emit(E(BridgeyEventKind.Connected, name: "Pixel 9"));
        Assert.True(device.IsConnected);
        Assert.False(device.ClipboardReady);
        _client.Emit(E(BridgeyEventKind.Features, text: On, extra: """{"clipboard":false}"""));
        Assert.False(device.ClipboardReady);
        _client.Emit(E(BridgeyEventKind.Features, text: On, extra: On));
        Assert.True(device.ClipboardReady);
        Assert.Equal("Connected to Pixel 9", model.StatusText);
        Assert.Same(device, model.Target);
        _client.Emit(E(BridgeyEventKind.Disconnected, text: "heartbeat_timeout"));
        Assert.False(device.ClipboardReady);
        Assert.Equal("Not connected", device.Status);
    }

    [Fact]
    public void ReceivedTextGoesOnTheClipboardAndIntoActivity()
    {
        var model = Connected();
        _client.Emit(E(BridgeyEventKind.Clipboard, text: "  one\n two  "));
        Assert.Equal("  one\n two  ", _clipboard.Text);
        var row = Assert.Single(model.Activity);
        Assert.Equal("Text from Pixel 9", row.Title);
        Assert.Equal("one two", row.Preview);
        Assert.Equal(ActivityDirection.Received, row.Direction);

        model.Settings.ShowPreviews = false;
        _client.Emit(E(BridgeyEventKind.Clipboard, text: "secret"));
        Assert.Equal("", model.Activity[0].Preview);
    }

    [Fact]
    public void SendBoxSendsToTheTargetAndShowsTheResult()
    {
        var model = Connected();
        Assert.False(model.CanSendDraft);
        model.Draft = "hello";
        Assert.True(model.CanSendDraft);
        model.SendDraft();
        Assert.Equal((Phone, "hello"), Assert.Single(_client.Sent));
        Assert.Equal("", model.Draft);
        var row = Assert.Single(model.Activity);
        Assert.Equal("Sending", row.Status);
        _client.Emit(E(BridgeyEventKind.ClipboardSent, id: row.Request, status: (int)SendStatus.Delivered));
        Assert.Equal("", row.Status);
        model.Draft = "again";
        model.SendDraft();
        _client.Emit(E(BridgeyEventKind.ClipboardSent, id: model.Activity[0].Request, status: (int)SendStatus.Rejected));
        Assert.Equal("Clipboard is off on that device", model.Activity[0].Status);
    }

    [Fact]
    public async Task AutomaticClipboardIsOffByDefaultAndSkipsPrivateAndEchoedText()
    {
        var model = Connected();
        Assert.False(model.Settings.AutomaticClipboard);
        model.LocalCopy("copied", privateContent: false);
        await Task.Delay(500, TestContext.Current.CancellationToken);
        Assert.Empty(_client.Sent);

        model.Settings.AutomaticClipboard = true;
        model.LocalCopy("password", privateContent: true);
        _client.Emit(E(BridgeyEventKind.Clipboard, text: "from the phone"));
        model.LocalCopy("from the phone", privateContent: false);
        await Task.Delay(500, TestContext.Current.CancellationToken);
        Assert.Empty(_client.Sent);

        model.LocalCopy("first", privateContent: false);
        model.LocalCopy("second", privateContent: false);
        await Task.Delay(700, TestContext.Current.CancellationToken);
        Assert.Equal((Phone, "second"), Assert.Single(_client.Sent));
        Assert.Equal("Text to Pixel 9, automatically", model.Activity[0].Title);
    }

    [Fact]
    public void PairingGoesFromConnectingThroughTheCodeToPaired()
    {
        var model = Model();
        var pairing = model.Pairing;
        pairing.Opened();
        Assert.Contains("allow 120", _client.Calls);
        pairing.Address = "192.168.1.20";
        Assert.True(pairing.CanPairByAddress);
        pairing.PairByAddress();
        Assert.Equal(PairingState.Connecting, pairing.State);
        Assert.Contains("pair  192.168.1.20 0", _client.Calls);

        _client.Emit(E(BridgeyEventKind.PairingWaiting, id: 7, device: null, name: "MacBook"));
        Assert.Equal(PairingState.Waiting, pairing.State);
        _client.Emit(E(BridgeyEventKind.PairingCode, id: 7, name: "MacBook", text: "482913"));
        Assert.Equal(PairingState.Code, pairing.State);
        Assert.Equal("482 913", pairing.Code);
        pairing.Confirm();
        Assert.Contains("confirm 7 True", _client.Calls);
        _client.Emit(E(BridgeyEventKind.PairingFinished, id: 7, name: "MacBook", text: "paired"));
        Assert.Equal(PairingState.Done, pairing.State);
        Assert.Equal("Paired with MacBook", pairing.Title);
        pairing.Closed();
        Assert.Contains("allow 0", _client.Calls);
        Assert.Equal(PairingState.Choose, pairing.State);
    }

    [Fact]
    public void AFailedPairingSaysWhyInPlainWords()
    {
        var model = Model();
        model.Pairing.Address = "10.0.0.2:42460";
        model.Pairing.PairByAddress();
        _client.Emit(E(BridgeyEventKind.PairingFinished, id: 7, device: null, name: "10.0.0.2", text: "unreachable", status: 1));
        Assert.Equal(PairingState.Failed, model.Pairing.State);
        Assert.StartsWith("Bridgey couldn't reach that device", model.Pairing.Message);
        Assert.Equal("The codes didn't match, so nothing was paired.", PairingViewModel.Reason("cancelled_remote:mismatch", "x"));
        Assert.Equal("MacBook needs a newer Bridgey to pair. Update it, then try again.", PairingViewModel.Reason("needs_protocol_2", "MacBook"));
    }

    [Fact]
    public void AnotherDevicesRequestIsShownUntilAllowed()
    {
        var model = Model();
        _client.Emit(E(BridgeyEventKind.PairingRequest, name: "Pixel 9"));
        Assert.True(model.HasPairingRequest);
        Assert.Equal("Pixel 9 wants to pair with this PC.", model.PairingRequestText);
        model.AllowPairingRequest();
        Assert.False(model.HasPairingRequest);
        Assert.Contains("allow 120", _client.Calls);
    }

    [Fact]
    public void PingsPlayASoundAndNearbyDevicesAreListedOnce()
    {
        var model = Connected();
        _client.Emit(E(BridgeyEventKind.Ping));
        Assert.Equal(["Pixel 9"], _alerts.Pings);
        const string mac = "22222222-2222-4222-8222-222222222222";
        _client.Emit(E(BridgeyEventKind.DeviceFound, device: mac, name: "MacBook", text: "192.168.1.5", extra: "macos", status: 42458));
        _client.Emit(E(BridgeyEventKind.DeviceFound, device: mac, name: "MacBook", text: "192.168.1.5", extra: "macos", status: 42458));
        var nearby = Assert.Single(model.Nearby);
        Assert.Equal("Mac", nearby.Detail);
        nearby.Pair();
        Assert.Contains($"pair {mac} 192.168.1.5 42458", _client.Calls);
        _client.Emit(E(BridgeyEventKind.DeviceLost, device: mac, text: "192.168.1.5"));
        Assert.Empty(model.Nearby);
    }

    [Fact]
    public void SettingsSaveAndTellTheClient()
    {
        AppSettings? saved = null;
        var settings = new SettingsViewModel(_settings, s => saved = s, "Test PC");
        var model = new MainViewModel(_client, settings, new InlineDispatcher(), _clipboard, _alerts);
        Assert.Equal("Test PC", settings.DeviceName);
        settings.DeviceName = "Rahul's PC";
        Assert.Contains("name Rahul's PC", _client.Calls);
        Assert.Equal("Rahul's PC", saved!.DeviceName);
        settings.Clipboard = false;
        Assert.Contains("feature  clipboard False", _client.Calls);
        settings.ThemeIndex = 2;
        Assert.Equal(AppTheme.Dark, saved.Theme);
        Assert.Equal(14, SettingsViewModel.Sections.Count);
        Assert.Equal("About", SettingsViewModel.Sections[^1].Title);
        model.Dispose();
    }

    [Theory]
    [InlineData("192.168.1.20", "192.168.1.20", 0)]
    [InlineData("100.101.102.103:42458", "100.101.102.103", 42458)]
    [InlineData("[fd7a:115c:a1e0::1]:42460", "fd7a:115c:a1e0::1", 42460)]
    [InlineData("fd7a:115c:a1e0::1", "fd7a:115c:a1e0::1", 0)]
    public void AddressesParse(string text, string host, int port)
    {
        Assert.True(PairingViewModel.TryParseAddress(text, out var h, out var p));
        Assert.Equal((host, (ushort)port), (h, p));
    }

    [Theory]
    [InlineData("")]
    [InlineData("pixel.local")]
    [InlineData("1.2.3.4:99999")]
    public void BadAddressesDoNot(string text) => Assert.False(PairingViewModel.TryParseAddress(text, out _, out _));
}

public sealed class VersionTests
{
    [Theory]
    [InlineData("1.0.0-beta.1", "1.0 Beta 1")]
    [InlineData("1.0.0", "1.0")]
    [InlineData("1.0.1", "1.0.1")]
    [InlineData("1.1.0-nightly.20261116", "1.1 Nightly 16 Nov")]
    [InlineData("0.11.0-rr.1-beta.3", "0.11.0-rr.1 Beta 3")]
    [InlineData("0.9.0-rr.2", "0.9.0-rr.2")]
    [InlineData("1.0.0-dev", "1.0.0-dev")]
    public void LabelsMatchTheOtherApps(string name, string label) => Assert.Equal(label, Versions.Display(name));

    [Fact]
    public void EditionComesFromTheEditionFile()
    {
        Assert.Equal("Bridgey by Round Robin", Edition.DisplayName);
        Assert.Matches(@"^\d+\.\d+\.\d+$", Edition.NextVersion);
        Assert.Matches(@"^\d{9}$", Edition.BuildNumber);
        Assert.StartsWith(Edition.NextVersion, Edition.VersionName);
    }

    [Fact]
    public void SettingsRoundTripAndSurviveABadFile()
    {
        var folder = Path.Combine(Path.GetTempPath(), "bridgey-settings-" + Guid.NewGuid());
        var store = new SettingsStore(folder);
        Assert.False(store.Load().AutomaticClipboard);
        Assert.True(store.Load().StartAtSignIn);
        store.Save(new AppSettings { Theme = AppTheme.Dark, AutomaticClipboard = true, SetupDone = true });
        var back = store.Load();
        Assert.Equal((AppTheme.Dark, true, true), (back.Theme, back.AutomaticClipboard, back.SetupDone));
        Assert.Contains("\"theme\": \"Dark\"", File.ReadAllText(Path.Combine(folder, "settings.json")));
        File.WriteAllText(Path.Combine(folder, "settings.json"), "{not json");
        Assert.Equal(AppTheme.System, store.Load().Theme);
        Directory.Delete(folder, true);
    }
}
