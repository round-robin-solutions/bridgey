using System.Runtime.InteropServices;

namespace Bridgey.Native;

/// <summary>
/// bridgey_core's C ABI (rust/client/include/bridgey_core.h). Source-generated P/Invoke only, so NativeAOT needs no
/// runtime marshalling. The library is bridgey_core.dll next to the app (libbridgey_core.so for tests on Linux).
/// </summary>
internal static unsafe partial class NativeMethods
{
    private const string Library = "bridgey_core";

    public const uint AbiVersion = 1;

    [LibraryImport(Library)]
    public static partial uint bridgey_abi_version();

    [LibraryImport(Library)]
    public static partial byte* bridgey_version();

    [LibraryImport(Library)]
    public static partial int bridgey_client_new(BridgeyConfig* config, BridgeyStorage* storage, ulong* handle);

    [LibraryImport(Library)]
    public static partial int bridgey_client_stop(ulong handle);

    [LibraryImport(Library)]
    public static partial void bridgey_client_free(ulong handle);

    [LibraryImport(Library)]
    public static partial int bridgey_next_event(ulong handle, uint timeoutMs, BridgeyNativeEvent** e);

    [LibraryImport(Library)]
    public static partial void bridgey_event_free(BridgeyNativeEvent* e);

    [LibraryImport(Library)]
    public static partial void bridgey_string_free(byte* text);

    [LibraryImport(Library)]
    public static partial byte* bridgey_device_id(ulong handle);

    [LibraryImport(Library)]
    public static partial byte* bridgey_snapshot(ulong handle);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int bridgey_set_device_name(ulong handle, string name);

    [LibraryImport(Library)]
    public static partial int bridgey_allow_pairing(ulong handle, uint seconds);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int bridgey_pair(ulong handle, string? deviceId, string? host, ushort port, ulong* pairing);

    [LibraryImport(Library)]
    public static partial int bridgey_pair_confirm(ulong handle, ulong pairing, byte accept);

    [LibraryImport(Library)]
    public static partial int bridgey_pair_cancel(ulong handle, ulong pairing);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int bridgey_forget(ulong handle, string deviceId);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int bridgey_send_clipboard(ulong handle, string deviceId, byte* text, nuint length, ulong* request);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int bridgey_ping(ulong handle, string deviceId, ulong* request);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int bridgey_set_feature(ulong handle, string? deviceId, string key, byte on);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int bridgey_add_discovered(ulong handle, string? deviceId, string? name, string? platform, string host, ushort port);

    [LibraryImport(Library)]
    public static partial int bridgey_network_changed(ulong handle);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int bridgey_set_receive_dir(ulong handle, string? dir);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int bridgey_send_file(ulong handle, string deviceId, string path, string? name, string? mime, ulong* transfer);

    [LibraryImport(Library)]
    public static partial int bridgey_cancel_file(ulong handle, ulong transfer);

    [LibraryImport(Library)]
    public static partial int bridgey_set_battery(ulong handle, int level, byte charging);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int bridgey_find(ulong handle, string deviceId, byte ring);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int bridgey_find_stopped(ulong handle, string deviceId);

    [LibraryImport(Library)]
    public static partial int bridgey_set_fast_transfers(ulong handle, byte on);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int bridgey_notification_dismiss(ulong handle, string deviceId, string notificationId);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int bridgey_notification_action(ulong handle, string deviceId, string notificationId, string token, string? reply);

    [LibraryImport(Library)]
    public static partial int bridgey_set_codes(ulong handle, byte sms, byte email);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int bridgey_codes_link_request(ulong handle, string deviceId);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    public static partial int bridgey_codes_advertise_result(ulong handle, string deviceId, string serviceUuid, byte ok, string? reason);

    [LibraryImport(Library)]
    public static partial int bridgey_set_presence(ulong handle, int state, uint idleSeconds);

    [LibraryImport(Library)]
    public static partial int bridgey_buffer_set(nint buffer, byte* data, nuint length);
}

[StructLayout(LayoutKind.Sequential)]
internal unsafe struct BridgeyConfig
{
    public uint StructSize;
    public ushort Port;
    public byte Listen;
    public byte Discovery;
    public uint EventCapacity;
    public byte* DeviceName;
    public byte* Platform;
    public byte* DataDir;
}

[StructLayout(LayoutKind.Sequential)]
internal unsafe struct BridgeyStorage
{
    public nint Context;
    public delegate* unmanaged[Cdecl]<nint, byte*, nint, int> Load;
    public delegate* unmanaged[Cdecl]<nint, byte*, byte*, nuint, int> Store;
    public delegate* unmanaged[Cdecl]<nint, byte*, int> Remove;
}

[StructLayout(LayoutKind.Sequential)]
internal unsafe struct BridgeyStr
{
    public byte* Ptr;
    public nuint Length;

    public readonly string? Read() => Ptr == null ? null : System.Text.Encoding.UTF8.GetString(Ptr, checked((int)Length));
}

[StructLayout(LayoutKind.Sequential)]
internal struct BridgeyNativeEvent
{
    public uint Kind;
    public int Status;
    public ulong Id;
    public BridgeyStr DeviceId;
    public BridgeyStr Name;
    public BridgeyStr Text;
    public BridgeyStr Extra;
    /// <summary>File events: bytes so far.</summary>
    public ulong Bytes;
    /// <summary>File events: the file's size.</summary>
    public ulong Total;
}
