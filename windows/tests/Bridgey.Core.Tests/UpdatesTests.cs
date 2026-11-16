using System.Security.Cryptography;
using Bridgey.ViewModels;
using Xunit;

namespace Bridgey.Tests;

internal sealed class FakeUpdateHost(string folder) : IUpdateHost
{
    public string Feed = "";
    public byte[] Download = [];
    public bool Answer = true;
    public readonly List<string> Calls = new();
    public string? Installed;
    public string DownloadFolder => folder;

    public Task<string> FetchAsync(string url, CancellationToken cancel)
    {
        Calls.Add($"fetch {url}");
        return Task.FromResult(Feed);
    }

    public Task DownloadAsync(string url, string path, IProgress<double> progress, CancellationToken cancel)
    {
        Calls.Add($"download {url}");
        File.WriteAllBytes(path, Download);
        progress.Report(1);
        return Task.CompletedTask;
    }

    public Task<bool> ConfirmAsync(string title, string text)
    {
        Calls.Add($"confirm {title}");
        return Task.FromResult(Answer);
    }

    public void Install(string zipPath) => Installed = zipPath;
}

/// <summary>Self-update: the feed check and download checks in bridgey_core, and the view model around them.</summary>
public sealed class UpdatesTests : IDisposable
{
    // Signed by the scripted peer's test key (peer --sign-update), never the release key.
    private static readonly byte[] Signed = "PK\u0003\u0004 Bridgey update fixture"u8.ToArray();
    private const string TestKey = "IVL40Zt5HSRFMkLhXy6rbLfP+ntqXtMAl5YOBpiB2xI=";
    private const string Signature = "GgSuCkRFXCmYMCfd5VXlQwyrTZlWh5AolJlSyCwIMYn27SGscDKqo1xn5CSK0JH4Y0Mlxxma05+P8rP5FUs+Bg==";
    private const string Prefix = "https://github.com/round-robin-solutions/bridgey/releases/download/";

    private readonly string _folder = Directory.CreateTempSubdirectory("bridgey-updates-").FullName;
    private readonly AppSettings _settings = new() { UpdateChannel = "beta" };
    private DateTimeOffset _now = new(2026, 11, 16, 12, 0, 0, TimeSpan.Zero);

    private static string Feed(ulong build, string sha, long size, string arch = "x64", string channel = "beta", string version = "1.1.0-beta.2") =>
        System.Text.Json.JsonSerializer.Serialize(new Dictionary<string, object>
        {
            ["schema"] = 1, ["app"] = "in.roundrobin.bridgey", ["channel"] = channel, ["version"] = version, ["build"] = build,
            ["windows"] = new Dictionary<string, object>
            {
                ["version"] = version, ["build"] = build, ["minimumOsBuild"] = 19041,
                [arch] = new Dictionary<string, object> { ["url"] = $"{Prefix}v{version}/Bridgey-RR-{version}-windows-{arch}.zip", ["sha256"] = sha, ["size"] = size, ["edSignature"] = Signature },
            },
        });

    private static string Sha(byte[] data) => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    private (UpdatesViewModel Model, FakeUpdateHost Host) Model(ulong current = 263190000)
    {
        var host = new FakeUpdateHost(_folder) { Feed = Feed(263201050, Sha(Signed), Signed.Length), Download = Signed };
        var settings = new SettingsViewModel(_settings, _ => { }, "Test PC");
        var source = new UpdateSource("https://example.test/channels", Prefix, TestKey, "x64", current, "in.roundrobin.bridgey");
        return (new UpdatesViewModel(settings, host, source, () => _now), host);
    }

    [Fact]
    public void TheNativeCheckOffersOnlyNewerTrustedBuilds()
    {
        var offer = UpdateLogic.Check(Feed(263201050, Sha(Signed), Signed.Length), "beta", "x64", 263190000, Prefix, "in.roundrobin.bridgey");
        Assert.Equal(("1.1.0-beta.2", 263201050UL), (offer!.Version, offer.Build));
        Assert.Null(UpdateLogic.Check(Feed(263201050, Sha(Signed), Signed.Length), "beta", "x64", 263201050, Prefix, "in.roundrobin.bridgey"));
        Assert.Null(UpdateLogic.Check(Feed(263201050, Sha(Signed), Signed.Length), "beta", "arm64", 1, Prefix, "in.roundrobin.bridgey"));
        Assert.Throws<InvalidDataException>(() => UpdateLogic.Check(Feed(263201050, Sha(Signed), Signed.Length), "beta", "x64", 1, "https://evil.example/", "in.roundrobin.bridgey"));
        Assert.Throws<InvalidDataException>(() => UpdateLogic.Check(Feed(263201050, Sha(Signed), Signed.Length, version: "1.1.0"), "beta", "x64", 1, Prefix, "in.roundrobin.bridgey"));
    }

