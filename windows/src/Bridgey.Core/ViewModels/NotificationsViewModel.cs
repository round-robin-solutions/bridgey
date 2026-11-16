using System.Collections.ObjectModel;

namespace Bridgey.ViewModels;

/// <summary>Windows notifications for phone notifications and codes (the host's toasts).</summary>
public interface IPhoneNotifier
{
    /// <summary>A phone notification: its buttons, a reply box for the action that takes one, and Dismiss.</summary>
    void Show(NotificationItem item);
    /// <summary>A one-time code with Copy code; <paramref name="copied"/> when it is on the clipboard already.</summary>
    void ShowCode(NotificationItem item, bool copied);
    void Remove(string deviceId, string notificationId);
}

/// <summary>Where notification history is kept (encrypted for the Windows user by the host).</summary>
public interface INotificationHistory
{
    List<StoredNotification> Load();
    void Save(List<StoredNotification> items);
}

/// <summary>The Bluetooth LE advertisement Android's companion link looks for (codes from messages).</summary>
public interface ICompanionAdvertiser
{
    /// <summary>Advertises the service for <paramref name="duration"/>; the reason is bluetooth_off, unauthorized, unsupported or failed.</summary>
    Task<(bool Ok, string? Reason)> StartAsync(Guid service, TimeSpan duration);
    void Stop(Guid service);
}

/// <summary>One phone notification: still on the phone, or kept in history.</summary>
public sealed partial class NotificationItem : ObservableObject
{
    private bool _active = true;
    private string _reply = "";

    internal NotificationsViewModel? Owner { get; set; }
    public required string DeviceId { get; init; }
    public required string DeviceName { get; set; }
    public required string NotificationId { get; init; }
    public string PackageName { get; set; } = "";
    public string AppName { get; set; } = "";
    public string Title { get; set; } = "";
    public string Text { get; set; } = "";
    public DateTimeOffset At { get; set; } = DateTimeOffset.Now;
    public string? Icon { get; set; }
    public string? CallType { get; set; }
    public bool Quiet { get; set; }
    public FoundCode? Code { get; set; }
    public List<PhoneAction> Actions { get; set; } = new();

    public List<NotificationActionItem> Buttons => Actions.Where(a => !a.AllowsReply).Select(a => new NotificationActionItem(this, a)).ToList();
    public PhoneAction? ReplyAction => Actions.FirstOrDefault(a => a.AllowsReply);
    public bool CanReply => _active && ReplyAction is not null;
    public bool HasCode => Code is not null;
    public string CodeText => Code is { } c ? c.Code : "";
    public bool HasText => Text.Length > 0;

    /// <summary>"Messages · 15:20".</summary>
    public string Detail => $"{(AppName.Length > 0 ? AppName : PackageName)} · {Time}";

    public string Time
    {
        get
        {
            var local = At.ToLocalTime();
            var today = DateTimeOffset.Now.ToLocalTime().Date;
            if (local.Date == today) return local.ToString("HH:mm");
            if (local.Date == today.AddDays(-1)) return $"Yesterday {local:HH:mm}";
            return local.ToString("d MMM HH:mm");
        }
    }

    /// <summary>Still on the phone: its actions and Dismiss work.</summary>
    public bool IsActive
    {
        get => _active;
        set
        {
            if (!Set(ref _active, value)) return;
            Raise(nameof(CanReply));
            Raise(nameof(CanAct));
        }
    }

    public bool CanAct => _active;

    public string Reply
    {
        get => _reply;
        set
        {
            if (Set(ref _reply, value)) Raise(nameof(CanSendReply));
        }
    }

    public bool CanSendReply => CanReply && _reply.Trim().Length > 0;

    public void SendReply() => Owner?.Reply(this, _reply);
    public void Dismiss() => Owner?.Dismiss(this);
    public void CopyCode() => Owner?.CopyCode(this);
}

/// <summary>A notification's button (Mark as read, Archive, Answer, Decline...).</summary>
public sealed class NotificationActionItem(NotificationItem owner, PhoneAction action)
{
    public string Title => action.Title;
    public string Token => action.Token;
    public void Run() => owner.Owner?.RunAction(owner, action.Token, null);
}

/// <summary>One app seen in phone notifications, with this PC's switch for its banners.</summary>
public sealed partial class AppFilterItem(NotificationsViewModel owner, string package, string name) : ObservableObject
{
    private bool _shown = true;
    public string PackageName { get; } = package;
    public string Name { get; set; } = name;

