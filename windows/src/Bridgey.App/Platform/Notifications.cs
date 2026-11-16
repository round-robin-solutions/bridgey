using Bridgey.ViewModels;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using Windows.System.Power;

namespace Bridgey.Platform;

/// <summary>
/// Windows notifications (Windows App SDK app notifications) with buttons and a reply box. Where Windows can't show
/// them (an old build, or registration fails), a notification area balloon says the same in one line.
/// </summary>
internal sealed class Notifications : IDisposable
{
    private bool _registered;

    /// <summary>A button or the notification itself was clicked: its arguments and anything typed. Raised off the UI thread.</summary>
    public event Action<IDictionary<string, string>, IDictionary<string, string>>? Invoked;

    /// <summary>The notification area icon, for the one-line fallback.</summary>
    public TrayIcon? Fallback { get; set; }

    public bool Registered => _registered;

    public void Start()
    {
        try
        {
            if (!AppNotificationManager.IsSupported()) return;
            AppNotificationManager.Default.NotificationInvoked += (_, args) =>
            {
                try { Invoked?.Invoke(args.Arguments, args.UserInput); }
                catch (Exception e) { App.Log($"Notification action failed: {e}"); }
            };
            AppNotificationManager.Default.Register();
            _registered = true;
            // Whether Windows lets this app's notifications through (a policy, the user or Do Not Disturb can stop them).
            App.Log($"App notifications registered; Windows setting: {AppNotificationManager.Default.Setting}");
        }
        catch (Exception e)
        {
            App.Log($"App notifications are not available: {e.Message}");
        }
    }

    /// <summary>Shows a notification; <paramref name="tag"/> and <paramref name="group"/> let it be replaced or removed.</summary>
    public void Show(AppNotificationBuilder builder, string fallbackTitle, string fallbackText, string? tag = null, string? group = null)
    {
        if (_registered)
        {
            try
            {
                var notification = builder.BuildNotification();
                if (tag is not null) notification.Tag = tag;
                if (group is not null) notification.Group = group;
                AppNotificationManager.Default.Show(notification);
                LogDelivered();
                return;
            }
            catch (Exception e)
            {
                App.Log($"Notification failed: {e.Message}");
            }
        }
        Fallback?.Balloon(fallbackTitle, fallbackText);
    }

    /// <summary>How many of this app's notifications Windows holds: evidence in the log that one was delivered.</summary>
    private static async void LogDelivered()
    {
        try
        {
            var all = await AppNotificationManager.Default.GetAllAsync();
            App.Log($"Notification shown ({all.Count} in the notification centre)");
        }
        catch (Exception e)
        {
            App.Log($"Notification count failed: {e.Message}");
        }
    }

    public async void Remove(string tag, string group)
    {
        if (!_registered) return;
        try { await AppNotificationManager.Default.RemoveByTagAndGroupAsync(tag, group); }
        catch (Exception e) { App.Log($"Removing a notification failed: {e.Message}"); }
    }

    public void Dispose()
    {
        if (!_registered) return;
        try { AppNotificationManager.Default.Unregister(); }
        catch (Exception) { }
        _registered = false;
    }
}

/// <summary>Pings, received files and find device: sounds and notifications.</summary>
internal sealed class Alerts(Notifications notifications, Func<AppSettings> settings) : IAlertService
{
    public const string RingTag = "ring";
    public const string RingGroup = "find";

    public void Ping(string deviceName) => Win32.MessageBeep(Win32.MB_ICONASTERISK);

    public void FileReceived(string deviceName, string fileName, string path)
    {
        if (!settings().FileNotifications) return;
        var builder = new AppNotificationBuilder()
            .AddArgument("action", "open")
            .AddArgument("path", path)
            .AddText(fileName)
            .AddText($"From {deviceName}")
            .AddButton(new AppNotificationButton("Open").AddArgument("action", "open").AddArgument("path", path))
            .AddButton(new AppNotificationButton("Show in folder").AddArgument("action", "folder").AddArgument("path", path));
        notifications.Show(builder, fileName, $"From {deviceName}");
    }

    public void StartRinging(string deviceName)
    {
        Sounds.StartRinging();
        var builder = new AppNotificationBuilder()
            .SetScenario(AppNotificationScenario.Reminder)
            .MuteAudio()
            .AddArgument("action", "stopRinging")
            .AddText($"{deviceName} is ringing this PC")
            .AddButton(new AppNotificationButton("Stop").AddArgument("action", "stopRinging"));
        notifications.Show(builder, "Bridgey", $"{deviceName} is ringing this PC", RingTag, RingGroup);
    }

    public void StopRinging()
    {
        Sounds.Stop();
        notifications.Remove(RingTag, RingGroup);
    }
}

/// <summary>This PC's battery, from Windows' power manager; desktops without one report none.</summary>
internal static class PowerWatch
{
    public static void Start(Action<int?, bool> changed)
    {
        void Report()
        {
            try
            {
                var status = PowerManager.BatteryStatus;
                if (status == BatteryStatus.NotPresent)
                {
                    changed(null, false);
                    return;
                }
                // Plugged in and full reads as idle: still on the charger, as the phone shows it.
                var charging = status == BatteryStatus.Charging || (status == BatteryStatus.Idle && PowerManager.PowerSupplyStatus != PowerSupplyStatus.NotPresent);
                changed(Math.Clamp(PowerManager.RemainingChargePercent, 0, 100), charging);
            }
            catch (Exception e)
            {
                App.Log($"Battery status failed: {e.Message}");
            }
        }
        try
        {
            PowerManager.BatteryStatusChanged += (_, _) => Report();
            PowerManager.RemainingChargePercentChanged += (_, _) => Report();
            PowerManager.PowerSupplyStatusChanged += (_, _) => Report();
        }
        catch (Exception e)
        {
            App.Log($"Battery events failed: {e.Message}");
        }
        Report();
    }
}
