using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Bridgey.Native;

namespace Bridgey;

/// <summary>What happened, from bridgey_core's event queue (BridgeyEventKind in bridgey_core.h).</summary>
public enum BridgeyEventKind : uint
{
    DeviceFound = 1,
    DeviceLost = 2,
    PairingRequest = 3,
    PairingWaiting = 4,
    PairingCode = 5,
    PairingFinished = 6,
    Connected = 7,
    Disconnected = 8,
    Features = 9,
    Clipboard = 10,
    ClipboardSent = 11,
    Ping = 12,
    PingResult = 13,
    TrustChanged = 14,
    EventsDropped = 15,
    Error = 16,
    /// <summary>A file is coming in. Id = transfer, Name, Extra = MIME type, Total = size.</summary>
    FileIncoming = 17,
    /// <summary>Id = transfer, Status = 1 incoming or 0 outgoing, Bytes, Total.</summary>
    FileProgress = 18,
    /// <summary>Id = transfer, Name = the name it was saved under, Status = 1 incoming, Text = where (incoming).</summary>
    FileDone = 19,
    /// <summary>Id = transfer, Name, Status = 1 incoming, Text = reason.</summary>
    FileFailed = 20,
    Link = 21,
    LinkSent = 22,
    Battery = 23,
    FindRequested = 24,
    FindState = 25,
    /// <summary>
    /// Not from the library: BridgeyClient folds the four file events into one per change, with the whole transfer as
    /// <see cref="TransferInfo"/> JSON in Text and its <see cref="TransferState"/> in Status. Id = transfer.
    /// </summary>
    Transfer = 1000,
}

/// <summary>BridgeyTransferState: where a file going either way is.</summary>
public enum TransferState
{
    Queued = 0,
    Offered = 1,
    Sending = 2,
    Receiving = 3,
    Done = 4,
    Rejected = 5,
    Cancelled = 6,
    Failed = 7,
    Interrupted = 8,
}

/// <summary>BridgeySendStatus: the result of a clipboard send or a ping.</summary>
public enum SendStatus
{
    Delivered = 0,
    Rejected = 1,
    TimedOut = 2,
    Failed = 3,
}

/// <summary>One event. Which fields are set depends on the kind (bridgey_core.h documents each).</summary>
public sealed record BridgeyEvent(BridgeyEventKind Kind, int Status, ulong Id, string? DeviceId, string? Name, string? Text, string? Extra, ulong Bytes = 0, ulong Total = 0);

/// <summary>A call bridgey_core refused, with its BRIDGEY_ERR_* code.</summary>
public sealed class BridgeyException(int code) : Exception(Describe(code))
{
    public const int InvalidArgument = -1;
    public const int NotConnected = -2;
    public const int FeatureOff = -3;
    public const int TooLarge = -4;
    public const int UnknownDevice = -5;
    public const int Stopped = -6;
    public const int Storage = -7;
    public const int Io = -8;

    public int Code { get; } = code;

    public static string Describe(int code) => code switch
    {
        InvalidArgument => "That isn't valid.",
        NotConnected => "That device isn't connected.",
        FeatureOff => "That's turned off on one of the devices.",
        TooLarge => "That's too large to send.",
        UnknownDevice => "Bridgey can't find that device.",
        Stopped => "Bridgey has stopped.",
        Storage => "Bridgey couldn't read or save its pairing data.",
        Io => "Bridgey couldn't use the network. Another app may be using port 42458.",
        _ => $"Something went wrong ({code}).",
    };
}

/// <summary>Where the identity and trusted devices are kept (DPAPI-protected files on Windows).</summary>
public interface ISecretStore
{
    byte[]? Load(string key);
    void Store(string key, byte[] value);
    void Remove(string key);
}

/// <summary>Keeps nothing past the process: tests and throwaway peers.</summary>
public sealed class MemorySecretStore : ISecretStore
{
    private readonly Dictionary<string, byte[]> _values = new();

    public byte[]? Load(string key)
    {
        lock (_values) return _values.TryGetValue(key, out var v) ? v : null;
    }

    public void Store(string key, byte[] value)
    {
        lock (_values) _values[key] = value;
    }

    public void Remove(string key)
    {
        lock (_values) _values.Remove(key);
    }
}

