using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using Xunit;

namespace Bridgey.Tests;

/// <summary>
/// Two clients through the real bridgey_core library and this app's P/Invoke layer: they pair with protocol 2 and
/// exchange clipboard text both ways, with the identity and trust kept through the managed storage callbacks.
/// </summary>
public sealed class ClientInteropTests
{
    private static readonly TimeSpan Wait = TimeSpan.FromSeconds(20);

    private sealed class Peer : IDisposable
    {
        public readonly BridgeyClient Client;
        public readonly BlockingCollection<BridgeyEvent> Events = new();
        public readonly ushort Port;
        public readonly MemorySecretStore Store;

        public Peer(string name, MemorySecretStore? store = null, ushort port = 0)
        {
            Port = port == 0 ? FreePort() : port;
            Store = store ?? new MemorySecretStore();
            Client = BridgeyClient.Start(new ClientOptions { DeviceName = name, Port = Port, Discovery = false }, Store);
            Client.EventReceived += e =>
            {
                if (e.Kind == BridgeyEventKind.PairingCode)
                {
                    try { Client.ConfirmPairing(e.Id, true); }
                    catch (BridgeyException) { }
                }
                Events.Add(e);
            };
        }

        public BridgeyEvent Expect(Func<BridgeyEvent, bool> match, string what)
        {
            var deadline = DateTime.UtcNow + Wait;
            var seen = new List<BridgeyEvent>();
            while (DateTime.UtcNow < deadline)
            {
                if (Events.TryTake(out var e, 200))
                {
                    seen.Add(e);
                    if (match(e)) return e;
                }
            }
            throw new Xunit.Sdk.XunitException($"{what}: not seen. Events: {string.Join(", ", seen.Select(s => s.Kind))}");
        }

        public void Dispose() => Client.Dispose();
    }

