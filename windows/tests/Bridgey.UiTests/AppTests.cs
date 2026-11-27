using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Capturing;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;
using FlaUI.UIA3;
using Xunit;

namespace Bridgey.UiTests;

/// <summary>
/// The published app on this desktop: first run, Home, pairing, Settings and the notification area menu in light and
/// dark, then a real protocol 2 pairing with the scripted peer and clipboard text both ways.
///
/// BRIDGEY_APP_EXE: the published Bridgey.exe. BRIDGEY_PEER_EXE: rust/client's peer example.
/// BRIDGEY_SCREENSHOTS: where the PNGs go.
/// </summary>
public sealed partial class AppTests : IDisposable
{
    private const ushort AppPort = 42458;
    private const ushort PeerPort = 42470;
    private const string PeerName = "Test phone";
    private const string FromPeer = "Hello from the test phone";
    private const string FromPc = "Hello from Windows";
    private static readonly TimeSpan Long = TimeSpan.FromSeconds(45);

    private readonly string _exe = Required("BRIDGEY_APP_EXE");
    private readonly string _peerExe = Required("BRIDGEY_PEER_EXE");
    private readonly string _shots = Environment.GetEnvironmentVariable("BRIDGEY_SCREENSHOTS") is { Length: > 0 } s ? s : Path.Combine(Path.GetTempPath(), "bridgey-screenshots");
    private readonly string _data = Path.Combine(Path.GetTempPath(), "bridgey-ui-" + Guid.NewGuid().ToString("N")[..8]);
    private readonly string _inbox = Path.Combine(Path.GetTempPath(), "bridgey-ui-inbox-" + Guid.NewGuid().ToString("N")[..8]);
    private readonly string _peerInbox = Path.Combine(Path.GetTempPath(), "bridgey-ui-peer-" + Guid.NewGuid().ToString("N")[..8]);
    private readonly string _sendTo = Path.Combine(Path.GetTempPath(), "bridgey-ui-sendto-" + Guid.NewGuid().ToString("N")[..8]);
    private readonly UIA3Automation _automation = new();
    private Application? _app;
    private Process? _peer;
    private readonly BlockingCollection<JsonElement> _peerEvents = new();
    private readonly List<string> _peerLog = new();

    private static string Required(string name) =>
        Environment.GetEnvironmentVariable(name) is { Length: > 0 } v ? v : throw new InvalidOperationException($"{name} is not set");

