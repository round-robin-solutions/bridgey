using System.Text.Json.Nodes;
using Bridgey.ViewModels;
using Xunit;

namespace Bridgey.Tests;

/// <summary>The Messages page's view model against a fake session client: what it asks bridgey_core and what it shows.</summary>
public sealed class MessagesViewModelTests
{
    private const string Phone = "11111111-1111-4111-8111-111111111111";
    private const string Both = """{"clipboard":true,"sms_draft1":true}""";

    private readonly FakeClient _client = new();
    private readonly AppSettings _settings = new() { TextMessages = true };

    private const string Threads = """
        {"ok":true,"threads":[
          {"threadId":12,"title":"Asha","participants":[{"address":"+447700900123","name":"Asha"}],"snippet":"See you at 6","date":1793091600000,"unread":2,"group":false},
          {"threadId":3,"title":"+447700900789, Sam","participants":[{"address":"+447700900789"},{"address":"+447700900790","name":"Sam"}],"snippet":"Ok","date":1793091400000,"unread":0,"group":true}
        ],"more":false}
        """;

    private const string Thread12 = """
        {"ok":true,"thread":{"threadId":12,"title":"Asha"},"older":false,"canSend":true,"sims":[],
         "messages":[
           {"id":"m40","threadId":12,"direction":"in","status":"received","date":1793091600000,"address":"+447700900123","body":"","parts":[{"partId":"p42","mimeType":"image/png"}]},
           {"id":"s101","threadId":12,"direction":"out","status":"delivered","date":1793091500000,"address":"+447700900123","body":"Running late"}
         ],
         "outgoing":[{"requestId":"5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293","body":"On my way","state":"failed","reason":"radio_off","threadId":12,"date":1793091700000}]}
        """;

