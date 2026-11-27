using System.Text.Json.Nodes;
using Bridgey.ViewModels;
using Xunit;

namespace Bridgey.Tests;

/// <summary>The Phone files page's view model against a fake session client: what it asks bridgey_core and what it shows.</summary>
public sealed class PhoneFilesViewModelTests
{
    private const string Phone = "11111111-1111-4111-8111-111111111111";
    private const string Local = """{"clipboard":true,"files":true,"folders_receive_draft1":true}""";
    private const string Remote = """{"clipboard":true,"files":true,"files_browse_draft1":true}""";

    private readonly FakeClient _client = new();

    private (MainViewModel Model, PhoneFilesViewModel Files) Connected(string remote = Remote)
    {
        _client.State.Devices.Add(new SnapshotDevice { DeviceId = Phone, Name = "Pixel 9", Platform = "android", Local = new() { ["clipboard"] = true, ["files"] = true } });
        _client.PhoneAnswers["status"] = """{"ok":true,"available":true,"files":true}""";
        foreach (var op in new[] { "places", "list", "media", "thumbnails", "download" }) _client.PhoneAnswers[op] = $$"""{"ok":true,"requestId":"r-{{op}}"}""";
        _client.PhoneAnswers["upload"] = """{"ok":true,"uploadId":"u-1"}""";
        var model = new MainViewModel(_client, new SettingsViewModel(new AppSettings(), _ => { }, "Test PC"), new InlineDispatcher(), new FakeClipboard(), new FakeAlerts());
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Connected, 0, 0, Phone, "Pixel 9", null, null));
        _client.Emit(new BridgeyEvent(BridgeyEventKind.Features, 0, 0, Phone, null, Local, remote));
        return (model, model.PhoneFiles);
    }

    private void Event(string what, string json) => _client.Emit(new BridgeyEvent(BridgeyEventKind.PhoneFiles, 0, 0, Phone, what, json, null));

    private JsonNode Last(string op) => JsonNode.Parse(_client.PhoneCommands.Last(c => JsonNode.Parse(c.Command)!["op"]!.GetValue<string>() == op).Command)!;

    [Fact]
    public void Places_then_a_folder_with_thumbnails()
    {
        var (model, files) = Connected();
        Assert.True(model.Devices.Single().PhoneFilesReady);
        Assert.Equal(Phone, files.PhoneId);
        Assert.True(files.InFolders);
        Assert.Equal("places", JsonNode.Parse(_client.PhoneCommands.Last().Command)!["op"]!.GetValue<string>());

        Event("places", """{"requestId":"r-places","places":[{"placeId":"default","label":"Download/Bridgey","available":true,"freeBytes":2147483648},{"placeId":"q3Jx0bVv1eG7tq8Wm2l5wA","label":"Pictures","available":false,"freeBytes":null}],"writable":true}""");
        Assert.Equal(["Download/Bridgey", "Pictures"], files.Items.Select(i => i.Name));
        Assert.Equal("2 GB free", files.Items[0].Detail);
        Assert.Equal("Not available", files.Items[1].Detail);
        Assert.False(files.CanUpload);

        files.Items[0].Open();
        var list = Last("list");
        Assert.Equal("default", list["placeId"]!.GetValue<string>());
        Assert.Equal("", list["path"]!.GetValue<string>());
        Assert.Equal(["Places", "Download/Bridgey"], files.Crumbs.Select(c => c.Title));

        Event("list", """{"requestId":"r-list","placeId":"default","path":"","entries":[{"name":"Trip","dir":true,"size":null,"modified":null,"mimeType":null,"thumb":false},{"name":"IMG_0001.jpg","dir":false,"size":300000,"modified":null,"mimeType":"image/jpeg","thumb":true}],"folderCount":1,"fileCount":1,"nextCursor":"o200","writable":true}""");
        Assert.Equal(["Trip", "IMG_0001.jpg"], files.Items.Select(i => i.ToString()));
        Assert.Equal("Folder", files.Items[0].Detail);
        Assert.Equal("293 KB", files.Items[1].Detail);
        Assert.True(files.HasMore);
        Assert.True(files.CanUpload);
        var thumbs = Last("thumbnails");
        var key = thumbs["items"]![0]!["key"]!.GetValue<string>();
        Assert.Equal("IMG_0001.jpg", thumbs["items"]![0]!["ref"]!["name"]!.GetValue<string>());
        Event("thumbnails", $$"""{"requestId":"r-thumbnails","thumbs":[{"key":"{{key}}","mimeType":"image/png","width":1,"height":1,"data":"iVBORw0KGgo="}],"missing":[],"done":true}""");
        Assert.True(files.Items[1].HasThumbnail);
        Assert.False(files.Items[0].HasThumbnail);

        files.Items[0].Open();
        Assert.Equal("Trip", Last("list")["path"]!.GetValue<string>());
        Assert.Equal(["Places", "Download/Bridgey", "Trip"], files.Crumbs.Select(c => c.Title));
        files.Up();
        Assert.Equal("", Last("list")["path"]!.GetValue<string>());
        files.Crumbs[0].Go();
        Assert.False(files.InPlace);
    }

    [Fact]
    public void Sections_ask_for_photos_documents_and_recent()
    {
        var (_, files) = Connected();
        files.Section = PhoneFilesViewModel.Photos;
        Assert.Equal("media", Last("media")["kind"]!.GetValue<string>());
        Event("media", """{"requestId":"r-media","kind":"media","items":[{"ref":{"mediaId":"101"},"name":"IMG_0001.jpg","size":2048,"thumb":true,"location":"Camera"}],"access":"full"}""");
        Assert.Equal("IMG_0001.jpg", files.Items.Single().Name);
        Assert.Contains("Camera", files.Items.Single().Detail);
        Assert.Equal("101", Last("thumbnails")["items"]![0]!["ref"]!["mediaId"]!.GetValue<string>());
        files.Section = PhoneFilesViewModel.Documents;
        Assert.Equal("files", Last("media")["kind"]!.GetValue<string>());
        files.Section = PhoneFilesViewModel.Recent;
        Assert.Equal("recent", Last("media")["kind"]!.GetValue<string>());
    }

    [Fact]
    public void A_download_shows_its_progress_and_where_it_landed()
    {
        var (_, files) = Connected();
        Event("places", """{"requestId":"r-places","places":[{"placeId":"default","label":"Download/Bridgey","available":true}]}""");
        files.Items[0].Open();
        Event("list", """{"requestId":"r-list","placeId":"default","path":"","entries":[{"name":"notes.txt","dir":false,"size":19,"thumb":false}],"writable":false}""");
        files.Download([files.Items[0]], @"D:\Here");
        var download = Last("download");
        Assert.Equal(@"D:\Here", download["folder"]!.GetValue<string>());
        Assert.Equal("notes.txt", download["items"]![0]!["name"]!.GetValue<string>());
        var row = files.Activities.Single();
        Assert.Equal("Downloading notes.txt", row.Heading);

        Event("download", """{"requestId":"r-download","state":"receiving","files":3,"filesDone":1,"bytes":1048576,"total":2097152,"folder":"D:\\Here"}""");
        Assert.Equal(50, row.Progress);
        Assert.Equal("1 of 3 files, 1 MB of 2 MB", row.Text);
        Assert.True(row.Running);
        Event("download", """{"requestId":"r-download","state":"done","files":3,"filesDone":3,"bytes":2097152,"total":2097152,"folder":"D:\\Here","renamed":1}""");
        Assert.False(row.Running);
        Assert.True(row.CanShow);
        Assert.Equal("Done. Items with names already in the folder were numbered.", row.Text);

        // A folder the phone sends on its own shows up too.
        Event("download", """{"requestId":"f-1","pushed":true,"state":"receiving","rootName":"Trip","files":1,"filesDone":0,"bytes":0,"total":10}""");
        Assert.Equal("Downloading Trip", files.Activities[0].Heading);
    }

    [Fact]
    public void Adding_files_goes_to_the_open_folder_and_failures_read_plainly()
    {
        var (_, files) = Connected();
        Event("places", """{"requestId":"r-places","places":[{"placeId":"default","label":"Download/Bridgey","available":true}]}""");
        files.Items[0].Open();
        Event("list", """{"requestId":"r-list","placeId":"default","path":"","entries":[],"writable":true}""");
        Assert.True(files.IsEmpty);
        Assert.Equal("This folder is empty.", files.EmptyText);
        files.Upload([@"C:\Users\test\Cafe\u0301.txt".Replace("\\u0301", "\u0301")]);
        var upload = Last("upload");
        Assert.Equal("default", upload["placeId"]!.GetValue<string>());
        // Names go composed (NFC), as the phone compares them.
        Assert.Equal("Caf\u00e9.txt", upload["files"]![0]!["name"]!.GetValue<string>());
        var row = files.Activities.Single();
        Event("upload", """{"uploadId":"u-1","state":"failed","error":"read_only"}""");
        Assert.True(row.Failed);
        Assert.Equal("Turn on Allow other devices to change files here on Pixel 9 to add files.", row.Text);

        Event("list", """{"requestId":"r-list","error":"not_found"}""");
        files.Reload();
        Event("list", """{"requestId":"r-list","error":"not_found"}""");
        Assert.Equal("This item is no longer on the phone.", files.Notice);
    }

    [Fact]
    public void A_phone_that_does_not_share_its_files_is_not_listed()
    {
        var (model, files) = Connected("""{"clipboard":true,"files":true}""");
        Assert.False(model.Devices.Single().PhoneFilesReady);
        Assert.Empty(files.Phones);
        Assert.True(files.HasNoPhone);
    }
}
