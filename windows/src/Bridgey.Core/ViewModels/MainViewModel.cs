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
    private readonly IFileService _files;
    private readonly Dictionary<string, Dictionary<string, bool>> _remote = new();
    private readonly Dictionary<ulong, ActivityItem> _sending = new();
    /// <summary>File rows by request ID, while their transfer runs.</summary>
    private readonly Dictionary<ulong, ActivityItem> _transfers = new();
    private string? _ringingFrom;
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

    public MainViewModel(IBridgeyClient client, SettingsViewModel settings, IUiDispatcher ui, IClipboardService clipboard, IAlertService alerts, IFileService? files = null)
    {
        _client = client;
        _ui = ui;
        _clipboard = clipboard;
        _alerts = alerts;
        _files = files ?? new NoFiles();
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
        Settings.FeatureDefaultChanged += (key, on) =>
        {
            Try(() => _client.SetFeature(null, key, on));
            foreach (var d in Devices) UpdateReadiness(d);
        };
        Settings.DeviceNameChanged += name => Try(() => _client.SetDeviceName(name));
        Settings.ReceiveFolderChanged += folder => Try(() => _client.SetReceiveDir(folder));
        client.EventReceived += e => _ui.Post(() => Handle(e));
        foreach (var (key, on) in Settings.FeatureDefaults) Try(() => _client.SetFeature(null, key, on));
        if (Settings.ReceiveFolder.Length > 0) Try(() => _client.SetReceiveDir(Settings.ReceiveFolder));
        Refresh();
    }

    private sealed class NoFiles : IFileService
    {
        public void Open(string path) { }
        public void ShowInFolder(string path) { }
    }

    /// <summary>Another device is ringing this PC: a banner with Stop.</summary>
    public bool IsRinging => _ringingFrom is not null;
    public string RingingText => $"{NameOf(_ringingFrom ?? "")} is ringing this PC.";

    /// <summary>The person pressed Stop: the sound ends and the device that rang is told.</summary>
    public void StopRinging()
    {
        if (_ringingFrom is not { } from) return;
        _alerts.StopRinging();
        Try(() => _client.FindStopped(from));
        SetRinging(null);
    }

    private void SetRinging(string? from)
    {
        _ringingFrom = from;
        Raise(nameof(IsRinging));
        Raise(nameof(RingingText));
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
            if (!Set(ref _target, value)) return;
            Raise(nameof(CanSendDraft));
            Raise(nameof(CanSendFiles));
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
            item.BatteryLevel = d.Battery?.Level;
            item.Charging = d.Battery?.Charging ?? false;
            item.IsRinging = d.Ringing;
            if (d.Remote is not null) _remote[d.DeviceId] = d.Remote;
            UpdateReadiness(item, d.Local);
        }
        foreach (var gone in Devices.Where(d => !seen.Contains(d.Id)).ToList()) Devices.Remove(gone);
        foreach (var t in snapshot.Transfers.Where(t => t.State is "queued" or "offered" or "sending" or "receiving")) UpdateTransfer(t.Request, t);
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
        if (local is not null)
        {
            item.ShowClipboardAllowed(On(local, "clipboard"));
            item.ShowSwitches(local);
        }
        item.ClipboardReady = item.IsConnected && On(local, "clipboard") && On(remote, "clipboard");
        item.PingReady = item.IsConnected && On(local, "ping") && On(remote, "ping");
        item.FilesReady = item.IsConnected && On(local, "files") && On(remote, "files");
        item.FindReady = item.IsConnected && On(local, "find_device") && On(remote, "find_device");
        if (!(On(local, "battery") && On(remote, "battery"))) item.BatteryLevel = null;
        Raise(nameof(CanSendDraft));
        Raise(nameof(CanSendFiles));
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
                    item.BatteryLevel = null;
                    _remote.Remove(e.DeviceId);
                    UpdateReadiness(item);
                }
                if (_ringingFrom == e.DeviceId)
                {
                    _alerts.StopRinging();
                    SetRinging(null);
                }
                DevicesChanged();
                break;
            }
            case BridgeyEventKind.Transfer when TransferInfo.Parse(e.Text) is { } transfer:
                UpdateTransfer(e.Id, transfer);
                break;
            case BridgeyEventKind.Battery when e.DeviceId is not null:
                if (Find(e.DeviceId) is { } battery)
                {
                    battery.Charging = e.Id != 0;
                    battery.BatteryLevel = Math.Clamp(e.Status, 0, 100);
                }
                break;
            case BridgeyEventKind.FindRequested when e.DeviceId is not null:
                if (e.Status != 0)
                {
                    SetRinging(e.DeviceId);
                    _alerts.StartRinging(NameOf(e.DeviceId));
                }
                else if (_ringingFrom == e.DeviceId)
                {
                    // Stopped from the other device; it has its answer already.
                    _alerts.StopRinging();
                    SetRinging(null);
                }
                break;
            case BridgeyEventKind.FindState when e.DeviceId is not null:
                if (Find(e.DeviceId) is { } ringing) ringing.IsRinging = e.Status != 0;
                break;
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

    internal void SetDeviceFeature(string deviceId, string key, bool on)
    {
        Try(() => _client.SetFeature(deviceId, key, on));
        if (Find(deviceId) is { } device)
        {
            if (key == "clipboard") device.ShowClipboardAllowed(on);
            UpdateReadiness(device);
        }
    }

    internal void Ping(DeviceItem device) => Try(() => _client.Ping(device.Id));

    /// <summary>Rings the device until someone stops it, or stops it.</summary>
    internal void Ring(DeviceItem device) => Try(() => _client.Find(device.Id, !device.IsRinging));

    /// <summary>The send bar's device can take files.</summary>
    public bool CanSendFiles => _target is { FilesReady: true };

    /// <summary>The host shows a file picker and answers with <see cref="SendFiles"/>.</summary>
    public event Action<DeviceItem>? FilesRequested;

    internal void RequestSendFiles(DeviceItem device) => FilesRequested?.Invoke(device);

    /// <summary>Files from Explorer's Send to, or dropped on the window: which device takes them is asked for when more
    /// than one could.</summary>
    public event Action<IReadOnlyList<string>, IReadOnlyList<DeviceItem>>? ChooseDeviceForFiles;

    /// <summary>Files from outside the window (Send to): straight to the one device that can take them, else asked.</summary>
    public void SendFilesFromShell(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return;
        var ready = Devices.Where(d => d.FilesReady).ToList();
        switch (ready.Count)
        {
            case 0:
                Notice = Devices.Count == 0 ? "Pair a phone or Mac first, then send files to it." : "Connect a device with Files on to send files.";
                break;
            case 1:
                SendFiles(ready[0], paths);
                break;
            default:
                ChooseDeviceForFiles?.Invoke(paths, ready);
                break;
        }
    }

    /// <summary>Queues files for one device; each gets a row in Activity.</summary>
    public void SendFiles(DeviceItem device, IEnumerable<string> paths)
    {
        foreach (var path in paths)
        {
            try
            {
                var request = _client.SendFile(device.Id, path);
                if (!_transfers.ContainsKey(request))
                {
                    var row = NewTransferRow(request, ActivityDirection.Sent, $"{FileName(path)} to {device.Name}");
                    row.Transfer = TransferState.Queued;
                    row.Status = "Waiting";
                }
            }
            catch (BridgeyException e)
            {
                Notice = e.Code switch
                {
                    BridgeyException.FeatureOff => $"Files is off on {device.Name} or on this PC.",
                    BridgeyException.TooLarge => $"{FileName(path)} is too large to send. Files can be up to 10 GB.",
                    BridgeyException.InvalidArgument => "Folders can't be sent yet. Choose files instead.",
                    BridgeyException.Io => $"Bridgey can't read {FileName(path)}.",
                    _ => e.Message,
                };
            }
        }
    }

    /// <summary>The last part of a path, with either separator (the same on Windows; the tests also run on Linux).</summary>
    private static string FileName(string path) => path.Split('\\', '/').LastOrDefault(p => p.Length > 0) ?? path;

    private ActivityItem NewTransferRow(ulong request, ActivityDirection direction, string title)
    {
        var row = new ActivityItem { Direction = direction, Title = title, Request = request, Owner = this };
        _transfers[request] = row;
        AddActivity(row);
        return row;
    }

    private void UpdateTransfer(ulong request, TransferInfo t)
    {
        var device = NameOf(t.DeviceId);
        // A file refused before it started (no room) still gets a row saying so.
        var row = _transfers.TryGetValue(request, out var known) ? known
            : NewTransferRow(request, t.Incoming ? ActivityDirection.Received : ActivityDirection.Sent, t.Incoming ? $"{t.Name} from {device}" : $"{t.Name} to {device}");
        if (!Enum.TryParse<TransferState>(t.State, true, out var state)) return;
        row.Transfer = state;
        row.Progress = t.Total > 0 ? Math.Round(100.0 * t.Bytes / t.Total, 1) : 0;
        row.Status = TransferStatus(t, state, device);
        if (state == TransferState.Done && t.Incoming)
        {
            row.Title = $"{t.Name} from {device}";
            row.Path = t.Path;
        }
        if (state is TransferState.Done or TransferState.Rejected or TransferState.Cancelled or TransferState.Failed or TransferState.Interrupted)
        {
            _transfers.Remove(request);
            if (state == TransferState.Done && t.Incoming && t.Path is { } path) _alerts.FileReceived(device, t.Name, path);
        }
    }

    /// <summary>What a file row says under its name.</summary>
    internal static string TransferStatus(TransferInfo t, TransferState state, string device) => state switch
    {
        TransferState.Queued => "Waiting",
        TransferState.Offered => $"Waiting for {device}",
        TransferState.Sending or TransferState.Receiving when t.Rate > 0 => $"{ActivityItem.Size(t.Bytes)} of {ActivityItem.Size(t.Total)}, {ActivityItem.Size(t.Rate)}/s",
        TransferState.Sending or TransferState.Receiving => $"{ActivityItem.Size(t.Bytes)} of {ActivityItem.Size(t.Total)}",
        TransferState.Done => "",
        TransferState.Rejected => $"Files is off on {device}",
        TransferState.Cancelled => t.Reason == "cancelled_remote" ? $"Cancelled on {device}" : "Cancelled",
        TransferState.Interrupted => "The connection dropped",
        _ => t.Reason switch
        {
            "hash_mismatch" or "size_mismatch" or "invalid_chunk" or "not_verified" => "The file didn't arrive intact",
            "no_space" => "Not enough free space",
            "write_failed" => "Bridgey couldn't save the file",
            "read_failed" => "Bridgey couldn't read the file",
            "file_changed" => "The file changed while it was sending",
            "too_large" => "Too large to send",
            "stalled" or "no_answer" or "no_confirmation" => $"No answer from {device}",
            _ => t.Incoming ? "Not received" : "Not sent",
        },
    };

    internal void CancelTransfer(ActivityItem row) => Try(() => _client.CancelTransfer(row.Request));

    internal void OpenFile(ActivityItem row)
    {
        if (row.Path is { } path) _files.Open(path);
    }

    internal void ShowFileInFolder(ActivityItem row)
    {
        if (row.Path is { } path) _files.ShowInFolder(path);
    }

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
