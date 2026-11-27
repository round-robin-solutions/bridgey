using System.Text.Json.Nodes;
using Bridgey.ViewModels;
using Xunit;

namespace Bridgey.Tests;

/// <summary>The Calls window and the call card against a fake session client: what they ask bridgey_core and show.</summary>
public sealed class CallsViewModelTests
{
    private const string Phone = "11111111-1111-4111-8111-111111111111";
    private const string Both = """{"clipboard":true,"dialer_draft1":true,"calls":true}""";

    private readonly FakeClient _client = new();
    private readonly AppSettings _settings = new() { CallsWindow = true };

    private const string State = """
        {"ok":true,"available":true,"upstream":true,"calling":false,"searching":false,"recentsLoaded":true,"loadingRecents":false,
         "phone":{"place":true,"confirm":false,"contacts":"on","recents":"on","whatsapp":true,
                  "sims":[{"subId":1,"slot":0,"label":"EE"},{"subId":2,"slot":1,"label":"Vodafone"}]}}
        """;

    private const string Rows = """
        {"ok":true,"searching":false,"rows":[
          {"kind":"contact","rowId":"c:7","number":"+44 7700 900123","id":7,"name":"Anna Kapoor","numbers":[{"address":"+44 7700 900123","label":"Mobile"}],
           "whatsapp":[{"address":"+447700900123","voice":4211,"video":4212}]},
          {"kind":"recent","rowId":"r:500","number":null,"id":500,"address":"","name":null,"type":"missed","date":1793091000000,"duration":0}
        ]}
        """;

