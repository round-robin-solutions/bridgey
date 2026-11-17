namespace Bridgey.ViewModels;

/// <summary>A trusted device on the home screen.</summary>
public sealed partial class DeviceItem(MainViewModel owner, string id) : ObservableObject
{
    private string _name = "";
    private string? _platform;
    private bool _connected;
    private bool _clipboardReady;
    private bool _pingReady;
    private bool _filesReady;
    private bool _findReady;
    private bool _ringing;
    private bool _clipboardAllowed = true;
    private string _status = "Not connected";
    private int? _battery;
    private bool _charging;

    public string Id { get; } = id;

    public string Name
    {
        get => _name;
        set
        {
            if (Set(ref _name, value)) Raise(nameof(Initial));
        }
    }

    public string? Platform
    {
        get => _platform;
        set
        {
            if (Set(ref _platform, value)) Raise(nameof(Glyph));
        }
    }

    public bool IsConnected
    {
        get => _connected;
        set
        {
            if (!Set(ref _connected, value)) return;
            Raise(nameof(IsOffline));
            Raise(nameof(HasBattery));
            Status = value ? "Connected" : "Not connected";
            if (!value) IsRinging = false;
        }
    }

    public bool IsOffline => !_connected;

    /// <summary>Clipboard is on for this device here and on the device itself.</summary>
    public bool ClipboardReady
    {
        get => _clipboardReady;
        set => Set(ref _clipboardReady, value);
    }

    public bool PingReady
    {
        get => _pingReady;
        set => Set(ref _pingReady, value);
    }

    /// <summary>Files is on for this device here and on the device itself.</summary>
    public bool FilesReady
    {
        get => _filesReady;
        set => Set(ref _filesReady, value);
    }

    /// <summary>Both ends allow find device, so this PC can ring it.</summary>
    public bool FindReady
    {
        get => _findReady;
        set
        {
            if (Set(ref _findReady, value)) Raise(nameof(RingText));
        }
    }

    /// <summary>The device says it is ringing.</summary>
    public bool IsRinging
    {
        get => _ringing;
        set
        {
            if (Set(ref _ringing, value)) Raise(nameof(RingText));
        }
    }

    public string RingText => _ringing ? "Stop ringing" : "Ring";

    /// <summary>The device's battery, when it shares it.</summary>
    public int? BatteryLevel
    {
        get => _battery;
        set
        {
            if (!Set(ref _battery, value)) return;
            Raise(nameof(HasBattery));
            Raise(nameof(BatteryText));
            Raise(nameof(BatteryGlyph));
        }
    }

    public bool Charging
    {
        get => _charging;
        set
        {
            if (!Set(ref _charging, value)) return;
            Raise(nameof(BatteryText));
            Raise(nameof(BatteryGlyph));
        }
    }

    public bool HasBattery => _battery is not null && _connected;

    /// <summary>"82%" or "82%, charging".</summary>
    public string BatteryText => _battery is { } level ? (_charging ? $"{level}%, charging" : $"{level}%") : "";

    /// <summary>A Segoe Fluent Icons battery glyph in tenths (Battery0 to Battery10, BatteryCharging0 to 10).</summary>
    public string BatteryGlyph
    {
        get
        {
            var tenth = Math.Clamp(((_battery ?? 0) + 5) / 10, 0, 10);
            var glyph = (_charging, tenth) switch
            {
                (false, 10) => 0xE83F,
                (false, _) => 0xE850 + tenth,
                (true, 10) => 0xEA93,
                (true, 9) => 0xE83E,
                (true, _) => 0xE85A + tenth,
            };
            return ((char)glyph).ToString();
        }
    }

    /// <summary>This PC's switches for this device (Settings > Devices), in the edition's order.</summary>
    public List<FeatureSwitch> Switches { get; } =
    [
        new(owner, id, "clipboard", "Clipboard"),
        new(owner, id, "files", "Files"),
        new(owner, id, "battery", "Battery"),
        new(owner, id, "find_device", "Find device"),
        new(owner, id, "ping", "Ping"),
        new(owner, id, "notifications", "Notifications"),
    ];

    internal void ShowSwitches(Dictionary<string, bool> local)
    {
        foreach (var s in Switches) s.Show(local.TryGetValue(s.Key, out var on) && on);
    }

    /// <summary>This PC's own Clipboard switch for this device (Settings > Devices).</summary>
    public bool ClipboardAllowed
    {
        get => _clipboardAllowed;
        set
        {
            if (Set(ref _clipboardAllowed, value)) owner.SetDeviceClipboard(this, value);
        }
    }

    internal void ShowClipboardAllowed(bool value)
    {
        if (_clipboardAllowed == value) return;
        _clipboardAllowed = value;
        Raise(nameof(ClipboardAllowed));
    }

    public string Status
    {
        get => _status;
        set => Set(ref _status, value);
    }

    public string Initial => string.IsNullOrWhiteSpace(_name) ? "?" : char.ToUpperInvariant(_name.TrimStart()[0]).ToString();

    /// <summary>A Segoe Fluent Icons glyph for the device's platform.</summary>
    public string Glyph => _platform switch
    {
        "android" or "ios" => "\uE8EA",
        "macos" => "\uE7F8",
        "windows" or "linux" => "\uE7F4",
        _ => "\uE703",
    };

    public void SendClipboard() => owner.RequestSendClipboard(this);

    public void SendFiles() => owner.RequestSendFiles(this);

    public void Ring() => owner.Ring(this);

    public void Ping() => owner.Ping(this);

    public void Forget() => owner.Forget(this);

    public override string ToString() => Name;
}

