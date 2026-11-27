using System.Collections.ObjectModel;
using System.Text.Json.Nodes;

namespace Bridgey.ViewModels;

/// <summary>
/// Text messages (sms_draft1): the phone's conversations, as the Mac's Messages window shows them. bridgey_core
/// (rust/client/src/sms.rs) keeps them in step with the phone and caches them; this asks it with JSON commands and
/// refreshes on its events. Unread conversations come first; pictures load when shown, in memory only.
/// </summary>
public sealed partial class MessagesViewModel : ObservableObject
{
    private readonly IBridgeyClient _client;
    private readonly Func<string, string> _nameOf;
    private string? _phone;
    private ConversationItem? _selected;
    private bool _unreadOnly;
    private string _draft = "";
    private string _to = "";
    private bool _composing;
    private string? _notice;
    private string _status = "";
    private bool _available;
    private bool _canSend;
    private bool _older;
    private bool _moreConversations;
    /// <summary>The list is being brought up to date: a list control that loses its selection while rows move does
    /// not close the open conversation.</summary>
    private bool _reloading;
    private SimChoice? _sim;
    private readonly Dictionary<string, byte[]> _images = new();
    private readonly HashSet<string> _failedImages = new();

    public MessagesViewModel(IBridgeyClient client, Func<string, string> nameOf)
    {
        _client = client;
        _nameOf = nameOf;
        Conversations.CollectionChanged += (_, _) =>
        {
            Raise(nameof(HasConversations));
            Raise(nameof(HasNoConversations));
        };
    }

    /// <summary>Phones with Text messages on at both ends.</summary>
    public ObservableCollection<DeviceItem> Phones { get; } = new();
    public ObservableCollection<ConversationItem> Conversations { get; } = new();
    /// <summary>The open conversation, oldest first.</summary>
    public ObservableCollection<MessageItem> Messages { get; } = new();
    public ObservableCollection<ContactItem> Contacts { get; } = new();
    public ObservableCollection<SimChoice> Sims { get; } = new();

    /// <summary>The phone the window shows.</summary>
    public string? PhoneId
    {
        get => _phone;
        set
        {
            if (!Set(ref _phone, value)) return;
            Selected = null;
            Composing = false;
            Raise(nameof(SelectedPhone));
            Reload();
            Refresh();
        }
    }

    public DeviceItem? SelectedPhone
    {
        get => Phones.FirstOrDefault(p => p.Id == _phone);
        set
        {
            if (value is not null) PhoneId = value.Id;
        }
    }

    public bool HasManyPhones => Phones.Count > 1;
    public bool HasPhone => _phone is not null;
    public bool HasNoPhone => _phone is null;
    public bool HasConversations => Conversations.Count > 0;
    public bool HasNoConversations => _phone is not null && Conversations.Count == 0;

    /// <summary>Text messages is on here and on the phone, and it is connected.</summary>
    public bool IsAvailable
    {
        get => _available;
        private set
        {
            if (Set(ref _available, value)) Raise(nameof(CanSendDraft));
        }
    }

    /// <summary>One line under the title: what the phone needs, or nothing.</summary>
    public string Status
    {
        get => _status;
        private set
        {
            if (Set(ref _status, value)) Raise(nameof(HasStatus));
        }
    }

    public bool HasStatus => _status.Length > 0;

    /// <summary>All (false) or Unread (true).</summary>
    public bool UnreadOnly
    {
        get => _unreadOnly;
        set
        {
            if (!Set(ref _unreadOnly, value)) return;
            Raise(nameof(FilterIndex));
            Reload();
        }
    }

    public int FilterIndex
    {
        get => _unreadOnly ? 1 : 0;
        set => UnreadOnly = value == 1;
    }