    private (MainViewModel Model, CallsViewModel Calls) Connected(bool allowed = true)
    {
        if (allowed) _settings.CallsAllowed.Add(Phone);
        _client.State.Devices.Add(new SnapshotDevice { DeviceId = Phone, Name = "Pixel 9", Platform = "android", Local = new() { ["clipboard"] = true, ["dialer_draft1"] = allowed, ["calls"] = allowed } });
        _client.PhoneAnswers["state"] = State;
        _client.PhoneAnswers["rows"] = Rows;
        var model = new MainViewModel(_client, new SettingsViewModel(_settings, _ => { }, "Test PC"), new InlineDispatcher(), new FakeClipboard(), new FakeAlerts());
        model.Calls.Delay = _ => Task.CompletedTask;
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Connected, 0, 0, Phone, "Pixel 9", null, null));
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Features, 0, 0, Phone, null, Both, Both));
        return (model, model.Calls);
    }

    private List<JsonNode> Commands(string op) =>
        _client.PhoneCommands.Where(c => c.Area == PhoneArea.Calls).Select(c => JsonNode.Parse(c.Command)!).Where(c => c["op"]!.GetValue<string>() == op).ToList();

    [Fact]
    public void An_allowed_phone_shows_contacts_recent_calls_and_its_SIMs()
    {
        var (model, calls) = Connected();
        Assert.True(model.Devices.Single().CallsReady);
        Assert.Equal(Phone, calls.PhoneId);
        Assert.True(calls.IsAvailable);
        Assert.True(calls.HasSims);
        Assert.Null(calls.Sim);
        Assert.Equal(["c:7", "r:500"], calls.Rows.Select(r => r.RowId));
        var anna = calls.Rows[0];
        Assert.Equal("AK", anna.Initials);
        Assert.Equal("Mobile · +44 7700 900123", anna.Detail);
        Assert.True(anna.HasWhatsAppVoice);
        Assert.True(anna.HasWhatsAppVideo);
        var missed = calls.Rows[1];
        Assert.Equal("Private number", missed.Title);
        Assert.True(missed.Missed);
        Assert.False(missed.CanCall);
        Assert.StartsWith("Missed · ", missed.Detail);
    }

    [Fact]
    public void Each_phone_is_off_until_allowed()
    {
        var (model, calls) = Connected(allowed: false);
        var phone = model.Devices.Single();
        Assert.False(phone.CallsReady);
        Assert.Empty(calls.Phones);
        Assert.False(phone.Switches.Single(s => s.Key == "dialer_draft1").IsOn);
        phone.Switches.Single(s => s.Key == "dialer_draft1").IsOn = true;
        Assert.Contains(Phone, _settings.CallsAllowed);
        Assert.Contains($"feature {Phone} dialer_draft1 True", _client.Calls);
        Assert.Contains($"feature {Phone} calls True", _client.Calls);
        // The Calls window off turns both keys off for every phone, and the allowance stays.
        _client.State.Devices[0].Local["dialer_draft1"] = true;
        _client.State.Devices[0].Local["calls"] = true;
        model.Settings.CallsWindow = false;
        Assert.Contains($"feature {Phone} dialer_draft1 False", _client.Calls);
        Assert.True(phone.CallsAllowed);
    }

    [Fact]
    public void A_typed_number_asks_for_a_SIM_then_calls_from_it()
    {
        var (_, calls) = Connected();
        calls.Press("0");
        calls.Press("7");
        calls.Query = "07700 900123";
        Assert.True(calls.QueryIsNumber);
        Assert.Equal("Results", calls.ListTitle);
        Assert.Equal("07700 900123", Commands("search").Last()["query"]!.GetValue<string>());
        _client.PhoneAnswers["call"] = """{"ok":false,"error":"choose_sim","sims":[]}""";
        calls.CallPrimary();
        Assert.True(calls.IsAskingSim);
        Assert.Equal("ask", Commands("call").Last()["prefer"]!.GetValue<string>());
        _client.PhoneAnswers["call"] = """{"ok":true,"requestId":"r1"}""";
        calls.CallWithSim(calls.Sims[1]);
        Assert.False(calls.IsAskingSim);
        Assert.Equal(2, Commands("call").Last()["subId"]!.GetValue<long>());
        Assert.Equal("Vodafone", calls.Sim!.Label);
    }

    [Fact]
    public void Each_call_says_what_happened()
    {
        var (_, calls) = Connected();
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Calls, 0, 0, Phone, "call", """{"requestId":"r1","result":"sent","via":"phone"}""", null));
        Assert.True(calls.Calling);
        Assert.Equal("Asking Pixel 9…", calls.Notice);
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Calls, 0, 0, Phone, "call", """{"requestId":"r1","result":"started","via":"phone"}""", null));
        Assert.False(calls.Calling);
        Assert.True(calls.NoticeGood);
        Assert.Equal("Calling on Pixel 9. Talk on the phone or its earbuds.", calls.Notice);
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Calls, 0, 0, Phone, "call", """{"requestId":"r2","result":"refused","reason":"emergency","via":"phone"}""", null));
        Assert.False(calls.NoticeGood);
        Assert.Equal("Call emergency numbers from your phone.", calls.Notice);
        Assert.Equal("WhatsApp is calling on Pixel 9.", CallsViewModel.NoticeText("started", "whatsapp_video", null, "Pixel 9"));
        Assert.Equal("Pixel 9 didn't answer. Check it's connected and try again.", CallsViewModel.NoticeText("no_answer", "calls", null, "Pixel 9"));

        calls.Rows[0].CallWhatsAppVideo();
        var wa = Commands("whatsapp").Single();
        Assert.Equal(4212, wa["dataId"]!.GetValue<long>());
        Assert.True(wa["video"]!.GetValue<bool>());
    }

    private static string CallPost(string id, string type, bool quiet = false, string caller = "Anna Kapoor") => $$"""
        {"packageName":"com.google.android.dialer","applicationName":"Phone","notificationId":"{{id}}","title":"{{caller}}","text":"Incoming call",
         "timestamp":1,"callType":"{{type}}","quiet":{{(quiet ? "true" : "false")}},
         "actions":[{"token":"aaaa","title":"Answer","allowsReply":false},{"token":"bbbb","title":"Speaker","allowsReply":false},{"token":"cccc","title":"Decline","allowsReply":false}]}
        """;

    [Fact]
    public void The_call_card_shows_the_phone_s_call_with_its_own_buttons_until_it_ends()
    {
        var (_, calls) = Connected();
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Notification, 0, 0, Phone, "Phone", CallPost("call-1", "incoming"), null));
        var card = Assert.IsType<CallCardItem>(calls.Card);
        Assert.Equal("Incoming call", card.Status);
        Assert.Equal("Anna Kapoor", card.Caller);
        // Two buttons, the end one kept in.
        Assert.Equal(["Answer", "Decline"], card.Actions.Select(a => a.Title));
        Assert.True(card.Actions[0].IsAnswer);
        Assert.True(card.Actions[1].IsEnd);
        card.Actions[0].Run();
        Assert.Contains("action call-1 aaaa ", _client.Calls);

        // Answered: the same notification becomes the call in progress.
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Notification, 0, 0, Phone, "Phone", CallPost("call-1", "ongoing"), null));
        Assert.Equal("Call in progress", calls.Card!.Status);
        _client.Emit(new BridgeyEvent(BridgeyEventKind.NotificationRemoved, 1, 0, Phone, null, "call-1", null));
        Assert.Null(calls.Card);

        // Taken away without the end flag: gone after the grace (immediate here).
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Notification, 0, 0, Phone, "Phone", CallPost("call-2", "incoming"), null));
        _client.Emit(new BridgeyEvent(BridgeyEventKind.NotificationRemoved, 0, 0, Phone, null, "call-2", null));
        Assert.Null(calls.Card);

        // Quiet calls never show; Hide hides one.
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Notification, 0, 0, Phone, "Phone", CallPost("call-3", "incoming", quiet: true), null));
        Assert.Null(calls.Card);
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Notification, 0, 0, Phone, "Phone", CallPost("call-4", "incoming"), null));
        calls.Card!.Hide();
        Assert.Null(calls.Card);
    }

    [Fact]
    public void Words_match_the_Mac()
    {
        Assert.Equal("AK", CallsWords.Initials("Anna Kapoor"));
        Assert.Equal("R", CallsWords.Initials("rohan"));
        Assert.Equal("MW", CallsWords.Initials("Mary Jane Watson"));
        Assert.Equal("#", CallsWords.Initials("+91 98765"));
        Assert.Equal("", CallsWords.Duration(0));
        Assert.Equal("45 s", CallsWords.Duration(45));
        Assert.Equal("3 min 4 s", CallsWords.Duration(184));
        var now = DateTimeOffset.Now;
        Assert.Equal("Just now", CallsWords.Relative(now.AddSeconds(-20), now));
        Assert.Equal("5 min ago", CallsWords.Relative(now.AddMinutes(-5), now));
        Assert.Equal("end", CallsWords.Role("Hang up"));
        Assert.Equal("answer", CallsWords.Role("Accept"));
        Assert.Equal("+79991234567", CallsViewModel.NormalisedNumber(" +7 (999) 123-45-67 "));
        Assert.Null(CallsViewModel.NormalisedNumber("*100#"));
        Assert.Null(CallsViewModel.NormalisedNumber("7 +999 123"));
    }
}
