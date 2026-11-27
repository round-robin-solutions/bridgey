using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Bridgey.ViewModels;
using Microsoft.Windows.AppNotifications.Builder;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.GenericAttributeProfile;

namespace Bridgey.Platform;

/// <summary>
/// Phone notifications as Windows notifications: the app's icon, the title and text, the phone's own buttons (up to
/// four), a reply box for the action that takes one, and Dismiss. A code shows as "Code 482913" with Copy code.
/// Each is tagged by device and notification, so an update replaces it and the phone's removal takes it away.
/// </summary>
internal sealed class PhoneNotifier(Notifications notifications) : IPhoneNotifier
{
    /// <summary>Windows allows five buttons; one is Dismiss and the reply box brings its own.</summary>
    private const int MaxButtons = 4;

    private static string Tag(string notificationId) => Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(notificationId)))[..32];
    private static string Group(string deviceId) => deviceId.Length > 32 ? deviceId[..32] : deviceId;

    private static AppNotificationButton Button(string title, NotificationItem item, string action) =>
        new AppNotificationButton(title).AddArgument("action", action).AddArgument("device", item.DeviceId).AddArgument("id", item.NotificationId);

    public void Show(NotificationItem item)
    {
        var builder = new AppNotificationBuilder()
            .AddText(item.Title.Length > 0 ? item.Title : item.AppName)
            .SetAttributionText($"{item.AppName} on {item.DeviceName}");
        // A text message opens its conversation; anything else opens Notifications.
        if (item.SmsThreadId is { } thread) builder.AddArgument("action", "openConversation").AddArgument("device", item.DeviceId).AddArgument("thread", thread.ToString());
        else builder.AddArgument("action", "openNotifications");
        if (item.Text.Length > 0) builder.AddText(item.Text);
        if (Icon(item) is { } icon) builder.SetAppLogoOverride(icon, AppNotificationImageCrop.Circle);
        if (item.CallType == "incoming") builder.SetScenario(AppNotificationScenario.IncomingCall);
        var replies = item.ReplyAction is not null || (item.SmsReply && item.CallType is null);
        if (item.ReplyAction is { } reply)
        {
            builder.AddTextBox("reply", "Reply", "");
            builder.AddButton(Button(reply.Title.Length > 0 ? reply.Title : "Reply", item, "phoneAction").AddArgument("token", reply.Token).SetInputId("reply"));
        }
        else if (replies)
        {
            // Text messages: the messaging app has no Reply of its own, so the phone sends the answer as a text.
            builder.AddTextBox("reply", "Reply", "");
            builder.AddButton(Button("Reply", item, "smsReply").SetInputId("reply"));
        }
        foreach (var action in item.Actions.Where(a => !a.AllowsReply).Take(MaxButtons - (replies ? 1 : 0)))
            builder.AddButton(Button(action.Title, item, "phoneAction").AddArgument("token", action.Token));
        builder.AddButton(Button("Dismiss", item, "phoneDismiss"));
        notifications.Show(builder, item.Title.Length > 0 ? item.Title : item.AppName, item.Text, Tag(item.NotificationId), Group(item.DeviceId));
    }

    public void ShowCode(NotificationItem item, bool copied)
    {
        var code = item.Code!;
        var builder = new AppNotificationBuilder()
            .AddArgument("action", "copyCode")
            .AddArgument("device", item.DeviceId)
            .AddArgument("id", item.NotificationId)
            .AddText($"Code {code.Code}")
            .AddText(copied ? $"From {code.Service}. Copied." : $"From {code.Service}")
            .SetAttributionText($"{item.AppName} on {item.DeviceName}");
        if (!copied) builder.AddButton(Button("Copy code", item, "copyCode"));
        notifications.Show(builder, $"Code {code.Code}", $"From {code.Service}", Tag(item.NotificationId), Group(item.DeviceId));
    }

    public void Remove(string deviceId, string notificationId) => notifications.Remove(Tag(notificationId), Group(deviceId));

    /// <summary>The phone app's icon (base64 PNG, at most 28 KiB) as a file Windows can show, cached by content.</summary>
    private static Uri? Icon(NotificationItem item)
    {
        if (item.Icon is not { Length: > 0 } b64) return null;
        try
        {
            var bytes = Convert.FromBase64String(b64);
            if (bytes.Length < 8 || bytes[0] != 0x89 || bytes[1] != (byte)'P') return null;
            var folder = Path.Combine(Paths.DataFolder, "icons");
            Directory.CreateDirectory(folder);
            var path = Path.Combine(folder, Convert.ToHexString(SHA256.HashData(bytes))[..24] + ".png");
            if (!File.Exists(path)) File.WriteAllBytes(path, bytes);
            return new Uri(path);
        }
        catch (Exception e) when (e is FormatException or IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}

/// <summary>Notification history in notification-history.dat, encrypted with DPAPI for this Windows user.</summary>
internal sealed class ProtectedHistory(string folder) : INotificationHistory
{
    private static readonly byte[] Entropy = "bridgey-rr-windows-history-v1"u8.ToArray();
    private string PathOf => System.IO.Path.Combine(folder, "notification-history.dat");

    public List<StoredNotification> Load()
    {
        try
        {
            if (!File.Exists(PathOf)) return new();
            var json = System.Text.Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(PathOf), Entropy, DataProtectionScope.CurrentUser));
            return StoredNotification.Deserialize(json);
        }
        catch (Exception e) when (e is CryptographicException or IOException or UnauthorizedAccessException)
        {
            return new();
        }
    }

    public void Save(List<StoredNotification> items)
    {
        Directory.CreateDirectory(folder);
        if (items.Count == 0)
        {
            File.Delete(PathOf);
            return;
        }
        var data = ProtectedData.Protect(System.Text.Encoding.UTF8.GetBytes(StoredNotification.Serialize(items)), Entropy, DataProtectionScope.CurrentUser);
        File.WriteAllBytes(PathOf + ".tmp", data);
        File.Move(PathOf + ".tmp", PathOf, overwrite: true);
    }
}

