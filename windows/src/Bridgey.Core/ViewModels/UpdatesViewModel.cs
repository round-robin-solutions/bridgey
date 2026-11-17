namespace Bridgey.ViewModels;

/// <summary>What the updater needs from Windows: the network, a confirmation, and installing (which ends this process).</summary>
public interface IUpdateHost
{
    Task<string> FetchAsync(string url, CancellationToken cancel);
    Task DownloadAsync(string url, string path, IProgress<double> progress, CancellationToken cancel);
    /// <summary>Asks the person before installing; true to go ahead.</summary>
    Task<bool> ConfirmAsync(string title, string text);
    /// <summary>Unpacks the checked zip and hands over to it: Bridgey closes, the files are replaced, it opens again.</summary>
    void Install(string zipPath);
    /// <summary>Where downloads go before they are checked.</summary>
    string DownloadFolder { get; }
}

/// <summary>Where updates come from: the edition's feeds and release key (tests point a separate profile elsewhere).</summary>
public sealed record UpdateSource(string FeedBase, string TrustedPrefix, string PublicKey, string Arch, ulong CurrentBuild, string AppId);

/// <summary>
/// Self-update on the Stable, Beta and Nightly feeds (Rahul's standard for direct downloads): a check when Bridgey opens,
/// at most every six hours, and from Settings; a trusted feed; the download's size, SHA-256 and release-key signature
/// checked before anything is installed; and the person confirms. A failed check or download changes nothing.
/// </summary>
public sealed partial class UpdatesViewModel : ObservableObject
{
    public static readonly TimeSpan Throttle = TimeSpan.FromHours(6);

    private readonly SettingsViewModel _settings;
    private readonly IUpdateHost _host;
    private readonly UpdateSource _source;
    private readonly Func<DateTimeOffset> _now;
    private UpdateOffer? _offer;
    private string _status = "";
    private bool _busy;
    private double _progress;
    private bool _bannerDismissed;

    public UpdatesViewModel(SettingsViewModel settings, IUpdateHost host, UpdateSource source, Func<DateTimeOffset>? now = null)
    {
        _settings = settings;
        _host = host;
        _source = source;
        _now = now ?? (() => DateTimeOffset.UtcNow);
        _status = settings.Values.LastUpdateCheck is { } last ? $"Up to date. Checked {Ago(last)}." : "";
    }

    /// <summary>0 Stable, 1 Beta, 2 Nightly (the order of the choices in Settings).</summary>
    public int ChannelIndex
    {
        get => Array.IndexOf(UpdateLogic.Channels, Channel) is var i and >= 0 ? i : 1;
        set
        {
            var channel = UpdateLogic.Channels[Math.Clamp(value, 0, 2)];
            if (channel == Channel) return;
            _settings.Values.UpdateChannel = channel;
            _settings.Save();
            Raise();
            Raise(nameof(Channel));
            _offer = null;
            RaiseOffer();
            _ = CheckAsync(quiet: false);
        }
    }

    public string Channel => _settings.Values.UpdateChannel is { Length: > 0 } c && UpdateLogic.Channels.Contains(c) ? c : UpdateLogic.DefaultChannel(Edition.VersionName);

    public bool AutoCheck
    {
        get => _settings.Values.AutoUpdateCheck;
        set
        {
            if (value == _settings.Values.AutoUpdateCheck) return;
            _settings.Values.AutoUpdateCheck = value;
            _settings.Save();
            Raise();
        }
    }

    public string Status
    {
        get => _status;
        private set => Set(ref _status, value);
    }

    public bool IsBusy
    {
        get => _busy;
        private set
        {
            if (!Set(ref _busy, value)) return;
            Raise(nameof(CanCheck));
            Raise(nameof(CanInstall));
        }
    }

    public double Progress
    {
        get => _progress;
        private set => Set(ref _progress, value);
    }

    public bool CanCheck => !_busy;
    public bool HasOffer => _offer is not null;
    public bool CanInstall => _offer is not null && !_busy;
    public string OfferLabel => _offer is { } o ? $"Bridgey {Versions.Display(o.Version)} is ready." : "";

