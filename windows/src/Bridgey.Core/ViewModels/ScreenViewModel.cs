using System.Collections.ObjectModel;
using System.Text.Json.Nodes;

namespace Bridgey.ViewModels;

/// <summary>
/// The phone's screen on this PC (screen_draft1) and control of the phone (phone_control_draft1), as the Mac's phone
/// screen window does it. bridgey_core (rust/client/src/screen.rs) asks the phone, checks its stream, puts frames back
/// together and numbers the input; this keeps one <see cref="PhoneScreenItem"/> per phone for its window, which pulls
/// the frames and decodes them with Windows' own H.264 decoder. The phone's grants decide: this PC only asks.
/// </summary>
public sealed partial class ScreenViewModel(IBridgeyClient client, Func<string, string> nameOf) : ObservableObject
{
    /// <summary>Phones whose screen is asked for or showing, each with its window.</summary>
    public ObservableCollection<PhoneScreenItem> Items { get; } = new();

    /// <summary>The host opens (or brings forward) the item's window.</summary>
    public event Action<PhoneScreenItem>? WindowRequested;

    /// <summary>Asks the phone to share its screen; the window opens at once and says what the phone does.</summary>
    public void Request(DeviceItem device)
    {
        var item = Items.FirstOrDefault(i => i.DeviceId == device.Id);
        if (item is null)
        {
            item = new PhoneScreenItem(this, device.Id, device.Name);
            Items.Add(item);
        }
        item.Name = device.Name;
        WindowRequested?.Invoke(item);
        if (item.IsShowing) return;
        var answer = Command(device.Id, new JsonObject { ["op"] = "request" });
        switch (MessagesViewModel.Str(answer?["error"]))
        {
            case null when MessagesViewModel.Bool(answer?["ok"]):
                if (MessagesViewModel.Bool(answer?["showing"])) return;
                if (!MessagesViewModel.Bool(answer?["waiting"])) item.Asking();
                break;
            case "too_soon":
                break;
            case "feature_off":
                item.Ended("Turn on Show phone screens in Settings here, and screen sharing for this PC on the phone.");
                break;
            default:
                item.Ended($"{device.Name} isn't connected.");
                break;
        }
    }

    /// <summary>Show phone screens is on at both ends for the device, and it is connected.</summary>
    internal void Readiness(DeviceItem device, bool ready)
    {
        if (!ready && Items.FirstOrDefault(i => i.DeviceId == device.Id) is { IsShowing: true } item) item.Ended($"{device.Name} isn't sharing its screen now.");
    }

    internal void Handle(BridgeyEvent e)
    {
        if (e.Kind != BridgeyEventKind.Screen || e.DeviceId is null || e.Text is null) return;
        if (Items.FirstOrDefault(i => i.DeviceId == e.DeviceId) is not { } item)
        {
            // The phone started sharing on its own: a window for it.
            if (e.Name != "started") return;
            item = new PhoneScreenItem(this, e.DeviceId, nameOf(e.DeviceId));
            Items.Add(item);
        }
        JsonNode? d;
        try { d = JsonNode.Parse(e.Text); }
        catch (System.Text.Json.JsonException) { return; }
        switch (e.Name)
        {
            case "status":
                item.Answered(MessagesViewModel.Str(d?["status"]), MessagesViewModel.Str(d?["needs"]));
                break;
            case "started":
                item.Started(d!);
                WindowRequested?.Invoke(item);
                break;
            case "stats" when (ulong)MessagesViewModel.Long(d?["stream"]) == item.Stream:
                item.Stats(d!);
                break;
            case "geometry" when (ulong)MessagesViewModel.Long(d?["stream"]) == item.Stream:
                item.Resized((int)MessagesViewModel.Long(d?["width"]), (int)MessagesViewModel.Long(d?["height"]));
                break;
            case "control" when (ulong)MessagesViewModel.Long(d?["stream"]) == item.Stream:
                item.ControlChanged(d!);
                break;
            case "stopped" when (ulong)MessagesViewModel.Long(d?["stream"]) == item.Stream:
                item.Stopped(MessagesViewModel.Str(d?["reason"]) ?? "failed", MessagesViewModel.Str(d?["by"]) == "phone");
                break;
        }
    }

    /// <summary>The window closed: the stream stops and the item goes.</summary>
    internal void Closed(PhoneScreenItem item)
    {
        if (item.IsShowing || item.IsAsking) Command(item.DeviceId, new JsonObject { ["op"] = "stop" });
        Items.Remove(item);
    }

    internal JsonNode? Command(string deviceId, JsonObject command)
    {
        try { return JsonNode.Parse(client.Phone(PhoneArea.Screen, deviceId, command.ToJsonString())); }
        catch (Exception e) when (e is BridgeyException or System.Text.Json.JsonException) { return null; }
    }

