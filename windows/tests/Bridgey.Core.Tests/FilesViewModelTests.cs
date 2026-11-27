using Bridgey.ViewModels;
using Xunit;

namespace Bridgey.Tests;

/// <summary>Files, battery, find device and per-device switches in the view models, against the fake client.</summary>
public sealed class FilesViewModelTests
{
    private const string Phone = "11111111-1111-4111-8111-111111111111";
    private const string Mac = "22222222-2222-4222-8222-222222222222";
    private const string AllOn = """{"clipboard":true,"files":true,"battery":true,"find_device":true,"ping":true,"notifications":true,"links":true,"media":true}""";

    private readonly FakeClient _client = new();
    private readonly FakeAlerts _alerts = new();
    private readonly FakeFiles _files = new();

    private MainViewModel Model(bool twoDevices = false)
    {
        var local = new Dictionary<string, bool> { ["clipboard"] = true, ["files"] = true, ["battery"] = true, ["find_device"] = true, ["ping"] = true, ["notifications"] = true, ["links"] = true, ["media"] = true };
        _client.State.Devices.Add(new SnapshotDevice { DeviceId = Phone, Name = "Pixel 9", Platform = "android", Local = new(local) });
        if (twoDevices) _client.State.Devices.Add(new SnapshotDevice { DeviceId = Mac, Name = "MacBook", Platform = "macos", Local = new(local) });
        var settings = new SettingsViewModel(new AppSettings(), _ => { }, "Test PC") { DefaultReceiveFolder = @"C:\Users\test\Downloads\Bridgey" };
        return new MainViewModel(_client, settings, new InlineDispatcher(), new FakeClipboard(), _alerts, _files);
    }

    private static BridgeyEvent E(BridgeyEventKind kind, ulong id = 0, string? device = Phone, string? name = null, string? text = null, string? extra = null, int status = 0) =>
        new(kind, status, id, device, name, text, extra);

    private MainViewModel Connected(bool twoDevices = false)
    {
        var model = Model(twoDevices);
        foreach (var (id, name) in twoDevices ? new[] { (Phone, "Pixel 9"), (Mac, "MacBook") } : new[] { (Phone, "Pixel 9") })
        {
            _client.Emit(E(BridgeyEventKind.Connected, device: id, name: name));
            _client.Emit(E(BridgeyEventKind.Features, device: id, text: AllOn, extra: AllOn));
        }
        return model;
    }