    public ConversationItem? Selected
    {
        get => _selected;
        set
        {
            var previous = _selected;
            if (_reloading && value is null && previous is not null && Conversations.Contains(previous))
            {
                Raise();
                return;
            }
            if (!Set(ref _selected, value)) return;
            Messages.Clear();
            _images.Clear();
            _failedImages.Clear();
            Draft = "";
            if (value is not null && _composing)
            {
                _composing = false;
                Raise(nameof(Composing));
            }
            Raise(nameof(HasSelection));
            Raise(nameof(HasNoSelection));
            Raise(nameof(HasThread));
            Raise(nameof(Title));
            Raise(nameof(Subtitle));
            Raise(nameof(IsGroup));
            if (previous is not null && _phone is not null && value is null) Command(new JsonObject { ["op"] = "close" });
            if (value is null || _phone is null) return;
            ShowMessages(Command(new JsonObject { ["op"] = "open", ["threadId"] = value.ThreadId }));
            if (value.Unread > 0) MarkRead(value);
        }
    }

    public bool HasSelection => _selected is not null;
    /// <summary>A conversation or a new message is open on the right.</summary>
    public bool HasThread => _selected is not null || _composing;
    public bool HasNoSelection => !HasThread;
    public string Title => _selected?.Title ?? (_composing ? "New message" : "");
    public string Subtitle => _selected is { Group: false } c && c.Address != c.Title ? c.Address : "";

    public string Draft
    {
        get => _draft;
        set
        {
            if (Set(ref _draft, value)) Raise(nameof(CanSendDraft));
        }
    }

    public bool CanSend
    {
        get => _canSend;
        private set
        {
            if (Set(ref _canSend, value)) Raise(nameof(CanSendDraft));
        }
    }

    /// <summary>Something to send, somewhere to send it, and the phone can send. Group conversations are answered on the phone.</summary>
    public bool CanSendDraft => _available && _canSend && _draft.Trim().Length > 0 && _draft.Length <= 2000
        && (_selected is { Group: false } || (_composing && _to.Trim().Length > 0));

    public bool IsGroup => _selected?.Group == true;

    /// <summary>The phone has older conversations than the list shows.</summary>
    public bool HasMoreConversations
    {
        get => _moreConversations;
        private set => Set(ref _moreConversations, value);
    }

    public bool HasOlder
    {
        get => _older;
        private set => Set(ref _older, value);
    }

    /// <summary>The SIM a message goes from, when the phone has more than one.</summary>
    public SimChoice? Sim
    {
        get => _sim;
        set => Set(ref _sim, value);
    }

    public bool HasSims => Sims.Count > 1;

    /// <summary>New message: the number or name typed in To.</summary>
    public bool Composing
    {
        get => _composing;
        set
        {
            if (!Set(ref _composing, value)) return;
            if (value) Selected = null;
            To = "";
            Contacts.Clear();
            Raise(nameof(HasThread));
            Raise(nameof(HasNoSelection));
            Raise(nameof(Title));
            Raise(nameof(CanSendDraft));
        }
    }

    public string To
    {
        get => _to;
        set
        {
            if (!Set(ref _to, value)) return;
            Raise(nameof(CanSendDraft));
            if (_composing && _phone is not null && value.Trim().Length >= 2 && !value.Any(char.IsDigit)) Command(new JsonObject { ["op"] = "contacts", ["query"] = value.Trim() });
            else Contacts.Clear();
        }
    }

    /// <summary>What Mark as read or Block on phone did, or why a send could not go.</summary>
    public string? Notice
    {
        get => _notice;
        set
        {
            if (Set(ref _notice, value)) Raise(nameof(HasNotice));
        }
    }

    public bool HasNotice => _notice is not null;

    public void DismissNotice() => Notice = null;

    // MARK: From the main view model

    /// <summary>Text messages became ready or stopped being ready on a device (both ends' switches and the connection).</summary>
    internal void Readiness(DeviceItem device, bool ready)
    {
        var listed = Phones.Contains(device);
        if (ready && !listed) Phones.Add(device);
        if (!ready && listed) Phones.Remove(device);
        Raise(nameof(HasManyPhones));
        Raise(nameof(SelectedPhone));
        if (_phone is null && Phones.Count > 0) PhoneId = Phones[0].Id;
        else if (_phone == device.Id) LoadStatus();
    }

