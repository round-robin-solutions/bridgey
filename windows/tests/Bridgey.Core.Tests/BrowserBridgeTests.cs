using System.Text;
using System.Text.Json;
using Bridgey.ViewModels;
using Xunit;

namespace Bridgey.Tests;

/// <summary>Browser support (BrowserBridge.cs, BrowserRequests.cs): requests, addresses, replies, manifests and the link path.</summary>
public sealed class BrowserBridgeTests
{
    private const string Phone = "11111111-1111-4111-8111-111111111111";
    private const string Mac = "22222222-2222-4222-8222-222222222222";
    private readonly FakeClient _client = new();

    private static BrowserHostRequest? Parse(string line) => BrowserHostRequest.Parse(Encoding.UTF8.GetBytes(line));

    private static JsonElement Json(byte[] line)
    {
        Assert.Equal((byte)'\n', line[^1]);
        return JsonDocument.Parse(line.AsMemory(0, line.Length - 1)).RootElement.Clone();
    }

    [Fact]
    public void RequestsAreStrict()
    {
        Assert.IsType<BrowserHostRequest.Devices>(Parse("""{"version":1,"type":"devices"}"""));
        var send = Assert.IsType<BrowserHostRequest.Send>(Parse("""{"version":1,"type":"send","device":"d-1","url":"https://example.com/a?b#c"}"""));
        Assert.Equal(new BrowserAddress(BrowserAddressKind.Web, "https://example.com/a?b#c"), send.Address);
        foreach (var bad in new[]
        {
            """{"version":2,"type":"devices"}""",
            """{"version":"1","type":"devices"}""",
            """{"version":1.5,"type":"devices"}""",
            """{"version":1,"type":"devices","extra":1}""",
            """{"version":1,"type":"devices","type":"devices"}""",
            """{"version":1,"type":"devices","x":{"y":1}}""",
            """{"version":1,"type":"send","device":"d"}""",
            """{"version":1,"type":"send","device":"a b","url":"https://a.b/"}""",
            """{"version":1,"type":"send","device":5,"url":"https://a.b/"}""",
            """{"version":1,"type":"send","device":"d","url":"file:///etc/hosts"}""",
            """{"version":1,"type":"open","device":"d","url":"https://a.b/"}""",
            """{"version":1,"type":"devices"} trailing""",
            "[1]",
            "not json",
        })
        {
            Assert.Null(Parse(bad));
        }
        Assert.Null(BrowserHostRequest.Parse(new byte[BrowserHostRequest.MaxBytes + 1]));
    }

    [Fact]
    public void Addresses()
    {
        Assert.Equal(new BrowserAddress(BrowserAddressKind.Tel, "+442079460958"), BrowserAddress.Parse("tel:+44%2020%207946%200958"));
        Assert.Equal(new BrowserAddress(BrowserAddressKind.Tel, "+15551234567"), BrowserAddress.Parse("tel:+1-555-123-4567;ext=2"));
        Assert.Equal(new BrowserAddress(BrowserAddressKind.Mailto, "hello@roundrobin.in"), BrowserAddress.Parse("mailto:hello@roundrobin.in?subject=Hi"));
        Assert.Equal(new BrowserAddress(BrowserAddressKind.Mailto, "a@b.c, d@e.f"), BrowserAddress.Parse("MAILTO:a@b.c,d%40e.f"));
        foreach (var bad in new[]
        {
            "", "https://user:pass@example.com/", "https://exa mple.com/", "https://example.com\\@evil", "javascript:alert(1)",
            "ftp://example.com/", "tel:12", "tel:12+34", "tel:%0A123", "mailto:", "mailto:nobody", "mailto:<a@b>",
            "https://example.com/" + new string('a', 4096),
        })
        {
            Assert.Null(BrowserAddress.Parse(bad));
        }
    }

