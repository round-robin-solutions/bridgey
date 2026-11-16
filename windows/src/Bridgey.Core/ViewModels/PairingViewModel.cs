using System.Collections.ObjectModel;

namespace Bridgey.ViewModels;

public enum PairingState
{
    /// <summary>Pick a device nearby, or type an address.</summary>
    Choose,
    Connecting,
    /// <summary>The other device has not allowed pairing yet; Bridgey keeps trying for two minutes.</summary>
    Waiting,
    Code,
    Done,
    Failed,
}

/// <summary>
/// The pairing screen. While it is open this PC allows pairing (as the apps do), so another device can pair from
/// its side too. Both people compare the six digits; nothing is trusted until both confirm.
/// </summary>
public sealed partial class PairingViewModel(MainViewModel owner, IBridgeyClient client) : ObservableObject
{
    private PairingState _state = PairingState.Choose;
    private string _peerName = "";
    private string _code = "";
    private string _message = "";
    private string _address = "";
    private ulong? _pairing;
    private bool _open;

    public ObservableCollection<NearbyItem> Nearby => owner.Nearby;

    public PairingState State
    {
        get => _state;
        private set
        {
            if (!Set(ref _state, value)) return;
            Raise(nameof(IsChoosing));
            Raise(nameof(IsBusy));
            Raise(nameof(IsCode));
            Raise(nameof(IsDone));
            Raise(nameof(IsFailed));
            Raise(nameof(Title));
        }
    }

    public bool IsChoosing => _state == PairingState.Choose;
    public bool IsBusy => _state is PairingState.Connecting or PairingState.Waiting;
    public bool IsCode => _state == PairingState.Code;
    public bool IsDone => _state == PairingState.Done;
    public bool IsFailed => _state == PairingState.Failed;

    public string Title => _state switch
    {
        PairingState.Choose => "Pair a device",
        PairingState.Connecting => $"Connecting to {_peerName}",
        PairingState.Waiting => $"Allow pairing on {_peerName}",
        PairingState.Code => "Check the code",
        PairingState.Done => $"Paired with {_peerName}",
        _ => "Not paired",
    };

    public string PeerName
    {
        get => _peerName;
        private set
        {
            if (Set(ref _peerName, value)) Raise(nameof(Title));
        }
    }

    /// <summary>The six digits as "482 913".</summary>
    public string Code
    {
        get => _code;
        private set => Set(ref _code, value);
    }

    public string Message
    {
        get => _message;
        private set => Set(ref _message, value);
    }

    /// <summary>An IP address, with an optional port: 192.168.1.20 or 100.101.102.103:42458.</summary>
    public string Address
    {
        get => _address;
        set
        {
            if (Set(ref _address, value)) Raise(nameof(CanPairByAddress));
        }
    }

    public bool CanPairByAddress => TryParseAddress(_address, out _, out _);

    public bool HasNearby => owner.Nearby.Count > 0;
    public bool HasNoNearby => owner.Nearby.Count == 0;

    internal void NearbyChanged()
    {
        Raise(nameof(HasNearby));
        Raise(nameof(HasNoNearby));
    }

    /// <summary>The screen opened: allow pairing while it stays open (two minutes at a time).</summary>
    public void Opened()
    {
        _open = true;
        TryAllow(TimeSpan.FromMinutes(2));
    }

    public void Closed()
    {
        _open = false;
        TryAllow(TimeSpan.Zero);
        if (_state is PairingState.Done or PairingState.Failed) Reset();
    }

    /// <summary>Renews Allow pairing while the screen is open; the host calls it every minute.</summary>
    public void KeepAllowing()
    {
        if (_open) TryAllow(TimeSpan.FromMinutes(2));
    }

    private void TryAllow(TimeSpan duration)
    {
        try { client.AllowPairing(duration); }
        catch (BridgeyException) { }
    }

    public void PairWith(NearbyItem device) => Start(device.DeviceId, device.Host, device.Port, device.Name);

    public void PairByAddress()
    {
        if (!TryParseAddress(_address, out var host, out var port)) return;
        Start(null, host, port, host);
    }

    private void Start(string? deviceId, string host, ushort port, string name)
    {
        PeerName = name;
        Code = "";
        Message = "";
        State = PairingState.Connecting;
        try
        {
            _pairing = client.Pair(deviceId, host, port);
        }
        catch (BridgeyException e)
        {
            Fail(e.Message);
        }
    }

