namespace Bridgey.ViewModels;

/// <summary>A trusted device on the home screen.</summary>
public sealed partial class DeviceItem(MainViewModel owner, string id) : ObservableObject
{
    private string _name = "";
    private string? _platform;
    private bool _connected;
    private bool _clipboardReady;
    private bool _pingReady;
    private bool _clipboardAllowed = true;
    private string _status = "Not connected";

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
            Status = value ? "Connected" : "Not connected";
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

    public void Ping() => owner.Ping(this);

    public void Forget() => owner.Forget(this);

    public override string ToString() => Name;
}

/// <summary>A device on the network that this PC could pair with.</summary>
public sealed partial class NearbyItem(MainViewModel owner) : ObservableObject
{
    public string? DeviceId { get; init; }
    public string Name { get; init; } = "";
    public string? Platform { get; init; }
    public string Host { get; init; } = "";
    public ushort Port { get; init; }

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

    public required ActivityDirection Direction { get; init; }
    public required string Title { get; init; }
    public string Preview { get; init; } = "";
    public DateTimeOffset At { get; init; } = DateTimeOffset.Now;
    public ulong Request { get; init; }

    public string Glyph => Direction == ActivityDirection.Received ? "\uE896" : "\uE898";
    public string Time => At.ToLocalTime().ToString("HH:mm");
    public bool HasPreview => Preview.Length > 0;

    /// <summary>"Sending", "Not delivered", or empty once delivered.</summary>
    public string Status
    {
        get => _status;
        set
        {
            if (Set(ref _status, value)) Raise(nameof(HasStatus));
        }
    }

    public bool HasStatus => _status.Length > 0;

    /// <summary>The activity list's one-line preview: whitespace collapsed, at most 80 characters.</summary>
    public static string PreviewOf(string text)
    {
        var collapsed = string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return collapsed.Length <= 80 ? collapsed : collapsed[..79].TrimEnd() + "…";
    }
}

/// <summary>A section in Settings, in the edition's order (Mac and Android use the same).</summary>
public sealed partial record SettingsSection(string Key, string Title, string Glyph, bool Available);