    [Fact]
    public void ScreensAndPairingInLightAndDark()
    {
        Directory.CreateDirectory(_shots);
        try
        {
            // First run.
            var window = Launch("Light", setupDone: false);
            Find(window, "SetupContinue");
            Shot(window, "setup-light");
            Quit();
            window = Launch("Dark", setupDone: false);
            Find(window, "SetupContinue");
            Shot(window, "setup-dark");
            Quit();

            // The peer is on this machine and publishes itself, like a phone on the same network.
            StartPeer();

            foreach (var theme in new[] { "Light", "Dark" })
            {
                var t = theme.ToLowerInvariant();
                window = Launch(theme, setupDone: true, textMessages: theme == "Dark", calls: theme == "Dark");
                Find(window, "HomeStatus");
                if (theme == "Light") Shot(window, "home-empty-light");

                Click(window, "NavSettings");
                Find(window, "SettingsTitle");
                Shot(window, $"settings-{t}");
                SelectSection(window, "General");
                Shot(window, $"settings-general-{t}");
                SelectSection(window, "About");
                Assert.Contains("1.0", Find(window, "ShortVersion").Name);
                Shot(window, $"settings-about-{t}");
                SelectSection(window, "Updates");
                Find(window, "CheckUpdates");
                Shot(window, $"settings-updates-{t}");

                Click(window, "NavPair");
                Find(window, "PairAddress");
                Wait.UntilInputIsProcessed(TimeSpan.FromSeconds(3));
                Shot(window, $"pairing-{t}");

                TrayMenu(window, $"tray-menu-{t}");

                if (theme == "Light")
                {
                    PairWithPeer(window);
                    FilesBatteryAndFind(window);
                    PhoneNotifications(window);
                    Links(window);
                    TextMessages(window);
                    CallsWindow(window);
                    PhoneFiles(window);
                }
                else
                {
                    // The pairing from the light run is kept (DPAPI-protected) and reconnects.
                    Click(window, "NavHome");
                    WaitFor(() => Find(window, "HomeStatus").Name == $"Connected to {PeerName}", "the dark run reconnects to the peer");
                    // Text still moves after the reconnect.
                    var draft = Find(window, "Draft").AsTextBox();
                    draft.Text = "Hello again after a restart";
                    Click(window, "SendDraft");
                    Assert.Equal("Hello again after a restart", PeerEvent("clipboard").GetProperty("text").GetString());
                }
                Click(window, "NavHome");
                if (theme == "Dark")
                {
                    PeerCommand("battery 23 0");
                    WaitFor(() => window.FindFirstDescendant(c => c.ByAutomationId("DeviceBattery"))?.Name == "23%" ? "ok" : null, "the battery after the reconnect");
                }
                Wait.UntilInputIsProcessed(TimeSpan.FromSeconds(2));
                Shot(window, $"home-paired-{t}");

                if (theme == "Dark")
                {
                    // Text messages stays on, and the conversations come back from the encrypted cache.
                    Click(window, "NavMessages");
                    var asha = WaitFor(() => Find(window, "Conversations").FindFirstDescendant(c => c.ByName("Asha", FlaUI.Core.Definitions.PropertyConditionFlags.MatchSubstring)), "the conversations in the dark run");
                    asha.Click();
                    WaitFor(() => window.FindFirstDescendant(c => c.ByName("See you at 6", FlaUI.Core.Definitions.PropertyConditionFlags.MatchSubstring)), "the conversation");
                    Wait.UntilInputIsProcessed(TimeSpan.FromSeconds(2));
                    Shot(window, "messages-thread-dark");
                    // The Calls window stays on, and the phone's call shows on its card.
                    Click(window, "NavCalls");
                    WaitFor(() => Find(window, "CallRows").FindFirstDescendant(c => c.ByName("Anna Kapoor", FlaUI.Core.Definitions.PropertyConditionFlags.MatchSubstring)), "recent calls in the dark run");
                    Wait.UntilInputIsProcessed(TimeSpan.FromSeconds(2));
                    Shot(window, "calls-dark");
                    PeerCommand($"notify {CallJson("call-dark", "Anna Kapoor")}");
                    Find(window, "CallCaller");
                    Wait.UntilInputIsProcessed(TimeSpan.FromSeconds(1));
                    Shot(window, "call-card-dark");
                    PeerCommand("unnotify call-dark");
                    WaitFor(() => window.FindFirstDescendant(c => c.ByAutomationId("CallCaller")) is null ? "ok" : null, "the call card gone");
                    // Phone files: the peer's places, then a folder, in dark.
                    Click(window, "NavPhoneFiles");
                    var darkPlace = WaitFor(() => Find(window, "PhoneFileList").FindFirstDescendant(c => c.ByName("Download/Bridgey")), "the phone's places in the dark run");
                    darkPlace.DoubleClick();
                    WaitFor(() => Find(window, "PhoneFileList").FindFirstDescendant(c => c.ByName("Trip")), "the phone's top folder in the dark run");
                    Wait.UntilInputIsProcessed(TimeSpan.FromSeconds(2));
                    Shot(window, "phone-files-dark");
                    PeerCommand($"notify {NotificationJson("dark-1", "Asha", "Lunch at one?", reply: true)}");
                    Click(window, "NavNotifications");
                    Find(window, "ReplyBox");
                    Shot(window, "notifications-dark");
                }
                Click(window, "NavSettings");
                SelectSection(window, "Notifications");
                Shot(window, $"settings-notifications-{t}");
                SelectSection(window, "Away from home");
                Find(window, "ConnectStatus");
                Shot(window, $"settings-away-{t}");
                SelectSection(window, "Files");
                Assert.Equal(_inbox, Find(window, "ReceiveFolder").Name);
                Shot(window, $"settings-files-{t}");
                SelectSection(window, "Media and actions");
                Shot(window, $"settings-media-{t}");
                SelectSection(window, "Devices");
                var device = Find(window, "DeviceSettings");
                if (device.Patterns.ExpandCollapse.IsSupported) device.Patterns.ExpandCollapse.Pattern.Expand();
                else device.Click();
                Find(window, "DeviceSettings").FindFirstDescendant(c => c.ByName("Find device"));
                Shot(window, $"settings-devices-{t}");
                Quit();
            }
        }
        catch
        {
            TryShot("failure");
            throw;
        }
    }

