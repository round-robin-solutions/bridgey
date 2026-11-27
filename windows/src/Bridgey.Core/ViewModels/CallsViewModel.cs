using System.Collections.ObjectModel;
using System.Text.Json.Nodes;

namespace Bridgey.ViewModels;

/// <summary>
/// The Calls window (dialer_draft1), as the Mac's: a keypad and a search field, the phone's contacts and recent calls,
/// the SIM to call from, and what happened to each call. The phone places every call, so its audio stays on the phone.
/// bridgey_core (rust/client/src/calls.rs) talks to the phone and builds the list; this asks it with JSON commands.
/// It also keeps the call card: the phone's incoming or ongoing call with its own Answer, Decline and Hang up.
/// </summary>
public sealed partial class CallsViewModel : ObservableObject
{
    private readonly IBridgeyClient _client;
    private readonly SettingsViewModel _settings;
    private readonly Func<string, string> _nameOf;
    private readonly IUiDispatcher _ui;
    private string? _phone;
    private string _query = "";
    private string? _notice;
    private bool _noticeGood;
    private bool _available;
    private bool _upstream;
    private bool _calling;
    private bool _searching;
    private bool _whatsApp;
    private SimChoice? _sim;
    private string? _askingSimFor;
    private string _empty = "";
    private CallRowItem? _selectedRow;
    private CallCardItem? _card;
    private readonly List<CallCardItem> _calls = new();
    private readonly HashSet<string> _hidden = new();

    /// <summary>How long a call card stays after the phone takes its notification away without saying the call ended.</summary>
    internal Func<TimeSpan, Task> Delay { get; set; } = Task.Delay;
    internal static readonly TimeSpan RemovalGrace = TimeSpan.FromSeconds(2);

    public CallsViewModel(IBridgeyClient client, SettingsViewModel settings, IUiDispatcher ui, Func<string, string> nameOf)
    {
        _client = client;
        _settings = settings;
        _ui = ui;
        _nameOf = nameOf;
    }

    /// <summary>Phones this PC may call through (the Calls window, or calls without it).</summary>
    public ObservableCollection<DeviceItem> Phones { get; } = new();
    public ObservableCollection<CallRowItem> Rows { get; } = new();
    public ObservableCollection<SimChoice> Sims { get; } = new();

