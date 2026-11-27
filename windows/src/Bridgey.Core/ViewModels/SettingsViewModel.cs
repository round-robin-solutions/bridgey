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
        new("away", "Away from home", "\uE774", true),
        new("clipboard", "Clipboard", "\uE77F", true),
        new("notifications", "Notifications", "\uEA8F", true),
        new("messages", "Text messages", "\uE8BD", true),
        new("calls", "Calls", "\uE717", true),
        new("files", "Files", "\uE8B7", true),
        new("media", "Media and actions", "\uE768", true),
        new("remoteControl", "Remote control", "\uE7C9", true),
        new("privacy", "Privacy", "\uE72E", true),
        new("updates", "Updates", "\uE895", true),
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
    /// <summary>Codes from messages or Also read codes in email changed.</summary>
    public event Action? CodesChanged;
    public event Action<bool>? NotificationHistoryChanged;
    public event Action<bool>? SendToMenuChanged;
    /// <summary>Settings > Media and actions > Browser extensions was turned on or off.</summary>
    public event Action<bool>? BrowserSupportChanged;

    public AppSettings Values => settings;

    /// <summary>Saves settings changed outside a property here (the updater's channel and last check).</summary>
    public void Save() => Changed();

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
            FeatureDefaultChanged?.Invoke("folders_receive_draft1", value);
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

    /// <summary>Browser extensions: the host manifests, registry keys and pipe the extension uses (Bridgey.App).</summary>
    public bool BrowserSupport
    {
        get => settings.BrowserSupport;
        set
        {
            if (value == settings.BrowserSupport) return;
            settings.BrowserSupport = value;
            Changed();
            Raise();
            BrowserSupportChanged?.Invoke(value);
        }
    }

    private string _browserSupportStatus = BrowserSupportOff;
    public const string BrowserSupportOff = "Send pages and links to your devices from Chrome, Edge, Firefox and Brave.";

    /// <summary>The line under Browser extensions: what it does, the browsers it was set up for, or why it can't be.</summary>
    public string BrowserSupportStatus
    {
        get => _browserSupportStatus;
        set => Set(ref _browserSupportStatus, value);
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

    /// <summary>
    /// Every switch the session client takes as a default, with its value (applied at start). The drafts follow the
    /// Mac's rules: routing and code status with Notifications, presence with Share when I'm using this PC, email codes
    /// with both code switches.
    /// </summary>
    public IEnumerable<(string Key, bool On)> FeatureDefaults =>
    [
        ("clipboard", settings.Clipboard),
        ("files", settings.Files),
        // Folders from the phone (downloads from Phone files, and folders it sends), as the Mac advertises them.
        ("folders_receive_draft1", settings.Files),
        ("battery", settings.Battery),
        ("find_device", settings.FindDevice),
        ("ping", settings.Ping),
        ("notifications", settings.Notifications),
        ("notification_routing_draft1", settings.Notifications),
        ("device_presence_draft1", settings.Notifications && settings.ShareActivity),
        ("sms_codes_draft1", settings.Notifications),
        ("email_codes_draft1", settings.Notifications && settings.CodesFromMessages && settings.CodesFromEmail),
        ("links", settings.Links),
        ("links_open_draft1", settings.Links),
        ("media", settings.Media),
        ("sms_draft1", settings.TextMessages),
        ("screen_draft1", settings.ShowPhoneScreens),
        ("phone_control_draft1", settings.ShowPhoneScreens),
    ];

    /// <summary>Keep conversations on this PC changed.</summary>
    public event Action<bool>? KeepConversationsChanged;

    /// <summary>The phone's conversations on this PC (Text messages), off until chosen.</summary>
    public bool TextMessages
    {
        get => settings.TextMessages;
        set
        {
            if (value == settings.TextMessages) return;
            settings.TextMessages = value;
            Changed();
            Raise();
            FeatureDefaultChanged?.Invoke("sms_draft1", value);
        }
    }

    /// <summary>A phone's screen in a window on this PC, and control of it when the phone allows. Off until chosen.</summary>
    public bool ShowPhoneScreens
    {
        get => settings.ShowPhoneScreens;
        set
        {
            if (value == settings.ShowPhoneScreens) return;
            settings.ShowPhoneScreens = value;
            Changed();
            Raise();
            FeatureDefaultChanged?.Invoke("screen_draft1", value);
            FeatureDefaultChanged?.Invoke("phone_control_draft1", value);
        }
    }

    public bool KeepConversations
    {
        get => settings.KeepConversations;
        set
        {
            if (value == settings.KeepConversations) return;
            settings.KeepConversations = value;
            Changed();
            Raise();
            KeepConversationsChanged?.Invoke(value);
        }
    }

    /// <summary>The Calls window switch, a phone's allowance, or one of the window's choices changed.</summary>
    public event Action? CallsChanged;

    /// <summary>The Calls window, off until chosen. Each phone needs allowing too.</summary>
    public bool CallsWindow
    {
        get => settings.CallsWindow;
        set
        {
            if (value == settings.CallsWindow) return;
            settings.CallsWindow = value;
            Changed();
            Raise();
            CallsChanged?.Invoke();
        }
    }

    public bool IsCallsAllowed(string deviceId) => settings.CallsAllowed.Contains(deviceId);

    public void SetCallsAllowed(string deviceId, bool on)
    {
        if (on == IsCallsAllowed(deviceId)) return;
        if (on) settings.CallsAllowed.Add(deviceId);
        else settings.CallsAllowed.Remove(deviceId);
        Changed();
        CallsChanged?.Invoke();
    }

    /// <summary>The SIM to call from: ask, sim1 or sim2.</summary>
    public string CallsSim => settings.CallsSim is "sim1" or "sim2" ? settings.CallsSim : "ask";

    /// <summary>Ask each time, SIM 1, SIM 2 (the order in Settings).</summary>
    public int CallsSimIndex
    {
        get => CallsSim switch { "sim1" => 1, "sim2" => 2, _ => 0 };
        set
        {
            var sim = value switch { 1 => "sim1", 2 => "sim2", _ => "ask" };
            if (sim == settings.CallsSim) return;
            settings.CallsSim = sim;
            Changed();
            Raise();
            CallsChanged?.Invoke();
        }
    }

    public bool CallsShowWhatsApp
    {
        get => settings.CallsShowWhatsApp;
        set
        {
            if (value == settings.CallsShowWhatsApp) return;
            settings.CallsShowWhatsApp = value;
            Changed();
            Raise();
            CallsChanged?.Invoke();
        }
    }

    public static IReadOnlyList<int> CallsRecentChoices { get; } = [10, 20, 50];

    public int CallsRecentCount => CallsRecentChoices.Contains(settings.CallsRecentCount) ? settings.CallsRecentCount : 20;

    /// <summary>Last 10, 20 or 50 (the order in Settings).</summary>
    public int CallsRecentIndex
    {
        get => Math.Max(0, CallsRecentChoices.ToList().IndexOf(CallsRecentCount));
        set
        {
            var count = CallsRecentChoices[Math.Clamp(value, 0, CallsRecentChoices.Count - 1)];
            if (count == settings.CallsRecentCount) return;
            settings.CallsRecentCount = count;
            Changed();
            Raise();
            CallsChanged?.Invoke();
        }
    }

    public event Action? LinksChanged;
    public event Action? MediaChanged;
    public event Action? ConnectChanged;

    public bool Links
    {
        get => settings.Links;
        set
        {
            if (value == settings.Links) return;
            settings.Links = value;
            Changed();
            Raise();
            FeatureDefaultChanged?.Invoke("links", value);
            FeatureDefaultChanged?.Invoke("links_open_draft1", value);
            LinksChanged?.Invoke();
        }
    }

    public bool OpenLinksRightAway
    {
        get => settings.OpenLinksRightAway;
        set
        {
            if (value == settings.OpenLinksRightAway) return;
            settings.OpenLinksRightAway = value;
            Changed();
            Raise();
            LinksChanged?.Invoke();
        }
    }

    public bool Media
    {
        get => settings.Media;
        set
        {
            if (value == settings.Media) return;
            settings.Media = value;
            Changed();
            Raise();
            FeatureDefaultChanged?.Invoke("media", value);
            MediaChanged?.Invoke();
        }
    }

    public bool ConnectAway
    {
        get => settings.ConnectAway;
        set
        {
            if (value == settings.ConnectAway) return;
            settings.ConnectAway = value;
            Changed();
            Raise();
            ConnectChanged?.Invoke();
        }
    }

    private void NotificationDefaultsChanged()
    {
        foreach (var (key, on) in FeatureDefaults.Where(f => f.Key is "notifications" or "notification_routing_draft1" or "device_presence_draft1" or "sms_codes_draft1" or "email_codes_draft1"))
            FeatureDefaultChanged?.Invoke(key, on);
    }

    public bool Notifications
    {
        get => settings.Notifications;
        set
        {
            if (value == settings.Notifications) return;
            settings.Notifications = value;
            Changed();
            Raise();
            NotificationDefaultsChanged();
        }
    }

    public bool NotificationBanners
    {
        get => settings.NotificationBanners;
        set
        {
            if (value == settings.NotificationBanners) return;
            settings.NotificationBanners = value;
            Changed();
            Raise();
        }
    }

    public bool NotificationHistory
    {
        get => settings.NotificationHistory;
        set
        {
            if (value == settings.NotificationHistory) return;
            settings.NotificationHistory = value;
            Changed();
            Raise();
            NotificationHistoryChanged?.Invoke(value);
        }
    }

    public bool CodesFromMessages
    {
        get => settings.CodesFromMessages;
        set
        {
            if (value == settings.CodesFromMessages) return;
            settings.CodesFromMessages = value;
            Changed();
            Raise();
            CodesChanged?.Invoke();
            NotificationDefaultsChanged();
        }
    }

    public bool CodesFromEmail
    {
        get => settings.CodesFromEmail;
        set
        {
            if (value == settings.CodesFromEmail) return;
            settings.CodesFromEmail = value;
            Changed();
            Raise();
            CodesChanged?.Invoke();
            NotificationDefaultsChanged();
        }
    }

    public bool CopyCodes
    {
        get => settings.CopyCodes;
        set
        {
            if (value == settings.CopyCodes) return;
            settings.CopyCodes = value;
            Changed();
            Raise();
        }
    }

    public bool ShareActivity
    {
        get => settings.ShareActivity;
        set
        {
            if (value == settings.ShareActivity) return;
            settings.ShareActivity = value;
            Changed();
            Raise();
            NotificationDefaultsChanged();
        }
    }

    /// <summary>Banners from one phone app off (muted) or on again.</summary>
    public void SetAppMuted(string package, bool muted)
    {
        var list = settings.MutedApps;
        if (muted == list.Contains(package)) return;
        if (muted) list.Add(package);
        else list.Remove(package);
        Changed();
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