    /// <summary>A device was forgotten.</summary>
    internal void Forgotten(string deviceId)
    {
        if (Phones.FirstOrDefault(p => p.Id == deviceId) is { } p) Phones.Remove(p);
        if (_phone == deviceId) PhoneId = Phones.FirstOrDefault()?.Id;
    }

    internal void Handle(BridgeyEvent e)
    {
        if (e.Kind != BridgeyEventKind.Sms || e.DeviceId != _phone || e.Text is null) return;
        JsonNode? detail;
        try { detail = JsonNode.Parse(e.Text); }
        catch (System.Text.Json.JsonException) { return; }
        switch (e.Name)
        {
            case "status":
                LoadStatus();
                break;
            case "changed":
                Reload();
                if (_selected is { } open && (detail?["threadId"] is null || Long(detail["threadId"]) == open.ThreadId))
                    ShowMessages(Command(new JsonObject { ["op"] = "messages", ["threadId"] = open.ThreadId }));
                break;
            case "send":
                if (_selected is { } c) ShowMessages(Command(new JsonObject { ["op"] = "messages", ["threadId"] = c.ThreadId }));
                if (Str(detail?["state"]) is "failed" or "refused") Notice = SendProblem(Str(detail?["reason"]));
                break;
            case "image" when Str(detail?["partId"]) is { } part:
                if (Str(detail?["data"]) is { } data)
                {
                    try { _images[part] = Convert.FromBase64String(data); }
                    catch (FormatException) { _failedImages.Add(part); }
                }
                else _failedImages.Add(part);
                foreach (var m in Messages.Where(m => m.PartId == part)) m.ImageArrived(_images.GetValueOrDefault(part), _failedImages.Contains(part));
                break;
            case "contacts":
                Contacts.Clear();
                foreach (var found in detail?["contacts"]?.AsArray() ?? [])
                    if (Str(found?["name"]) is { } name && Str(found?["address"]) is { } address) Contacts.Add(new ContactItem(this, name, address, Str(found?["label"])));
                break;
            case "notice":
                Notice = NoticeText(detail);
                break;
        }
    }

    internal static string SendProblem(string? reason) => reason switch
    {
        "disabled" => "Text messages is off for this PC on your phone.",
        "permission" => "Your phone needs permission to send texts. Open Bridgey on the phone.",
        "group" => "Group conversations are answered on the phone.",
        "no_sim" => "That SIM isn't active on your phone.",
        "rate_limited" => "Too many texts at once. Try again in a moment.",
        "radio_off" or "no_service" => "Your phone has no mobile signal right now.",
        "invalid" => "Your phone can't send to that number.",
        _ => "The text wasn't sent.",
    };

    internal static string? NoticeText(JsonNode? d)
    {
        switch (Str(d?["kind"]))
        {
            case "mark_read":
                if (Bool(d?["noAnswer"])) return "Your phone didn't answer, so it still counts them unread.";
                if (Bool(d?["disabled"])) return "Text messages is off for this PC on your phone.";
                var left = Long(d?["total"]) - Long(d?["marked"]);
                if (left <= 0) return null;
                return left == 1 ? "1 conversation stays unread on your phone. Open it there to clear it." : $"{left} conversations stay unread on your phone. Open them there to clear them.";
            case "blocked":
                return Str(d?["result"]) switch
                {
                    "opened" => "Blocked numbers is open on your phone.",
                    "notified" => "Tap the notification on your phone to open Blocked numbers.",
                    "unavailable" => "Your phone has no Blocked numbers screen.",
                    _ => "Your phone didn't answer.",
                };
            default:
                return null;
        }
    }

    // MARK: Actions

    /// <summary>The newest conversations again (the window opened, or Refresh).</summary>
    public void Refresh()
    {
        if (_phone is null) return;
        Command(new JsonObject { ["op"] = "refresh" });
    }

    public void LoadOlder() => Command(new JsonObject { ["op"] = "older_threads" });