    public bool IsShown
    {
        get => _shown;
        set
        {
            if (Set(ref _shown, value)) owner.SetMuted(PackageName, !value);
        }
    }

    internal void Show(bool shown)
    {
        if (_shown == shown) return;
        _shown = shown;
        Raise(nameof(IsShown));
    }
}

/// <summary>Whether a phone shows Bridgey the text of code messages, and the way to fix it.</summary>
public sealed partial class CodesDevice(NotificationsViewModel owner, string deviceId) : ObservableObject
{
    private string _status = "";
    private string _name = "";
    public string DeviceId { get; } = deviceId;

    public string Name
    {
        get => _name;
        set
        {
            if (Set(ref _name, value)) Raise(nameof(Text));
        }
    }

    public string Status
    {
        get => _status;
        set
        {
            if (!Set(ref _status, value)) return;
            Raise(nameof(Text));
            Raise(nameof(NeedsLink));
        }
    }

    public bool NeedsLink => _status is "hidden" or "not_linked";

    public string Text => _status switch
    {
        "allowed" => $"{_name} shows Bridgey its code messages.",
        "hidden" => $"Android on {_name} hides code messages from Bridgey. Link this PC on the phone to show them.",
        "not_linked" => $"Link this PC on {_name} so Android shows Bridgey its code messages.",
        _ => "",
    };

    public void Link() => owner.Link(DeviceId);
}

/// <summary>
/// Phone notifications on this PC: banners with the phone's own buttons, a reply box and Dismiss; codes from messages
/// with Copy code; per-app banners; and history (off by default, seven days and at most 200, encrypted by the host).
/// Notifications the phone marks quiet (it is alerting on another device) are kept but never shown as banners.
/// </summary>
public sealed partial class NotificationsViewModel : ObservableObject
{
    public const int Limit = 200;
    public static readonly TimeSpan Keep = TimeSpan.FromDays(7);
    /// <summary>What history keeps instead of a message that held a code (as the Mac does).</summary>
    public const string CodeRedacted = "Sent a one-time code";

    private readonly IBridgeyClient _client;
    private readonly SettingsViewModel _settings;
    private readonly IPhoneNotifier _notifier;
    private readonly IClipboardService _clipboard;
    private readonly INotificationHistory? _history;
    private readonly ICompanionAdvertiser? _advertiser;
    private readonly Func<string, string> _nameOf;
    private string? _notice;

    public ObservableCollection<NotificationItem> Items { get; } = new();
    public ObservableCollection<AppFilterItem> Apps { get; } = new();
    public ObservableCollection<CodesDevice> CodesDevices { get; } = new();

    public NotificationsViewModel(IBridgeyClient client, SettingsViewModel settings, IPhoneNotifier notifier, IClipboardService clipboard,
        INotificationHistory? history, ICompanionAdvertiser? advertiser, Func<string, string> nameOf)
    {
        _client = client;
        _settings = settings;
        _notifier = notifier;
        _clipboard = clipboard;
        _history = history;
        _advertiser = advertiser;
        _nameOf = nameOf;
        Items.CollectionChanged += (_, _) =>
        {
            Raise(nameof(HasItems));
            Raise(nameof(HasNoItems));
        };
        Apps.CollectionChanged += (_, _) => Raise(nameof(HasApps));
        settings.CodesChanged += ApplyCodes;
        settings.NotificationHistoryChanged += on =>
        {
            if (!on) ClearHistory();
            else SaveHistory();
        };
        ApplyCodes();
        foreach (var package in settings.Values.MutedApps) Learn(package, package);
        if (settings.NotificationHistory && _history is not null)
        {
            var cutoff = DateTimeOffset.Now - Keep;
            foreach (var s in _history.Load().Where(s => DateTimeOffset.FromUnixTimeMilliseconds(s.ReceivedAt) > cutoff).OrderByDescending(s => s.ReceivedAt).Take(Limit))
            {
                Items.Add(new NotificationItem
                {
                    Owner = this, DeviceId = s.DeviceId, DeviceName = s.DeviceName, NotificationId = s.NotificationId, PackageName = s.PackageName,
                    AppName = s.ApplicationName, Title = s.Title, Text = s.Text, At = DateTimeOffset.FromUnixTimeMilliseconds(s.ReceivedAt), IsActive = false,
                });
                Learn(s.PackageName, s.ApplicationName);
            }
        }
    }

