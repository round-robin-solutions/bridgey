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
public sealed record BridgeyEvent(BridgeyEventKind Kind, int Status, ulong Id, string? DeviceId, string? Name, string? Text, string? Extra);

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
        FeatureOff => "Clipboard is off on one of the devices.",
        TooLarge => "That's too long to send. Text can be up to 32 KB.",
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
                e = new BridgeyEvent((BridgeyEventKind)native->Kind, native->Status, native->Id, native->DeviceId.Read(), native->Name.Read(), native->Text.Read(), native->Extra.Read());
            }
            finally
            {
                NativeMethods.bridgey_event_free(native);
            }
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

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        NativeMethods.bridgey_client_stop(_handle);
        _pump.Join(TimeSpan.FromSeconds(5));
        NativeMethods.bridgey_client_free(_handle);
        _store.Free();
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
internal sealed partial class BridgeyJson : JsonSerializerContext;