    internal int TakeFrame(ulong stream, uint timeoutMs, byte[] buffer, out int length, out long captureMicros, out uint flags) =>
        client.ScreenFrame(stream, timeoutMs, buffer, out length, out captureMicros, out flags);
}

/// <summary>One phone's screen window: what it shows, the stream it pulls frames from, and control.</summary>
public sealed partial class PhoneScreenItem(ScreenViewModel owner, string deviceId, string name) : ObservableObject
{
    private string _name = name;
    private string _phase = "asking";
    private string _status = "";
    private ulong _stream;
    private int _width;
    private int _height;
    private bool _screenshots;
    private string _stats = "";
    private bool _capable;
    private bool _allowed;
    private string _control = "off";
    private string? _note;
    private bool _keys;
    private bool _text;
    private bool _touch;
    private bool _pointer;
    private bool _navigation;
    private readonly Dictionary<uint, byte> _contacts = new();

    public string DeviceId { get; } = deviceId;

    public string Name
    {
        get => _name;
        set
        {
            if (Set(ref _name, value)) Raise(nameof(Title));
        }
    }

    /// <summary>The window's title.</summary>
    public string Title => $"{_name}'s screen";

    /// <summary>asking, waiting, showing or ended.</summary>
    public string Phase
    {
        get => _phase;
        private set
        {
            if (!Set(ref _phase, value)) return;
            Raise(nameof(IsShowing));
            Raise(nameof(IsAsking));
            Raise(nameof(HasStatus));
            Raise(nameof(IsBusy));
            RaiseControl();
        }
    }

    public bool IsShowing => _phase == "showing";
    public bool IsAsking => _phase is "asking" or "waiting";
    /// <summary>A spinner beside the status while the phone has not answered.</summary>
    public bool IsBusy => IsAsking;

    /// <summary>What the window says instead of the picture, in plain words.</summary>
    public string Status
    {
        get => _status;
        private set => Set(ref _status, value);
    }

    public bool HasStatus => !IsShowing;

    /// <summary>The stream the window pulls frames from (0 until it starts).</summary>
    public ulong Stream
    {
        get => _stream;
        private set => Set(ref _stream, value);
    }

    /// <summary>The stream's size: the picture, and the frame positions are fractions of.</summary>
    public int Width
    {
        get => _width;
        private set => Set(ref _width, value);
    }

    public int Height
    {
        get => _height;
        private set => Set(ref _height, value);
    }

    /// <summary>Unattended access sends screenshots, about 3 a second: the window says it is a slower mode.</summary>
    public bool Screenshots
    {
        get => _screenshots;
        private set => Set(ref _screenshots, value);
    }

    /// <summary>"30 fps · 4.0 Mb/s · 48 ms", once a second.</summary>
    public string StatsText
    {
        get => _stats;
        private set => Set(ref _stats, value);
    }

    /// <summary>The window offers Control: the stream can be controlled and the phone allows asking now.</summary>
    public bool CanControl => IsShowing && _capable && _allowed && _control == "off";
    public bool IsControlling => IsShowing && _control == "active";
    public bool IsAskingControl => IsShowing && _control is "starting" or "waiting";
    public bool CanType => IsControlling && (_keys || _text);
    public bool CanNavigate => IsControlling && _navigation;

    /// <summary>Asking for control, or why it ended; empty when there is nothing to say.</summary>
    public string ControlText => _control switch
    {
        "starting" => $"Asking {_name} for control…",
        "waiting" => $"Allow control on {_name}.",
        "active" => "Controlling",
        _ => _note switch
        {
            null => "",
            "declined" => $"{_name} didn't allow control.",
            "disabled" => $"Control is off for this PC on {_name}.",
            "permission" => $"Turn on Bridgey control on {_name}.",
            "locked" => $"{_name} is locked.",
            "focus" => $"Typing stopped: another display is active on {_name}.",
            "timeout" => "Control timed out.",
            "rate" => "Too much input at once, so control stopped.",
            "local_stop" => $"Control was stopped on {_name}.",
            _ => "Control stopped.",
        },
    };

    public bool HasControlText => ControlText.Length > 0;

    private void RaiseControl()
    {
        Raise(nameof(CanControl));
        Raise(nameof(IsControlling));
        Raise(nameof(IsAskingControl));
        Raise(nameof(CanType));
        Raise(nameof(CanNavigate));
        Raise(nameof(ControlText));
        Raise(nameof(HasControlText));
    }

    // MARK: From the view model

    internal void Asking()
    {
        Phase = "asking";
        Status = $"Asking {_name} to share its screen…";
    }