    private void PairWithPeer(Window window)
    {
        var address = Find(window, "PairAddress").AsTextBox();
        address.Text = $"127.0.0.1:{PeerPort}";
        Click(window, "PairByAddress");
        var codeText = WaitFor(() => window.FindFirstDescendant(c => c.ByAutomationId("PairingCode"))?.Name is { Length: > 0 } n ? n : null, "the code on this PC");
        var peerCode = PeerEvent("code");
        Assert.Equal(peerCode.GetProperty("code").GetString(), codeText.Replace(" ", ""));
        Shot(window, "pairing-code-light");
        Click(window, "ConfirmCode");
        PeerEvent("connected");
        Click(window, "PairedHome");
        WaitFor(() => Find(window, "HomeStatus").Name == $"Connected to {PeerName}", "Home shows the peer connected");

        // Peer to PC: the text lands on the Windows clipboard and in Activity.
        PeerEvent("sending");
        WaitFor(() => ClipboardText() == FromPeer ? "ok" : null, "the peer's text on the Windows clipboard");

        // PC to peer: type, send, and the peer receives it.
        var draft = Find(window, "Draft").AsTextBox();
        draft.Text = FromPc;
        Click(window, "SendDraft");
        var received = PeerEvent("clipboard");
        Assert.Equal(FromPc, received.GetProperty("text").GetString());
    }

    /// <summary>
    /// Battery from the peer, a file each way (the peer sends one; Explorer's Send to sends one to it), the PC rings the
    /// peer, the peer rings the PC and Stop ends it, all against the scripted peer.
    /// </summary>
    private void FilesBatteryAndFind(Window window)
    {
        Assert.True(File.Exists(Path.Combine(_sendTo, "Bridgey.lnk")), "Bridgey is in Send to");

        PeerCommand("battery 45 1");
        WaitFor(() => window.FindFirstDescendant(c => c.ByAutomationId("DeviceBattery"))?.Name == "45%, charging" ? "ok" : null, "the peer's battery on its card");

        // The peer sends a file: it lands in the receive folder and its row offers Open.
        var fromPeer = Path.Combine(Path.GetTempPath(), "Holiday photo.jpg");
        var bytes = Enumerable.Range(0, 3_000_000).Select(i => (byte)(i % 253)).ToArray();
        File.WriteAllBytes(fromPeer, bytes);
        PeerCommand($"file {fromPeer}");
        Find(window, "OpenFile");
        Assert.Equal(bytes, File.ReadAllBytes(Path.Combine(_inbox, "Holiday photo.jpg")));
        Shot(window, "home-file-received-light");
        NotificationCenter("notification-file-light");

        // Explorer's Send to: Bridgey.exe --send <file> hands it to the running app, which sends it to the only device.
        var toPeer = Path.Combine(Path.GetTempPath(), "Quarterly report.pdf");
        File.WriteAllBytes(toPeer, bytes[..700_000]);
        var send = new ProcessStartInfo(_exe) { UseShellExecute = false, ArgumentList = { "--send", toPeer } };
        send.Environment["BRIDGEY_DATA_DIR"] = _data;
        Process.Start(send)?.WaitForExit(10_000);
        var arrived = PeerEvent("transfer", e => e.GetProperty("direction").GetString() == "receive" && e.GetProperty("state").GetString() == "done");
        Assert.Equal(bytes[..700_000], File.ReadAllBytes(arrived.GetProperty("path").GetString()!));

        // Send files on the card opens Windows' Open dialog; a path typed there goes to the peer.
        var picked = Path.Combine(Path.GetTempPath(), "Picked notes.txt");
        File.WriteAllText(picked, "Chosen in the file picker");
        Click(window, "SendFiles");
        var dialog = Retry.WhileNull(() => window.ModalWindows.FirstOrDefault()
            ?? _automation.GetDesktop().FindFirstChild(c => c.ByControlType(FlaUI.Core.Definitions.ControlType.Window).And(c.ByName("Open"))), TimeSpan.FromSeconds(20)).Result
            ?? throw new InvalidOperationException("the file picker did not open");
        Thread.Sleep(800);
        var fileName = Retry.WhileNull(() => dialog.FindFirstDescendant(c => c.ByControlType(FlaUI.Core.Definitions.ControlType.Edit).And(c.ByAutomationId("1148"))), TimeSpan.FromSeconds(10)).Result
            ?? throw new InvalidOperationException("the picker's file name box was not found");
        fileName.AsTextBox().Text = picked;
        // The dialog's Open button (ID 1) by UI Automation: a key press can land in a flyout still closing.
        var open = Retry.WhileNull(() => dialog.FindFirstDescendant(c => c.ByAutomationId("1")), TimeSpan.FromSeconds(10)).Result
            ?? throw new InvalidOperationException("the picker's Open button was not found");
        if (open.Patterns.Invoke.IsSupported) open.Patterns.Invoke.Pattern.Invoke();
        else open.Click();
        var viaPicker = PeerEvent("transfer", e => e.GetProperty("direction").GetString() == "receive" && e.GetProperty("state").GetString() == "done"
            && e.GetProperty("name").GetString() == "Picked notes.txt");
        Assert.Equal("Chosen in the file picker", File.ReadAllText(viaPicker.GetProperty("path").GetString()!));
        Shot(window, "home-file-sent-light");

        // The PC rings the peer; the peer stops itself, and the card offers Ring again.
        Click(window, "DeviceMore");
        Click(window, "RingDevice");
        PeerEvent("find", e => e.GetProperty("ring").GetBoolean());
        PeerCommand("stopped");
        Keyboard.Press(VirtualKeyShort.ESCAPE);

        // The peer rings the PC: the banner shows until Stop, and the peer hears it stopped.
        PeerCommand("ring");
        Find(window, "StopRinging");
        WaitFor(() => Find(window, "RingingBar").FindFirstDescendant(c => c.ByName($"{PeerName} is ringing this PC.")) is not null ? "ok" : null, "the ringing banner");
        Shot(window, "home-ringing-light");
        Click(window, "StopRinging");
        PeerEvent("ringing", e => !e.GetProperty("ringing").GetBoolean());
    }