/// <summary>One of this PC's switches for one paired device. The default for new devices is in each section.</summary>
public sealed partial class FeatureSwitch(MainViewModel owner, string deviceId, string key, string title) : ObservableObject
{
    private bool _on;

    public string Key { get; } = key;
    public string Title { get; } = title;

    public bool IsOn
    {
        get => _on;
        set
        {
            if (Set(ref _on, value)) owner.SetDeviceFeature(deviceId, Key, value);
        }
    }

    internal void Show(bool on)
    {
        if (_on == on) return;
        _on = on;
        Raise(nameof(IsOn));
    }
}

/// <summary>A device on the network that this PC could pair with.</summary>
public sealed partial class NearbyItem(MainViewModel owner) : ObservableObject
{
    public string? DeviceId { get; set; }
    public string Name { get; set; } = "";
    public string? Platform { get; set; }
    public string Host { get; set; } = "";
    public ushort Port { get; set; }

    public string Glyph => Platform switch
    {
        "android" or "ios" => "\uE8EA",
        "macos" => "\uE7F8",
        "windows" or "linux" => "\uE7F4",
        _ => "\uE703",
    };

    public string Detail => Platform switch
    {
        "android" => "Android phone",
        "ios" => "iPhone or iPad",
        "macos" => "Mac",
        "windows" => "Windows PC",
        "linux" => "Linux",
        _ => Host,
    };

    public void Pair() => owner.Pairing.PairWith(this);
}

public enum ActivityDirection
{
    Received,
    Sent,
}

/// <summary>One row of the activity list: what moved between devices. Kept in memory only.</summary>
public sealed partial class ActivityItem : ObservableObject
{
    private string _status = "";
    private TransferState? _transfer;
    private double _progress;
    private string? _path;
    private string _title = "";

    public required ActivityDirection Direction { get; set; }

    public required string Title
    {
        get => _title;
        set => Set(ref _title, value);
    }
    public string Preview { get; set; } = "";
    public DateTimeOffset At { get; set; } = DateTimeOffset.Now;
    public ulong Request { get; set; }
    internal MainViewModel? Owner { get; set; }

    public string Glyph => _transfer is not null ? "\uE8A5" : Direction == ActivityDirection.Received ? "\uE896" : "\uE898";

    /// <summary>A file row's state; null for text.</summary>
    public TransferState? Transfer
    {
        get => _transfer;
        set
        {
            if (!Set(ref _transfer, value)) return;
            Raise(nameof(Glyph));
            Raise(nameof(IsActive));
            Raise(nameof(CanOpen));
            Raise(nameof(IsDeterminate));
            Raise(nameof(IsWaiting));
            Raise(nameof(ShowsProblem));
        }
    }

    /// <summary>Queued or offered: the bar moves without a number.</summary>
    public bool IsWaiting => _transfer is TransferState.Queued or TransferState.Offered;

    /// <summary>Text rows show "Sending" and "Not delivered" on the right; file rows only how they ended badly.</summary>
    public bool ShowsProblem => _status.Length > 0 && !IsActive;

    /// <summary>Waiting, offered or moving: a progress bar and Cancel.</summary>
    public bool IsActive => _transfer is TransferState.Queued or TransferState.Offered or TransferState.Sending or TransferState.Receiving;

    /// <summary>Bytes are moving, so the bar shows how far.</summary>
    public bool IsDeterminate => _transfer is TransferState.Sending or TransferState.Receiving;

    /// <summary>0 to 100.</summary>
    public double Progress
    {
        get => _progress;
        set => Set(ref _progress, value);
    }

    /// <summary>Where a received file was saved.</summary>
    public string? Path
    {
        get => _path;
        set
        {
            if (Set(ref _path, value)) Raise(nameof(CanOpen));
        }
    }

    public bool CanOpen => _transfer == TransferState.Done && Direction == ActivityDirection.Received && _path is not null;

    public void Cancel() => Owner?.CancelTransfer(this);

    public void Open() => Owner?.OpenFile(this);

    public void ShowInFolder() => Owner?.ShowFileInFolder(this);
    public string Time => At.ToLocalTime().ToString("HH:mm");
    public bool HasPreview => Preview.Length > 0;

    /// <summary>"Sending", "Not delivered", or empty once delivered.</summary>
    public string Status
    {
        get => _status;
        set
        {
            if (!Set(ref _status, value)) return;
            Raise(nameof(HasStatus));
            Raise(nameof(ShowsProblem));
        }
    }

    public bool HasStatus => _status.Length > 0;

    /// <summary>"3.1 MB", "640 KB", "12 bytes": sizes and speeds in transfer rows (decimal units, as Explorer's are not).</summary>
    public static string Size(long bytes) => bytes switch
    {
        < 1_000 => bytes == 1 ? "1 byte" : $"{bytes} bytes",
        < 1_000_000 => $"{bytes / 1_000.0:0.#} KB",
        < 1_000_000_000 => $"{bytes / 1_000_000.0:0.#} MB",
        _ => $"{bytes / 1_000_000_000.0:0.##} GB",
    };

    /// <summary>The activity list's one-line preview: whitespace collapsed, at most 80 characters.</summary>
    public static string PreviewOf(string text)
    {
        var collapsed = string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return collapsed.Length <= 80 ? collapsed : collapsed[..79].TrimEnd() + "…";
    }
}

/// <summary>A section in Settings, in the edition's order (Mac and Android use the same).</summary>
public sealed partial class SettingsSection(string key, string title, string glyph, bool available)
{
    public string Key { get; } = key;
    public string Title { get; } = title;
    public string Glyph { get; } = glyph;
    public bool Available { get; } = available;

    public override string ToString() => Title;
}