    internal void Answered(string? status, string? needs)
    {
        if (IsShowing) return;
        Phase = status == "waiting" ? "waiting" : "ended";
        Status = (status, needs) switch
        {
            ("waiting", "accessibility") => $"Waiting for someone on {_name}. To see it unattended, turn on Bridgey control there.",
            ("waiting", "android_11") => $"Waiting for someone on {_name}. Seeing it unattended needs Android 11 or later.",
            ("waiting", "unlock") => $"Unlock {_name} to see its screen.",
            ("waiting", _) => $"Tap the notification on {_name}.",
            ("declined", _) => $"{_name} didn't share its screen.",
            ("busy", _) => $"{_name} is sharing its screen with another device.",
            ("disabled", _) => $"Screen sharing is off for this PC on {_name}.",
            ("expired", _) => $"No answer from {_name}.",
            _ => $"{_name} couldn't share its screen.",
        };
    }

    internal void Started(JsonNode d)
    {
        Stream = (ulong)MessagesViewModel.Long(d["stream"]);
        Width = (int)MessagesViewModel.Long(d["width"]);
        Height = (int)MessagesViewModel.Long(d["height"]);
        Screenshots = MessagesViewModel.Bool(d["screenshots"]);
        StatsText = "";
        Status = "";
        _contacts.Clear();
        Phase = "showing";
        if (d["control"] is { } c) ControlChanged(c);
    }

    internal void Stats(JsonNode d)
    {
        var mbps = MessagesViewModel.Long(d["bitrate"]) / 1_000_000.0;
        StatsText = $"{MessagesViewModel.Long(d["fps"])} fps · {mbps:0.0} Mb/s · {MessagesViewModel.Long(d["latencyMs"])} ms";
    }

    internal void Resized(int width, int height)
    {
        // The phone rotated: gestures in progress are forgotten (the phone has lifted its fingers).
        _contacts.Clear();
        Width = width;
        Height = height;
    }

    internal void ControlChanged(JsonNode c)
    {
        _capable = MessagesViewModel.Bool(c["capable"]);
        _allowed = MessagesViewModel.Bool(c["allowed"]);
        var phase = MessagesViewModel.Str(c["phase"]) ?? "off";
        if (phase != "active") _contacts.Clear();
        _control = phase;
        _note = MessagesViewModel.Str(c["note"]);
        var input = c["input"];
        _keys = MessagesViewModel.Bool(input?["keys"]);
        _text = MessagesViewModel.Bool(input?["text"]);
        _touch = MessagesViewModel.Bool(input?["touch"]);
        _pointer = MessagesViewModel.Bool(input?["pointer"]);
        _navigation = MessagesViewModel.Bool(input?["navigation"]);
        RaiseControl();
    }

    /// <summary>Stop in the window: the window closes once the stream has ended.</summary>
    public event Action? CloseRequested;

    internal void Stopped(string reason, bool byPhone)
    {
        if (reason == "closed")
        {
            Phase = "ended";
            CloseRequested?.Invoke();
            return;
        }
        _control = "off";
        _contacts.Clear();
        Stream = 0;
        Ended(reason switch
        {
            "user" or "ended" => $"Sharing stopped on {_name}.",
            "screen_off" => $"{_name} locked its screen.",
            "disabled" => byPhone ? $"Screen sharing is off for this PC on {_name}." : "Show phone screens is off on this PC.",
            "timeout" => $"Lost the screen of {_name}.",
            "disconnected" => $"{_name} disconnected.",
            _ => $"The screen of {_name} stopped.",
        });
    }

    internal void Ended(string message)
    {
        Phase = "ended";
        Status = message;
    }

    // MARK: From the window

    public void Stop() => owner.Command(DeviceId, new JsonObject { ["op"] = "stop" });
    public void Close() => owner.Closed(this);
    public void BeginControl() => owner.Command(DeviceId, new JsonObject { ["op"] = "control_begin" });
    public void EndControl() => owner.Command(DeviceId, new JsonObject { ["op"] = "control_end" });
    public void Back() => Navigate("back");
    public void Home() => Navigate("home");
    public void Recents() => Navigate("recents");

    private void Navigate(string action)
    {
        if (CanNavigate) owner.Command(DeviceId, new JsonObject { ["op"] = "navigate", ["action"] = action });
    }