    [Fact]
    public void RepliesCarryOnlyTheListedFields()
    {
        var devices = Json(BrowserHostReply.Devices([new BrowserDevice(Phone, "Pixel 9", "android", true, true, false)]));
        Assert.Equal(1, devices.GetProperty("version").GetInt32());
        Assert.True(devices.GetProperty("ok").GetBoolean());
        var first = devices.GetProperty("devices")[0];
        Assert.Equal(["calls", "connected", "id", "links", "name", "platform"], first.EnumerateObject().Select(p => p.Name).ToArray());
        Assert.Equal("""{"ok":true,"result":"waiting","version":1}""" + "\n", Encoding.UTF8.GetString(BrowserHostReply.Sent("waiting")));
        Assert.Equal("""{"error":"links_off","ok":false,"version":1}""" + "\n", Encoding.UTF8.GetString(BrowserHostReply.Error("links_off")));
    }

    [Fact]
    public void ManifestsAndRegistryKeys()
    {
        var config = BrowserHostConfig.Load(Path.Combine(RepoRoot(), "extensions", "browser", "native-host.json"));
        Assert.NotNull(config);
        Assert.Equal(["aajelmcjgfjbhemgofnompobgbcdfcin"], config.ChromiumIds);
        Assert.Equal(["bridgey@roundrobin.in"], config.FirefoxIds);
        var helper = @"C:\Users\a\AppData\Local\Programs\Bridgey by Round Robin\bridgey-browser-host.exe";
        var chromium = JsonDocument.Parse(BrowserRegistration.Manifest(config, helper, firefox: false)).RootElement;
        Assert.Equal("in.roundrobin.bridgey", chromium.GetProperty("name").GetString());
        Assert.Equal(helper, chromium.GetProperty("path").GetString());
        Assert.Equal("stdio", chromium.GetProperty("type").GetString());
        Assert.Equal("chrome-extension://aajelmcjgfjbhemgofnompobgbcdfcin/", chromium.GetProperty("allowed_origins")[0].GetString());
        Assert.False(chromium.TryGetProperty("allowed_extensions", out _));
        var firefox = JsonDocument.Parse(BrowserRegistration.Manifest(config, helper, firefox: true)).RootElement;
        Assert.Equal("bridgey@roundrobin.in", firefox.GetProperty("allowed_extensions")[0].GetString());
        Assert.False(firefox.TryGetProperty("allowed_origins", out _));
        Assert.Contains(BrowserRegistration.Keys, k => k.Key == @"Software\Google\Chrome\NativeMessagingHosts\in.roundrobin.bridgey" && !k.Firefox);
        Assert.Contains(BrowserRegistration.Keys, k => k.Key == @"Software\Microsoft\Edge\NativeMessagingHosts\in.roundrobin.bridgey" && !k.Firefox);
        Assert.Contains(BrowserRegistration.Keys, k => k.Key == @"Software\Mozilla\NativeMessagingHosts\in.roundrobin.bridgey" && k.Firefox);
        Assert.All(BrowserRegistration.Keys, k => Assert.StartsWith(@"Software\", k.Key));
        Assert.Equal("in.roundrobin.bridgey.browser.S-1-5-21-1-2-3-1001", BrowserRegistration.PipeName("S-1-5-21-1-2-3-1001"));
    }

    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "rr-edition.properties"))) dir = dir.Parent;
        return dir?.FullName ?? throw new InvalidOperationException("repository root not found");
    }

    private MainViewModel Connected()
    {
        _client.State.Devices.Add(new SnapshotDevice { DeviceId = Phone, Name = "Pixel 9", Platform = "android", Local = new() { ["links"] = true, ["clipboard"] = true } });
        _client.State.Devices.Add(new SnapshotDevice { DeviceId = Mac, Name = "Work Mac", Platform = "macos", Local = new() { ["links"] = true } });
        var model = new MainViewModel(_client, new SettingsViewModel(new AppSettings(), _ => { }, "Test PC"), new InlineDispatcher(), new FakeClipboard(), new FakeAlerts(),
            new FakeFiles(), null, null, null, new FakeLinks(), new FakeMedia());
        const string on = """{"clipboard":true,"links":true}""";
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Connected, 0, 0, Phone, "Pixel 9", null, null));
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Features, 0, 0, Phone, null, on, on));
        return model;
    }

    [Fact]
    public async Task DevicesAndLinksGoThroughTheAppsOwnPaths()
    {
        var model = Connected();
        var list = Json(await model.HandleBrowserRequest(new BrowserHostRequest.Devices())).GetProperty("devices");
        Assert.Equal(2, list.GetArrayLength());
        Assert.Equal("Pixel 9", list[0].GetProperty("name").GetString());
        Assert.True(list[0].GetProperty("connected").GetBoolean());
        Assert.True(list[0].GetProperty("links").GetBoolean());
        Assert.False(list[1].GetProperty("connected").GetBoolean());

        var pending = model.HandleBrowserRequest(new BrowserHostRequest.Send(Phone, new BrowserAddress(BrowserAddressKind.Web, "https://roundrobin.in/bridgey")));
        Assert.False(pending.IsCompleted);
        Assert.Contains("link-send https://roundrobin.in/bridgey", _client.Calls);
        Assert.Contains(model.Activity, a => a.Title == "Link to Pixel 9");
        _client.Emit(new BridgeyEvent(BridgeyEventKind.LinkSent, (int)SendStatus.Delivered, 101, Phone, null, "opened", null));
        Assert.Equal("opened", Json(await pending).GetProperty("result").GetString());

        pending = model.HandleBrowserRequest(new BrowserHostRequest.Send(Phone, new BrowserAddress(BrowserAddressKind.Web, "https://example.com/")));
        _client.Emit(new BridgeyEvent(BridgeyEventKind.LinkSent, (int)SendStatus.Delivered, 102, Phone, null, null, null));
        Assert.Equal("waiting", Json(await pending).GetProperty("result").GetString());
        pending = model.HandleBrowserRequest(new BrowserHostRequest.Send(Phone, new BrowserAddress(BrowserAddressKind.Web, "https://example.com/")));
        _client.Emit(new BridgeyEvent(BridgeyEventKind.LinkSent, (int)SendStatus.TimedOut, 103, Phone, null, null, null));
        Assert.Equal("no_answer", Json(await pending).GetProperty("error").GetString());

        var copied = Json(await model.HandleBrowserRequest(new BrowserHostRequest.Send(Phone, new BrowserAddress(BrowserAddressKind.Mailto, "hello@roundrobin.in"))));
        Assert.Equal("copied", copied.GetProperty("result").GetString());
        Assert.Contains((Phone, "hello@roundrobin.in"), _client.Sent);
    }

    [Fact]
    public async Task RefusalsSayWhy()
    {
        var model = Connected();
        async Task<string> Error(BrowserHostRequest request) => Json(await model.HandleBrowserRequest(request)).GetProperty("error").GetString()!;
        var web = new BrowserAddress(BrowserAddressKind.Web, "https://example.com/");
        Assert.Equal("unknown_device", await Error(new BrowserHostRequest.Send("33333333-3333-4333-8333-333333333333", web)));
        Assert.Equal("not_connected", await Error(new BrowserHostRequest.Send(Mac, web)));
        Assert.Equal("calls_off", await Error(new BrowserHostRequest.Send(Phone, new BrowserAddress(BrowserAddressKind.Tel, "+442079460958"))));
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Features, 0, 0, Phone, null, """{"clipboard":true,"links":true}""", """{"clipboard":false,"links":false}"""));
        Assert.Equal("links_off", await Error(new BrowserHostRequest.Send(Phone, web)));
        Assert.Equal("unsupported", await Error(new BrowserHostRequest.Send(Phone, new BrowserAddress(BrowserAddressKind.Mailto, "a@b.c"))));
        Assert.DoesNotContain(_client.Calls, c => c.StartsWith("link-send", StringComparison.Ordinal));
    }

    [Fact]
    public void TheSettingSavesAndSaysWhatItDoes()
    {
        var saved = 0;
        var settings = new SettingsViewModel(new AppSettings(), _ => saved++, "Test PC");
        Assert.False(settings.BrowserSupport);
        Assert.Equal(SettingsViewModel.BrowserSupportOff, settings.BrowserSupportStatus);
        bool? changed = null;
        settings.BrowserSupportChanged += on => changed = on;
        settings.BrowserSupport = true;
        Assert.True(changed);
        Assert.True(settings.Values.BrowserSupport);
        Assert.Equal(1, saved);
    }
}
