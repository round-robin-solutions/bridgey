using System.Collections.ObjectModel;
using System.Text.Json;

namespace Bridgey.ViewModels;

/// <summary>
/// The app's state: trusted devices with their status, devices nearby, the activity list, the send box, pairing and
/// settings. Events from bridgey_core arrive on its thread and are handled on the UI thread.
/// </summary>
public sealed partial class MainViewModel : ObservableObject, IDisposable
{
    /// <summary>At most this many rows in the activity list, newest first.</summary>
    public const int ActivityLimit = 200;
    private static readonly TimeSpan AutomaticQuiet = TimeSpan.FromMilliseconds(300);

    private readonly IBridgeyClient _client;
    private readonly IUiDispatcher _ui;
    private readonly IClipboardService _clipboard;
    private readonly IAlertService _alerts;
    private readonly Dictionary<string, Dictionary<string, bool>> _remote = new();
    private readonly Dictionary<ulong, ActivityItem> _sending = new();
    private string _draft = "";
    private string? _notice;
    private string? _requestId;
    private string _requestName = "";
    private DeviceItem? _target;
    /// <summary>The last text received, so writing it to the clipboard is not sent straight back.</summary>
    private string? _lastReceived;
    private string? _lastAutomatic;
    private CancellationTokenSource? _automatic;

    public ObservableCollection<DeviceItem> Devices { get; } = new();
    public ObservableCollection<NearbyItem> Nearby { get; } = new();
    public ObservableCollection<ActivityItem> Activity { get; } = new();
    public PairingViewModel Pairing { get; }
    public SettingsViewModel Settings { get; }

    public MainViewModel(IBridgeyClient client, SettingsViewModel settings, IUiDispatcher ui, IClipboardService clipboard, IAlertService alerts)
    {
        _client = client;
        _ui = ui;
        _clipboard = clipboard;
        _alerts = alerts;
        Settings = settings;
        Pairing = new PairingViewModel(this, client);
        Devices.CollectionChanged += (_, _) => DevicesChanged();
        Activity.CollectionChanged += (_, _) =>
        {
            Raise(nameof(HasActivity));
            Raise(nameof(HasNoActivity));
        };
        Nearby.CollectionChanged += (_, _) => Pairing.NearbyChanged();
        Settings.ClipboardDefaultChanged += on => Try(() => _client.SetFeature(null, "clipboard", on));
        Settings.DeviceNameChanged += name => Try(() => _client.SetDeviceName(name));
        client.EventReceived += e => _ui.Post(() => Handle(e));
        Refresh();
    }

    public bool HasDevices => Devices.Count > 0;
    public bool HasNoDevices => Devices.Count == 0;
    public bool HasActivity => Activity.Count > 0;
    public bool HasNoActivity => Activity.Count == 0;
    public bool HasConnected => Devices.Any(d => d.IsConnected);

    /// <summary>"Connected to Pixel 9", for the notification area tooltip and the home screen.</summary>
    public string StatusText
    {
        get
        {
            var connected = Devices.Where(d => d.IsConnected).Select(d => d.Name).ToList();
            return connected.Count switch
            {
                0 => Devices.Count == 0 ? "No devices paired" : "No devices connected",
                1 => $"Connected to {connected[0]}",
                _ => $"Connected to {connected.Count} devices",
            };
        }
    }

    /// <summary>Text typed or pasted into the send box.</summary>
    public string Draft
    {
        get => _draft;
        set
        {
            if (Set(ref _draft, value)) Raise(nameof(CanSendDraft));
        }
    }

    /// <summary>Where the send box sends: the selected connected device.</summary>
    public DeviceItem? Target
    {
        get => _target;
        set
        {
            if (Set(ref _target, value)) Raise(nameof(CanSendDraft));
        }
    }

    public bool CanSendDraft => _draft.Length > 0 && _target is { IsConnected: true, ClipboardReady: true };

    /// <summary>A short message about the last thing that went wrong, shown until dismissed.</summary>
    public string? Notice
    {
        get => _notice;
        private set
        {
            if (Set(ref _notice, value)) Raise(nameof(HasNotice));
        }
    }

    public bool HasNotice => _notice is not null;

    public void DismissNotice() => Notice = null;

    /// <summary>Someone asked to pair while pairing was not allowed here.</summary>
    public bool HasPairingRequest => _requestId is not null;
    public string PairingRequestText => $"{_requestName} wants to pair with this PC.";

    public void AllowPairingRequest()
    {
        Try(() => _client.AllowPairing(TimeSpan.FromMinutes(2)));
        _requestId = null;
        Raise(nameof(HasPairingRequest));
    }

    public void DismissPairingRequest()
    {
        _requestId = null;
        Raise(nameof(HasPairingRequest));
    }

    /// <summary>Lets other devices pair with this PC for two minutes (the notification area menu).</summary>
    public void AllowPairing() => Try(() => _client.AllowPairing(TimeSpan.FromMinutes(2)));

