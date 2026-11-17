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