    [Fact]
    public void TheNativeVerifyChecksSizeHashAndTheReleaseKey()
    {
        var path = Path.Combine(_folder, "u.zip");
        File.WriteAllBytes(path, Signed);
        var offer = new UpdateOffer { Sha256 = Sha(Signed), Size = (ulong)Signed.Length, Signature = Signature };
        Assert.Null(UpdateLogic.Verify(path, offer, TestKey));
        Assert.NotNull(UpdateLogic.Verify(path, offer, Edition.UpdatePublicKey));
        File.WriteAllBytes(path, [.. Signed, 0]);
        Assert.NotNull(UpdateLogic.Verify(path, offer, TestKey));
    }

    [Fact]
    public async Task OnOpenChecksAtMostEverySixHours()
    {
        var (model, host) = Model();
        await model.CheckOnOpenAsync();
        Assert.Single(host.Calls);
        Assert.Equal("fetch https://example.test/channels/beta.json", host.Calls[0]);
        Assert.True(model.ShowBanner);
        Assert.Equal("Bridgey 1.1 Beta 2 is ready.", model.OfferLabel);
        _now += TimeSpan.FromHours(5);
        await model.CheckOnOpenAsync();
        Assert.Single(host.Calls);
        _now += TimeSpan.FromHours(2);
        await model.CheckOnOpenAsync();
        Assert.Equal(2, host.Calls.Count);
        model.AutoCheck = false;
        _now += TimeSpan.FromHours(7);
        await model.CheckOnOpenAsync();
        Assert.Equal(2, host.Calls.Count);
    }

    [Fact]
    public async Task InstallAsksDownloadsChecksThenHandsOver()
    {
        var (model, host) = Model();
        await model.CheckAsync();
        Assert.False(model.ShowBanner, "a check from Settings shows the result there, not on Home");
        host.Answer = false;
        await model.InstallAsync();
        Assert.Null(host.Installed);
        Assert.DoesNotContain(host.Calls, c => c.StartsWith("download"));
        host.Answer = true;
        await model.InstallAsync();
        Assert.Contains("confirm Install Bridgey 1.1 Beta 2?", host.Calls);
        Assert.NotNull(host.Installed);
        Assert.Equal("Installing…", model.Status);
    }

    [Fact]
    public async Task ADownloadThatDoesNotCheckOutIsNotInstalled()
    {
        var (model, host) = Model();
        await model.CheckAsync();
        host.Download = [.. Signed.Take(Signed.Length - 1), (byte)'!'];
        await model.InstallAsync();
        Assert.Null(host.Installed);
        Assert.StartsWith("The download didn't check out", model.Status);
        Assert.Empty(Directory.GetFiles(_folder));
    }

    [Fact]
    public async Task UpToDateAndChannels()
    {
        var (model, host) = Model(current: 263201050);
        await model.CheckAsync();
        Assert.Equal("Bridgey is up to date.", model.Status);
        Assert.False(model.HasOffer);
        Assert.Equal(1, model.ChannelIndex);
        host.Feed = Feed(263201060, Sha(Signed), Signed.Length, channel: "nightly", version: "1.1.0-nightly.20261116");
        model.ChannelIndex = 2;
        await Task.Delay(20, TestContext.Current.CancellationToken);
        Assert.Equal("nightly", _settings.UpdateChannel);
        Assert.Contains("fetch https://example.test/channels/nightly.json", host.Calls);
        Assert.Equal("beta", UpdateLogic.DefaultChannel("1.0.0-dev"));
        Assert.Equal("nightly", UpdateLogic.DefaultChannel("1.0.0-nightly.20261116"));
        Assert.Equal("stable", UpdateLogic.DefaultChannel("1.0.0"));
    }

    public void Dispose() => Directory.Delete(_folder, true);
}