    private (MainViewModel Model, MessagesViewModel Messages) Connected()
    {
        _client.State.Devices.Add(new SnapshotDevice { DeviceId = Phone, Name = "Pixel 9", Platform = "android", Local = new() { ["clipboard"] = true, ["sms_draft1"] = true } });
        _client.PhoneAnswers["status"] = """{"ok":true,"available":true,"phone":{"read":true,"send":true,"contacts":true,"sims":[{"subId":1,"slot":0,"label":"EE"},{"subId":2,"slot":1,"label":"Vodafone"}]}}""";
        _client.PhoneAnswers["threads"] = Threads;
        _client.PhoneAnswers["open"] = Thread12;
        _client.PhoneAnswers["messages"] = Thread12;
        var model = new MainViewModel(_client, new SettingsViewModel(_settings, _ => { }, "Test PC"), new InlineDispatcher(), new FakeClipboard(), new FakeAlerts());
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Connected, 0, 0, Phone, "Pixel 9", null, null));
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Features, 0, 0, Phone, null, Both, Both));
        return (model, model.Messages);
    }

    private List<string> Ops() => _client.PhoneCommands.Select(c => JsonNode.Parse(c.Command)!["op"]!.GetValue<string>()).ToList();

    [Fact]
    public void A_ready_phone_shows_its_conversations_unread_first()
    {
        var (model, messages) = Connected();
        Assert.True(model.Devices.Single().MessagesReady);
        Assert.Equal(Phone, messages.PhoneId);
        Assert.Contains("refresh", Ops());
        Assert.Equal([12L, 3L], messages.Conversations.Select(c => c.ThreadId));
        Assert.True(messages.Conversations[0].IsUnread);
        Assert.Equal("2", messages.Conversations[0].UnreadText);
        Assert.Equal("A", messages.Conversations[0].Initial);
        Assert.Equal("#", messages.Conversations[1].Initial);
        Assert.Contains("2 unread", messages.Conversations[0].Label);
        Assert.True(messages.HasSims);
        Assert.Equal("EE", messages.Sim!.Label);
        Assert.Equal("", messages.Status);
    }

    [Fact]
    public void Opening_a_conversation_reads_it_shows_pictures_and_failed_sends()
    {
        var (_, messages) = Connected();
        messages.Selected = messages.Conversations[0];
        var ops = Ops();
        Assert.Contains("open", ops);
        Assert.Contains("mark_read", ops);
        Assert.Contains("image", ops);
        Assert.Equal(0, messages.Conversations[0].Unread);
        // Oldest first, then this PC's send that did not go.
        Assert.Equal(["s101", "m40", "out:5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293"], messages.Messages.Select(m => m.Id));
        Assert.Equal("Delivered", messages.Messages[0].State);
        Assert.True(messages.Messages[1].Incoming);
        Assert.True(messages.Messages[1].HasPicture);
        Assert.True(messages.Messages[2].CanRetry);

        _client.Emit(new BridgeyEvent(BridgeyEventKind.Sms, 0, 0, Phone, "image", """{"partId":"p42","data":"iVBORw0KGgo=","width":1,"height":1}""", null));
        Assert.True(messages.Messages[1].HasImage);

        messages.Messages[2].Retry();
        Assert.Equal("retry", Ops()[^1]);
    }

    [Fact]
    public void Sending_goes_to_the_open_conversation_from_the_chosen_SIM()
    {
        var (_, messages) = Connected();
        messages.Selected = messages.Conversations[0];
        Assert.False(messages.CanSendDraft);
        messages.Draft = "On my way";
        messages.Sim = messages.Sims[1];
        Assert.True(messages.CanSendDraft);
        messages.Send();
        var send = JsonNode.Parse(_client.PhoneCommands.Last(c => c.Command.Contains("\"send\"")).Command)!;
        Assert.Equal(12, send["threadId"]!.GetValue<long>());
        Assert.Equal(2, send["subId"]!.GetValue<long>());
        Assert.Equal("On my way", send["body"]!.GetValue<string>());
        Assert.Equal("", messages.Draft);

        // A group conversation is answered on the phone.
        messages.Selected = messages.Conversations[1];
        messages.Draft = "Hi all";
        Assert.True(messages.IsGroup);
        Assert.False(messages.CanSendDraft);
    }

    [Fact]
    public void A_new_message_searches_contacts_and_sends_to_the_number()
    {
        var (_, messages) = Connected();
        messages.NewMessage();
        Assert.True(messages.HasThread);
        Assert.Equal("New message", messages.Title);
        messages.To = "As";
        Assert.Equal("contacts", Ops()[^1]);
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Sms, 0, 0, Phone, "contacts", """{"contacts":[{"name":"Asha","address":"+447700900123","label":"Mobile"}]}""", null));
        Assert.Equal("Mobile · +447700900123", messages.Contacts.Single().Detail);
        messages.Contacts.Single().Pick();
        Assert.Equal("+447700900123", messages.To);
        messages.Draft = "Hello";
        messages.Send();
        var send = JsonNode.Parse(_client.PhoneCommands.Last(c => c.Command.Contains("\"send\"")).Command)!;
        Assert.Equal("+447700900123", send["address"]!.GetValue<string>());
        Assert.False(messages.Composing);
    }

    [Fact]
    public void Notices_say_what_the_phone_did()
    {
        var (_, messages) = Connected();
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Sms, 0, 0, Phone, "notice", """{"kind":"mark_read","total":3,"marked":1}""", null));
        Assert.Equal("2 conversations stay unread on your phone. Open them there to clear them.", messages.Notice);
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Sms, 0, 0, Phone, "notice", """{"kind":"blocked","result":"notified"}""", null));
        Assert.Equal("Tap the notification on your phone to open Blocked numbers.", messages.Notice);
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Sms, 0, 0, Phone, "send", """{"requestId":"x","state":"refused","reason":"rate_limited"}""", null));
        Assert.Equal("Too many texts at once. Try again in a moment.", messages.Notice);
    }

    [Fact]
    public void Turning_text_messages_off_takes_the_phone_away()
    {
        var (model, messages) = Connected();
        model.Settings.TextMessages = false;
        Assert.Contains("feature  sms_draft1 False", _client.Calls);
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Features, 0, 0, Phone, null, """{"clipboard":true}""", Both));
        Assert.False(model.Devices.Single().MessagesReady);
        Assert.Empty(messages.Phones);
    }

    [Fact]
    public void An_sms_notification_without_its_own_reply_is_answered_through_the_phone()
    {
        var (model, _) = Connected();
        _settings.Notifications = true;
        var post = """{"packageName":"com.google.android.apps.messaging","applicationName":"Messages","notificationId":"0|sms|9","title":"Asha","text":"Lunch?","timestamp":1,"actions":[],"smsReply":true,"smsThreadId":12}""";
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Notification, 0, 0, Phone, "Messages", post, null));
        var item = model.Notifications.Items.Single();
        Assert.True(item.CanReply);
        Assert.Equal(12, item.SmsThreadId);
        item.Reply = "Yes";
        item.SendReply();
        var send = JsonNode.Parse(_client.PhoneCommands.Last(c => c.Command.Contains("\"send\"")).Command)!;
        Assert.Equal("0|sms|9", send["notificationId"]!.GetValue<string>());
        Assert.Equal("", item.Reply);
    }
}
