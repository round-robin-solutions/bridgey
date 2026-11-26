namespace Bridgey.ViewModels;

/// <summary>
/// Requests from Bridgey's browser extension (BrowserBridge.cs, docs/browser-extensions.md), answered with the paths
/// this app already has: a link goes to the device as a link (opened at once where that device allows it), an email
/// address goes to its clipboard. Calls from tel: links need the phone's call request, which Windows does not have yet.
/// </summary>
public sealed partial class MainViewModel
{
    /// <summary>Links from the browser waiting for their device's answer, by request ID.</summary>
    private readonly Dictionary<ulong, TaskCompletionSource<byte[]>> _browserLinks = new();

    /// <summary>Paired devices for the extension's list, connected first.</summary>
    public IReadOnlyList<BrowserDevice> BrowserDevices() =>
        Devices.Select(d => new BrowserDevice(d.Id, d.Name, d.Platform ?? "", d.IsConnected, d.LinksReady, false))
            .OrderByDescending(d => d.Connected).ToList();

    /// <summary>Answers one request. Call on the UI thread; the answer may wait for the device (at most its timeout).</summary>
    public Task<byte[]> HandleBrowserRequest(BrowserHostRequest request)
    {
        if (request is not BrowserHostRequest.Send send) return Task.FromResult(BrowserHostReply.Devices(BrowserDevices()));
        if (Find(send.Device) is not { } device) return Error("unknown_device");
        if (!device.IsConnected) return Error("not_connected");
        try
        {
            switch (send.Address.Kind)
            {
                case BrowserAddressKind.Web:
                    if (!device.LinksReady) return Error("links_off");
                    var id = _client.SendLink(device.Id, send.Address.Value);
                    var answer = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
                    _browserLinks[id] = answer;
                    var row = new ActivityItem { Direction = ActivityDirection.Sent, Title = $"Link to {device.Name}", Preview = send.Address.Value, Request = id, Status = "Sending" };
                    _linksOut[id] = row;
                    AddActivity(row);
                    return answer.Task;
                case BrowserAddressKind.Mailto:
                    if (!device.ClipboardReady) return Error("unsupported");
                    _client.SendClipboard(device.Id, send.Address.Value);
                    return Task.FromResult(BrowserHostReply.Sent("copied"));
                default:
                    return Error("calls_off");
            }
        }
        catch (BridgeyException)
        {
            return Error("not_connected");
        }
    }

    private static Task<byte[]> Error(string code) => Task.FromResult(BrowserHostReply.Error(code));

    private void BrowserLinkAnswered(BridgeyEvent e)
    {
        if (!_browserLinks.Remove(e.Id, out var answer)) return;
        answer.TrySetResult((SendStatus)e.Status switch
        {
            SendStatus.Delivered => BrowserHostReply.Sent(e.Text == "opened" ? "opened" : "waiting"),
            SendStatus.Rejected => BrowserHostReply.Error("declined"),
            SendStatus.TimedOut => BrowserHostReply.Error("no_answer"),
            _ => BrowserHostReply.Error("not_connected"),
        });
    }
}
