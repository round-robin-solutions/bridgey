using System.Diagnostics;
using Bridgey.ViewModels;
using Windows.Graphics.Imaging;
using Windows.Media.Control;
using Windows.Storage.Streams;

namespace Bridgey.Platform;

/// <summary>Opens web links in the default browser (http and https only). BRIDGEY_NO_BROWSER=1 (tests) only logs.</summary>
internal sealed class BrowserLinks : ILinkOpener
{
    public bool Open(string url)
    {
        if (!MainViewModel.IsWebLink(url)) return false;
        if (Environment.GetEnvironmentVariable("BRIDGEY_NO_BROWSER") == "1")
        {
            App.Log("Link opened (browser skipped for a test)");
            return true;
        }
        try
        {
            Process.Start(new ProcessStartInfo(url.Trim()) { UseShellExecute = true });
            return true;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            App.Log($"Opening a link failed: {e.Message}");
            return false;
        }
    }
}

/// <summary>
/// What plays on this PC, through Windows' system media controls (any app that shows in the volume flyout): its name,
/// title and artist, position, the buttons it takes, and artwork at most 128x128 and 16 KiB. The phone's buttons
/// become the same controls. Windows has no per-app volume here, so volume is not offered.
/// </summary>
internal sealed class SystemMedia : IMediaHost
{
    private GlobalSystemMediaTransportControlsSessionManager? _manager;
    private GlobalSystemMediaTransportControlsSession? _session;
    private Timer? _timer;
    private bool _running;
    private string? _artworkFor;
    private string? _artwork;

    public event Action<MediaState?>? Changed;

    public async void Start()
    {
        if (_running) return;
        _running = true;
        try
        {
            _manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
            _manager.CurrentSessionChanged += (_, _) => Watch();
            Watch();
            // Position moves without events from most players: refresh it while something plays.
            _timer = new Timer(_ => _ = Report(), null, TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(5));
        }
        catch (Exception e)
        {
            App.Log($"Media controls are not available: {e.Message}");
            Changed?.Invoke(null);
        }
    }

    public void Stop()
    {
        _running = false;
        _timer?.Dispose();
        _timer = null;
        _session = null;
        _manager = null;
    }

    private void Watch()
    {
        if (!_running || _manager is null) return;
        var session = _manager.GetCurrentSession();
        if (!ReferenceEquals(session, _session))
        {
            _session = session;
            if (session is not null)
            {
                session.MediaPropertiesChanged += (_, _) => _ = Report();
                session.PlaybackInfoChanged += (_, _) => _ = Report();
                session.TimelinePropertiesChanged += (_, _) => _ = Report();
            }
        }
        _ = Report();
    }

    private async Task Report()
    {
        if (!_running) return;
        var session = _session;
        if (session is null)
        {
            Changed?.Invoke(null);
            return;
        }
        try
        {
            var info = session.GetPlaybackInfo();
            var timeline = session.GetTimelineProperties();
            var props = await session.TryGetMediaPropertiesAsync();
            var controls = new List<string>();
            if (info.Controls.IsPlayPauseToggleEnabled || info.Controls.IsPlayEnabled) controls.Add("toggle");
            if (info.Controls.IsPauseEnabled) controls.Add("pause");
            if (info.Controls.IsNextEnabled) controls.Add("next");
            if (info.Controls.IsPreviousEnabled) controls.Add("previous");
            if (info.Controls.IsPlaybackPositionEnabled) controls.Add("seek");
            var key = $"{props.Title}|{props.Artist}";
            if (key != _artworkFor)
            {
                _artworkFor = key;
                _artwork = await Artwork(props.Thumbnail);
            }
            Changed?.Invoke(new MediaState
            {
                Player = PlayerName(session.SourceAppUserModelId),
                Title = props.Title ?? "",
                Artist = props.Artist ?? "",
                Playing = info.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing,
                Position = (long)Math.Max(0, (timeline.Position - timeline.StartTime).TotalSeconds),
                Duration = (long)Math.Max(0, (timeline.EndTime - timeline.StartTime).TotalSeconds),
                Controls = controls,
                Artwork = _artwork,
            });
        }
        catch (Exception e)
        {
            App.Log($"Reading the media session failed: {e.Message}");
        }
    }

