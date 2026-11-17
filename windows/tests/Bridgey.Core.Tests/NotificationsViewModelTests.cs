using Bridgey.ViewModels;
using Xunit;

namespace Bridgey.Tests;

internal sealed class FakeNotifier : IPhoneNotifier
{
    public readonly List<string> Shown = new();
    public void Show(NotificationItem item) => Shown.Add($"show {item.Title}");
    public void ShowCode(NotificationItem item, bool copied) => Shown.Add($"code {item.Code!.Code} {copied}");
    public void Remove(string deviceId, string notificationId) => Shown.Add($"remove {notificationId}");
}

internal sealed class MemoryHistory : INotificationHistory
{
    public List<StoredNotification> Saved = new();
    public List<StoredNotification> Load() => Saved.ToList();
    public void Save(List<StoredNotification> items) => Saved = items.ToList();
}

internal sealed class FakeAdvertiser(bool ok) : ICompanionAdvertiser
{
    public readonly List<string> Calls = new();
    public Task<(bool Ok, string? Reason)> StartAsync(Guid service, TimeSpan duration)
    {
        Calls.Add($"start {service} {duration.TotalSeconds}");
        return Task.FromResult((ok, ok ? null : "unsupported"));
    }
    public void Stop(Guid service) => Calls.Add($"stop {service}");
}

/// <summary>Phone notifications, codes, per-app banners, history and presence in the view models.</summary>
public sealed class NotificationsViewModelTests
{
    private const string Phone = "11111111-1111-4111-8111-111111111111";
    private readonly FakeClient _client = new();
    private readonly FakeNotifier _notifier = new();
    private readonly FakeClipboard _clipboard = new();
    private readonly MemoryHistory _history = new();
    private readonly FakeAdvertiser _advertiser = new(ok: false);
    private readonly AppSettings _settings = new();

    private MainViewModel Model()
    {
        _client.State.Devices.Add(new SnapshotDevice { DeviceId = Phone, Name = "Pixel 9", Platform = "android", Local = new() { ["notifications"] = true } });
        return new MainViewModel(_client, new SettingsViewModel(_settings, _ => { }, "Test PC"), new InlineDispatcher(), _clipboard, new FakeAlerts(), new FakeFiles(), _notifier, _history, _advertiser);
    }

