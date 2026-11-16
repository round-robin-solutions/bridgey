namespace Bridgey.ViewModels;

/// <summary>
/// Settings, in the edition's sections. Every change is saved at once. Sections whose features have not reached
/// Windows yet say so in one line.
/// </summary>
public sealed partial class SettingsViewModel(AppSettings settings, Action<AppSettings> save, string defaultDeviceName) : ObservableObject
{
    public static IReadOnlyList<SettingsSection> Sections { get; } =
    [
        new("thisPc", "This PC", "\uE7F4", true),
        new("devices", "Devices", "\uE772", true),
        new("clipboard", "Clipboard", "\uE77F", true),
        new("notifications", "Notifications", "\uEA8F", false),
        new("messages", "Text messages", "\uE8BD", false),
        new("calls", "Calls", "\uE717", false),
        new("files", "Files", "\uE8B7", true),
        new("media", "Media and actions", "\uE768", true),
        new("remoteControl", "Remote control", "\uE7C9", false),
        new("privacy", "Privacy", "\uE72E", true),
        new("updates", "Updates", "\uE895", false),
        new("general", "General", "\uE713", true),
        new("about", "About", "\uE946", true),
    ];

    public event Action? AppearanceChanged;
    public event Action<bool>? StartAtSignInChanged;
    public event Action<bool>? ClipboardDefaultChanged;
    public event Action<string>? DeviceNameChanged;
    /// <summary>A feature's default for devices without their own switch changed (feature key, on).</summary>
    public event Action<string, bool>? FeatureDefaultChanged;
    public event Action<string>? ReceiveFolderChanged;
    public event Action<bool>? SendToMenuChanged;

    public AppSettings Values => settings;