    public void LoadOlderMessages()
    {
        if (_selected is { } c) Command(new JsonObject { ["op"] = "older_messages", ["threadId"] = c.ThreadId });
    }

    public void NewMessage() => Composing = true;

    public void Send()
    {
        if (!CanSendDraft) return;
        var command = new JsonObject { ["op"] = "send", ["body"] = _draft };
        if (_selected is { } c) command["threadId"] = c.ThreadId;
        else command["address"] = _to.Trim();
        if (_sim is { } sim && HasSims) command["subId"] = sim.SubId;
        var answer = Command(command);
        if (!Bool(answer?["ok"]))
        {
            Notice = Str(answer?["error"]) == "invalid" ? "That number can't take texts." : "Your phone isn't connected.";
            return;
        }
        Draft = "";
        if (_composing)
        {
            // The conversation shows up with the phone's next change; the list is where it lands.
            Composing = false;
            Refresh();
        }
        else if (_selected is { } open) ShowMessages(Command(new JsonObject { ["op"] = "messages", ["threadId"] = open.ThreadId }));
    }

    public void Retry(MessageItem item)
    {
        if (item.RequestId is { } id) Command(new JsonObject { ["op"] = "retry", ["requestId"] = id });
    }

    public void Discard(MessageItem item)
    {
        if (item.RequestId is not { } id) return;
        Command(new JsonObject { ["op"] = "discard", ["requestId"] = id });
        Messages.Remove(item);
    }

    public void MarkRead(ConversationItem item)
    {
        Command(new JsonObject { ["op"] = "mark_read", ["threadIds"] = new JsonArray(item.ThreadId) });
        item.Unread = 0;
    }

    public void MarkUnread(ConversationItem item) => Command(new JsonObject { ["op"] = "mark_unread", ["threadIds"] = new JsonArray(item.ThreadId) });

    /// <summary>Opens Android's Blocked numbers on the phone, with the conversation's number.</summary>
    public void BlockOnPhone(ConversationItem item) => Command(new JsonObject { ["op"] = "block", ["address"] = item.Address });

    internal void PickContact(ContactItem contact)
    {
        To = contact.Address;
        Contacts.Clear();
    }

    /// <summary>A picture to show: asked for once, kept in memory while the conversation is open.</summary>
    internal void WantImage(MessageItem item)
    {
        if (item.PartId is not { } part) return;
        if (_images.TryGetValue(part, out var bytes) || _failedImages.Contains(part))
        {
            item.ImageArrived(bytes, _failedImages.Contains(part));
            return;
        }
        Command(new JsonObject { ["op"] = "image", ["partId"] = part });
    }

    /// <summary>Opens a conversation from a notification (smsThreadId).</summary>
    public void Open(string deviceId, long threadId)
    {
        if (Phones.Any(p => p.Id == deviceId)) PhoneId = deviceId;
        if (_phone != deviceId) return;
        Reload();
        Selected = Conversations.FirstOrDefault(c => c.ThreadId == threadId);
    }

    /// <summary>A reply typed into an SMS notification that has no reply of its own: sent through the phone.</summary>
    public bool ReplyToNotification(string deviceId, string notificationId, string body) =>
        Bool(Command(new JsonObject { ["op"] = "send", ["notificationId"] = notificationId, ["body"] = body }, deviceId)?["ok"]);

    /// <summary>Keep conversations on this PC (Settings > Text messages); off deletes what is stored.</summary>
    public void Keep(bool on)
    {
        // The setting is the library's, not a phone's; any trusted device carries the command.
        if (_client.Snapshot().Devices.FirstOrDefault() is { } any) Command(new JsonObject { ["op"] = "keep", ["on"] = on }, any.DeviceId);
    }

    // MARK: Reading what bridgey_core keeps

    private JsonNode? Command(JsonObject command, string? device = null)
    {
        if ((device ?? _phone) is not { } id) return null;
        try { return JsonNode.Parse(_client.Phone(PhoneArea.Sms, id, command.ToJsonString())); }
        catch (Exception e) when (e is BridgeyException or System.Text.Json.JsonException) { return null; }
    }