/// <summary>
/// The Bluetooth LE advertisement of a service that Android's companion link looks for (codes from messages): a
/// GATT service with that UUID, discoverable, for 60 seconds. Nothing connects to it.
/// </summary>
internal sealed class CompanionAdvertiser : ICompanionAdvertiser
{
    private readonly Dictionary<Guid, GattServiceProvider> _running = new();

    public async Task<(bool Ok, string? Reason)> StartAsync(Guid service, TimeSpan duration)
    {
        try
        {
            var adapter = await BluetoothAdapter.GetDefaultAsync();
            if (adapter is null || !adapter.IsLowEnergySupported || !adapter.IsPeripheralRoleSupported) return (false, "unsupported");
            var result = await GattServiceProvider.CreateAsync(service);
            if (result.Error != BluetoothError.Success) return (false, Reason(result.Error));
            var provider = result.ServiceProvider;
            var started = new TaskCompletionSource<string?>();
            provider.AdvertisementStatusChanged += (p, args) =>
            {
                if (args.Status is GattServiceProviderAdvertisementStatus.Started or GattServiceProviderAdvertisementStatus.StartedWithoutAllAdvertisementData) started.TrySetResult(null);
                else if (args.Status == GattServiceProviderAdvertisementStatus.Aborted) started.TrySetResult(Reason(args.Error));
            };
            provider.StartAdvertising(new GattServiceProviderAdvertisingParameters { IsDiscoverable = true, IsConnectable = true });
            var outcome = await Task.WhenAny(started.Task, Task.Delay(TimeSpan.FromSeconds(10)));
            var reason = outcome == started.Task ? started.Task.Result : "failed";
            if (reason is not null)
            {
                provider.StopAdvertising();
                return (false, reason);
            }
            lock (_running) _running[service] = provider;
            _ = Task.Delay(duration).ContinueWith(_ => Stop(service), TaskScheduler.Default);
            return (true, null);
        }
        catch (Exception e) when (e is COMException or UnauthorizedAccessException or InvalidOperationException)
        {
            App.Log($"Bluetooth advertisement failed: {e.Message}");
            return (false, e is UnauthorizedAccessException ? "unauthorized" : "failed");
        }
    }

    private static string Reason(BluetoothError error) => error switch
    {
        BluetoothError.RadioNotAvailable => "bluetooth_off",
        BluetoothError.DisabledByPolicy or BluetoothError.DisabledByUser or BluetoothError.ConsentRequired => "unauthorized",
        BluetoothError.NotSupported => "unsupported",
        _ => "failed",
    };

    public void Stop(Guid service)
    {
        GattServiceProvider? provider;
        lock (_running)
        {
            if (!_running.Remove(service, out provider)) return;
        }
        try { provider.StopAdvertising(); }
        catch (COMException) { }
    }
}

/// <summary>
/// This PC's activity for presence.state, every two seconds: seconds since the last keyboard or mouse input (Windows'
/// GetLastInputInfo) and whether the session is locked. Nothing else: no keys, no apps, no screen.
/// </summary>
internal static unsafe partial class ActivityWatch
{
    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetLastInputInfo(LASTINPUTINFO* info);

    [LibraryImport("kernel32.dll")]
    private static partial ulong GetTickCount64();

    /// <summary>Set from the notification area window's session messages (WM_WTSSESSION_CHANGE).</summary>
    public static volatile bool Locked;

    public static uint IdleSeconds()
    {
        var info = new LASTINPUTINFO { cbSize = (uint)sizeof(LASTINPUTINFO) };
        if (!GetLastInputInfo(&info)) return 0;
        // dwTime is the 32-bit tick count of the last input; compare in 32 bits so the wrap after 49 days works.
        var now = (uint)GetTickCount64();
        return (now - info.dwTime) / 1000;
    }
}