    public string? PhoneId
    {
        get => _phone;
        set
        {
            if (!Set(ref _phone, value)) return;
            Raise(nameof(SelectedPhone));
            Raise(nameof(HasPhone));
            Raise(nameof(HasNoPhone));
            Notice = null;
            AskingSimFor = null;
            Load();
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

    public string PhoneName => _phone is null ? "your phone" : _nameOf(_phone);
    public bool HasManyPhones => Phones.Count > 1;
    public bool HasPhone => _phone is not null;
    public bool HasNoPhone => _phone is null;

    /// <summary>The Calls window is on at both ends: contacts, recent calls and WhatsApp work.</summary>
    public bool IsAvailable
    {
        get => _available;
        private set
        {
            if (!Set(ref _available, value)) return;
            Raise(nameof(CanCall));
            Raise(nameof(ShowsWhatsApp));
        }
    }

    /// <summary>Only plain calls work (the phone has calls on, but not the Calls window for this PC).</summary>
    public bool IsUpstreamOnly
    {
        get => _upstream && !_available;
        private set
        {
            if (Set(ref _upstream, value)) Raise(nameof(CanCall));
        }
    }

    public bool CanCall => (_available || _upstream) && !_calling;

    public bool Calling
    {
        get => _calling;
        private set
        {
            if (Set(ref _calling, value)) Raise(nameof(CanCall));
        }
    }

    public bool Searching
    {
        get => _searching;
        private set => Set(ref _searching, value);
    }

    /// <summary>WhatsApp voice and video buttons: the phone has WhatsApp and Settings > Calls shows them.</summary>
    public bool ShowsWhatsApp => _available && _whatsApp && _settings.CallsShowWhatsApp;

    /// <summary>The name or number typed, or keyed on the keypad.</summary>
    public string Query
    {
        get => _query;
        set
        {
            value ??= "";
            if (!Set(ref _query, value)) return;
            Raise(nameof(HasQuery));
            Raise(nameof(ListTitle));
            Raise(nameof(QueryIsNumber));
            AskingSimFor = null;
            Command(new JsonObject { ["op"] = "search", ["query"] = value });
            LoadRows();
        }
    }

    public bool HasQuery => _query.Length > 0;
    public bool QueryIsNumber => NormalisedNumber(_query) is not null;
    public string ListTitle => _query.Trim().Length == 0 ? "Recent calls" : "Results";

    public CallRowItem? SelectedRow
    {
        get => _selectedRow;
        set => Set(ref _selectedRow, value);
    }

    /// <summary>The SIM chosen in the window for the next call, when the phone has two.</summary>
    public SimChoice? Sim
    {
        get => _sim;
        set => Set(ref _sim, value);
    }

    public bool HasSims => _available && Sims.Count > 1;

    /// <summary>The number waiting for a SIM choice ("Call from which SIM?").</summary>
    public string? AskingSimFor
    {
        get => _askingSimFor;
        private set
        {
            if (Set(ref _askingSimFor, value)) Raise(nameof(IsAskingSim));
        }
    }

    public bool IsAskingSim => _askingSimFor is not null;

    /// <summary>What the list says when it is empty (why, and what to do).</summary>
    public string EmptyText
    {
        get => _empty;
        private set
        {
            if (Set(ref _empty, value)) Raise(nameof(HasEmptyText));
        }
    }

    public bool HasEmptyText => _empty.Length > 0 && Rows.Count == 0;

    /// <summary>What happened to the last call, in plain words.</summary>
    public string? Notice
    {
        get => _notice;
        private set
        {
            if (!Set(ref _notice, value)) return;
            Raise(nameof(HasNotice));
            Raise(nameof(AudioText));
        }
    }

    public bool NoticeGood
    {
        get => _noticeGood;
        private set => Set(ref _noticeGood, value);
    }

    public bool HasNotice => _notice is not null;
    public string AudioText => $"Call audio stays on {PhoneName} or its earbuds.";

    public void DismissNotice() => Notice = null;

    // MARK: From the main view model

    internal void Readiness(DeviceItem device, bool ready)
    {
        var listed = Phones.Contains(device);
        if (ready && !listed) Phones.Add(device);
        if (!ready && listed) Phones.Remove(device);
        Raise(nameof(HasManyPhones));
        Raise(nameof(SelectedPhone));
        if (_phone is null && Phones.Count > 0) PhoneId = Phones[0].Id;
        else if (_phone == device.Id)
        {
            if (!ready) PhoneId = Phones.FirstOrDefault()?.Id;
            else Load();
        }
    }

    internal void Forgotten(string deviceId)
    {
        if (Phones.FirstOrDefault(p => p.Id == deviceId) is { } p) Phones.Remove(p);
        if (_phone == deviceId) PhoneId = Phones.FirstOrDefault()?.Id;
        foreach (var call in _calls.Where(c => c.DeviceId == deviceId).ToList()) _calls.Remove(call);
        ShowCard();
    }

    internal void SettingsChanged()
    {
        Raise(nameof(ShowsWhatsApp));
        LoadRows();
    }

    internal void Handle(BridgeyEvent e)
    {
        switch (e.Kind)
        {
            case BridgeyEventKind.Calls when e.DeviceId == _phone && e.Text is not null:
                JsonNode? detail;
                try { detail = JsonNode.Parse(e.Text); }
                catch (System.Text.Json.JsonException) { return; }
                if (e.Name == "call") CallChanged(detail);
                else Load();
                break;
            case BridgeyEventKind.Notification when e.DeviceId is not null && PhoneNotification.Parse(e.Text) is { CallType: { } } n:
                CallPosted(e.DeviceId, n);
                break;
            case BridgeyEventKind.NotificationRemoved when e.DeviceId is not null && e.Text is not null:
                CallRemoved(e.DeviceId, e.Text, ended: e.Status != 0);
                break;
            case BridgeyEventKind.Disconnected when e.DeviceId is not null:
                foreach (var call in _calls.Where(c => c.DeviceId == e.DeviceId).ToList()) _calls.Remove(call);
                ShowCard();
                break;
        }
    }

    private void CallChanged(JsonNode? d)
    {
        var result = MessagesViewModel.Str(d?["result"]);
        var via = MessagesViewModel.Str(d?["via"]) ?? "phone";
        Calling = result == "sent";
        NoticeGood = result is "sent" or "started" or "confirm";
        Notice = NoticeText(result, via, MessagesViewModel.Str(d?["reason"]), PhoneName);
    }

    /// <summary>The line after a call request (PhoneCalls.swift callsNoticeText).</summary>
    internal static string? NoticeText(string? result, string via, string? reason, string phone) => result switch
    {
        "sent" => $"Asking {phone}…",
        "started" when via.StartsWith("whatsapp", StringComparison.Ordinal) => $"WhatsApp is calling on {phone}.",
        "started" => $"Calling on {phone}. Talk on the phone or its earbuds.",
        "confirm" => $"Tap the notification on {phone} to start the call.",
        "no_answer" => $"{phone} didn't answer. Check it's connected and try again.",
        "refused" => reason switch
        {
            "disabled" => $"{phone} doesn't allow this PC to call. Turn it on in Bridgey there: Settings > Calls.",
            "permission" => $"Allow Bridgey's notifications or Phone access on {phone}.",
            "invalid" => "That number can't be called from here.",
            "emergency" => "Call emergency numbers from your phone.",
            "no_sim" => $"That SIM isn't on {phone} any more. Pick another.",
            "rate_limited" => "Too many calls at once. Wait a moment and try again.",
            "not_found" => $"That WhatsApp contact isn't on {phone} any more.",
            "unavailable" => $"WhatsApp isn't available on {phone}.",
            _ => $"{phone} couldn't start the call.",
        },
        _ => null,
    };

    // MARK: Actions

    /// <summary>The keypad: a digit or +.</summary>
    public void Press(string key) => Query += key;

    public void Backspace()
    {
        if (_query.Length > 0) Query = _query[..^1];
    }

    public void Clear() => Query = "";

    /// <summary>Enter or the Call button: the typed number, else the selected or first row's number.</summary>
    public void CallPrimary()
    {
        var number = QueryIsNumber ? _query.Trim() : (SelectedRow ?? Rows.FirstOrDefault())?.Number;
        if (number is not null) CallNumber(number);
    }

    public void CallNumber(string number, long? subId = null)
    {
        if (_phone is null || !CanCall) return;
        var command = new JsonObject { ["op"] = "call", ["address"] = number, ["prefer"] = _settings.CallsSim };
        var picked = subId ?? (HasSims ? _sim?.SubId : null);
        if (picked is { } sub) command["subId"] = sub;
        var answer = Command(command);
        if (MessagesViewModel.Bool(answer?["ok"]))
        {
            AskingSimFor = null;
            return;
        }
        switch (MessagesViewModel.Str(answer?["error"]))
        {
            case "choose_sim":
                AskingSimFor = number;
                break;
            case "too_soon" or "busy":
                Show("Wait a moment before the next call.", good: false);
                break;
            case "invalid":
                Show("That number can't be called from here.", good: false);
                break;
            default:
                Show($"{PhoneName} isn't connected.", good: false);
                break;
        }
    }

    /// <summary>"Call from which SIM?": the answer.</summary>
    public void CallWithSim(SimChoice sim)
    {
        if (_askingSimFor is not { } number) return;
        Sim = sim;
        CallNumber(number, sim.SubId);
    }

    public void CancelSim() => AskingSimFor = null;

    public void WhatsApp(long dataId, bool video)
    {
        if (_phone is null) return;
        var answer = Command(new JsonObject { ["op"] = "whatsapp", ["dataId"] = dataId, ["video"] = video });
        if (!MessagesViewModel.Bool(answer?["ok"]))
            Show(MessagesViewModel.Str(answer?["error"]) is "too_soon" or "busy" ? "Wait a moment before the next call." : $"{PhoneName} isn't connected.", good: false);
    }

    /// <summary>Something on this PC went wrong (WhatsApp is not here).</summary>
    public void ShowProblem(string text) => Show(text, good: false);

    private void Show(string text, bool good)
    {
        NoticeGood = good;
        Notice = text;
    }

    // MARK: Reading what bridgey_core keeps

    private JsonNode? Command(JsonObject command)
    {
        if (_phone is not { } id) return null;
        try { return JsonNode.Parse(_client.Phone(PhoneArea.Calls, id, command.ToJsonString())); }
        catch (Exception e) when (e is BridgeyException or System.Text.Json.JsonException) { return null; }
    }

    /// <summary>The phone's state again, and the list.</summary>
    private void Load()
    {
        var s = Command(new JsonObject { ["op"] = "state" });
        IsAvailable = MessagesViewModel.Bool(s?["available"]);
        IsUpstreamOnly = MessagesViewModel.Bool(s?["upstream"]);
        Raise(nameof(IsUpstreamOnly));
        Calling = MessagesViewModel.Bool(s?["calling"]);
        Searching = MessagesViewModel.Bool(s?["searching"]);
        var phone = s?["phone"];
        _whatsApp = MessagesViewModel.Bool(phone?["whatsapp"]);
        Raise(nameof(ShowsWhatsApp));
        var sims = (phone?["sims"]?.AsArray() ?? []).Where(x => x is not null)
            .Select(x => new SimChoice(MessagesViewModel.Long(x!["subId"]), MessagesViewModel.Str(x["label"]) is { Length: > 0 } l ? l : $"SIM {MessagesViewModel.Long(x["slot"]) + 1}")).ToList();
        if (!sims.SequenceEqual(Sims))
        {
            Sims.Clear();
            foreach (var sim in sims) Sims.Add(sim);
            var slot = _settings.CallsSim switch { "sim1" => 0, "sim2" => 1, _ => -1 };
            Sim = slot >= 0 && slot < Sims.Count ? Sims[slot] : null;
        }
        Raise(nameof(HasSims));
        LoadRows(s);
    }

    private void LoadRows(JsonNode? state = null)
    {
        var answer = Command(new JsonObject { ["op"] = "rows", ["query"] = _query, ["limit"] = _settings.CallsRecentCount });
        var wanted = new List<CallRowItem>();
        foreach (var row in answer?["rows"]?.AsArray() ?? [])
        {
            if (row is null) continue;
            var id = MessagesViewModel.Str(row["rowId"]) ?? "";
            var item = Rows.FirstOrDefault(r => r.RowId == id) ?? new CallRowItem(this, id);
            item.Update(row);
            wanted.Add(item);
        }
        foreach (var gone in Rows.Where(r => !wanted.Contains(r)).ToList()) Rows.Remove(gone);
        for (var i = 0; i < wanted.Count; i++)
        {
            var at = Rows.IndexOf(wanted[i]);
            if (at == i) continue;
            if (at >= 0) Rows.Move(at, i);
            else Rows.Insert(i, wanted[i]);
        }
        if (SelectedRow is { } selected && !Rows.Contains(selected)) SelectedRow = null;
        state ??= Command(new JsonObject { ["op"] = "state" });
        Searching = MessagesViewModel.Bool(state?["searching"]) || MessagesViewModel.Bool(answer?["searching"]);
        EmptyText = Empty(state);
        Raise(nameof(HasEmptyText));
    }

    /// <summary>Why the list is empty (CallsWindow.swift emptyText).</summary>
    private string Empty(JsonNode? state)
    {
        if (_phone is null) return "";
        if (!_available) return _upstream ? $"Type a number to call it from {PhoneName}. Allow this PC in Bridgey's Calls window on {PhoneName} for contacts and recent calls." : $"{PhoneName} isn't connected.";
        var phone = state?["phone"];
        if (_query.Trim().Length > 0)
        {
            var contacts = MessagesViewModel.Str(phone?["contacts"]);
            if (contacts == "off" || MessagesViewModel.Str(state?["contactsError"]) == "permission") return $"Allow Contacts in Bridgey on {PhoneName} to search names. Numbers work now.";
            if (contacts == "unavailable") return "Type a number to call it.";
            return _searching ? "" : "No contacts match.";
        }
        return MessagesViewModel.Str(phone?["recents"]) switch
        {
            "off" => $"Allow Call history in Bridgey on {PhoneName} to see recent calls here.",
            "unavailable" => $"{PhoneName} doesn't share recent calls. Type a number or a name.",
            _ => MessagesViewModel.Bool(state?["loadingRecents"]) ? "" : "No recent calls.",
        };
    }

    /// <summary>The number the phone dials, or null (CallRequest.swift normalizedPhoneNumber).</summary>
    public static string? NormalisedNumber(string value)
    {
        var trimmed = value.Trim();
        if (trimmed.Length == 0 || trimmed.Any(c => !"+-(). 0123456789".Contains(c))) return null;
        var pluses = trimmed.Count(c => c == '+');
        if (pluses > 1 || (pluses == 1 && trimmed[0] != '+')) return null;
        var digits = new string(trimmed.Where(char.IsAsciiDigit).ToArray());
        if (digits.Length is < 3 or > 15) return null;
        return trimmed[0] == '+' ? "+" + digits : digits;
    }

    // MARK: The call card (CallOverlayWindow.swift)

    /// <summary>The call the card shows: the newest incoming one, else the newest; quiet calls never show.</summary>
    public CallCardItem? Card
    {
        get => _card;
        private set
        {
            if (Set(ref _card, value)) Raise(nameof(HasCard));
        }
    }

    public bool HasCard => _card is not null;

    private void CallPosted(string deviceId, PhoneNotification n)
    {
        var existing = _calls.FirstOrDefault(c => c.DeviceId == deviceId && c.NotificationId == n.NotificationId);
        // The phone posts every call under one notification: another caller after a retraction is a new call.
        if (existing is not null && existing.Leaving && existing.Caller != n.Title && existing.Caller.Length > 0 && n.Title.Length > 0) _hidden.Remove(existing.Key);
        if (existing is null)
        {
            existing = new CallCardItem(this, deviceId, n.NotificationId);
            _calls.Add(existing);
            while (_calls.Count > 8) _calls.RemoveAt(0);
        }
        existing.Update(n, _nameOf(deviceId));
        ShowCard();
    }

    private void CallRemoved(string deviceId, string notificationId, bool ended)
    {
        if (_calls.FirstOrDefault(c => c.DeviceId == deviceId && c.NotificationId == notificationId) is not { } call) return;
        if (ended)
        {
            _calls.Remove(call);
            _hidden.Remove(call.Key);
            ShowCard();
            return;
        }
        // Without the end flag the card stays a moment, in case the dialer posts the same call again.
        call.Leaving = true;
        _ = Later(call);
    }

    private async Task Later(CallCardItem call)
    {
        await Delay(RemovalGrace);
        _ui.Post(() =>
        {
            if (!call.Leaving) return;
            _calls.Remove(call);
            _hidden.Remove(call.Key);
            ShowCard();
        });
    }

    private void ShowCard() =>
        Card = _calls.LastOrDefault(c => !c.Quiet && c.Type == "incoming" && !_hidden.Contains(c.Key))
               ?? _calls.LastOrDefault(c => !c.Quiet && !_hidden.Contains(c.Key));

    internal void Hide(CallCardItem call)
    {
        _hidden.Add(call.Key);
        ShowCard();
    }

    internal void RunCallAction(CallCardItem call, string token)
    {
        try { _client.NotificationAction(call.DeviceId, call.NotificationId, token, null); }
        catch (BridgeyException e) { Show(e.Code == BridgeyException.NotConnected ? $"{_nameOf(call.DeviceId)} isn't connected." : e.Message, good: false); }
    }
}

/// <summary>One row of the Calls list: a typed number, a contact, or a recent call.</summary>
public sealed partial class CallRowItem(CallsViewModel owner, string rowId) : ObservableObject
{
    private string _title = "";
    private string _detail = "";

    public string RowId { get; } = rowId;
    /// <summary>number, contact or recent.</summary>
    public string Kind { get; private set; } = "";
    public string? Number { get; private set; }
    public bool CanCall => Number is not null;
    public long? WhatsAppVoice { get; private set; }
    public long? WhatsAppVideo { get; private set; }
    public bool HasWhatsAppVoice => WhatsAppVoice is not null && owner.ShowsWhatsApp;
    public bool HasWhatsAppVideo => WhatsAppVideo is not null && owner.ShowsWhatsApp;
    /// <summary>A missed, rejected or blocked call shows in the warning colour.</summary>
    public bool Missed { get; private set; }
    public bool IsRecent => Kind == "recent";

    public string Title
    {
        get => _title;
        private set
        {
            if (Set(ref _title, value)) Raise(nameof(Initials));
        }
    }

    public string Detail
    {
        get => _detail;
        private set => Set(ref _detail, value);
    }

    public string Initials => Kind == "number" ? "#" : CallsWords.Initials(_title);

    /// <summary>A Segoe Fluent Icons glyph for the kind of call.</summary>
    public string Glyph => Kind switch
    {
        "number" => "\uE717",
        "contact" => "\uE77B",
        _ => Missed ? "\uE778" : "\uE81C",
    };

    public string Label => Kind switch
    {
        "number" => $"Call {Number}",
        _ => $"{_title}. {_detail}",
    };

    internal void Update(JsonNode row)
    {
        Kind = MessagesViewModel.Str(row["kind"]) ?? "";
        Number = MessagesViewModel.Str(row["number"]);
        WhatsAppVoice = null;
        WhatsAppVideo = null;
        Missed = false;
        switch (Kind)
        {
            case "number":
                Title = $"Call {MessagesViewModel.Str(row["address"])}";
                Detail = "Through the phone";
                break;
            case "contact":
            {
                Title = MessagesViewModel.Str(row["name"]) ?? "";
                var first = row["numbers"]?.AsArray().FirstOrDefault();
                var parts = new[] { MessagesViewModel.Str(first?["label"]), MessagesViewModel.Str(first?["address"]) }.Where(p => p is { Length: > 0 });
                Detail = string.Join(" · ", parts) is { Length: > 0 } d ? d : "WhatsApp";
                foreach (var w in row["whatsapp"]?.AsArray() ?? [])
                {
                    if (WhatsAppVoice is null && w?["voice"] is { } voice) WhatsAppVoice = MessagesViewModel.Long(voice);
                    if (WhatsAppVideo is null && w?["video"] is { } video) WhatsAppVideo = MessagesViewModel.Long(video);
                }
                break;
            }
            default:
            {
                var address = MessagesViewModel.Str(row["address"]) ?? "";
                Title = MessagesViewModel.Str(row["name"]) is { Length: > 0 } name ? name : address.Length > 0 ? address : "Private number";
                var type = MessagesViewModel.Str(row["type"]) ?? "incoming";
                Missed = type is "missed" or "rejected" or "blocked";
                var when = CallsWords.Relative(DateTimeOffset.FromUnixTimeMilliseconds(MessagesViewModel.Long(row["date"])), DateTimeOffset.Now);
                var duration = CallsWords.Duration(MessagesViewModel.Long(row["duration"]));
                Detail = string.Join(" · ", new[] { CallsWords.Type(type), when, duration }.Where(p => p is { Length: > 0 }));
                break;
            }
        }
        Raise(nameof(CanCall));
        Raise(nameof(HasWhatsAppVoice));
        Raise(nameof(HasWhatsAppVideo));
        Raise(nameof(Missed));
        Raise(nameof(Glyph));
        Raise(nameof(Label));
        Raise(nameof(Initials));
        Raise(nameof(IsRecent));
    }

    public void Call()
    {
        if (Number is { } n) owner.CallNumber(n);
    }

    /// <summary>The list row's name for Narrator and UI Automation.</summary>
    public override string ToString() => Label;

    public void CallWhatsApp()
    {
        if (WhatsAppVoice is { } id) owner.WhatsApp(id, video: false);
    }

    public void CallWhatsAppVideo()
    {
        if (WhatsAppVideo is { } id) owner.WhatsApp(id, video: true);
    }
}

/// <summary>The phone's call on the card: who, what state, and the phone's own buttons.</summary>
public sealed partial class CallCardItem(CallsViewModel owner, string deviceId, string notificationId) : ObservableObject
{
    private string _caller = "";
    private string _type = "";

    public string DeviceId { get; } = deviceId;
    public string NotificationId { get; } = notificationId;
    internal string Key => DeviceId + "\0" + NotificationId;
    internal bool Leaving { get; set; }
    public bool Quiet { get; private set; }
    public ObservableCollection<CallActionItem> Actions { get; } = new();

    public string Caller
    {
        get => _caller;
        private set => Set(ref _caller, value);
    }

    /// <summary>incoming, ongoing, screening or unknown.</summary>
    public string Type
    {
        get => _type;
        private set
        {
            if (Set(ref _type, value)) Raise(nameof(Status));
        }
    }

    /// <summary>"Incoming call", "Call in progress" (NotificationCall.swift remoteCallStatusTitle).</summary>
    public string Status => _type switch
    {
        "incoming" => "Incoming call",
        "ongoing" => "Call in progress",
        "screening" => "Call screening",
        _ => "Phone call",
    };

    public string PhoneName { get; private set; } = "";
    public bool HasActions => Actions.Count > 0;
    public bool HasNoActions => Actions.Count == 0;
    public string Label => $"{Status} on {PhoneName}: {_caller}";

    internal void Update(PhoneNotification n, string phoneName)
    {
        Leaving = false;
        PhoneName = phoneName;
        Quiet = n.Quiet;
        Type = n.CallType ?? "unknown";
        Caller = n.Title.Trim().Length > 0 ? n.Title.Trim() : n.ApplicationName;
        Actions.Clear();
        foreach (var a in CallsWords.VisibleActions(n.Actions, 2)) Actions.Add(new CallActionItem(this, a));
        Raise(nameof(HasActions));
        Raise(nameof(HasNoActions));
        Raise(nameof(Label));
    }

    public void Hide() => owner.Hide(this);

    internal void Run(string token) => owner.RunCallAction(this, token);
}

/// <summary>One of the call's own buttons (Answer, Decline, Hang up), in the phone's words.</summary>
public sealed class CallActionItem(CallCardItem owner, PhoneAction action)
{
    public string Title => action.Title;
    /// <summary>answer, end or other: the button's colour.</summary>
    public string Role => CallsWords.Role(action.Title);
    public bool IsAnswer => Role == "answer";
    public bool IsEnd => Role == "end";
    public bool IsOther => Role == "other";
    public void Run() => owner.Run(action.Token);
    public override string ToString() => Title;
}

/// <summary>Words and small rules the Calls window shares with the Mac's.</summary>
public static class CallsWords
{
    private static readonly string[] AnswerTitles = ["answer", "accept", "ответить", "принять"];
    private static readonly string[] EndTitles = ["decline", "reject", "hang up", "hangup", "end call", "отклонить", "сбросить", "завершить"];

    /// <summary>Titles are only a hint: Android sends the call's own actions first, in its own order.</summary>
    public static string Role(string title)
    {
        var t = title.ToLowerInvariant();
        if (EndTitles.Any(t.Contains)) return "end";
        if (AnswerTitles.Any(t.Contains)) return "answer";
        return "other";
    }

    /// <summary>The first <paramref name="limit"/> actions, with an end action kept in when there is one further on.</summary>
    public static List<PhoneAction> VisibleActions(IReadOnlyList<PhoneAction> actions, int limit)
    {
        var visible = actions.Take(limit).ToList();
        if (visible.Count == 0 || visible.Any(a => Role(a.Title) == "end")) return visible;
        if (actions.Skip(limit).FirstOrDefault(a => Role(a.Title) == "end") is { } end) visible[^1] = end;
        return visible;
    }

    /// <summary>"AK" for Anna Kapoor, "#" for a number.</summary>
    public static string Initials(string name)
    {
        var words = name.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Where(w => char.IsLetter(w[0])).ToList();
        if (words.Count == 0) return "#";
        var first = char.ToUpperInvariant(words[0][0]).ToString();
        return words.Count > 1 ? first + char.ToUpperInvariant(words[^1][0]) : first;
    }

    public static string Type(string type) => type switch
    {
        "outgoing" => "Outgoing",
        "missed" => "Missed",
        "rejected" => "Declined",
        "blocked" => "Blocked",
        "voicemail" => "Voicemail",
        _ => "Incoming",
    };

    /// <summary>"Just now", "5 min ago", "14:20", "Yesterday", "Mon", "12 Nov".</summary>
    public static string Relative(DateTimeOffset at, DateTimeOffset now)
    {
        var seconds = (now - at).TotalSeconds;
        if (seconds < 60) return "Just now";
        if (seconds < 3_600) return $"{(int)(seconds / 60)} min ago";
        var local = at.ToLocalTime();
        var today = now.ToLocalTime().Date;
        if (local.Date == today) return local.ToString("HH:mm");
        if (local.Date == today.AddDays(-1)) return "Yesterday";
        if (seconds < 6 * 86_400) return local.ToString("ddd");
        return local.ToString("d MMM");
    }

    /// <summary>"3 min 4 s", "45 s"; empty when the call did not connect.</summary>
    public static string Duration(long seconds) => seconds switch
    {
        <= 0 => "",
        < 60 => $"{seconds} s",
        < 3_600 => $"{seconds / 60} min {seconds % 60} s",
        _ => $"{seconds / 3_600} h {seconds % 3_600 / 60} min",
    };
}