    private void LoadStatus()
    {
        var s = Command(new JsonObject { ["op"] = "status" });
        IsAvailable = Bool(s?["available"]);
        var phone = s?["phone"];
        CanSend = Bool(phone?["send"]);
        var sims = (phone?["sims"]?.AsArray() ?? []).Where(x => x is not null).Select(x => new SimChoice(Long(x!["subId"]), Str(x["label"]) ?? $"SIM {Long(x["slot"]) + 1}")).ToList();
        if (!sims.SequenceEqual(Sims))
        {
            Sims.Clear();
            foreach (var sim in sims) Sims.Add(sim);
            Sim = Sims.FirstOrDefault();
            Raise(nameof(HasSims));
        }
        Status = _phone is null ? ""
            : !IsAvailable ? $"{_nameOf(_phone)} isn't connected."
            : phone is null ? "Waiting for your phone…"
            : !Bool(phone["read"]) ? "Your phone needs permission to read texts. Open Bridgey on the phone."
            : "";
    }

    /// <summary>The list again, keeping rows that did not change so the list moves only what changed.</summary>
    private void Reload()
    {
        var command = new JsonObject { ["op"] = "threads", ["filter"] = _unreadOnly ? "unread" : "all" };
        if (_selected is { } held) command["holding"] = held.ThreadId;
        var answer = Command(command);
        HasMoreConversations = Bool(answer?["more"]);
        var rows = answer?["threads"]?.AsArray() ?? [];
        var wanted = new List<ConversationItem>();
        foreach (var row in rows)
        {
            if (row is null) continue;
            var id = Long(row["threadId"]);
            var item = Conversations.FirstOrDefault(c => c.ThreadId == id) ?? new ConversationItem(this, id);
            item.Update(row);
            wanted.Add(item);
        }
        _reloading = true;
        try { Sync(Conversations, wanted); }
        finally { _reloading = false; }
        Raise(nameof(HasNoConversations));
        Raise(nameof(HasPhone));
        Raise(nameof(HasNoPhone));
        if (_selected is { } s && !Conversations.Contains(s)) Selected = null;
        LoadStatus();
    }

    /// <summary>Moves, inserts and removes in place, so the list animates only what changed.</summary>
    private static void Sync<T>(ObservableCollection<T> list, List<T> wanted) where T : class
    {
        foreach (var gone in list.Where(x => !wanted.Contains(x)).ToList()) list.Remove(gone);
        for (var i = 0; i < wanted.Count; i++)
        {
            var at = list.IndexOf(wanted[i]);
            if (at == i) continue;
            if (at >= 0) list.Move(at, i);
            else list.Insert(i, wanted[i]);
        }
    }

    private void ShowMessages(JsonNode? answer)
    {
        if (!Bool(answer?["ok"])) return;
        HasOlder = Bool(answer!["older"]);
        var wanted = new List<MessageItem>();
        // bridgey_core lists newest first; the conversation reads oldest at the top.
        foreach (var m in (answer["messages"]?.AsArray() ?? []).Reverse())
        {
            if (m is null) continue;
            var id = Str(m["id"]) ?? "";
            var item = Messages.FirstOrDefault(x => x.Id == id) ?? new MessageItem(this, id);
            item.Update(m);
            wanted.Add(item);
        }
        foreach (var o in answer["outgoing"]?.AsArray() ?? [])
        {
            if (o is null) continue;
            var id = "out:" + Str(o["requestId"]);
            var item = Messages.FirstOrDefault(x => x.Id == id) ?? new MessageItem(this, id);
            item.UpdateOutgoing(o);
            wanted.Add(item);
        }
        Sync(Messages, wanted);
        CanSend = Bool(answer["canSend"]);
        Raise(nameof(IsGroup));
        Raise(nameof(CanSendDraft));
    }