    public bool HasItems => Items.Count > 0;
    public bool HasNoItems => Items.Count == 0;
    public bool HasApps => Apps.Count > 0;

    /// <summary>The last thing that went wrong here, for the Notifications page.</summary>
    public string? Notice
    {
        get => _notice;
        private set
        {
            if (Set(ref _notice, value)) Raise(nameof(HasNotice));
        }
    }

    public bool HasNotice => _notice is not null;

    public void DismissNotice() => Notice = null;

    private void ApplyCodes()
    {
        try { _client.SetCodes(_settings.CodesFromMessages, _settings.CodesFromMessages && _settings.CodesFromEmail); }
        catch (BridgeyException) { }
    }

    internal void Handle(BridgeyEvent e)
    {
        switch (e.Kind)
        {
            case BridgeyEventKind.Notification when e.DeviceId is not null && PhoneNotification.Parse(e.Text) is { } n:
                Posted(e.DeviceId, n);
                break;
            case BridgeyEventKind.NotificationRemoved when e.DeviceId is not null && e.Text is not null:
                Removed(e.DeviceId, e.Text);
                break;
            case BridgeyEventKind.CodesStatus when e.DeviceId is not null && e.Text is not null:
            {
                var device = CodesDevices.FirstOrDefault(d => d.DeviceId == e.DeviceId);
                if (device is null)
                {
                    device = new CodesDevice(this, e.DeviceId);
                    CodesDevices.Add(device);
                }
                device.Name = _nameOf(e.DeviceId);
                device.Status = e.Text;
                break;
            }
            case BridgeyEventKind.CodesAdvertise when e.DeviceId is not null && Guid.TryParse(e.Text, out var service):
                if (e.Status != 0) _ = Advertise(e.DeviceId, service);
                else _advertiser?.Stop(service);
                break;
            case BridgeyEventKind.TrustChanged when e.Status == 0 && e.DeviceId is not null:
                foreach (var gone in CodesDevices.Where(d => d.DeviceId == e.DeviceId).ToList()) CodesDevices.Remove(gone);
                break;
        }
    }

    private async Task Advertise(string deviceId, Guid service)
    {
        var (ok, reason) = _advertiser is null ? (false, "unsupported") : await _advertiser.StartAsync(service, TimeSpan.FromSeconds(60));
        try { _client.CodesAdvertiseResult(deviceId, service.ToString(), ok, ok ? null : reason); }
        catch (BridgeyException) { }
    }

    private void Posted(string deviceId, PhoneNotification n)
    {
        var item = Items.FirstOrDefault(i => i.DeviceId == deviceId && i.NotificationId == n.NotificationId);
        if (item is not null) Items.Remove(item);
        item = new NotificationItem
        {
            Owner = this,
            DeviceId = deviceId,
            DeviceName = _nameOf(deviceId),
            NotificationId = n.NotificationId,
            PackageName = n.PackageName,
            AppName = n.ApplicationName,
            Title = n.Title,
            Text = n.Text,
            At = n.Timestamp > 0 ? DateTimeOffset.FromUnixTimeMilliseconds(n.Timestamp) : DateTimeOffset.Now,
            Icon = n.Icon,
            CallType = n.CallType,
            Quiet = n.Quiet,
            Code = n.Code,
            Actions = n.Actions,
        };
        Items.Insert(0, item);
        Trim();
        Learn(n.PackageName, n.ApplicationName);
        SaveHistory();
        // A quiet notification is for history: the phone is alerting on the device in use.
        if (n.Quiet) return;
        if (n.Code is not null && _settings.CodesFromMessages)
        {
            var copied = false;
            if (_settings.CopyCodes)
            {
                _clipboard.SetText(n.Code.Code);
                copied = true;
            }
            _notifier.ShowCode(item, copied);
            return;
        }
        if (!_settings.NotificationBanners || IsMuted(n.PackageName)) return;
        // An update of a notification already shown replaces its banner in Windows (same tag).
        _notifier.Show(item);
    }

    private void Removed(string deviceId, string id)
    {
        _notifier.Remove(deviceId, id);
        var item = Items.FirstOrDefault(i => i.DeviceId == deviceId && i.NotificationId == id && i.IsActive);
        if (item is null) return;
        if (_settings.NotificationHistory) item.IsActive = false;
        else Items.Remove(item);
    }