    private static string Transfer(string state, string direction = "send", long bytes = 0, long total = 1000, string? path = null, string? reason = null, long rate = 0, string name = "photo.jpg") =>
        System.Text.Json.JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["request"] = 0, ["transferId"] = "t", ["deviceId"] = Phone, ["direction"] = direction, ["name"] = name, ["bytes"] = bytes,
            ["total"] = total, ["state"] = state, ["path"] = path, ["reason"] = reason, ["rate"] = rate,
        });

    [Fact]
    public void EverySwitchIsAppliedAsADefaultAtStart()
    {
        Model();
        foreach (var key in new[] { "clipboard", "files", "battery", "find_device", "ping" })
            Assert.Contains($"feature  {key} True", _client.Calls);
    }

    [Fact]
    public void SendingFilesAddsRowsThatFollowTheTransfer()
    {
        var model = Connected();
        var phone = model.Devices.Single();
        Assert.True(phone.FilesReady);
        Assert.True(model.CanSendFiles);
        model.SendFiles(phone, [@"C:\docs\photo.jpg", @"C:\docs\notes.txt"]);
        Assert.Equal(2, _client.Files.Count);
        var row = model.Activity.Single(a => a.Title == "photo.jpg to Pixel 9");
        Assert.Equal(TransferState.Queued, row.Transfer);
        Assert.True(row.IsActive);
        Assert.Equal("Waiting", row.Status);

        _client.Emit(E(BridgeyEventKind.Transfer, id: row.Request, text: Transfer("offered")));
        Assert.Equal("Waiting for Pixel 9", row.Status);
        _client.Emit(E(BridgeyEventKind.Transfer, id: row.Request, text: Transfer("sending", bytes: 250, rate: 2_500_000)));
        Assert.Equal(25, row.Progress);
        Assert.Equal("250 bytes of 1 KB, 2.5 MB/s", row.Status);
        Assert.True(row.IsDeterminate);
        row.Cancel();
        Assert.Contains($"cancel-transfer {row.Request}", _client.Calls);
        _client.Emit(E(BridgeyEventKind.Transfer, id: row.Request, text: Transfer("done", bytes: 1000)));
        Assert.False(row.IsActive);
        Assert.Equal("", row.Status);
        Assert.False(row.CanOpen, "a sent file has nothing to open here");
    }

    [Fact]
    public void AReceivedFileCanBeOpenedAndRaisesANotification()
    {
        var model = Connected();
        _client.Emit(E(BridgeyEventKind.Transfer, id: 900, text: Transfer("receiving", "receive", bytes: 500)));
        var row = model.Activity.Single();
        Assert.Equal("photo.jpg from Pixel 9", row.Title);
        Assert.Equal(ActivityDirection.Received, row.Direction);
        _client.Emit(E(BridgeyEventKind.Transfer, id: 900, text: Transfer("done", "receive", bytes: 1000, path: @"C:\Downloads\Bridgey\photo (1).jpg", name: "photo (1).jpg")));
        Assert.Equal("photo (1).jpg from Pixel 9", row.Title);
        Assert.True(row.CanOpen);
        row.Open();
        row.ShowInFolder();
        Assert.Equal([@"open C:\Downloads\Bridgey\photo (1).jpg", @"folder C:\Downloads\Bridgey\photo (1).jpg"], _files.Opened);
        Assert.Equal([@"photo (1).jpg from Pixel 9 at C:\Downloads\Bridgey\photo (1).jpg"], _alerts.Received);
    }

    [Theory]
    [InlineData("rejected", null, "Files is off on Pixel 9")]
    [InlineData("cancelled", "cancelled_remote", "Cancelled on Pixel 9")]
    [InlineData("interrupted", "disconnected", "The connection dropped")]
    [InlineData("failed", "hash_mismatch", "The file didn't arrive intact")]
    [InlineData("failed", "no_space", "Not enough free space")]
    [InlineData("failed", "stalled", "No answer from Pixel 9")]
    public void FailedTransfersSayWhy(string state, string? reason, string expected)
    {
        var model = Connected();
        _client.Emit(E(BridgeyEventKind.Transfer, id: 901, text: Transfer(state, reason: reason)));
        Assert.Equal(expected, model.Activity.Single().Status);
    }

    [Fact]
    public void RefusedFilesExplainThemselves()
    {
        var model = Connected();
        _client.FileError = BridgeyException.InvalidArgument;
        model.SendFiles(model.Devices.Single(), [@"C:\docs"]);
        Assert.Equal("Folders can't be sent yet. Choose files instead.", model.Notice);
        _client.FileError = BridgeyException.FeatureOff;
        model.SendFiles(model.Devices.Single(), [@"C:\docs\a.txt"]);
        Assert.Equal("Files is off on Pixel 9 or on this PC.", model.Notice);
    }

    [Fact]
    public void SendToGoesStraightToTheOnlyDeviceOrAsks()
    {
        var model = Connected();
        model.SendFilesFromShell([@"C:\a.txt"]);
        Assert.Equal(Phone, _client.Files.Single().Device);

        var two = new FilesViewModelTests();
        var both = two.Connected(twoDevices: true);
        IReadOnlyList<DeviceItem>? asked = null;
        both.ChooseDeviceForFiles += (_, devices) => asked = devices;
        both.SendFilesFromShell([@"C:\a.txt"]);
        Assert.Equal(2, asked!.Count);
        Assert.Empty(two._client.Files);
    }

    [Fact]
    public void BatteryShowsOnTheDeviceUntilItDisconnects()
    {
        var model = Connected();
        var phone = model.Devices.Single();
        _client.Emit(E(BridgeyEventKind.Battery, id: 1, status: 82));
        Assert.True(phone.HasBattery);
        Assert.Equal("82%, charging", phone.BatteryText);
        _client.Emit(E(BridgeyEventKind.Battery, id: 0, status: 41));
        Assert.Equal("41%", phone.BatteryText);
        _client.Emit(E(BridgeyEventKind.Disconnected, text: "heartbeat_timeout"));
        Assert.False(phone.HasBattery);
    }

    [Fact]
    public void ThisPcRingsUntilStoppedAndCanRingTheDevice()
    {
        var model = Connected();
        _client.Emit(E(BridgeyEventKind.FindRequested, status: 1));
        Assert.True(model.IsRinging);
        Assert.Equal("Pixel 9 is ringing this PC.", model.RingingText);
        Assert.Equal("Pixel 9", _alerts.RingingFor);
        model.StopRinging();
        Assert.False(model.IsRinging);
        Assert.Null(_alerts.RingingFor);
        Assert.Contains($"find-stopped {Phone}", _client.Calls);

        // Stopped from the phone: nothing more to tell it.
        _client.Emit(E(BridgeyEventKind.FindRequested, status: 1));
        _client.Calls.Clear();
        _client.Emit(E(BridgeyEventKind.FindRequested, status: 0));
        Assert.False(model.IsRinging);
        Assert.DoesNotContain($"find-stopped {Phone}", _client.Calls);

        var phone = model.Devices.Single();
        Assert.True(phone.FindReady);
        Assert.Equal("Ring", phone.RingText);
        phone.Ring();
        Assert.Contains($"find {Phone} True", _client.Calls);
        _client.Emit(E(BridgeyEventKind.FindState, status: 1));
        Assert.Equal("Stop ringing", phone.RingText);
        phone.Ring();
        Assert.Contains($"find {Phone} False", _client.Calls);
    }

    [Fact]
    public void PerDeviceSwitchesChangeOnlyThatDevice()
    {
        var model = Connected();
        var phone = model.Devices.Single();
        Assert.Equal(["Clipboard", "Files", "Battery", "Find device", "Ping", "Notifications", "Links", "Media controls", "Text messages", "Calls window", "Phone screen"], phone.Switches.Select(s => s.Title));
        // Text messages, the Calls window and Phone screen are off until chosen.
        Assert.All(phone.Switches.Where(s => s.Key is not ("sms_draft1" or "dialer_draft1" or "screen_draft1")), s => Assert.True(s.IsOn));
        Assert.False(phone.Switches.Single(s => s.Key == "screen_draft1").IsOn);
        Assert.False(phone.Switches.Single(s => s.Key == "sms_draft1").IsOn);
        Assert.False(phone.Switches.Single(s => s.Key == "dialer_draft1").IsOn);
        phone.Switches.Single(s => s.Key == "files").IsOn = false;
        Assert.Contains($"feature {Phone} files False", _client.Calls);
    }

    [Fact]
    public void TheReceiveFolderDefaultsToDownloadsAndCanChange()
    {
        var model = Model();
        Assert.Equal(@"C:\Users\test\Downloads\Bridgey", model.Settings.ReceiveFolder);
        Assert.True(model.Settings.ReceiveFolderIsDefault);
        model.Settings.ReceiveFolder = @"D:\Inbox";
        Assert.Contains(@"receive D:\Inbox", _client.Calls);
        Assert.False(model.Settings.ReceiveFolderIsDefault);
        model.Settings.ResetReceiveFolder();
        Assert.Contains(@"receive C:\Users\test\Downloads\Bridgey", _client.Calls);
    }

    [Theory]
    [InlineData(999, "999 bytes")]
    [InlineData(1, "1 byte")]
    [InlineData(640_000, "640 KB")]
    [InlineData(3_120_000, "3.1 MB")]
    [InlineData(2_500_000_000, "2.5 GB")]
    public void SizesReadPlainly(long bytes, string expected) => Assert.Equal(expected, ActivityItem.Size(bytes));
}

public sealed class ReceivedFilesTests
{
    [Theory]
    [InlineData("photo.jpg", true)]
    [InlineData("report.pdf", true)]
    [InlineData("notes", true)]
    [InlineData("setup.exe", false)]
    [InlineData("SETUP.EXE", false)]
    [InlineData("photo.jpg.exe", false)]
    [InlineData("setup.exe. . ", false)]
    [InlineData("run.bat", false)]
    [InlineData("script.ps1", false)]
    [InlineData("page.hta", false)]
    [InlineData("link.lnk", false)]
    [InlineData("site.url", false)]
    [InlineData("installer.msi", false)]
    [InlineData("disk.iso", false)]
    [InlineData("a.txt:evil.exe", false)]
    public void RunnableFilesAreShownNotOpened(string name, bool opens)
    {
        // Security review 1.0: a paired device chooses the name; one click on the toast must not run it.
        Assert.Equal(opens, ReceivedFiles.OpensDirectly(Path.Combine(Path.GetTempPath(), name)));
    }
}