    internal static long Long(JsonNode? node)
    {
        try { return node?.GetValue<long>() ?? 0; }
        catch (Exception e) when (e is FormatException or InvalidOperationException) { return 0; }
    }

    internal static string? Str(JsonNode? node)
    {
        try { return node?.GetValue<string>(); }
        catch (Exception e) when (e is FormatException or InvalidOperationException) { return null; }
    }

    internal static bool Bool(JsonNode? node)
    {
        try { return node?.GetValue<bool>() == true; }
        catch (Exception e) when (e is FormatException or InvalidOperationException) { return false; }
    }

    /// <summary>"15:20", "Yesterday", "Monday", "3 Nov", "3 Nov 2025".</summary>
    internal static string When(long ms)
    {
        if (ms <= 0) return "";
        var at = DateTimeOffset.FromUnixTimeMilliseconds(ms).ToLocalTime();
        var today = DateTimeOffset.Now.ToLocalTime().Date;
        if (at.Date == today) return at.ToString("HH:mm");
        if (at.Date == today.AddDays(-1)) return "Yesterday";
        if (at.Date > today.AddDays(-7)) return at.ToString("dddd");
        return at.ToString(at.Year == today.Year ? "d MMM" : "d MMM yyyy");
    }
}

/// <summary>One conversation in the list.</summary>
public sealed partial class ConversationItem(MessagesViewModel owner, long threadId) : ObservableObject
{
    private string _title = "";
    private string _snippet = "";
    private long _date;
    private long _unread;

    public long ThreadId { get; } = threadId;
    public string Address { get; private set; } = "";
    public bool Group { get; private set; }

    public string Title
    {
        get => _title;
        private set
        {
            if (Set(ref _title, value)) Raise(nameof(Initial));
        }
    }

    public string Snippet
    {
        get => _snippet;
        private set => Set(ref _snippet, value);
    }

    public long Unread
    {
        get => _unread;
        set
        {
            if (!Set(ref _unread, value)) return;
            Raise(nameof(IsUnread));
            Raise(nameof(UnreadText));
            Raise(nameof(Label));
        }
    }

    public bool IsUnread => _unread > 0;
    public string UnreadText => _unread > 99 ? "99+" : _unread.ToString();
    public string Time => MessagesViewModel.When(_date);
    public string Initial => string.IsNullOrWhiteSpace(_title) || !char.IsLetter(_title.TrimStart()[0]) ? "#" : char.ToUpperInvariant(_title.TrimStart()[0]).ToString();

    /// <summary>What Narrator reads for the row.</summary>
    public string Label => $"{_title}. {(_unread == 1 ? "1 unread. " : _unread > 1 ? $"{_unread} unread. " : "")}{_snippet}. {Time}";

    internal void Update(JsonNode row)
    {
        Title = MessagesViewModel.Str(row["title"]) ?? "";
        Snippet = MessagesViewModel.Str(row["snippet"]) ?? "";
        _date = MessagesViewModel.Long(row["date"]);
        Raise(nameof(Time));
        Group = MessagesViewModel.Bool(row["group"]);
        Address = MessagesViewModel.Str(row["participants"]?[0]?["address"]) ?? "";
        Unread = MessagesViewModel.Long(row["unread"]);
        Raise(nameof(Label));
    }

    public void MarkRead() => owner.MarkRead(this);
    public void MarkUnread() => owner.MarkUnread(this);
    public void BlockOnPhone() => owner.BlockOnPhone(this);

    /// <summary>The list row's name for Narrator and UI Automation.</summary>
    public override string ToString() => Label;
}

/// <summary>One message in the open conversation, or a text this PC is sending.</summary>
public sealed partial class MessageItem(MessagesViewModel owner, string id) : ObservableObject
{
    private string _body = "";
    private string _state = "";
    private long _date;
    private byte[]? _image;
    private bool _imageFailed;
    private bool _incoming;

    public string Id { get; } = id;

    public bool Incoming
    {
        get => _incoming;
        private set
        {
            if (Set(ref _incoming, value)) Raise(nameof(Outgoing));
        }
    }