    /// <summary>
    /// A press, drag or release at a point of the view (<paramref name="viewWidth"/> by <paramref name="viewHeight"/>,
    /// the picture letterboxed in it). <paramref name="pointer"/> is the system's pointer ID; up to 10 fingers. Presses
    /// on the letterbox send nothing; drags and releases past the picture's edge stay on it. True when it went.
    /// </summary>
    public bool Touch(uint pointer, string phase, double viewWidth, double viewHeight, double px, double py)
    {
        if (!IsControlling || !_touch) return false;
        var at = Fraction(viewWidth, viewHeight, _width, _height, px, py, clamp: phase != "down");
        if (at is not { } p) return false;
        byte contact;
        if (phase == "down")
        {
            if (_contacts.ContainsKey(pointer) || _contacts.Count >= 10) return false;
            contact = Enumerable.Range(0, 10).Select(i => (byte)i).First(i => !_contacts.ContainsValue(i));
            _contacts[pointer] = contact;
        }
        else if (!_contacts.TryGetValue(pointer, out contact)) return false;
        if (phase == "up") _contacts.Remove(pointer);
        return Taken(new JsonObject { ["op"] = "touch", ["contact"] = contact, ["phase"] = phase, ["x"] = p.X, ["y"] = p.Y });
    }

    /// <summary>The mouse wheel or a touchpad: view pixels the content moves, positive right and down.</summary>
    public bool Scroll(double viewWidth, double viewHeight, double px, double py, double viewDx, double viewDy)
    {
        if (!IsControlling || !_pointer) return false;
        if (Fraction(viewWidth, viewHeight, _width, _height, px, py) is not { } p) return false;
        var dx = Math.Round(StreamPixels(viewDx, viewWidth, viewHeight, _width, _height));
        var dy = Math.Round(StreamPixels(viewDy, viewWidth, viewHeight, _width, _height));
        if (dx == 0 && dy == 0) return false;
        return Taken(new JsonObject { ["op"] = "scroll", ["dx"] = dx, ["dy"] = dy, ["x"] = p.X, ["y"] = p.Y });
    }

    /// <summary>Typed text, when the phone takes it (Android 13 and later).</summary>
    public bool Type(string text) => CanType && _text && text.Length > 0 && Taken(new JsonObject { ["op"] = "text", ["text"] = text });

    /// <summary>One press of a named key (enter, tab, backspace, escape, arrows, home, end, page_up, page_down, delete).</summary>
    public bool Press(string key, bool shift) => CanType && _keys && Taken(new JsonObject { ["op"] = "press", ["key"] = key, ["shift"] = shift });

    /// <summary>Every finger lifts where it is (the window lost the mouse or focus).</summary>
    public void LiftAll()
    {
        foreach (var pointer in _contacts.Keys.ToList())
        {
            var contact = _contacts[pointer];
            _contacts.Remove(pointer);
            owner.Command(DeviceId, new JsonObject { ["op"] = "touch", ["contact"] = contact, ["phase"] = "up", ["x"] = 0.5, ["y"] = 0.5 });
        }
    }

    private bool Taken(JsonObject command) => MessagesViewModel.Bool(owner.Command(DeviceId, command)?["taken"]);

    /// <summary>The window's frame pump: the next whole H.264 access unit (bridgey_screen_frame).</summary>
    public int TakeFrame(byte[] buffer, uint timeoutMs, out int length, out long captureMicros, out uint flags) =>
        owner.TakeFrame(_stream, timeoutMs, buffer, out length, out captureMicros, out flags);

    /// <summary>Windows' decoder could not go on: frames wait for the next key frame, which is asked for now.</summary>
    public void DecoderFailed() => owner.Command(DeviceId, new JsonObject { ["op"] = "keyframe" });

    // MARK: The picture in the view (docs/protocol.md, "Geometry")

    /// <summary>
    /// A point of a view as fractions of the whole stream, the picture letterboxed (aspect kept, centred); null on the
    /// letterbox. <paramref name="clamp"/> keeps a point past the edge on it.
    /// </summary>
    public static (double X, double Y)? Fraction(double viewWidth, double viewHeight, int videoWidth, int videoHeight, double px, double py, bool clamp = false)
    {
        if (viewWidth <= 0 || viewHeight <= 0 || videoWidth <= 0 || videoHeight <= 0) return null;
        var k = Math.Min(viewWidth / videoWidth, viewHeight / videoHeight);
        var width = videoWidth * k;
        var height = videoHeight * k;
        var x = (px - (viewWidth - width) / 2) / width;
        var y = (py - (viewHeight - height) / 2) / height;
        if (!double.IsFinite(x) || !double.IsFinite(y)) return null;
        if (clamp)
        {
            x = Math.Clamp(x, 0, 1);
            y = Math.Clamp(y, 0, 1);
        }
        if (x is < 0 or > 1 || y is < 0 or > 1) return null;
        return (x, y);
    }

    /// <summary>A distance in view pixels as stream pixels.</summary>
    public static double StreamPixels(double viewDelta, double viewWidth, double viewHeight, int videoWidth, int videoHeight)
    {
        if (viewWidth <= 0 || viewHeight <= 0 || videoWidth <= 0 || videoHeight <= 0) return 0;
        return viewDelta / Math.Min(viewWidth / videoWidth, viewHeight / videoHeight);
    }
}
