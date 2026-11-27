using System.Text.Json;
using System.Text.Json.Nodes;
using Bridgey.ViewModels;
using Xunit;

namespace Bridgey.Tests;

/// <summary>The phone screen window's view model against a fake session client, and the letterbox maths against display-v1.json.</summary>
public sealed class ScreenViewModelTests
{
    private const string Phone = "11111111-1111-4111-8111-111111111111";
    private const string Both = """{"clipboard":true,"screen_draft1":true,"phone_control_draft1":true}""";

    private readonly FakeClient _client = new();
    private readonly AppSettings _settings = new() { ShowPhoneScreens = true };
    private readonly List<PhoneScreenItem> _windows = new();

    private (MainViewModel Model, ScreenViewModel Screen) Connected()
    {
        _client.State.Devices.Add(new SnapshotDevice { DeviceId = Phone, Name = "Pixel 9", Platform = "android", Local = new() { ["clipboard"] = true, ["screen_draft1"] = true, ["phone_control_draft1"] = true } });
        _client.PhoneAnswers["request"] = """{"ok":true,"requestId":"8a5d9c3e-2b47-4f1a-9e60-7c1d2b3a4f5e"}""";
        _client.PhoneAnswers["touch"] = """{"ok":true,"taken":true}""";
        _client.PhoneAnswers["scroll"] = """{"ok":true,"taken":true}""";
        _client.PhoneAnswers["text"] = """{"ok":true,"taken":true}""";
        _client.PhoneAnswers["press"] = """{"ok":true,"taken":true}""";
        var model = new MainViewModel(_client, new SettingsViewModel(_settings, _ => { }, "Test PC"), new InlineDispatcher(), new FakeClipboard(), new FakeAlerts());
        model.Screen.WindowRequested += _windows.Add;
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Connected, 0, 0, Phone, "Pixel 9", null, null));
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Features, 0, 0, Phone, null, Both, Both));
        return (model, model.Screen);
    }

    private void Event(string what, string json, ulong id = 0) => _client.Emit(new BridgeyEvent(BridgeyEventKind.Screen, 0, id, Phone, what, json, null));

    private JsonNode Last(string op) => JsonNode.Parse(_client.PhoneCommands.Last(c => c.Area == PhoneArea.Screen && c.Command.Contains($"\"op\":\"{op}\"")).Command)!;

    private PhoneScreenItem Showing(bool controlling = true)
    {
        var (model, _) = Connected();
        model.Devices.Single().ShowScreen();
        Event("started", """{"stream":7,"width":720,"height":1600,"fps":3,"bitrate":1500000,"screenshots":true,"control":{"stream":7,"capable":true,"allowed":true,"phase":"off","input":{},"note":null}}""", 7);
        var item = model.Screen.Items.Single();
        if (controlling) Event("control", """{"stream":7,"capable":true,"allowed":true,"phase":"active","input":{"pointer":true,"touch":true,"keys":true,"text":true,"navigation":true},"note":null}""", 7);
        return item;
    }

    [Fact]
    public void Show_screen_opens_the_window_at_once_and_says_what_the_phone_needs()
    {
        var (model, screen) = Connected();
        var device = model.Devices.Single();
        Assert.True(device.ScreenReady);
        device.ShowScreen();
        var item = Assert.Single(_windows);
        Assert.Equal("Pixel 9's screen", item.Title);
        Assert.True(item.IsAsking);
        Assert.Equal("Asking Pixel 9 to share its screen…", item.Status);
        Event("status", """{"requestId":"8a5d9c3e-2b47-4f1a-9e60-7c1d2b3a4f5e","status":"waiting","needs":"unlock"}""");
        Assert.Equal("Unlock Pixel 9 to see its screen.", item.Status);
        Event("status", """{"requestId":"8a5d9c3e-2b47-4f1a-9e60-7c1d2b3a4f5e","status":"waiting","needs":"accessibility"}""");
        Assert.Contains("turn on Bridgey control", item.Status);
        Event("status", """{"requestId":"8a5d9c3e-2b47-4f1a-9e60-7c1d2b3a4f5e","status":"declined"}""");
        Assert.Equal("Pixel 9 didn't share its screen.", item.Status);
        Assert.False(item.IsAsking);
        Assert.Same(item, screen.Items.Single());
    }

    [Fact]
    public void A_stream_shows_slower_mode_stats_and_offers_control()
    {
        var item = Showing(controlling: false);
        Assert.True(item.IsShowing);
        Assert.False(item.HasStatus);
        Assert.Equal((720, 1600), (item.Width, item.Height));
        Assert.True(item.Screenshots);
        Assert.True(item.CanControl);
        Event("stats", """{"stream":7,"latencyMs":48,"rttMs":6,"bitrate":1500000,"sentBitrate":1400000,"fps":3,"dropped":0}""", 7);
        Assert.Equal("3 fps · 1.5 Mb/s · 48 ms", item.StatsText);
        item.BeginControl();
        Assert.Equal("control_begin", Last("control_begin")["op"]!.GetValue<string>());
        Event("control", """{"stream":7,"capable":true,"allowed":true,"phase":"waiting","input":{},"note":null}""", 7);
        Assert.Equal("Allow control on Pixel 9.", item.ControlText);
        Event("control", """{"stream":7,"capable":true,"allowed":true,"phase":"off","input":{},"note":"declined"}""", 7);
        Assert.Equal("Pixel 9 didn't allow control.", item.ControlText);
        Assert.True(item.CanControl);
    }

    [Fact]
    public void Touches_map_through_the_letterbox_and_get_their_own_fingers()
    {
        var item = Showing();
        Assert.True(item.IsControlling);
        Assert.Equal("Controlling", item.ControlText);
        // A view of 1000 by 1000: the 720 by 1600 picture is 450 wide, centred.
        Assert.False(item.Touch(1, "down", 1000, 1000, 100, 500), "a press on the letterbox sends nothing");
        Assert.True(item.Touch(1, "down", 1000, 1000, 500, 500));
        var down = Last("touch");
        Assert.Equal(0, down["contact"]!.GetValue<int>());
        Assert.Equal(0.5, down["x"]!.GetValue<double>(), 9);
        Assert.True(item.Touch(2, "down", 1000, 1000, 600, 250));
        Assert.Equal(1, Last("touch")["contact"]!.GetValue<int>());
        // A drag past the edge stays on it.
        Assert.True(item.Touch(1, "move", 1000, 1000, 2000, 500));
        Assert.Equal(1.0, Last("touch")["x"]!.GetValue<double>(), 9);
        Assert.True(item.Touch(1, "up", 1000, 1000, 500, 500));
        Assert.False(item.Touch(1, "move", 1000, 1000, 500, 500), "that finger is up");
        // The next press reuses the free finger.
        Assert.True(item.Touch(3, "down", 1000, 1000, 500, 500));
        Assert.Equal(0, Last("touch")["contact"]!.GetValue<int>());
    }

    [Fact]
    public void Scrolling_typing_keys_and_navigation()
    {
        var item = Showing();
        // 1000 by 1000 view, k = 0.625: 100 view pixels are 160 stream pixels.
        Assert.True(item.Scroll(1000, 1000, 500, 500, 0, 100));
        Assert.Equal(160, Last("scroll")["dy"]!.GetValue<double>());
        Assert.True(item.Type("Hello"));
        Assert.Equal("Hello", Last("text")["text"]!.GetValue<string>());
        Assert.True(item.Press("enter", shift: true));
        Assert.True(Last("press")["shift"]!.GetValue<bool>());
        item.Back();
        Assert.Equal("back", Last("navigate")["action"]!.GetValue<string>());
        // A rotation: gestures in progress are forgotten.
        item.Touch(1, "down", 1000, 1000, 500, 500);
        Event("geometry", """{"stream":7,"generation":2,"width":1600,"height":720}""", 7);
        Assert.Equal((1600, 720), (item.Width, item.Height));
        Assert.False(item.Touch(1, "up", 1000, 1000, 500, 500));
        // Without typing on the phone (Android 12), text and keys are not offered.
        Event("control", """{"stream":7,"capable":true,"allowed":true,"phase":"active","input":{"pointer":true,"touch":true,"navigation":true},"note":null}""", 7);
        Assert.False(item.CanType);
        Assert.False(item.Type("a"));
    }

    [Fact]
    public void Stopping_closes_and_the_phone_stopping_says_why()
    {
        var item = Showing();
        var closed = false;
        item.CloseRequested += () => closed = true;
        Event("stopped", """{"stream":7,"reason":"screen_off","by":"phone"}""", 7);
        Assert.Equal("Pixel 9 locked its screen.", item.Status);
        Assert.False(item.IsControlling);
        Assert.False(closed);
        item.Stop();
        Assert.Equal("stop", Last("stop")["op"]!.GetValue<string>());
        Event("started", """{"stream":8,"width":720,"height":1600,"fps":30,"bitrate":4000000,"screenshots":false,"control":{"stream":8,"capable":false,"allowed":false,"phase":"off","input":{},"note":null}}""", 8);
        Assert.False(item.Screenshots);
        Assert.False(item.CanControl);
        Event("stopped", """{"stream":8,"reason":"closed","by":"here"}""", 8);
        Assert.True(closed);
    }

    [Fact]
    public void Frames_come_from_the_pull_call()
    {
        var item = Showing(controlling: false);
        _client.ScreenFrames.Enqueue([0, 0, 0, 1, 0x65]);
        var buffer = new byte[16];
        Assert.Equal(1, item.TakeFrame(buffer, 100, out var length, out _, out var flags));
        Assert.Equal((5, 1u), (length, flags));
        Assert.Equal(BridgeyException.NotConnected, item.TakeFrame(buffer, 100, out _, out _, out _));
    }

    [Fact]
    public void Show_phone_screens_sets_seeing_and_control_together()
    {
        var (model, _) = Connected();
        model.Settings.ShowPhoneScreens = false;
        Assert.Contains("feature  screen_draft1 False", _client.Calls);
        Assert.Contains("feature  phone_control_draft1 False", _client.Calls);
        model.Devices.Single().Switches.Single(s => s.Key == "screen_draft1").IsOn = false;
        Assert.Contains($"feature {Phone} phone_control_draft1 False", _client.Calls);
    }

    /// <summary>The letterbox rules both viewers follow (protocol/test-vectors/display-v1.json "letterbox").</summary>
    [Fact]
    public void Letterbox_vectors()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "protocol", "test-vectors", "display-v1.json"))) dir = dir.Parent;
        Assert.NotNull(dir);
        using var vectors = JsonDocument.Parse(File.ReadAllText(Path.Combine(dir!.FullName, "protocol", "test-vectors", "display-v1.json")));
        var count = 0;
        foreach (var v in vectors.RootElement.GetProperty("letterbox").EnumerateArray())
        {
            double Get(string key, int i) => v.GetProperty(key)[i].GetDouble();
            var got = PhoneScreenItem.Fraction(Get("view", 0), Get("view", 1), (int)Get("video", 0), (int)Get("video", 1), Get("touch", 0), Get("touch", 1));
            if (v.GetProperty("expect").ValueKind == JsonValueKind.Null) Assert.Null(got);
            else
            {
                Assert.NotNull(got);
                Assert.Equal(Get("expect", 0), got!.Value.X, 9);
                Assert.Equal(Get("expect", 1), got!.Value.Y, 9);
            }
            count++;
        }
        Assert.True(count >= 8);
    }
}