    private static string NotificationJson(string id, string title, string text, bool reply = false, string package = "com.whatsapp", string app = "WhatsApp", bool sms = false)
    {
        var actions = reply
            ? new object[]
            {
                new Dictionary<string, object> { ["actionToken"] = new string('a', 64), ["title"] = "Reply", ["allowsReply"] = true },
                new Dictionary<string, object> { ["actionToken"] = new string('b', 64), ["title"] = "Mark as read", ["allowsReply"] = false },
            }
            : Array.Empty<object>();
        return JsonSerializer.Serialize(new Dictionary<string, object>
        {
            ["packageName"] = package, ["applicationName"] = app, ["notificationId"] = id, ["title"] = title, ["text"] = text,
            ["timestamp"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), ["actions"] = actions, ["smsDefaultApp"] = sms, ["redacted"] = false,
        });
    }

    /// <summary>
    /// Phone notifications from the peer: a message with Reply and Mark as read, an SMS code (after Codes from messages
    /// is turned on) with Copy code, a reply, Dismiss, the phone removing one, and the link prompt for hidden codes.
    /// </summary>
    private void PhoneNotifications(Window window)
    {
        Click(window, "NavSettings");
        SelectSection(window, "Notifications");
        var codes = Find(window, "CodesFromMessages");
        if (codes.Patterns.Toggle.IsSupported) codes.Patterns.Toggle.Pattern.Toggle();
        PeerCommand("codes-status hidden");
        WaitFor(() => Find(window, "CodesStatus").Name.Contains("hides code messages") ? "ok" : null, "the codes status");
        Shot(window, "settings-notifications-codes-light");
        Click(window, "LinkPhone");

        PeerCommand($"notify {NotificationJson("wa-1", "Ravi", "On my way, ten minutes", reply: true)}");
        PeerCommand($"notify {NotificationJson("sms-1", "VM-HDFCBK", "OTP is 482913 for txn of INR 2,499.00 at AMAZON PAY. Do not share OTP.", package: "com.google.android.apps.messaging", app: "Messages", sms: true)}");
        Click(window, "NavNotifications");
        WaitFor(() => window.FindFirstDescendant(c => c.ByAutomationId("NotificationCode"))?.Name == "482913" ? "ok" : null, "the code on the Notifications page");
        Find(window, "ReplyBox");
        Shot(window, "notifications-light");
        NotificationCenter("notification-phone-light");

        Click(window, "CopyCode");
        WaitFor(() => ClipboardText() == "482913" ? "ok" : null, "the code on the clipboard");

        var reply = Find(window, "ReplyBox").AsTextBox();
        reply.Text = "Thanks";
        Click(window, "SendReply");
        WaitFor(() => Find(window, "ReplyBox").AsTextBox().Text == "" ? "ok" : null, "the reply sent and the box cleared");

        // The phone removes the SMS; the WhatsApp message is dismissed here.
        PeerCommand("unnotify sms-1");
        WaitFor(() => window.FindFirstDescendant(c => c.ByAutomationId("NotificationCode")) is null ? "ok" : null, "the SMS gone");
        Click(window, "DismissNotification");
        Find(window, "NoNotifications");
    }