    private void Trim()
    {
        var cutoff = DateTimeOffset.Now - Keep;
        foreach (var old in Items.Where(i => !i.IsActive && i.At < cutoff).ToList()) Items.Remove(old);
        while (Items.Count > Limit) Items.RemoveAt(Items.Count - 1);
    }

    private void SaveHistory()
    {
        if (!_settings.NotificationHistory || _history is null) return;
        var rows = Items.Take(Limit).Select(i => new StoredNotification
        {
            DeviceId = i.DeviceId, DeviceName = i.DeviceName, PackageName = i.PackageName, ApplicationName = i.AppName, NotificationId = i.NotificationId,
            Title = i.Title, Text = i.Code is null ? i.Text : CodeRedacted, Timestamp = i.At.ToUnixTimeMilliseconds(), ReceivedAt = i.At.ToUnixTimeMilliseconds(),
        }).ToList();
        try { _history.Save(rows); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    /// <summary>Deletes the history file and the notifications no longer on the phone.</summary>
    public void ClearHistory()
    {
        foreach (var old in Items.Where(i => !i.IsActive).ToList()) Items.Remove(old);
        try { _history?.Save(new()); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private bool IsMuted(string package) => _settings.Values.MutedApps.Contains(package);

    private void Learn(string package, string name)
    {
        if (package.Length == 0) return;
        var app = Apps.FirstOrDefault(a => a.PackageName == package);
        if (app is null)
        {
            app = new AppFilterItem(this, package, name.Length > 0 ? name : package);
            var at = 0;
            while (at < Apps.Count && string.Compare(Apps[at].Name, app.Name, StringComparison.CurrentCultureIgnoreCase) < 0) at++;
            Apps.Insert(at, app);
        }
        else if (name.Length > 0 && app.Name == package) app.Name = name;
        app.Show(!IsMuted(package));
    }

    internal void SetMuted(string package, bool muted) => _settings.SetAppMuted(package, muted);

    internal void Reply(NotificationItem item, string text)
    {
        if (item.ReplyAction is not { } action || text.Trim().Length == 0) return;
        if (RunAction(item, action.Token, text.Trim())) item.Reply = "";
    }

    /// <summary>Runs one of the phone's actions; true when it went.</summary>
    internal bool RunAction(NotificationItem item, string token, string? reply)
    {
        try
        {
            _client.NotificationAction(item.DeviceId, item.NotificationId, token, reply);
            return true;
        }
        catch (BridgeyException e)
        {
            Notice = e.Code == BridgeyException.NotConnected ? $"{item.DeviceName} isn't connected." : e.Message;
            return false;
        }
    }

    internal void Dismiss(NotificationItem item)
    {
        try { _client.DismissNotification(item.DeviceId, item.NotificationId); }
        catch (BridgeyException e) { Notice = e.Code == BridgeyException.NotConnected ? $"{item.DeviceName} isn't connected." : e.Message; }
        _notifier.Remove(item.DeviceId, item.NotificationId);
        if (_settings.NotificationHistory) item.IsActive = false;
        else Items.Remove(item);
    }

    internal void CopyCode(NotificationItem item)
    {
        if (item.Code is { } code) _clipboard.SetText(code.Code);
    }

    /// <summary>A notification's button or reply from a Windows notification (the host passes its arguments).</summary>
    public void FromBanner(string deviceId, string notificationId, string action, string? token, string? reply)
    {
        var item = Items.FirstOrDefault(i => i.DeviceId == deviceId && i.NotificationId == notificationId);
        switch (action)
        {
            case "phoneDismiss":
                if (item is not null) Dismiss(item);
                else
                {
                    try { _client.DismissNotification(deviceId, notificationId); }
                    catch (BridgeyException) { }
                }
                break;
            case "phoneAction" when token is not null:
                try { _client.NotificationAction(deviceId, notificationId, token, reply is { Length: > 0 } ? reply : null); }
                catch (BridgeyException) { }
                break;
            case "copyCode" when item?.Code is { } code:
                _clipboard.SetText(code.Code);
                break;
        }
    }

    internal void Link(string deviceId)
    {
        try { _client.CodesLinkRequest(deviceId); }
        catch (BridgeyException e) { Notice = e.Message; }
    }

    internal void DeviceRenamed(string deviceId, string name)
    {
        foreach (var d in CodesDevices.Where(d => d.DeviceId == deviceId)) d.Name = name;
    }
}