public sealed class ClientOptions
{
    public required string DeviceName { get; init; }
    public string Platform { get; init; } = "windows";
    /// <summary>0 is Bridgey's port, 42458.</summary>
    public ushort Port { get; init; }
    public bool Listen { get; init; } = true;
    public bool Discovery { get; init; } = true;
    public uint EventCapacity { get; init; }
}

/// <summary>What the app needs from the session client; the view models are tested against a fake.</summary>
public interface IBridgeyClient : IDisposable
{
    string DeviceId { get; }
    event Action<BridgeyEvent>? EventReceived;
    Snapshot Snapshot();
    void SetDeviceName(string name);
    void AllowPairing(TimeSpan duration);
    ulong Pair(string? deviceId, string? host, ushort port);
    void ConfirmPairing(ulong pairing, bool accept);
    void CancelPairing(ulong pairing);
    void Forget(string deviceId);
    ulong SendClipboard(string deviceId, string text);
    ulong Ping(string deviceId);
    void SetFeature(string? deviceId, string key, bool on);
    void AddDiscovered(string? deviceId, string? name, string? platform, string host, ushort port);
    void NetworkChanged();
    /// <summary>Where received files go; null refuses files.</summary>
    void SetReceiveDir(string? folder);
    /// <summary>Queues a file for a connected device; the result is the request ID its Transfer events carry.</summary>
    ulong SendFile(string deviceId, string path);
    void CancelTransfer(ulong request);
    /// <summary>This PC's battery, or null when it has none.</summary>
    void SetBattery(int? level, bool charging);
    void Find(string deviceId, bool ring);
    void FindStopped(string deviceId);
}

/// <summary>
/// The managed side of bridgey_core: one client, one background thread that drains its event queue and raises
/// <see cref="EventReceived"/> on that thread. Dispose stops the client, waits for the thread and frees it.
/// </summary>
public sealed unsafe class BridgeyClient : IBridgeyClient
{
    private readonly ulong _handle;
    private readonly GCHandle _store;
    private readonly Thread _pump;
    private int _disposed;

    public string DeviceId { get; }
    public event Action<BridgeyEvent>? EventReceived;

    private BridgeyClient(ulong handle, GCHandle store)
    {
        _handle = handle;
        _store = store;
        DeviceId = TakeString(NativeMethods.bridgey_device_id(handle)) ?? "";
        _pump = new Thread(Pump) { IsBackground = true, Name = "Bridgey events" };
        _pump.Start();
    }

    /// <summary>The library's own version, for About.</summary>
    public static string LibraryVersion => Marshal.PtrToStringUTF8((nint)NativeMethods.bridgey_version()) ?? "";

    public static BridgeyClient Start(ClientOptions options, ISecretStore store)
    {
        if (NativeMethods.bridgey_abi_version() != NativeMethods.AbiVersion)
            throw new InvalidOperationException("bridgey_core.dll is from another version of Bridgey.");
        var storeHandle = GCHandle.Alloc(store);
        var name = Utf8(options.DeviceName);
        var platform = Utf8(options.Platform);
        try
        {
            fixed (byte* namePtr = name)
            fixed (byte* platformPtr = platform)
            {
                var config = new BridgeyConfig
                {
                    StructSize = (uint)sizeof(BridgeyConfig),
                    Port = options.Port,
                    Listen = options.Listen ? (byte)1 : (byte)0,
                    Discovery = options.Discovery ? (byte)1 : (byte)0,
                    EventCapacity = options.EventCapacity,
                    DeviceName = namePtr,
                    Platform = platformPtr,
                    DataDir = null,
                };
                var storage = new BridgeyStorage
                {
                    Context = GCHandle.ToIntPtr(storeHandle),
                    Load = &LoadValue,
                    Store = &StoreValue,
                    Remove = &RemoveValue,
                };
                ulong handle;
                Check(NativeMethods.bridgey_client_new(&config, &storage, &handle));
                return new BridgeyClient(handle, storeHandle);
            }
        }
        catch
        {
            storeHandle.Free();
            throw;
        }
    }