    private void DevicesChanged()
    {
        Raise(nameof(HasDevices));
        Raise(nameof(HasNoDevices));
        Raise(nameof(HasConnected));
        Raise(nameof(StatusText));
        if (_target is null || !Devices.Contains(_target) || !_target.IsConnected) Target = Devices.FirstOrDefault(d => d.IsConnected) ?? Devices.FirstOrDefault();
    }

    /// <summary>Reads everything from bridgey_core again (at start and after dropped events).</summary>
    public void Refresh()
    {
        Snapshot snapshot;
        try { snapshot = _client.Snapshot(); }
        catch (BridgeyException) { return; }
        var seen = new HashSet<string>();
        foreach (var d in snapshot.Devices)
        {
            seen.Add(d.DeviceId);
            var item = Find(d.DeviceId) ?? Add(d.DeviceId);
            item.Name = d.Name;
            item.Platform = d.Platform;
            item.IsConnected = d.Connected;
            if (d.Remote is not null) _remote[d.DeviceId] = d.Remote;
            UpdateReadiness(item, d.Local);
        }
        foreach (var gone in Devices.Where(d => !seen.Contains(d.Id)).ToList()) Devices.Remove(gone);
        Nearby.Clear();
        foreach (var n in snapshot.Nearby.Where(n => !n.Trusted && n.Host is not null))
            Nearby.Add(new NearbyItem(this) { DeviceId = n.DeviceId, Name = n.Name, Platform = n.Platform, Host = n.Host!, Port = (ushort)(n.Port ?? 0) });
        DevicesChanged();
    }

    private DeviceItem? Find(string id) => Devices.FirstOrDefault(d => d.Id == id);

    private DeviceItem Add(string id)
    {
        var item = new DeviceItem(this, id);
        Devices.Add(item);
        return item;
    }

    private void UpdateReadiness(DeviceItem item, Dictionary<string, bool>? local = null)
    {
        local ??= LocalPolicy(item.Id);
        _remote.TryGetValue(item.Id, out var remote);
        bool On(Dictionary<string, bool>? map, string key) => map is not null && map.TryGetValue(key, out var v) && v;
        if (local is not null) item.ShowClipboardAllowed(On(local, "clipboard"));
        item.ClipboardReady = item.IsConnected && On(local, "clipboard") && On(remote, "clipboard");
        item.PingReady = item.IsConnected && On(local, "ping") && On(remote, "ping");
        Raise(nameof(CanSendDraft));
    }

    private Dictionary<string, bool>? LocalPolicy(string id)
    {
        try { return _client.Snapshot().Devices.FirstOrDefault(d => d.DeviceId == id)?.Local; }
        catch (BridgeyException) { return null; }
    }

    internal void Handle(BridgeyEvent e)
    {
        Pairing.Handle(e);
        switch (e.Kind)
        {
            case BridgeyEventKind.DeviceFound when e.Text is not null:
                if (e.DeviceId is not null && (Find(e.DeviceId) is not null || Nearby.Any(n => n.DeviceId == e.DeviceId))) break;
                if (e.DeviceId is null && Nearby.Any(n => n.Host == e.Text)) break;
                Nearby.Add(new NearbyItem(this) { DeviceId = e.DeviceId, Name = e.Name ?? e.Text, Platform = e.Extra, Host = e.Text, Port = (ushort)e.Status });
                break;
            case BridgeyEventKind.DeviceLost:
                foreach (var n in Nearby.Where(n => n.Host == e.Text && (e.DeviceId is null || n.DeviceId == e.DeviceId)).ToList()) Nearby.Remove(n);
                break;
            case BridgeyEventKind.PairingRequest when e.DeviceId is not null:
                if (Pairing.IsCode) break;
                _requestId = e.DeviceId;
                _requestName = e.Name ?? "A device";
                Raise(nameof(PairingRequestText));
                Raise(nameof(HasPairingRequest));
                break;
            case BridgeyEventKind.TrustChanged:
            case BridgeyEventKind.EventsDropped:
                Refresh();
                break;
            case BridgeyEventKind.Connected when e.DeviceId is not null:
            {
                var item = Find(e.DeviceId) ?? Add(e.DeviceId);
                if (e.Name is not null) item.Name = e.Name;
                item.IsConnected = true;
                foreach (var n in Nearby.Where(n => n.DeviceId == e.DeviceId).ToList()) Nearby.Remove(n);
                UpdateReadiness(item);
                DevicesChanged();
                break;
            }
            case BridgeyEventKind.Disconnected when e.DeviceId is not null:
            {
                if (Find(e.DeviceId) is { } item)
                {
                    item.IsConnected = false;
                    _remote.Remove(e.DeviceId);
                    UpdateReadiness(item);
                }
                DevicesChanged();
                break;
            }
            case BridgeyEventKind.Features when e.DeviceId is not null:
            {
                var local = Parse(e.Text);
                if (Parse(e.Extra) is { } remote) _remote[e.DeviceId] = remote;
                if (Find(e.DeviceId) is { } item) UpdateReadiness(item, local);
                break;
            }
            case BridgeyEventKind.Clipboard when e.DeviceId is not null && e.Text is not null:
            {
                _lastReceived = e.Text;
                _clipboard.SetText(e.Text);
                AddActivity(new ActivityItem
                {
                    Direction = ActivityDirection.Received,
                    Title = $"Text from {NameOf(e.DeviceId)}",
                    Preview = Settings.ShowPreviews ? ActivityItem.PreviewOf(e.Text) : "",
                });
                break;
            }
            case BridgeyEventKind.ClipboardSent:
                if (_sending.Remove(e.Id, out var row))
                    row.Status = (SendStatus)e.Status switch
                    {
                        SendStatus.Delivered => "",
                        SendStatus.Rejected => "Clipboard is off on that device",
                        SendStatus.TimedOut => "No answer",
                        _ => "Not delivered",
                    };
                break;
            case BridgeyEventKind.Ping when e.DeviceId is not null:
                _alerts.Ping(NameOf(e.DeviceId));
                break;
            case BridgeyEventKind.PingResult:
                if ((SendStatus)e.Status != SendStatus.Delivered) Notice = "The ping wasn't answered.";
                break;
            case BridgeyEventKind.Error when e.Text is not null:
                Notice = e.Text;
                break;
        }
    }