    public bool Outgoing => !_incoming;
    /// <summary>The first picture of an MMS, if any.</summary>
    public string? PartId { get; private set; }
    public bool HasPicture => PartId is not null;
    /// <summary>This PC's send, until the phone's own list has it.</summary>
    public string? RequestId { get; private set; }

    public string Body
    {
        get => _body;
        private set
        {
            if (Set(ref _body, value)) Raise(nameof(HasBody));
        }
    }

    public bool HasBody => _body.Length > 0;

    /// <summary>Sending, Sent, Delivered or Not sent (outgoing only).</summary>
    public string State
    {
        get => _state;
        private set
        {
            if (!Set(ref _state, value)) return;
            Raise(nameof(Failed));
            Raise(nameof(Meta));
        }
    }

    public bool Failed => _state == "Not sent";
    public bool CanRetry => Failed && RequestId is not null;
    public string Meta => _incoming || _state.Length == 0 ? MessagesViewModel.When(_date) : $"{MessagesViewModel.When(_date)} · {_state}";
    public string Label => $"{(_incoming ? "Received" : "Sent")} {Meta}. {(HasPicture ? "Picture. " : "")}{_body}";

    /// <summary>The picture's bytes once they arrived (a JPEG or PNG of at most 28 KiB from the phone).</summary>
    public byte[]? Image
    {
        get => _image;
        private set
        {
            if (Set(ref _image, value)) Raise(nameof(HasImage));
        }
    }

    public bool HasImage => _image is not null;

    public bool ImageFailed
    {
        get => _imageFailed;
        private set => Set(ref _imageFailed, value);
    }

    internal void Update(JsonNode m)
    {
        Incoming = MessagesViewModel.Str(m["direction"]) == "in";
        Body = MessagesViewModel.Str(m["body"]) ?? "";
        _date = MessagesViewModel.Long(m["date"]);
        PartId = (m["parts"]?.AsArray() ?? []).Select(p => MessagesViewModel.Str(p?["partId"])).FirstOrDefault(p => p is not null);
        State = _incoming ? "" : MessagesViewModel.Str(m["status"]) switch
        {
            "pending" => "Sending",
            "failed" => "Not sent",
            "delivered" => "Delivered",
            _ => "",
        };
        Raise(nameof(Meta));
        Raise(nameof(Label));
        Raise(nameof(HasPicture));
        Raise(nameof(CanRetry));
        if (PartId is not null && _image is null && !_imageFailed) owner.WantImage(this);
    }

    internal void UpdateOutgoing(JsonNode o)
    {
        Incoming = false;
        RequestId = MessagesViewModel.Str(o["requestId"]);
        Body = MessagesViewModel.Str(o["body"]) ?? "";
        _date = MessagesViewModel.Long(o["date"]);
        State = MessagesViewModel.Str(o["state"]) switch
        {
            "sending" => "Sending",
            "sent" => "Sent",
            "delivered" => "Delivered",
            _ => "Not sent",
        };
        Raise(nameof(Meta));
        Raise(nameof(Label));
        Raise(nameof(CanRetry));
    }

    internal void ImageArrived(byte[]? bytes, bool failed)
    {
        Image = bytes;
        ImageFailed = failed && bytes is null;
    }

    public void Retry() => owner.Retry(this);
    public void Discard() => owner.Discard(this);

    public override string ToString() => Label;
}

/// <summary>A contact the phone found for a new message.</summary>
public sealed class ContactItem(MessagesViewModel owner, string name, string address, string? label)
{
    public string Name { get; } = name;
    public string Address { get; } = address;
    public string Detail => label is { Length: > 0 } l ? $"{l} · {Address}" : Address;
    public void Pick() => owner.PickContact(this);

    public override string ToString() => $"{Name}, {Detail}";
}

/// <summary>One of the phone's SIMs.</summary>
public sealed record SimChoice(long SubId, string Label)
{
    public override string ToString() => Label;
}