    /// <summary>Links from the peer (kept on Home for Open, or opened right away) and Send link to it.</summary>
    private void Links(Window window)
    {
        Click(window, "NavHome");
        PeerCommand("link https://example.com/kept-for-later");
        Find(window, "OpenLink");
        WaitFor(() => Find(window, "LinkBar").FindFirstDescendant(c => c.ByName("Test phone sent a link: https://example.com/kept-for-later")) is not null ? "ok" : null, "the link banner");
        Shot(window, "home-link-light");
        Click(window, "OpenLink");
        WaitFor(() => window.FindFirstDescendant(c => c.ByAutomationId("OpenLink")) is null ? "ok" : null, "the banner closed after Open");

        PeerCommand("link-open https://example.com/right-away");
        WaitFor(() => window.FindFirstDescendant(c => c.ByName("Link from Test phone")) is not null ? "ok" : null, "the opened link in Activity");

        var draft = Find(window, "Draft").AsTextBox();
        draft.Text = "https://roundrobin.in/bridgey";
        Click(window, "SendLink");
        var link = PeerEvent("link");
        Assert.Equal("https://roundrobin.in/bridgey", link.GetProperty("url").GetString());
    }

    /// <summary>
    /// Text messages with the peer acting as a phone (--phone): turn it on, the conversations load unread first, a
    /// conversation opens with its picture, and a text goes and is delivered.
    /// </summary>
    private void TextMessages(Window window)
    {
        Click(window, "NavMessages");
        Find(window, "MessagesSettings");
        Shot(window, "messages-off-light");
        Click(window, "MessagesSettings");
        var on = Find(window, "TextMessagesOn");
        if (on.Patterns.Toggle.IsSupported) on.Patterns.Toggle.Pattern.Toggle();
        Shot(window, "settings-messages-light");

        Click(window, "NavMessages");
        var list = Find(window, "Conversations");
        var asha = WaitFor(() => list.FindFirstDescendant(c => c.ByName("Asha", FlaUI.Core.Definitions.PropertyConditionFlags.MatchSubstring)), "Asha's conversation");
        Assert.Contains("2 unread", asha.Name);
        Shot(window, "messages-light");

        asha.Click();
        WaitFor(() => window.FindFirstDescendant(c => c.ByName("See you at 6", FlaUI.Core.Definitions.PropertyConditionFlags.MatchSubstring)), "the conversation's messages");
        var draft = Find(window, "MessageDraft").AsTextBox();
        draft.Text = "On my way";
        Click(window, "SendMessage");
        WaitFor(() => window.FindFirstDescendant(c => c.ByName("Delivered", FlaUI.Core.Definitions.PropertyConditionFlags.MatchSubstring)), "the text delivered");
        Shot(window, "messages-thread-light");

        // A picture message.
        var ravi = WaitFor(() => list.FindFirstDescendant(c => c.ByName("Ravi", FlaUI.Core.Definitions.PropertyConditionFlags.MatchSubstring)), "Ravi's conversation");
        ravi.Click();
        WaitFor(() => window.FindFirstDescendant(c => c.ByName("Picture")), "the picture");

        // A new message to a contact the phone finds.
        Click(window, "NewMessage");
        Find(window, "MessageTo").AsTextBox().Text = "As";
        var contact = WaitFor(() => Find(window, "MessageContacts").FindFirstDescendant(c => c.ByName("Asha")), "the contact");
        Shot(window, "messages-new-light");
        contact.Click();
        Assert.Equal("+447700900123", Find(window, "MessageTo").AsTextBox().Text);
    }

    /// <summary>A phone call's notification, as the phone's dialer posts it: Answer and Decline.</summary>
    private static string CallJson(string id, string caller) => JsonSerializer.Serialize(new Dictionary<string, object>
    {
        ["packageName"] = "com.google.android.dialer", ["applicationName"] = "Phone", ["notificationId"] = id, ["title"] = caller,
        ["text"] = "Incoming call", ["timestamp"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), ["callType"] = "incoming",
        ["actions"] = new object[]
        {
            new Dictionary<string, object> { ["actionToken"] = new string('c', 64), ["title"] = "Answer", ["allowsReply"] = false },
            new Dictionary<string, object> { ["actionToken"] = new string('d', 64), ["title"] = "Decline", ["allowsReply"] = false },
        },
    });