    private static byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text + "\0");

    private static void Check(int code)
    {
        if (code < 0) throw new BridgeyException(code);
    }

    private static string? TakeString(byte* text)
    {
        if (text == null) return null;
        try { return Marshal.PtrToStringUTF8((nint)text); }
        finally { NativeMethods.bridgey_string_free(text); }
    }

    private static ISecretStore StoreOf(nint context) => (ISecretStore)GCHandle.FromIntPtr(context).Target!;

    // Storage callbacks run on bridgey_core's threads; exceptions never cross back into native code.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int LoadValue(nint context, byte* key, nint buffer)
    {
        try
        {
            var value = StoreOf(context).Load(Marshal.PtrToStringUTF8((nint)key)!);
            if (value is null) return 0;
            fixed (byte* data = value) return NativeMethods.bridgey_buffer_set(buffer, data, (nuint)value.Length) == 0 ? 1 : -1;
        }
        catch { return -1; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int StoreValue(nint context, byte* key, byte* data, nuint length)
    {
        try
        {
            StoreOf(context).Store(Marshal.PtrToStringUTF8((nint)key)!, new ReadOnlySpan<byte>(data, checked((int)length)).ToArray());
            return 0;
        }
        catch { return -1; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int RemoveValue(nint context, byte* key)
    {
        try
        {
            StoreOf(context).Remove(Marshal.PtrToStringUTF8((nint)key)!);
            return 0;
        }
        catch { return -1; }
    }

    private void Pump()
    {
        while (true)
        {
            BridgeyNativeEvent* native;
            var rc = NativeMethods.bridgey_next_event(_handle, 500, &native);
            if (rc < 0) return;
            if (rc == 0) continue;
            BridgeyEvent e;
            try
            {
                e = new BridgeyEvent((BridgeyEventKind)native->Kind, native->Status, native->Id, native->DeviceId.Read(), native->Name.Read(), native->Text.Read(), native->Extra.Read(), native->Bytes, native->Total);
            }
            finally
            {
                NativeMethods.bridgey_event_free(native);
            }
            if (Transfers.Fold(e) is { } transfer) e = transfer;
            try { EventReceived?.Invoke(e); }
            catch (Exception ex) { System.Diagnostics.Debug.WriteLine($"Bridgey event handler failed: {ex}"); }
        }
    }

    public Snapshot Snapshot()
    {
        var json = TakeString(NativeMethods.bridgey_snapshot(_handle)) ?? throw new BridgeyException(BridgeyException.Stopped);
        return JsonSerializer.Deserialize(json, BridgeyJson.Default.Snapshot) ?? throw new BridgeyException(BridgeyException.Stopped);
    }

    public void SetDeviceName(string name) => Check(NativeMethods.bridgey_set_device_name(_handle, name));

    public void AllowPairing(TimeSpan duration) => Check(NativeMethods.bridgey_allow_pairing(_handle, (uint)Math.Clamp(duration.TotalSeconds, 0, 600)));

    public ulong Pair(string? deviceId, string? host, ushort port)
    {
        ulong pairing;
        Check(NativeMethods.bridgey_pair(_handle, deviceId, host, port, &pairing));
        return pairing;
    }

    public void ConfirmPairing(ulong pairing, bool accept) => Check(NativeMethods.bridgey_pair_confirm(_handle, pairing, accept ? (byte)1 : (byte)0));

    public void CancelPairing(ulong pairing) => Check(NativeMethods.bridgey_pair_cancel(_handle, pairing));

    public void Forget(string deviceId) => Check(NativeMethods.bridgey_forget(_handle, deviceId));

    public ulong SendClipboard(string deviceId, string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        ulong request;
        fixed (byte* data = bytes)
        {
            // A pointer is needed even for empty text; the library refuses empty text itself.
            byte empty = 0;
            Check(NativeMethods.bridgey_send_clipboard(_handle, deviceId, bytes.Length == 0 ? &empty : data, (nuint)bytes.Length, &request));
        }
        return request;
    }

    public ulong Ping(string deviceId)
    {
        ulong request;
        Check(NativeMethods.bridgey_ping(_handle, deviceId, &request));
        return request;
    }

    public void SetFeature(string? deviceId, string key, bool on) => Check(NativeMethods.bridgey_set_feature(_handle, deviceId, key, on ? (byte)1 : (byte)0));

    public void AddDiscovered(string? deviceId, string? name, string? platform, string host, ushort port) =>
        Check(NativeMethods.bridgey_add_discovered(_handle, deviceId, name, platform, host, port));

    public void NetworkChanged() => Check(NativeMethods.bridgey_network_changed(_handle));

    public void SetReceiveDir(string? folder) => Check(NativeMethods.bridgey_set_receive_dir(_handle, folder));

    public ulong SendFile(string deviceId, string path)
    {
        ulong transfer;
        Check(NativeMethods.bridgey_send_file(_handle, deviceId, path, null, null, &transfer));
        Transfers.Sent(transfer, deviceId, path);
        return transfer;
    }

    public void CancelTransfer(ulong request) => Check(NativeMethods.bridgey_cancel_file(_handle, request));

    /// <summary>Every transfer this client has seen, built from the library's file events.</summary>
    internal TransferTracker Transfers { get; } = new();

    public void SetBattery(int? level, bool charging) => Check(NativeMethods.bridgey_set_battery(_handle, level ?? -1, charging ? (byte)1 : (byte)0));

    public void Find(string deviceId, bool ring) => Check(NativeMethods.bridgey_find(_handle, deviceId, ring ? (byte)1 : (byte)0));

    public void FindStopped(string deviceId) => Check(NativeMethods.bridgey_find_stopped(_handle, deviceId));

    /// <summary>Fast transfers with peers that show them; off sends JSON chunks (a test setting).</summary>
    public void SetFastTransfers(bool on) => Check(NativeMethods.bridgey_set_fast_transfers(_handle, on ? (byte)1 : (byte)0));

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        NativeMethods.bridgey_client_stop(_handle);
        _pump.Join(TimeSpan.FromSeconds(5));
        NativeMethods.bridgey_client_free(_handle);
        _store.Free();
    }
}

/// <summary>
/// Folds FileIncoming, FileProgress, FileDone and FileFailed into one <see cref="TransferInfo"/> per transfer, with a
/// state, the name and size from the first event that has them, and a smoothed rate (bytes per second).
/// </summary>
public sealed class TransferTracker
{
    private readonly Dictionary<ulong, (TransferInfo Info, long Ticks)> _all = new();
    private readonly object _gate = new();

    /// <summary>A file this end queued: its row starts out waiting.</summary>
    public void Sent(ulong transfer, string deviceId, string path)
    {
        long size = 0;
        try { size = new FileInfo(path).Length; }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        lock (_gate) _all[transfer] = (new TransferInfo { Request = transfer, DeviceId = deviceId, Direction = "send", Name = System.IO.Path.GetFileName(path), Total = size, State = "queued", Path = path }, System.Diagnostics.Stopwatch.GetTimestamp());
    }

    /// <summary>The Transfer event for a file event, or null for any other event.</summary>
    public BridgeyEvent? Fold(BridgeyEvent e)
    {
        if (e.Kind is not (BridgeyEventKind.FileIncoming or BridgeyEventKind.FileProgress or BridgeyEventKind.FileDone or BridgeyEventKind.FileFailed)) return null;
        TransferInfo info;
        lock (_gate)
        {
            var now = System.Diagnostics.Stopwatch.GetTimestamp();
            var incoming = e.Status == 1;
            if (!_all.TryGetValue(e.Id, out var entry))
                entry = (new TransferInfo { Request = e.Id, DeviceId = e.DeviceId ?? "", Direction = incoming ? "receive" : "send" }, now);
            info = entry.Info;
            if (!string.IsNullOrEmpty(e.Name)) info.Name = e.Name;
            if (e.Total > 0) info.Total = (long)e.Total;
            switch (e.Kind)
            {
                case BridgeyEventKind.FileIncoming:
                    info.State = "receiving";
                    info.Direction = "receive";
                    break;
                case BridgeyEventKind.FileProgress:
                    var seconds = (now - entry.Ticks) / (double)System.Diagnostics.Stopwatch.Frequency;
                    var delta = (long)e.Bytes - info.Bytes;
                    if (seconds > 0 && delta > 0)
                    {
                        var rate = delta / seconds;
                        info.Rate = info.Rate == 0 ? (long)rate : (long)(info.Rate * 0.6 + rate * 0.4);
                    }
                    info.Bytes = (long)e.Bytes;
                    info.State = incoming ? "receiving" : e.Bytes == 0 ? "offered" : "sending";
                    entry.Ticks = now;
                    break;
                case BridgeyEventKind.FileDone:
                    info.State = "done";
                    info.Bytes = info.Total = (long)e.Total;
                    if (incoming) info.Path = e.Text;
                    break;
                case BridgeyEventKind.FileFailed:
                    info.Reason = e.Text;
                    info.State = e.Text switch
                    {
                        "cancelled" or "cancelled_remote" => "cancelled",
                        "rejected" => "rejected",
                        "interrupted" or "stopped" or "not_connected" => "interrupted",
                        _ => "failed",
                    };
                    break;
            }
            _all[e.Id] = (info, entry.Ticks);
        }
        return new BridgeyEvent(BridgeyEventKind.Transfer, (int)info.StateValue, e.Id, info.DeviceId, info.Name, JsonSerializer.Serialize(info, BridgeyJson.Default.TransferInfo), null, (ulong)info.Bytes, (ulong)info.Total);
    }
}

/// <summary>bridgey_snapshot's JSON (rust/client/src/client.rs, <c>snapshot</c>).</summary>
public sealed class Snapshot
{
    public string DeviceId { get; set; } = "";
    public string Name { get; set; } = "";
    public string Platform { get; set; } = "";
    public int Port { get; set; }
    public int AllowPairingSeconds { get; set; }
    public Dictionary<string, bool> Defaults { get; set; } = new();
    public List<SnapshotDevice> Devices { get; set; } = new();
    public List<SnapshotNearby> Nearby { get; set; } = new();
    public string? ReceiveDir { get; set; }
    public List<TransferInfo> Transfers { get; set; } = new();
}

public sealed class SnapshotBattery
{
    public int Level { get; set; }
    public bool Charging { get; set; }
}

/// <summary>A Transfer event's JSON, as <see cref="TransferTracker"/> builds it.</summary>
public sealed class TransferInfo
{
    public ulong Request { get; set; }
    public string TransferId { get; set; } = "";
    public string DeviceId { get; set; } = "";
    public string Direction { get; set; } = "send";
    public string Name { get; set; } = "";
    public long Bytes { get; set; }
    public long Total { get; set; }
    public string State { get; set; } = "queued";
    public string? Path { get; set; }
    public string? Reason { get; set; }
    public long Rate { get; set; }

    public bool Incoming => Direction == "receive";

    [JsonIgnore]
    public TransferState StateValue => State switch
    {
        "queued" => TransferState.Queued,
        "offered" => TransferState.Offered,
        "sending" => TransferState.Sending,
        "receiving" => TransferState.Receiving,
        "done" => TransferState.Done,
        "rejected" => TransferState.Rejected,
        "cancelled" => TransferState.Cancelled,
        "interrupted" => TransferState.Interrupted,
        _ => TransferState.Failed,
    };

    public static TransferInfo? Parse(string? json)
    {
        if (string.IsNullOrEmpty(json)) return null;
        try { return JsonSerializer.Deserialize(json, BridgeyJson.Default.TransferInfo); }
        catch (JsonException) { return null; }
    }
}

public sealed class SnapshotDevice
{
    public string DeviceId { get; set; } = "";
    public string Name { get; set; } = "";
    public string? Platform { get; set; }
    public bool Connected { get; set; }
    public long PairedAtMs { get; set; }
    public long? LastConnectedMs { get; set; }
    public Dictionary<string, bool> Local { get; set; } = new();
    public Dictionary<string, bool>? Remote { get; set; }
    public SnapshotBattery? Battery { get; set; }
    public bool Ringing { get; set; }
}

public sealed class SnapshotNearby
{
    public string? DeviceId { get; set; }
    public string Name { get; set; } = "";
    public string? Platform { get; set; }
    public string? Host { get; set; }
    public int? Port { get; set; }
    public bool Trusted { get; set; }
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(Snapshot))]
[JsonSerializable(typeof(Dictionary<string, bool>))]
[JsonSerializable(typeof(TransferInfo))]
internal sealed partial class BridgeyJson : JsonSerializerContext;