    /// <summary>The banner on Home after an automatic check found an update, until Install or Later.</summary>
    public bool ShowBanner => _offer is not null && !_bannerDismissed;

    public void DismissBanner()
    {
        _bannerDismissed = true;
        Raise(nameof(ShowBanner));
    }

    private void RaiseOffer()
    {
        Raise(nameof(HasOffer));
        Raise(nameof(CanInstall));
        Raise(nameof(OfferLabel));
        Raise(nameof(ShowBanner));
    }

    private string Ago(DateTimeOffset at)
    {
        var age = _now() - at;
        return age.TotalMinutes < 1 ? "just now" : age.TotalHours < 1 ? $"{(int)age.TotalMinutes} min ago" : age.TotalDays < 1 ? $"{(int)age.TotalHours} h ago" : $"{(int)age.TotalDays} d ago";
    }

    /// <summary>When Bridgey opens: a quiet check, unless one ran in the last six hours or checks are off.</summary>
    public Task CheckOnOpenAsync()
    {
        if (!AutoCheck) return Task.CompletedTask;
        if (_settings.Values.LastUpdateCheck is { } last && _now() - last < Throttle) return Task.CompletedTask;
        return CheckAsync(quiet: true);
    }

    /// <summary>Reads the channel's feed. <paramref name="quiet"/>: a failure only updates the status line.</summary>
    public async Task CheckAsync(bool quiet = false)
    {
        if (_busy) return;
        IsBusy = true;
        Status = "Checking…";
        try
        {
            var feed = await _host.FetchAsync($"{_source.FeedBase.TrimEnd('/')}/{Channel}.json", CancellationToken.None);
            _offer = UpdateLogic.Check(feed, Channel, _source.Arch, _source.CurrentBuild, _source.TrustedPrefix, _source.AppId);
            _settings.Values.LastUpdateCheck = _now();
            _settings.Save();
            _bannerDismissed = !quiet && _offer is not null;
            Status = _offer is null ? "Bridgey is up to date." : OfferLabel;
        }
        catch (Exception e) when (e is HttpRequestException or InvalidDataException or IOException or TaskCanceledException or UnauthorizedAccessException)
        {
            _offer = null;
            Status = e is InvalidDataException ? $"The update feed can't be trusted: {e.Message}." : "Bridgey couldn't check for updates. Check your connection and try again.";
        }
        finally
        {
            IsBusy = false;
            RaiseOffer();
        }
    }

    /// <summary>Asks, downloads, checks the download and installs. Bridgey closes and opens again on the new version.</summary>
    public async Task InstallAsync()
    {
        if (_offer is not { } offer || _busy) return;
        if (!await _host.ConfirmAsync($"Install Bridgey {Versions.Display(offer.Version)}?", "Bridgey closes, updates and opens again. Your devices reconnect by themselves.")) return;
        DismissBanner();
        IsBusy = true;
        Progress = 0;
        Status = "Downloading…";
        var path = Path.Combine(_host.DownloadFolder, $"Bridgey-{offer.Build}.zip");
        // Progress reports arrive posted, and may come after the download has returned: once it has, they are stale.
        var gate = new object();
        var downloading = true;
        try
        {
            Directory.CreateDirectory(_host.DownloadFolder);
            await _host.DownloadAsync(offer.Url, path, new Progress<double>(p =>
            {
                lock (gate)
                {
                    if (!downloading) return;
                    Progress = Math.Round(p * 100);
                    Status = $"Downloading… {Progress:0}%";
                }
            }), CancellationToken.None);
            lock (gate) downloading = false;
            if (UpdateLogic.Verify(path, offer, _source.PublicKey) is { } problem)
            {
                TryDelete(path);
                Status = $"The download didn't check out ({problem}). Nothing was installed.";
                return;
            }
            Status = "Installing…";
            _host.Install(path);
        }
        catch (Exception e) when (e is HttpRequestException or IOException or TaskCanceledException or UnauthorizedAccessException or InvalidDataException)
        {
            lock (gate) downloading = false;
            TryDelete(path);
            Status = "The download failed. Nothing was installed.";
        }
        finally
        {
            IsBusy = false;
        }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