    /// <summary>
    /// The Calls window with the peer acting as a phone (--phone): turn it on and allow the phone, recent calls load,
    /// a search finds a contact, a typed number asks for a SIM and calls, and the phone's incoming call shows on the card.
    /// </summary>
    private void CallsWindow(Window window)
    {
        Click(window, "NavCalls");
        Find(window, "CallsSettings");
        Shot(window, "calls-off-light");
        Click(window, "CallsSettings");
        var on = Find(window, "CallsWindowOn");
        if (on.Patterns.Toggle.IsSupported) on.Patterns.Toggle.Pattern.Toggle();
        var allowed = Find(window, "CallsAllowed");
        if (allowed.Patterns.Toggle.IsSupported) allowed.Patterns.Toggle.Pattern.Toggle();
        Shot(window, "settings-calls-light");

        Click(window, "NavCalls");
        var rows = Find(window, "CallRows");
        WaitFor(() => rows.FindFirstDescendant(c => c.ByName("Anna Kapoor", FlaUI.Core.Definitions.PropertyConditionFlags.MatchSubstring)), "recent calls");
        Shot(window, "calls-light");

        Find(window, "CallsQuery").AsTextBox().Text = "anna";
        WaitFor(() => rows.FindFirstDescendant(c => c.ByName("WhatsApp video call")), "the contact with WhatsApp");
        Shot(window, "calls-search-light");

        // Two SIMs and Ask each time: which SIM, then the call.
        Find(window, "CallsQuery").AsTextBox().Text = "+44 20 7946 0000";
        Click(window, "CallButton");
        var question = Find(window, "SimQuestion");
        var vodafone = WaitFor(() => question.FindFirstDescendant(c => c.ByName("Vodafone")), "the SIM question");
        Shot(window, "calls-sim-light");
        vodafone.Click();
        WaitFor(() => Find(window, "CallsNotice").FindFirstDescendant(c => c.ByName("Calling on", FlaUI.Core.Definitions.PropertyConditionFlags.MatchSubstring)), "the call started");
        Shot(window, "calls-started-light");

        // The phone's incoming call: the card with the phone's own buttons, until the phone takes it away.
        PeerCommand($"notify {CallJson("call-1", "Anna Kapoor")}");
        WaitFor(() => Find(window, "CallCaller").Name == "Anna Kapoor" ? "ok" : null, "the caller on the card");
        Shot(window, "call-card-light");
        PeerCommand("unnotify call-1");
        WaitFor(() => window.FindFirstDescendant(c => c.ByAutomationId("CallCaller")) is null ? "ok" : null, "the call card gone");
    }

    /// <summary>
    /// Phone files with the peer acting as a phone (--phone): its places, a folder and its photos with thumbnails, and a
    /// download that lands in this PC's receive folder.
    /// </summary>
    private void PhoneFiles(Window window)
    {
        Click(window, "NavPhoneFiles");
        var list = Find(window, "PhoneFileList");
        var place = WaitFor(() => list.FindFirstDescendant(c => c.ByName("Download/Bridgey")), "the phone's places");
        Shot(window, "phone-files-places-light");
        place.DoubleClick();
        var trip = WaitFor(() => list.FindFirstDescendant(c => c.ByName("Trip")), "the phone's top folder");
        trip.DoubleClick();
        var photo = WaitFor(() => list.FindFirstDescendant(c => c.ByName("IMG_0002.jpg")), "the photos in Trip");
        Wait.UntilInputIsProcessed(TimeSpan.FromSeconds(2));
        Shot(window, "phone-files-light");

        if (photo.Patterns.SelectionItem.IsSupported) photo.Patterns.SelectionItem.Pattern.Select();
        else photo.Click();
        WaitFor(() => Find(window, "DownloadSelected").IsEnabled ? "ok" : null, "Download enabled for the selection");
        Click(window, "DownloadSelected");
        var landed = Path.Combine(_inbox, "IMG_0002.jpg");
        WaitFor(() => File.Exists(landed) && new FileInfo(landed).Length == 2048 ? "ok" : null, "the photo downloaded to the receive folder");
        Find(window, "ShowDownload");
        Shot(window, "phone-files-downloaded-light");

        Click(window, "SectionPhotos");
        WaitFor(() => list.FindFirstDescendant(c => c.ByName("IMG_0001.jpg")), "the phone's photos");
        Wait.UntilInputIsProcessed(TimeSpan.FromSeconds(2));
        Shot(window, "phone-files-photos-light");
        Click(window, "SectionFolders");
    }

    private void PeerCommand(string line)
    {
        _peer!.StandardInput.WriteLine(line);
        _peer.StandardInput.Flush();
    }

