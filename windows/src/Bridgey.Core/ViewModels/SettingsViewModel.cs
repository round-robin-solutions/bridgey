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
        new("files", "Files", "\uE8B7", false),
        new("media", "Media and actions", "\uE768", false),
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
