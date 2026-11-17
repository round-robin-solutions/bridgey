using Bridgey.ViewModels;
using Xunit;

namespace Bridgey.Tests;

internal sealed class FakeLinks : ILinkOpener
{
    public readonly List<string> Opened = new();
    public bool Open(string url)
    {
        Opened.Add(url);
        return true;
    }
}

internal sealed class FakeMedia : IMediaHost
{
    public event Action<MediaState?>? Changed;
    public bool Running;
    public readonly List<string> Commands = new();
    public void Start() => Running = true;
    public void Stop() => Running = false;
    public Task<bool> RunAsync(string action, long? value)
    {
        Commands.Add($"{action} {value}");
        return Task.FromResult(action != "volume");
    }
    public void Report(MediaState? state) => Changed?.Invoke(state);
}

/// <summary>Links both ways, the phone's media controls and Connect away from home in the view models.</summary>
public sealed class LinksMediaConnectTests
{
    private const string Phone = "11111111-1111-4111-8111-111111111111";
    private const string On = """{"clipboard":true,"links":true,"media":true}""";
    private readonly FakeClient _client = new();
    private readonly FakeLinks _links = new();
    private readonly FakeMedia _media = new();
    private readonly AppSettings _settings = new();

    private MainViewModel Connected()
    {
        _client.State.Devices.Add(new SnapshotDevice { DeviceId = Phone, Name = "Pixel 9", Platform = "android", Local = new() { ["links"] = true, ["media"] = true } });
        var model = new MainViewModel(_client, new SettingsViewModel(_settings, _ => { }, "Test PC"), new InlineDispatcher(), new FakeClipboard(), new FakeAlerts(),
            new FakeFiles(), null, null, null, _links, _media);
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Connected, 0, 0, Phone, "Pixel 9", null, null));
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Features, 0, 0, Phone, null, On, On));
        return model;
    }

    private void Emit(BridgeyEventKind kind, ulong id = 0, string? name = null, string? text = null, int status = 0) => _client.Emit(new BridgeyEvent(kind, status, id, Phone, name, text, null));

    [Fact]
    public void LinksOpenRightAwayOrWaitOnHome()
    {
        var model = Connected();
        Assert.Contains("links-open True", _client.Calls);
        Assert.Contains("feature  links_open_draft1 True", _client.Calls);
        Emit(BridgeyEventKind.Link, text: "https://example.com/now", status: 1);
        Assert.Equal(["https://example.com/now"], _links.Opened);
        Assert.False(model.HasPendingLink);
        Emit(BridgeyEventKind.Link, text: "https://example.com/later");
        Assert.True(model.HasPendingLink);
        Assert.Equal("Pixel 9 sent a link: https://example.com/later", model.PendingLinkText);
        model.OpenPendingLink();
        Assert.Contains("https://example.com/later", _links.Opened);
        Assert.False(model.HasPendingLink);
        model.Settings.OpenLinksRightAway = false;
        Assert.Contains("links-open False", _client.Calls);
    }

    [Fact]
    public void ALinkInTheSendBoxGoesAsALink()
    {
        var model = Connected();
        model.Draft = "hello";
        Assert.False(model.CanSendLink);
        model.Draft = "https://roundrobin.in/bridgey";
        Assert.True(model.CanSendLink);
        model.SendDraftAsLink();
        Assert.Contains("link-send https://roundrobin.in/bridgey", _client.Calls);
        Assert.Equal("", model.Draft);
        var row = model.Activity.First();
        Assert.Equal("Link to Pixel 9", row.Title);
        Emit(BridgeyEventKind.LinkSent, id: row.Request, status: (int)SendStatus.Delivered);
        Assert.Equal("", row.Status);
        Assert.False(MainViewModel.IsWebLink("https://user:pw@example.com"));
        Assert.False(MainViewModel.IsWebLink("ftp://example.com"));
    }

    [Fact]
    public async Task MediaControlsAreOffUntilChosenThenRunOnThePlayer()
    {
        var model = Connected();
        Assert.False(_media.Running);
        Assert.Contains("feature  media False", _client.Calls);
        Emit(BridgeyEventKind.MediaCommand, id: 0, name: "toggle", text: "req-1");
        await Task.Delay(50, TestContext.Current.CancellationToken);
        Assert.Contains("media-result req-1 False", _client.Calls);
        Assert.Empty(_media.Commands);

        model.Settings.Media = true;
        Assert.True(_media.Running);
        _media.Report(new MediaState { Player = "Spotify", Title = "Song", Playing = true, Controls = ["toggle", "seek"] });
        Assert.Contains("media-state song", _client.Calls);
        Emit(BridgeyEventKind.MediaCommand, id: 1, name: "seek", text: "req-2", status: 95);
        await Task.Delay(50, TestContext.Current.CancellationToken);
        Assert.Equal(["seek 95"], _media.Commands);
        Assert.Contains("media-result req-2 True", _client.Calls);
        model.Settings.Media = false;
        Assert.False(_media.Running);
        Assert.Contains("media-state none", _client.Calls);
    }

    [Fact]
    public void ConnectAwayFromHomeStartsWithTheEditionsServiceAndReportsItsState()
    {
        var model = Connected();
        Assert.Contains($"connect True {Edition.ConnectControlUrl}", _client.Calls);
        _client.Emit(new BridgeyEvent(BridgeyEventKind.ConnectState, 0, 0, null, null, "unreachable", "[]"));
        Assert.Equal("Round Robin's service can't be reached. Your local and private networks still work.", model.ConnectStatus);
        model.Settings.ConnectAway = false;
        Assert.Contains("connect False " + Edition.ConnectControlUrl, _client.Calls);
        _client.Emit(new BridgeyEvent(BridgeyEventKind.ConnectState, 0, 0, null, null, "off", "[]"));
        Assert.StartsWith("Off.", model.ConnectStatus);
    }
}