    /// <summary>Opens Windows' notification centre (Win+N) and captures the screen: evidence that the notification
    /// was delivered. Hosted runners may hold notifications back, so nothing is asserted.</summary>
    private void NotificationCenter(string name)
    {
        try
        {
            Thread.Sleep(1500);
            Keyboard.TypeSimultaneously(VirtualKeyShort.LWIN, VirtualKeyShort.KEY_N);
            Thread.Sleep(1500);
            Capture.Screen().ToFile(Path.Combine(_shots, name + ".png"));
            Keyboard.Press(VirtualKeyShort.ESCAPE);
            Thread.Sleep(500);
            // Escape doesn't always close it: give the focus back to Bridgey, which closes the flyout.
            _app?.GetMainWindow(_automation, TimeSpan.FromSeconds(2))?.Focus();
            Thread.Sleep(300);
        }
        catch (Exception) { }
    }

    /// <summary>
    /// Starts the app with fresh settings; <paramref name="textMessages"/> keeps Text messages on from the light run and
    /// <paramref name="calls"/> the Calls window, with the peer allowed.
    /// </summary>
    private Window Launch(string theme, bool setupDone, bool textMessages = false, bool calls = false)
    {
        Directory.CreateDirectory(_data);
        File.WriteAllText(Path.Combine(_data, "settings.json"), JsonSerializer.Serialize(new Dictionary<string, object>
        {
            ["deviceName"] = "Bridgey CI PC",
            ["theme"] = theme,
            ["setupDone"] = setupDone,
            ["startAtSignIn"] = false,
            ["textMessages"] = textMessages,
            ["callsWindow"] = calls,
            ["callsAllowed"] = calls && _peerId is { } peer ? new[] { peer } : Array.Empty<string>(),
        }));
        var start = new ProcessStartInfo(_exe) { UseShellExecute = false };
        start.Environment["BRIDGEY_DATA_DIR"] = _data;
        start.Environment["BRIDGEY_PORT"] = AppPort.ToString();
        start.Environment["BRIDGEY_RECEIVE_DIR"] = _inbox;
        start.Environment["BRIDGEY_SENDTO_DIR"] = _sendTo;
        start.Environment["BRIDGEY_NO_BROWSER"] = "1";
        _app = Application.Launch(start);
        Window? window = null;
        try { window = _app.GetMainWindow(_automation, Long); }
        catch (Exception e) { throw new InvalidOperationException($"Bridgey's window did not open. App log:\n{AppLog()}", e); }
        if (window is null) throw new InvalidOperationException($"Bridgey's window did not open. App log:\n{AppLog()}");
        window.Focus();
        return window;
    }

    private string AppLog()
    {
        var path = Path.Combine(_data, "bridgey.log");
        return File.Exists(path) ? File.ReadAllText(path) : "(no bridgey.log)";
    }

    private void Quit()
    {
        if (_app is null) return;
        var quit = new ProcessStartInfo(_exe, "--quit") { UseShellExecute = false };
        quit.Environment["BRIDGEY_DATA_DIR"] = _data;
        Process.Start(quit)?.WaitForExit(10_000);
        for (var i = 0; i < 40 && !_app.HasExited; i++) Thread.Sleep(250);
        if (!_app.HasExited) _app.Kill();
        _app.Dispose();
        _app = null;
        Thread.Sleep(500);
    }

    private AutomationElement Find(Window window, string id) =>
        Retry.WhileNull(() => window.FindFirstDescendant(c => c.ByAutomationId(id)), Long, TimeSpan.FromMilliseconds(250)).Result
        ?? throw new InvalidOperationException($"{id} not found");

    private void Click(Window window, string id)
    {
        var element = Find(window, id);
        if (element.Patterns.Invoke.IsSupported) element.Patterns.Invoke.Pattern.Invoke();
        else if (element.Patterns.SelectionItem.IsSupported) element.Patterns.SelectionItem.Pattern.Select();
        else element.Click();
        Wait.UntilInputIsProcessed(TimeSpan.FromSeconds(1));
    }

    private void SelectSection(Window window, string title)
    {
        var list = Find(window, "SettingsSections");
        var item = Retry.WhileNull(() => list.FindFirstDescendant(c => c.ByName(title)), Long).Result ?? throw new InvalidOperationException($"{title} section not found");
        var row = item.Patterns.SelectionItem.IsSupported ? item : item.Parent;
        if (row.Patterns.SelectionItem.IsSupported) row.Patterns.SelectionItem.Pattern.Select();
        else row.Click();
        WaitFor(() => Find(window, "SettingsTitle").Name == title ? "ok" : null, $"the {title} section");
    }

