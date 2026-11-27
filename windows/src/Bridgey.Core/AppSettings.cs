using System.Text.Json;
using System.Text.Json.Serialization;

namespace Bridgey;

public enum AppTheme
{
    System,
    Light,
    Dark,
}

/// <summary>
/// The app's own settings (settings.json in the data folder). Defaults are the sensible choice; every one has a
/// switch in Settings. Pairing data is not here: bridgey_core keeps it in protected storage.
/// </summary>
public sealed class AppSettings
{
    /// <summary>The name other devices show. Empty uses this PC's name.</summary>
    public string DeviceName { get; set; } = "";
    public AppTheme Theme { get; set; } = AppTheme.System;
    /// <summary>Less motion than Windows allows. Windows' own "Animation effects" switch always applies.</summary>
    public bool ReduceMotion { get; set; }
    /// <summary>Copies on this PC go to connected devices by themselves. Off by default.</summary>
    public bool AutomaticClipboard { get; set; }
    /// <summary>Clipboard on for devices without their own switch.</summary>
    public bool Clipboard { get; set; } = true;
    public bool StartAtSignIn { get; set; } = true;
    /// <summary>Closing the window keeps Bridgey running in the notification area.</summary>
    public bool KeepRunningInTray { get; set; } = true;
    /// <summary>One-line previews of clipboard text in the activity list.</summary>
    public bool ShowPreviews { get; set; } = true;
    /// <summary>Files on for devices without their own switch.</summary>
    public bool Files { get; set; } = true;
    /// <summary>Where received files go. Empty is Downloads\Bridgey.</summary>
    public string ReceiveFolder { get; set; } = "";
    /// <summary>A notification with Open and Show in folder when a file arrives.</summary>
    public bool FileNotifications { get; set; } = true;
    /// <summary>Bridgey in Explorer's Send to menu.</summary>
    public bool SendToMenu { get; set; } = true;
    /// <summary>This PC's battery on paired devices, and theirs here.</summary>
    public bool Battery { get; set; } = true;
    /// <summary>Paired devices can ring this PC, and it can ring them.</summary>
    public bool FindDevice { get; set; } = true;
    /// <summary>One short sound from a paired device.</summary>
    public bool Ping { get; set; } = true;
    /// <summary>Phone notifications on this PC.</summary>
    public bool Notifications { get; set; } = true;
    /// <summary>Windows notifications for phone notifications (off: they only appear in Bridgey).</summary>
    public bool NotificationBanners { get; set; } = true;
    /// <summary>Apps whose notifications show no banner here (Android package names).</summary>
    public List<string> MutedApps { get; set; } = new();
    /// <summary>Keep phone notifications for seven days (at most 200), encrypted for this Windows user.</summary>
    public bool NotificationHistory { get; set; }
    /// <summary>Show one-time codes from text messages with Copy code. Found on this PC; nothing leaves it.</summary>
    public bool CodesFromMessages { get; set; }
    /// <summary>Also look for codes in Gmail, Outlook, Proton Mail and Spark notifications.</summary>
    public bool CodesFromEmail { get; set; }
    /// <summary>Put a found code on the clipboard straight away.</summary>
    public bool CopyCodes { get; set; }
    /// <summary>Tell the phone when this PC is in use, so its alerts come here (activity only: never keys or apps).</summary>
    public bool ShareActivity { get; set; } = true;
    /// <summary>Links both ways with paired devices.</summary>
    public bool Links { get; set; } = true;
    /// <summary>A link a phone sends with Open on PC opens at once (otherwise it waits for Open or Dismiss).</summary>
    public bool OpenLinksRightAway { get; set; } = true;
    /// <summary>Browser extensions: the native messaging host for Chrome, Edge, Firefox and Brave (docs/browser-extensions.md). Off until chosen.</summary>
    public bool BrowserSupport { get; set; }
    /// <summary>The phone's media controls for this PC's player. Off until chosen, as on the Mac.</summary>
    public bool Media { get; set; }
    /// <summary>Text messages: the phone's conversations on this PC. Off until chosen, as on the Mac.</summary>
    public bool TextMessages { get; set; }
    /// <summary>Keep the phone's conversations on this PC between runs (encrypted for this Windows user).</summary>
    public bool KeepConversations { get; set; } = true;
    /// <summary>The Calls window: call through a phone from this PC. Off until chosen, as on the Mac.</summary>
    public bool CallsWindow { get; set; }
    /// <summary>Phones this PC may call through (device IDs), each off until allowed, as on the Mac.</summary>
    public List<string> CallsAllowed { get; set; } = new();
    /// <summary>The SIM to call from on a phone with two: ask, sim1 or sim2.</summary>
    public string CallsSim { get; set; } = "ask";
    /// <summary>WhatsApp voice and video calls through the phone's WhatsApp.</summary>
    public bool CallsShowWhatsApp { get; set; } = true;
    /// <summary>How many recent calls the Calls window lists.</summary>
    public int CallsRecentCount { get; set; } = 20;
    /// <summary>Connect away from home: paired devices reach this PC off the local network (on, as on the Mac).</summary>
    public bool ConnectAway { get; set; } = true;
    /// <summary>stable, beta or nightly. Empty: the channel this build came from (a beta build follows Beta).</summary>
    public string UpdateChannel { get; set; } = "";
    /// <summary>Look for a new version when Bridgey opens, at most every six hours.</summary>
    public bool AutoUpdateCheck { get; set; } = true;
    public DateTimeOffset? LastUpdateCheck { get; set; }
    /// <summary>Binary frames with devices that have them. Off only for a test (settings.json).</summary>
    public bool FastTransfers { get; set; } = true;
    public bool SetupDone { get; set; }
}

/// <summary>Reads and writes settings.json atomically. A missing or unreadable file gives the defaults.</summary>
public sealed class SettingsStore(string folder)
{
    private readonly string _path = Path.Combine(folder, "settings.json");

    public AppSettings Load()
    {
        try
        {
            if (File.Exists(_path)) return JsonSerializer.Deserialize(File.ReadAllText(_path), SettingsJson.Default.AppSettings) ?? new AppSettings();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
        }
        return new AppSettings();
    }

    public void Save(AppSettings settings)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        var temp = _path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(settings, SettingsJson.Default.AppSettings));
        File.Move(temp, _path, overwrite: true);
    }
}

[JsonSourceGenerationOptions(WriteIndented = true, PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, UseStringEnumConverter = true)]
[JsonSerializable(typeof(AppSettings))]
internal sealed partial class SettingsJson : JsonSerializerContext;