    public async Task<bool> RunAsync(string action, long? value)
    {
        var session = _session;
        if (session is null) return false;
        try
        {
            var done = action switch
            {
                "toggle" => await session.TryTogglePlayPauseAsync(),
                "pause" => await session.TryPauseAsync(),
                "next" => await session.TrySkipNextAsync(),
                "previous" => await session.TrySkipPreviousAsync(),
                "seek" when value is { } seconds => await session.TryChangePlaybackPositionAsync(TimeSpan.FromSeconds(seconds).Ticks + session.GetTimelineProperties().StartTime.Ticks),
                _ => false,
            };
            _ = Report();
            return done;
        }
        catch (Exception e)
        {
            App.Log($"A media command failed: {e.Message}");
            return false;
        }
    }

    /// <summary>"Spotify", "Media Player", "Microsoft Edge": from the app's identity, as the volume flyout names it.</summary>
    private static string PlayerName(string aumid)
    {
        try
        {
            var info = Windows.ApplicationModel.AppInfo.GetFromAppUserModelId(aumid);
            if (info?.DisplayInfo?.DisplayName is { Length: > 0 } name) return name;
        }
        catch (Exception) { }
        var part = aumid.Contains('!') ? aumid[(aumid.LastIndexOf('!') + 1)..] : aumid;
        if (part.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) part = part[..^4];
        return part switch
        {
            "Microsoft.ZuneMusic" or "ZuneMusic" => "Media Player",
            "MSEdge" or "msedge" => "Microsoft Edge",
            "chrome" => "Chrome",
            "firefox" => "Firefox",
            "" => "This PC",
            _ => part.Length > 64 ? part[..64] : part,
        };
    }

    /// <summary>The cover as base64 JPEG, at most 128x128 and 16 KiB (media.state's limit), or none.</summary>
    private static async Task<string?> Artwork(IRandomAccessStreamReference? thumbnail)
    {
        if (thumbnail is null) return null;
        try
        {
            using var source = await thumbnail.OpenReadAsync();
            var decoder = await BitmapDecoder.CreateAsync(source);
            var scale = Math.Min(1.0, 128.0 / Math.Max(decoder.PixelWidth, decoder.PixelHeight));
            var transform = new BitmapTransform
            {
                ScaledWidth = (uint)Math.Max(1, decoder.PixelWidth * scale),
                ScaledHeight = (uint)Math.Max(1, decoder.PixelHeight * scale),
                InterpolationMode = BitmapInterpolationMode.Fant,
            };
            var pixels = (await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, transform, ExifOrientationMode.RespectExifOrientation, ColorManagementMode.DoNotColorManage)).DetachPixelData();
            foreach (var quality in new[] { 0.75, 0.55, 0.35 })
            {
                using var output = new InMemoryRandomAccessStream();
                var options = new BitmapPropertySet { { "ImageQuality", new BitmapTypedValue(quality, Windows.Foundation.PropertyType.Single) } };
                var jpeg = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, output, options);
                jpeg.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, transform.ScaledWidth, transform.ScaledHeight, 96, 96, pixels);
                await jpeg.FlushAsync();
                if (output.Size > 16 * 1024) continue;
                var bytes = new byte[output.Size];
                output.Seek(0);
                using var reader = new DataReader(output.GetInputStreamAt(0));
                await reader.LoadAsync((uint)output.Size);
                reader.ReadBytes(bytes);
                return Convert.ToBase64String(bytes);
            }
        }
        catch (Exception e)
        {
            App.Log($"Artwork failed: {e.Message}");
        }
        return null;
    }
}