    public void Confirm()
    {
        if (_pairing is not { } p) return;
        try
        {
            client.ConfirmPairing(p, true);
            Message = $"Waiting for {_peerName} to confirm too.";
        }
        catch (BridgeyException)
        {
            Fail("Pairing ended before the code was confirmed.");
        }
    }

    public void Reject()
    {
        if (_pairing is { } p)
        {
            try { client.ConfirmPairing(p, false); }
            catch (BridgeyException) { }
        }
        Fail("The codes didn't match, so nothing was paired.");
    }

    public void Cancel()
    {
        if (_pairing is { } p)
        {
            try { client.CancelPairing(p); }
            catch (BridgeyException) { }
        }
        Reset();
    }

    public void Reset()
    {
        _pairing = null;
        Code = "";
        Message = "";
        State = PairingState.Choose;
    }

    private void Fail(string message)
    {
        _pairing = null;
        Message = message;
        State = PairingState.Failed;
    }

    internal void Handle(BridgeyEvent e)
    {
        switch (e.Kind)
        {
            case BridgeyEventKind.PairingWaiting when _pairing == e.Id:
                State = PairingState.Waiting;
                Message = $"On {_peerName}, allow pairing with this PC. Bridgey keeps trying for two minutes.";
                break;
            case BridgeyEventKind.PairingCode:
                // Ours, or another device pairing with this PC while the screen is open.
                _pairing = e.Id;
                PeerName = e.Name ?? "the other device";
                Code = FormatCode(e.Text ?? "");
                Message = $"Check that {_peerName} shows the same code.";
                State = PairingState.Code;
                break;
            case BridgeyEventKind.PairingFinished when _pairing == e.Id || (_state == PairingState.Code && e.Status != 0):
                if (e.Status == 0)
                {
                    _pairing = null;
                    PeerName = e.Name ?? _peerName;
                    Message = $"{_peerName} is connected. Copy text on either device and send it from Home.";
                    State = PairingState.Done;
                }
                else if (e.Text == "cancelled")
                {
                    Reset();
                }
                else
                {
                    Fail(Reason(e.Text ?? "", _peerName));
                }
                break;
        }
    }

    /// <summary>What a failed pairing tells the person (reasons from rust/client).</summary>
    public static string Reason(string reason, string peer) => reason switch
    {
        "cancelled_remote:mismatch" or "code_rejected" => "The codes didn't match, so nothing was paired.",
        "not_allowed" => $"{peer} didn't allow pairing in time. Try again and allow it on {peer}.",
        "unreachable" => "Bridgey couldn't reach that device. Check it's on the same network with Bridgey open.",
        "needs_protocol_2" or "cancelled_remote:needs_protocol_2" => $"{peer} needs a newer Bridgey to pair. Update it, then try again.",
        "cancelled_remote:busy" or "refused:busy" => $"{peer} is pairing with another device. Try again in a moment.",
        "cancelled_remote:rate_limited" => "Too many tries. Wait a minute, then try again.",
        "code_timeout" or "cancelled_remote:timeout" => "The code wasn't confirmed in time.",
        "cancelled_remote:cancelled" => $"Pairing was cancelled on {peer}.",
        _ => "Pairing didn't finish. Try again.",
    };

    public static string FormatCode(string code) => code.Length == 6 ? $"{code[..3]} {code[3..]}" : code;

    /// <summary>An IPv4 or IPv6 address with an optional port (default 42458).</summary>
    public static bool TryParseAddress(string text, out string host, out ushort port)
    {
        host = "";
        port = 0;
        var t = (text ?? "").Trim();
        if (t.Length == 0) return false;
        if (System.Net.IPEndPoint.TryParse(t, out var endpoint) && (t.Contains(']') || t.Count(c => c == ':') == 1))
        {
            host = endpoint.Address.ToString();
            port = endpoint.Port == 0 ? (ushort)0 : (ushort)endpoint.Port;
            return endpoint.Port is >= 0 and <= 65535;
        }
        if (System.Net.IPAddress.TryParse(t.Trim('[', ']'), out var address))
        {
            host = address.ToString();
            return true;
        }
        return false;
    }
}