    private void Changed()
    {
        try { save(settings); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    /// <summary>The name other devices show; empty means this PC's name.</summary>
    public string DeviceName
    {
        get => settings.DeviceName.Length > 0 ? settings.DeviceName : defaultDeviceName;
        set
        {
            var name = (value ?? "").Trim();
            if (name == defaultDeviceName) name = "";
            if (name == settings.DeviceName) return;
            settings.DeviceName = name;
            Changed();
            Raise();
            DeviceNameChanged?.Invoke(DeviceName);
        }
    }

    /// <summary>0 System, 1 Light, 2 Dark (the order of the choices in Settings).</summary>
    public int ThemeIndex
    {
        get => (int)settings.Theme;
        set
        {
            var theme = (AppTheme)Math.Clamp(value, 0, 2);
            if (theme == settings.Theme) return;
            settings.Theme = theme;
            Changed();
            Raise();
            AppearanceChanged?.Invoke();
        }
    }

    public bool ReduceMotion
    {
        get => settings.ReduceMotion;
        set
        {
            if (value == settings.ReduceMotion) return;
            settings.ReduceMotion = value;
            Changed();
            Raise();
            AppearanceChanged?.Invoke();
        }
    }

    public bool AutomaticClipboard
    {
        get => settings.AutomaticClipboard;
        set
        {
            if (value == settings.AutomaticClipboard) return;
            settings.AutomaticClipboard = value;
            Changed();
            Raise();
        }
    }

    public bool Clipboard
    {
        get => settings.Clipboard;
        set
        {
            if (value == settings.Clipboard) return;
            settings.Clipboard = value;
            Changed();
            Raise();
            ClipboardDefaultChanged?.Invoke(value);
        }
    }

    public bool StartAtSignIn
    {
        get => settings.StartAtSignIn;
        set
        {
            if (value == settings.StartAtSignIn) return;
            settings.StartAtSignIn = value;
            Changed();
            Raise();
            StartAtSignInChanged?.Invoke(value);
        }
    }

    public bool KeepRunningInTray
    {
        get => settings.KeepRunningInTray;
        set
        {
            if (value == settings.KeepRunningInTray) return;
            settings.KeepRunningInTray = value;
            Changed();
            Raise();
        }
    }

    public bool ShowPreviews
    {
        get => settings.ShowPreviews;
        set
        {
            if (value == settings.ShowPreviews) return;
            settings.ShowPreviews = value;
            Changed();
            Raise();
        }
    }

    public bool Files
    {
        get => settings.Files;
        set
        {
            if (value == settings.Files) return;
            settings.Files = value;
            Changed();
            Raise();
            FeatureDefaultChanged?.Invoke("files", value);
        }
    }

    public bool Battery
    {
        get => settings.Battery;
        set
        {
            if (value == settings.Battery) return;
            settings.Battery = value;
            Changed();
            Raise();
            FeatureDefaultChanged?.Invoke("battery", value);
        }
    }

    public bool FindDevice
    {
        get => settings.FindDevice;
        set
        {
            if (value == settings.FindDevice) return;
            settings.FindDevice = value;
            Changed();
            Raise();
            FeatureDefaultChanged?.Invoke("find_device", value);
        }
    }

    public bool Ping
    {
        get => settings.Ping;
        set
        {
            if (value == settings.Ping) return;
            settings.Ping = value;
            Changed();
            Raise();
            FeatureDefaultChanged?.Invoke("ping", value);
        }
    }

    public bool FileNotifications
    {
        get => settings.FileNotifications;
        set
        {
            if (value == settings.FileNotifications) return;
            settings.FileNotifications = value;
            Changed();
            Raise();
        }
    }

    public bool SendToMenu
    {
        get => settings.SendToMenu;
        set
        {
            if (value == settings.SendToMenu) return;
            settings.SendToMenu = value;
            Changed();
            Raise();
            SendToMenuChanged?.Invoke(value);
        }
    }

    /// <summary>The host's default receive folder (Downloads\Bridgey); set once at start.</summary>
    public string DefaultReceiveFolder { get; set; } = "";

    /// <summary>Where received files go: the chosen folder, or Downloads\Bridgey.</summary>
    public string ReceiveFolder
    {
        get => settings.ReceiveFolder.Length > 0 ? settings.ReceiveFolder : DefaultReceiveFolder;
        set
        {
            var folder = (value ?? "").Trim();
            if (string.Equals(folder, DefaultReceiveFolder, StringComparison.OrdinalIgnoreCase)) folder = "";
            if (folder == settings.ReceiveFolder) return;
            settings.ReceiveFolder = folder;
            Changed();
            Raise();
            Raise(nameof(ReceiveFolderIsDefault));
            Raise(nameof(ReceiveFolderIsCustom));
            ReceiveFolderChanged?.Invoke(ReceiveFolder);
        }
    }

    public bool ReceiveFolderIsDefault => settings.ReceiveFolder.Length == 0;
    public bool ReceiveFolderIsCustom => !ReceiveFolderIsDefault;

    public void ResetReceiveFolder() => ReceiveFolder = "";

    /// <summary>Every switch the session client takes as a default, with its value (applied at start).</summary>
    public IEnumerable<(string Key, bool On)> FeatureDefaults =>
    [
        ("clipboard", settings.Clipboard),
        ("files", settings.Files),
        ("battery", settings.Battery),
        ("find_device", settings.FindDevice),
        ("ping", settings.Ping),
    ];

    public bool SetupDone
    {
        get => settings.SetupDone;
        set
        {
            if (value == settings.SetupDone) return;
            settings.SetupDone = value;
            Changed();
            Raise();
        }
    }

    public string AppName => Edition.DisplayName;
    public string ShortVersion => Versions.ShortLabel;
    public string FullVersion => Versions.FullLabel;
    public string UpstreamCredit => $"Built on Bridgey by Semyon Mikhailov (MIT licence), up to {Edition.UpstreamBase}.";
    public string UpstreamUrl => "https://github.com/singeol/bridgey";
    public string RepositoryUrl => $"https://github.com/{Edition.Repository}";
}