    private static Dictionary<string, bool>? Parse(string? json)
    {
        if (string.IsNullOrEmpty(json)) return null;
        try { return JsonSerializer.Deserialize(json, BridgeyJson.Default.DictionaryStringBoolean); }
        catch (JsonException) { return null; }
    }

    private string NameOf(string deviceId) => Find(deviceId)?.Name ?? "a device";

    private void AddActivity(ActivityItem item)
    {
        Activity.Insert(0, item);
        while (Activity.Count > ActivityLimit) Activity.RemoveAt(Activity.Count - 1);
    }

    /// <summary>Sends text to one device's clipboard and records it in the activity list.</summary>
    public bool SendText(DeviceItem device, string text, bool automatic = false)
    {
        if (string.IsNullOrEmpty(text)) return false;
        try
        {
            var request = _client.SendClipboard(device.Id, text);
            var row = new ActivityItem
            {
                Direction = ActivityDirection.Sent,
                Title = automatic ? $"Text to {device.Name}, automatically" : $"Text to {device.Name}",
                Preview = Settings.ShowPreviews ? ActivityItem.PreviewOf(text) : "",
                Request = request,
                Status = "Sending",
            };
            _sending[request] = row;
            AddActivity(row);
            return true;
        }
        catch (BridgeyException e)
        {
            Notice = e.Message;
            return false;
        }
    }

    public void SendDraft()
    {
        if (_target is null || !SendText(_target, _draft)) return;
        Draft = "";
    }

    /// <summary>The host reads the Windows clipboard and answers with <see cref="SendClipboardText"/>.</summary>
    public event Action<DeviceItem>? ClipboardRequested;

    internal void RequestSendClipboard(DeviceItem device) => ClipboardRequested?.Invoke(device);

    public void SendClipboardText(DeviceItem device, string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            Notice = "The clipboard has no text to send.";
            return;
        }
        SendText(device, text);
    }

    internal void SetDeviceClipboard(DeviceItem device, bool on)
    {
        Try(() => _client.SetFeature(device.Id, "clipboard", on));
        UpdateReadiness(device);
    }

    internal void Ping(DeviceItem device) => Try(() => _client.Ping(device.Id));

    internal void Forget(DeviceItem device)
    {
        Try(() => _client.Forget(device.Id));
        Devices.Remove(device);
    }

    /// <summary>
    /// Something was copied on this PC. With Automatic clipboard on, it goes to every connected device once the
    /// clipboard has been still for 300 ms. Text marked private by its app, empty text and text this PC just
    /// received are never sent.
    /// </summary>
    public void LocalCopy(string? text, bool privateContent)
    {
        if (!Settings.AutomaticClipboard || privateContent || string.IsNullOrEmpty(text)) return;
        if (text == _lastReceived || text == _lastAutomatic) return;
        if (System.Text.Encoding.UTF8.GetByteCount(text) > 32_768) return;
        _automatic?.Cancel();
        var cts = _automatic = new CancellationTokenSource();
        _ = Task.Delay(AutomaticQuiet, cts.Token).ContinueWith(t =>
        {
            if (t.IsCanceled) return;
            _ui.Post(() =>
            {
                if (cts.IsCancellationRequested) return;
                _lastAutomatic = text;
                foreach (var d in Devices.Where(d => d.ClipboardReady)) SendText(d, text, automatic: true);
            });
        }, TaskScheduler.Default);
    }

    private void Try(Action action)
    {
        try { action(); }
        catch (BridgeyException e) { Notice = e.Message; }
    }

    public void Dispose()
    {
        _automatic?.Cancel();
        _client.Dispose();
    }
}