    private static string Post(string id, string title = "Ravi", string text = "On my way", bool quiet = false, string package = "com.whatsapp", string? code = null, bool reply = true) =>
        System.Text.Json.JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["packageName"] = package, ["applicationName"] = package == "com.whatsapp" ? "WhatsApp" : "Messages", ["notificationId"] = id, ["title"] = title, ["text"] = text,
            ["timestamp"] = DateTimeOffset.Now.ToUnixTimeMilliseconds(), ["quiet"] = quiet,
            ["actions"] = reply ? new object[] { new Dictionary<string, object> { ["token"] = "t-reply", ["title"] = "Reply", ["allowsReply"] = true }, new Dictionary<string, object> { ["token"] = "t-read", ["title"] = "Mark as read", ["allowsReply"] = false } } : Array.Empty<object>(),
            ["code"] = code is null ? null : new Dictionary<string, object> { ["code"] = code, ["service"] = "HDFC Bank", ["channel"] = "sms" },
        });

    private void Emit(BridgeyEventKind kind, string? text, int status = 0) => _client.Emit(new BridgeyEvent(kind, status, 0, Phone, null, text, null));

    [Fact]
    public void NotificationDraftsFollowTheSettings()
    {
        var model = Model();
        Assert.Contains("feature  notifications True", _client.Calls);
        Assert.Contains("feature  notification_routing_draft1 True", _client.Calls);
        Assert.Contains("feature  device_presence_draft1 True", _client.Calls);
        Assert.Contains("feature  email_codes_draft1 False", _client.Calls);
        Assert.Contains("codes False False", _client.Calls);
        _client.Calls.Clear();
        model.Settings.ShareActivity = false;
        Assert.Contains("feature  device_presence_draft1 False", _client.Calls);
        model.Settings.CodesFromMessages = true;
        model.Settings.CodesFromEmail = true;
        Assert.Contains("codes True True", _client.Calls);
        Assert.Contains("feature  email_codes_draft1 True", _client.Calls);
        model.ReportActivity(42, locked: false);
        model.ReportActivity(0, locked: true);
        Assert.Contains("presence Input 42", _client.Calls);
        Assert.Contains("presence Locked 0", _client.Calls);
    }

    [Fact]
    public void NotificationsShowWithRepliesAndActionsAndGoAway()
    {
        var model = Model();
        Emit(BridgeyEventKind.Notification, Post("n1"));
        var item = Assert.Single(model.Notifications.Items);
        Assert.Equal(["show Ravi"], _notifier.Shown);
        Assert.True(item.CanReply);
        Assert.Equal("Mark as read", Assert.Single(item.Buttons).Title);
        item.Reply = "  Thanks  ";
        Assert.True(item.CanSendReply);
        item.SendReply();
        Assert.Contains("action n1 t-reply Thanks", _client.Calls);
        Assert.Equal("", item.Reply);
        item.Buttons[0].Run();
        Assert.Contains("action n1 t-read ", _client.Calls);

        // An update replaces it in place; the phone's removal takes it away (history off).
        Emit(BridgeyEventKind.Notification, Post("n1", text: "Here now"));
        Assert.Equal("Here now", Assert.Single(model.Notifications.Items).Text);
        Emit(BridgeyEventKind.NotificationRemoved, "n1");
        Assert.Empty(model.Notifications.Items);
        Assert.Contains("remove n1", _notifier.Shown);
    }

    [Fact]
    public void QuietAndMutedNotificationsShowNoBanner()
    {
        var model = Model();
        Emit(BridgeyEventKind.Notification, Post("q1", quiet: true), status: 1);
        Assert.Single(model.Notifications.Items);
        Assert.Empty(_notifier.Shown);
        var app = Assert.Single(model.Notifications.Apps);
        Assert.Equal("WhatsApp", app.Name);
        app.IsShown = false;
        Assert.Contains("com.whatsapp", _settings.MutedApps);
        Emit(BridgeyEventKind.Notification, Post("m1"));
        Assert.Empty(_notifier.Shown);
        Assert.Equal(2, model.Notifications.Items.Count);
    }

    [Fact]
    public void CodesShowWithCopyAndCanCopyThemselves()
    {
        var model = Model();
        model.Settings.CodesFromMessages = true;
        Emit(BridgeyEventKind.Notification, Post("c1", "VM-HDFCBK", "OTP is 482913", package: "com.google.android.apps.messaging", code: "482913"));
        Assert.Equal(["code 482913 False"], _notifier.Shown);
        model.Notifications.Items[0].CopyCode();
        Assert.Equal("482913", _clipboard.Text);
        model.Settings.CopyCodes = true;
        _clipboard.Text = null;
        Emit(BridgeyEventKind.Notification, Post("c2", "VM-HDFCBK", "OTP is 730164", package: "com.google.android.apps.messaging", code: "730164"));
        Assert.Equal("730164", _clipboard.Text);
        Assert.Contains("code 730164 True", _notifier.Shown);
    }

    [Fact]
    public void HistoryKeepsRemovedNotificationsWithoutCodesAndClears()
    {
        var model = Model();
        model.Settings.NotificationHistory = true;
        Emit(BridgeyEventKind.Notification, Post("h1"));
        Emit(BridgeyEventKind.Notification, Post("h2", "VM-HDFCBK", "OTP is 482913", package: "com.google.android.apps.messaging", code: "482913"));
        Emit(BridgeyEventKind.NotificationRemoved, "h1");
        Assert.False(model.Notifications.Items.Single(i => i.NotificationId == "h1").IsActive);
        Assert.Equal(2, _history.Saved.Count);
        Assert.Equal(NotificationsViewModel.CodeRedacted, _history.Saved.Single(s => s.NotificationId == "h2").Text);

        // Restarting reads it back.
        var again = new NotificationsViewModelTests();
        again._history.Saved = _history.Saved;
        again._settings.NotificationHistory = true;
        Assert.Equal(2, again.Model().Notifications.Items.Count);

        model.Settings.NotificationHistory = false;
        Assert.Empty(_history.Saved);
        Assert.DoesNotContain(model.Notifications.Items, i => !i.IsActive);
    }

    [Fact]
    public void CodesStatusOffersTheLinkAndAdvertisingAnswers()
    {
        var model = Model();
        Emit(BridgeyEventKind.CodesStatus, "hidden");
        var device = Assert.Single(model.Notifications.CodesDevices);
        Assert.True(device.NeedsLink);
        Assert.StartsWith("Android on Pixel 9 hides code messages", device.Text);
        device.Link();
        Assert.Contains($"link {Phone}", _client.Calls);
        var service = Guid.NewGuid();
        Emit(BridgeyEventKind.CodesAdvertise, service.ToString(), status: 1);
        Assert.Contains($"start {service} 60", _advertiser.Calls);
        Assert.Contains($"advertised {service} False unsupported", _client.Calls);
        Emit(BridgeyEventKind.CodesAdvertise, service.ToString(), status: 0);
        Assert.Contains($"stop {service}", _advertiser.Calls);
    }

    [Fact]
    public void BannerButtonsReachThePhone()
    {
        var model = Model();
        Emit(BridgeyEventKind.Notification, Post("b1"));
        model.Notifications.FromBanner(Phone, "b1", "phoneAction", "t-reply", "On it");
        Assert.Contains("action b1 t-reply On it", _client.Calls);
        model.Notifications.FromBanner(Phone, "b1", "phoneDismiss", null, null);
        Assert.Contains($"dismiss {Phone} b1", _client.Calls);
        Assert.Empty(model.Notifications.Items);
    }
}