    /// <summary>Opens the notification area menu through a second launch (<c>--tray-menu</c>) and captures it.</summary>
    private void TrayMenu(Window window, string name)
    {
        var bounds = window.BoundingRectangle;
        Mouse.Position = new System.Drawing.Point(bounds.X + bounds.Width / 2, bounds.Y + bounds.Height / 3);
        var open = new ProcessStartInfo(_exe, "--tray-menu") { UseShellExecute = false };
        open.Environment["BRIDGEY_DATA_DIR"] = _data;
        Process.Start(open)?.WaitForExit(10_000);
        var desktop = _automation.GetDesktop();
        var menu = Retry.WhileNull(() => desktop.FindFirstChild(c => c.ByClassName("#32768")), TimeSpan.FromSeconds(10)).Result;
        Assert.NotNull(menu);
        Assert.NotNull(menu!.FindFirstDescendant(c => c.ByName("Quit Bridgey")));
        Thread.Sleep(400);
        var r = menu.BoundingRectangle;
        Capture.Rectangle(new System.Drawing.Rectangle(r.X - 8, r.Y - 8, r.Width + 16, r.Height + 16)).ToFile(Path.Combine(_shots, name + ".png"));
        Keyboard.Press(VirtualKeyShort.ESCAPE);
        Wait.UntilInputIsProcessed(TimeSpan.FromSeconds(1));
    }

    private void Shot(Window window, string name)
    {
        // Let page and panel animations finish first.
        Thread.Sleep(700);
        Capture.Element(window).ToFile(Path.Combine(_shots, name + ".png"));
    }

    private void TryShot(string name)
    {
        try { Capture.Screen().ToFile(Path.Combine(_shots, name + ".png")); }
        catch (Exception) { }
    }

    private static T WaitFor<T>(Func<T?> probe, string what) where T : class
    {
        var deadline = DateTime.UtcNow + Long;
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                if (probe() is { } found) return found;
            }
            catch (Exception) { }
            Thread.Sleep(250);
        }
        throw new TimeoutException($"Timed out waiting for {what}");
    }

    private static void WaitFor(Func<bool> probe, string what) => WaitFor(() => probe() ? "ok" : null, what);

    private void StartPeer()
    {
        var start = new ProcessStartInfo(_peerExe)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            ArgumentList = { "--name", PeerName, "--port", PeerPort.ToString(), "--allow", "--discover", "--send", FromPeer, "--seconds", "900", "--receive-dir", _peerInbox, "--phone" },
        };
        _peer = Process.Start(start) ?? throw new InvalidOperationException("peer did not start");
        _peer.OutputDataReceived += (_, e) =>
        {
            if (string.IsNullOrEmpty(e.Data)) return;
            lock (_peerLog) _peerLog.Add(e.Data);
            try { _peerEvents.Add(JsonDocument.Parse(e.Data).RootElement.Clone()); }
            catch (JsonException) { }
        };
        _peer.ErrorDataReceived += (_, e) =>
        {
            if (!string.IsNullOrEmpty(e.Data)) lock (_peerLog) _peerLog.Add("stderr: " + e.Data);
        };
        _peer.BeginOutputReadLine();
        _peer.BeginErrorReadLine();
        _peerId = PeerEvent("ready").GetProperty("deviceId").GetString();
    }

    /// <summary>The peer's device ID, so a relaunch can keep it allowed in the Calls window.</summary>
    private string? _peerId;

    private JsonElement PeerEvent(string kind, Func<JsonElement, bool>? match = null)
    {
        var deadline = DateTime.UtcNow + Long;
        while (DateTime.UtcNow < deadline)
        {
            if (_peerEvents.TryTake(out var e, 250) && e.GetProperty("event").GetString() == kind && (match is null || match(e))) return e;
        }
        string log;
        lock (_peerLog) log = string.Join("\n", _peerLog);
        throw new TimeoutException($"The peer never reported {kind}. Its output:\n{log}");
    }

    private static string? ClipboardText()
    {
        if (!OpenClipboard(0)) return null;
        try
        {
            var handle = GetClipboardData(13 /* CF_UNICODETEXT */);
            if (handle == 0) return null;
            var pointer = GlobalLock(handle);
            try { return Marshal.PtrToStringUni(pointer); }
            finally { GlobalUnlock(handle); }
        }
        finally { CloseClipboard(); }
    }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool OpenClipboard(nint owner);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseClipboard();

    [LibraryImport("user32.dll")]
    private static partial nint GetClipboardData(uint format);

    [LibraryImport("kernel32.dll")]
    private static partial nint GlobalLock(nint handle);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GlobalUnlock(nint handle);

    public void Dispose()
    {
        try { Quit(); }
        catch (Exception) { }
        if (_peer is { HasExited: false }) _peer.Kill();
        _peer?.Dispose();
        _automation.Dispose();
        // The data folder stays: the build script copies the app's log (bridgey.log) from it into the artifacts.
    }
}