    private static ushort FreePort()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        var port = (ushort)((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }

    [Fact]
    public void PairAndExchangeClipboardTextThroughTheNativeLibrary()
    {
        using var pc = new Peer("Test PC");
        using var phone = new Peer("Test phone");
        Assert.Matches("^[0-9a-f-]{36}$", pc.Client.DeviceId);
        Assert.NotNull(pc.Store.Load("identity"));

        phone.Client.AllowPairing(TimeSpan.FromMinutes(2));
        var pairing = pc.Client.Pair(null, "127.0.0.1", phone.Port);
        var codeAtPc = pc.Expect(e => e.Kind == BridgeyEventKind.PairingCode, "code on the PC");
        var codeAtPhone = phone.Expect(e => e.Kind == BridgeyEventKind.PairingCode, "code on the phone");
        Assert.Equal(codeAtPc.Text, codeAtPhone.Text);
        Assert.Equal(pairing, codeAtPc.Id);
        var finished = pc.Expect(e => e.Kind == BridgeyEventKind.PairingFinished, "pairing finished");
        Assert.Equal(0, finished.Status);
        pc.Expect(e => e.Kind == BridgeyEventKind.Features && e.DeviceId == phone.Client.DeviceId, "the phone's features");
        phone.Expect(e => e.Kind == BridgeyEventKind.Features && e.DeviceId == pc.Client.DeviceId, "the PC's features");

        var request = pc.Client.SendClipboard(phone.Client.DeviceId, "Hello from Windows ✓");
        var received = phone.Expect(e => e.Kind == BridgeyEventKind.Clipboard, "text at the phone");
        Assert.Equal("Hello from Windows ✓", received.Text);
        var sent = pc.Expect(e => e.Kind == BridgeyEventKind.ClipboardSent, "delivery");
        Assert.Equal((request, (int)SendStatus.Delivered), (sent.Id, sent.Status));

        phone.Client.SendClipboard(pc.Client.DeviceId, "And back again");
        Assert.Equal("And back again", pc.Expect(e => e.Kind == BridgeyEventKind.Clipboard, "text at the PC").Text);

        var snapshot = pc.Client.Snapshot();
        var device = Assert.Single(snapshot.Devices);
        Assert.Equal(phone.Client.DeviceId, device.DeviceId);
        Assert.True(device.Connected);
        Assert.True(device.Remote!["clipboard"]);
        Assert.NotNull(pc.Store.Load("trust"));

        var tooLong = Assert.Throws<BridgeyException>(() => pc.Client.SendClipboard(phone.Client.DeviceId, new string('x', 32_769)));
        Assert.Equal(BridgeyException.TooLarge, tooLong.Code);
        Assert.Equal(BridgeyException.NotConnected, Assert.Throws<BridgeyException>(() => pc.Client.SendClipboard(Guid.NewGuid().ToString(), "x")).Code);

        pc.Client.Forget(phone.Client.DeviceId);
        pc.Expect(e => e.Kind == BridgeyEventKind.TrustChanged && e.Status == 0, "forgotten");
        Assert.Empty(pc.Client.Snapshot().Devices);
    }

    [Fact]
    public void FilesBatteryAndFindThroughTheNativeLibrary()
    {
        using var pc = new Peer("Test PC");
        using var phone = new Peer("Test phone");
        foreach (var p in new[] { pc, phone })
            foreach (var key in new[] { "files", "battery", "find_device" }) p.Client.SetFeature(null, key, true);
        var inbox = Directory.CreateTempSubdirectory("bridgey-interop-");
        phone.Client.SetReceiveDir(inbox.FullName);
        phone.Client.AllowPairing(TimeSpan.FromMinutes(2));
        pc.Client.Pair(null, "127.0.0.1", phone.Port);
        pc.Expect(e => e.Kind == BridgeyEventKind.Features && e.Extra!.Contains("\"files\":true"), "the phone's files switch");

        var source = Path.Combine(Path.GetTempPath(), $"bridgey-interop-{Guid.NewGuid():N}.bin");
        var data = Enumerable.Range(0, 700_000).Select(i => (byte)(i * 7)).ToArray();
        File.WriteAllBytes(source, data);
        var request = pc.Client.SendFile(phone.Client.DeviceId, source);
        var sent = pc.Expect(e => e.Kind == BridgeyEventKind.Transfer && e.Id == request && e.Status >= (int)TransferState.Done, "the file sent");
        Assert.Equal((int)TransferState.Done, sent.Status);
        var received = phone.Expect(e => e.Kind == BridgeyEventKind.Transfer && e.Status == (int)TransferState.Done, "the file received");
        var info = TransferInfo.Parse(received.Text)!;
        Assert.True(info.Incoming);
        Assert.Equal(data, File.ReadAllBytes(info.Path!));
        Assert.Equal(inbox.FullName, Path.GetDirectoryName(info.Path));

        pc.Client.SetBattery(64, true);
        var battery = phone.Expect(e => e.Kind == BridgeyEventKind.Battery, "the PC's battery");
        Assert.Equal((64, 1UL), (battery.Status, battery.Id));

        phone.Client.Find(pc.Client.DeviceId, true);
        pc.Expect(e => e.Kind == BridgeyEventKind.FindRequested && e.Status == 1, "asked to ring");
        phone.Expect(e => e.Kind == BridgeyEventKind.FindState && e.Status == 1, "the PC rings");
        pc.Client.FindStopped(phone.Client.DeviceId);
        phone.Expect(e => e.Kind == BridgeyEventKind.FindState && e.Status == 0, "the PC stopped");

        File.Delete(source);
        inbox.Delete(true);
    }

    [Fact]
    public void TheIdentitySurvivesARestartThroughTheStore()
    {
        var store = new MemorySecretStore();
        string id;
        using (var first = new Peer("PC", store)) id = first.Client.DeviceId;
        using var second = new Peer("PC", store);
        Assert.Equal(id, second.Client.DeviceId);
    }

    [Fact]
    public void LibraryVersionAndDisposeTwice()
    {
        Assert.False(string.IsNullOrEmpty(BridgeyClient.LibraryVersion));
        var peer = new Peer("PC");
        peer.Dispose();
        peer.Dispose();
    }
}
