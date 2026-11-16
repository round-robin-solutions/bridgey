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
