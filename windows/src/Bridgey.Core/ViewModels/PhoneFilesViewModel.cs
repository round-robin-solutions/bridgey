using System.Collections.ObjectModel;
using System.Text.Json.Nodes;

namespace Bridgey.ViewModels;

/// <summary>
/// The phone's files (files_browse_draft1), as the Mac's Phone files window shows them: Photos and videos, Files (recent
/// documents), Folders (its places and folders) and Recent, with thumbnails; Download to this PC and Add files to the
/// folder being browsed. bridgey_core (rust/client/src/phone_files.rs) talks to the phone and runs the folder transfers;
/// this asks it with JSON commands and follows its events.
/// </summary>
public sealed partial class PhoneFilesViewModel : ObservableObject
{
    public const int Photos = 0, Documents = 1, Folders = 2, Recent = 3;

    private readonly IBridgeyClient _client;
    private readonly Func<string, string> _nameOf;
    private string? _phone;
    private int _section = Folders;
    private string? _place;
    private string _placeLabel = "";
    private string _path = "";
    private string _sort = "name";
    private bool _descending;
    private bool _writable;
    private bool _loading;
    private bool _available;
    private string? _cursor;
    private string? _notice;
    private string _status = "";
    private string? _listRequest;
    private string? _thumbRequest;
    private readonly Dictionary<string, PhoneFileItem> _thumbKeys = new();
    private readonly Dictionary<string, string> _placeLabels = new();
    private int _nextKey;

    public PhoneFilesViewModel(IBridgeyClient client, Func<string, string> nameOf)
    {
        _client = client;
        _nameOf = nameOf;
        Items.CollectionChanged += (_, _) =>
        {
            Raise(nameof(HasItems));
            Raise(nameof(IsEmpty));
        };
        Activities.CollectionChanged += (_, _) => Raise(nameof(HasActivities));
    }

    /// <summary>Phones that let this PC browse them.</summary>
    public ObservableCollection<DeviceItem> Phones { get; } = new();
    /// <summary>The section's items: places, folders and files, photos.</summary>
    public ObservableCollection<PhoneFileItem> Items { get; } = new();
    /// <summary>Downloads and uploads from here, newest first.</summary>
    public ObservableCollection<FileActivity> Activities { get; } = new();
    /// <summary>The way back up: the place, then each folder.</summary>
    public ObservableCollection<Crumb> Crumbs { get; } = new();

    public string? PhoneId
    {
        get => _phone;
        set
        {
            if (!Set(ref _phone, value)) return;
            _place = null;
            _path = "";
            Raise(nameof(SelectedPhone));
            Raise(nameof(HasPhone));
            Raise(nameof(HasNoPhone));
            LoadStatus();
            Reload();
        }
    }

    public DeviceItem? SelectedPhone
    {
        get => Phones.FirstOrDefault(p => p.Id == _phone);
        set
        {
            if (value is not null) PhoneId = value.Id;
        }
    }

    public bool HasManyPhones => Phones.Count > 1;
    public bool HasPhone => _phone is not null;
    public bool HasNoPhone => _phone is null;
    public bool HasItems => Items.Count > 0;
    public bool IsEmpty => _phone is not null && !_loading && Items.Count == 0;
    public bool HasActivities => Activities.Count > 0;

    /// <summary>Photos and videos, Files, Folders or Recent from phone.</summary>
    public int Section
    {
        get => _section;
        set
        {
            if (!Set(ref _section, Math.Clamp(value, 0, 3))) return;
            Raise(nameof(InFolders));
            Raise(nameof(CanUpload));
            Raise(nameof(EmptyText));
            Reload();
        }
    }

    public bool InFolders => _section == Folders;
    /// <summary>Inside a place (not the list of places).</summary>
    public bool InPlace => InFolders && _place is not null;

    public string Sort
    {
        get => _sort;
        set
        {
            if (!Set(ref _sort, value is "modified" or "size" or "kind" ? value : "name")) return;
            Raise(nameof(SortIndex));
            if (InPlace) Reload();
        }
    }

    public int SortIndex
    {
        get => _sort switch { "modified" => 1, "size" => 2, "kind" => 3, _ => 0 };
        set => Sort = value switch { 1 => "modified", 2 => "size", 3 => "kind", _ => "name" };
    }

    public bool Descending
    {
        get => _descending;
        set
        {
            if (Set(ref _descending, value) && InPlace) Reload();
        }
    }

    /// <summary>The phone lets other devices change files in this folder.</summary>
    public bool Writable
    {
        get => _writable;
        private set
        {
            if (Set(ref _writable, value)) Raise(nameof(CanUpload));
        }
    }

    public bool CanUpload => _available && InPlace && _writable;

    public bool Loading
    {
        get => _loading;
        private set
        {
            if (Set(ref _loading, value)) Raise(nameof(IsEmpty));
        }
    }

    public bool HasMore => _cursor is not null;

    public bool IsAvailable
    {
        get => _available;
        private set
        {
            if (!Set(ref _available, value)) return;
            Raise(nameof(CanUpload));
        }
    }

    public string Status
    {
        get => _status;
        private set
        {
            if (Set(ref _status, value)) Raise(nameof(HasStatus));
        }
    }

    public bool HasStatus => _status.Length > 0;

    public string? Notice
    {
        get => _notice;
        set
        {
            if (Set(ref _notice, value)) Raise(nameof(HasNotice));
        }
    }

    public bool HasNotice => _notice is not null;

    public void DismissNotice() => Notice = null;

    public string EmptyText => _section switch
    {
        Photos => "No photos or videos.",
        Documents => "No recent documents.",
        Recent => "Nothing recent.",
        _ => InPlace ? "This folder is empty." : "No places to show.",
    };

    // MARK: From the main view model

    internal void Readiness(DeviceItem device, bool ready)
    {
        var listed = Phones.Contains(device);
        if (ready && !listed) Phones.Add(device);
        if (!ready && listed) Phones.Remove(device);
        Raise(nameof(HasManyPhones));
        Raise(nameof(SelectedPhone));
        if (_phone is null && Phones.Count > 0) PhoneId = Phones[0].Id;
        else if (_phone == device.Id)
        {
            var was = _available;
            LoadStatus();
            if (!was && _available) Reload();
        }
    }

    internal void Forgotten(string deviceId)
    {
        if (Phones.FirstOrDefault(p => p.Id == deviceId) is { } p) Phones.Remove(p);
        if (_phone == deviceId) PhoneId = Phones.FirstOrDefault()?.Id;
    }

    internal void Handle(BridgeyEvent e)
    {
        if (e.Kind != BridgeyEventKind.PhoneFiles || e.DeviceId is null || e.Text is null) return;
        JsonNode? d;
        try { d = JsonNode.Parse(e.Text); }
        catch (System.Text.Json.JsonException) { return; }
        if (d is null) return;
        switch (e.Name)
        {
            case "status" when e.DeviceId == _phone:
                var was = _available;
                LoadStatus();
                if (!was && _available) Reload();
                break;
            case "places" when Str(d["requestId"]) == _listRequest:
                ShowPlaces(d);
                break;
            case "list" when Str(d["requestId"]) == _listRequest:
                ShowList(d);
                break;
            case "media" when Str(d["requestId"]) == _listRequest:
                ShowMedia(d);
                break;
            case "thumbnails":
                foreach (var t in d["thumbs"]?.AsArray() ?? [])
                {
                    if (Str(t?["key"]) is not { } key || !_thumbKeys.TryGetValue(key, out var item) || Str(t?["data"]) is not { } data) continue;
                    try { item.Thumbnail = Convert.FromBase64String(data); }
                    catch (FormatException) { }
                }
                break;
            case "download":
                Activity(e.DeviceId, d, download: true);
                break;
            case "upload":
                Activity(e.DeviceId, d, download: false);
                // New files show up in the folder they went to.
                if (Str(d["state"]) is "done" or "incomplete" && InPlace && d["destination"] is { } dest && Str(dest["placeId"]) == _place && Str(dest["path"]) == _path) Reload();
                break;
        }
    }

    // MARK: Moving around

    /// <summary>The section or folder again from the phone.</summary>
    public void Reload()
    {
        _cursor = null;
        Raise(nameof(HasMore));
        Load(more: false);
    }

    public void LoadMore()
    {
        if (_cursor is not null) Load(more: true);
    }

    /// <summary>Opens a place or a folder; a file opens nothing (Download takes it).</summary>
    public void Open(PhoneFileItem item)
    {
        if (item.PlaceId is { } place && item.IsPlace)
        {
            _place = place;
            _placeLabel = item.Name;
            _path = "";
        }
        else if (item.IsFolder && _place is not null)
        {
            _path = _path.Length == 0 ? item.Name : $"{_path}/{item.Name}";
        }
        else return;
        Raise(nameof(InPlace));
        Raise(nameof(CanUpload));
        Raise(nameof(EmptyText));
        Reload();
    }

    /// <summary>One level up: the parent folder, then the list of places.</summary>
    public void Up()
    {
        if (!InPlace) return;
        if (_path.Length == 0) _place = null;
        else _path = _path.Contains('/') ? _path[.._path.LastIndexOf('/')] : "";
        Raise(nameof(InPlace));
        Raise(nameof(CanUpload));
        Raise(nameof(EmptyText));
        Reload();
    }

    public bool CanGoUp => InPlace;

    internal void GoTo(Crumb crumb)
    {
        if (crumb.Place is null) _place = null;
        else
        {
            _place = crumb.Place;
            _path = crumb.Path;
        }
        Raise(nameof(InPlace));
        Raise(nameof(CanUpload));
        Raise(nameof(EmptyText));
        Reload();
    }

    private void Load(bool more)
    {
        if (_phone is null) return;
        var command = _section switch
        {
            Photos => new JsonObject { ["op"] = "media", ["kind"] = "media" },
            Documents => new JsonObject { ["op"] = "media", ["kind"] = "files" },
            Recent => new JsonObject { ["op"] = "media", ["kind"] = "recent" },
            _ when _place is null => new JsonObject { ["op"] = "places" },
            _ => new JsonObject { ["op"] = "list", ["placeId"] = _place, ["path"] = _path, ["sort"] = _sort, ["descending"] = _descending },
        };
        if (more && _cursor is not null) command["cursor"] = _cursor;
        if (!more)
        {
            Items.Clear();
            _thumbKeys.Clear();
            UpdateCrumbs();
        }
        var answer = Command(command);
        if (!Bool(answer?["ok"]))
        {
            _listRequest = null;
            Loading = false;
            if (Str(answer?["error"]) is "not_connected") Status = _phone is null ? "" : $"{_nameOf(_phone)} isn't connected.";
            return;
        }
        _listRequest = Str(answer!["requestId"]);
        Loading = true;
    }

    private void UpdateCrumbs()
    {
        Crumbs.Clear();
        if (!InFolders) return;
        Crumbs.Add(new Crumb(this, "Places", null, ""));
        if (_place is null) return;
        Crumbs.Add(new Crumb(this, _placeLabel.Length > 0 ? _placeLabel : _placeLabels.GetValueOrDefault(_place, "Phone"), _place, ""));
        var walked = "";
        foreach (var part in _path.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            walked = walked.Length == 0 ? part : $"{walked}/{part}";
            Crumbs.Add(new Crumb(this, part, _place, walked));
        }
        Raise(nameof(CanGoUp));
    }

    private void ShowPlaces(JsonNode d)
    {
        Loading = false;
        _listRequest = null;
        if (Str(d["error"]) is { } error)
        {
            Notice = Problem(error);
            return;
        }
        Items.Clear();
        foreach (var p in d["places"]?.AsArray() ?? [])
        {
            if (Str(p?["placeId"]) is not { } id) continue;
            var label = Str(p?["label"]) ?? id;
            _placeLabels[id] = label;
            var free = Long(p?["freeBytes"]);
            Items.Add(new PhoneFileItem(this)
            {
                Name = label,
                PlaceId = id,
                IsPlace = true,
                IsFolder = true,
                Detail = !Bool(p?["available"]) ? "Not available" : free > 0 ? $"{Sizes.Text(free)} free" : "",
            });
        }
    }

    private void ShowList(JsonNode d)
    {
        Loading = false;
        _listRequest = null;
        if (Str(d["error"]) is { } error)
        {
            Notice = Problem(error);
            return;
        }
        Writable = Bool(d["writable"]);
        _cursor = Str(d["nextCursor"]);
        Raise(nameof(HasMore));
        var added = new List<PhoneFileItem>();
        foreach (var e in d["entries"]?.AsArray() ?? [])
        {
            if (e is null || Str(e["name"]) is not { } name) continue;
            var folder = Bool(e["dir"]);
            var item = new PhoneFileItem(this)
            {
                Name = name,
                IsFolder = folder,
                PlaceId = _place,
                Ref = new JsonObject { ["placeId"] = _place, ["path"] = _path, ["name"] = name },
                Detail = folder ? "Folder" : Detail(Long(e["size"]), Long(e["modified"])),
                HasThumb = Bool(e["thumb"]),
            };
            Items.Add(item);
            added.Add(item);
        }
        AskThumbnails(added);
    }

    private void ShowMedia(JsonNode d)
    {
        Loading = false;
        _listRequest = null;
        if (Str(d["error"]) is { } error)
        {
            Notice = Problem(error);
            return;
        }
        _cursor = Str(d["nextCursor"]);
        Raise(nameof(HasMore));
        if (_section == Photos && Str(d["access"]) == "none") Status = "Bridgey on the phone can't see its photos. Allow photo access there.";
        var added = new List<PhoneFileItem>();
        foreach (var m in d["items"]?.AsArray() ?? [])
        {
            if (m is null || Str(m["name"]) is not { } name || m["ref"] is not JsonObject r) continue;
            var where = Str(m["location"]);
            var item = new PhoneFileItem(this)
            {
                Name = name,
                Ref = (JsonObject)r.DeepClone(),
                Detail = string.Join(" · ", new[] { Detail(Long(m["size"]), Long(m["taken"]) is > 0 and var t ? t : Long(m["modified"])), where ?? "" }.Where(s => s.Length > 0)),
                HasThumb = Bool(m["thumb"]),
            };
            Items.Add(item);
            added.Add(item);
        }
        AskThumbnails(added);
    }

    /// <summary>Thumbnails for what just showed, in batches of 64; a new folder replaces the request of the last.</summary>
    private void AskThumbnails(List<PhoneFileItem> items)
    {
        foreach (var batch in items.Where(i => i.HasThumb && i.Ref is not null).Chunk(64))
        {
            var list = new JsonArray();
            foreach (var item in batch)
            {
                var key = $"t{++_nextKey}";
                _thumbKeys[key] = item;
                list.Add((JsonNode)new JsonObject { ["key"] = key, ["ref"] = item.Ref!.DeepClone() });
            }
            var command = new JsonObject { ["op"] = "thumbnails", ["items"] = list, ["size"] = 128 };
            var answer = Command(command);
            _thumbRequest = Str(answer?["requestId"]) ?? _thumbRequest;
        }
    }

    // MARK: Downloads and uploads

    /// <summary>Downloads the chosen items (files and folders) into <paramref name="folder"/>, or the receive folder.</summary>
    public void Download(IReadOnlyList<PhoneFileItem> items, string? folder = null)
    {
        var refs = new JsonArray();
        foreach (var item in items.Where(i => i.Ref is not null).Take(100)) refs.Add(item.Ref!.DeepClone());
        if (refs.Count == 0) return;
        var command = new JsonObject { ["op"] = "download", ["items"] = refs };
        if (folder is not null) command["folder"] = folder;
        var answer = Command(command);
        if (!Bool(answer?["ok"]) || Str(answer?["requestId"]) is not { } id)
        {
            Notice = Str(answer?["error"]) == "not_connected" ? $"{_nameOf(_phone ?? "")} isn't connected." : "That can't be downloaded.";
            return;
        }
        var title = items.Count == 1 ? items[0].Name : $"{items.Count} items";
        Activities.Insert(0, new FileActivity(this, id, true, _phone!) { Title = title, Text = "Preparing on the phone" });
    }

    /// <summary>Adds files from this PC to the folder being browsed.</summary>
    public void Upload(IReadOnlyList<string> paths)
    {
        if (!CanUpload || paths.Count == 0) return;
        var files = new JsonArray();
        foreach (var p in paths)
        {
            // The phone composes names like the Mac does (NFC).
            files.Add((JsonNode)new JsonObject { ["path"] = p, ["name"] = FileName(p).Normalize(System.Text.NormalizationForm.FormC) });
        }
        var answer = Command(new JsonObject { ["op"] = "upload", ["placeId"] = _place, ["path"] = _path, ["files"] = files });
        if (!Bool(answer?["ok"]) || Str(answer?["uploadId"]) is not { } id)
        {
            Notice = "Those files can't be added. Folders aren't supported yet.";
            return;
        }
        var title = paths.Count == 1 ? FileName(paths[0]) : $"{paths.Count} files";
        Activities.Insert(0, new FileActivity(this, id, false, _phone!) { Title = title, Text = "Getting ready" });
    }

    internal void Cancel(FileActivity a) => Command(new JsonObject { ["op"] = a.IsDownload ? "cancel_download" : "cancel_upload", [a.IsDownload ? "requestId" : "uploadId"] = a.Id }, a.DeviceId);

    internal void Clear(FileActivity a) => Activities.Remove(a);

    /// <summary>Show in folder on a finished download: the host opens Explorer there.</summary>
    public event Action<string>? ShowFolderRequested;

    internal void ShowFolder(FileActivity a)
    {
        if (a.Folder is { } folder) ShowFolderRequested?.Invoke(folder);
    }

    private void Activity(string device, JsonNode d, bool download)
    {
        var id = Str(d[download ? "requestId" : "uploadId"]);
        if (id is null) return;
        var a = Activities.FirstOrDefault(x => x.Id == id && x.IsDownload == download);
        if (a is null)
        {
            // A folder the phone sends on its own lands in the receive folder; it shows here too.
            if (!download || !Bool(d["pushed"])) return;
            a = new FileActivity(this, id, true, device) { Title = Str(d["rootName"]) ?? "Folder" };
            Activities.Insert(0, a);
        }
        a.Update(d, _nameOf(device));
    }

    // MARK: Helpers

    /// <summary>The last part of a Windows or Unix path.</summary>
    private static string FileName(string path) => path[(path.LastIndexOfAny(['/', '\\']) + 1)..];

    private JsonNode? Command(JsonObject command, string? device = null)
    {
        if ((device ?? _phone) is not { } id) return null;
        try { return JsonNode.Parse(_client.Phone(PhoneArea.PhoneFiles, id, command.ToJsonString())); }
        catch (Exception e) when (e is BridgeyException or System.Text.Json.JsonException) { return null; }
    }

    private void LoadStatus()
    {
        var s = Command(new JsonObject { ["op"] = "status" });
        IsAvailable = Bool(s?["available"]);
        Status = _phone is null || IsAvailable ? ""
            : !Bool(s?["files"]) ? $"{_nameOf(_phone)} isn't connected, or Files is off."
            : $"Turn on Let other devices browse this phone in Bridgey on {_nameOf(_phone)}, or update it.";
    }

    /// <summary>What a protocol error code means, in plain words (the Mac's).</summary>
    internal string Problem(string code)
    {
        var phone = _phone is null ? "Your phone" : _nameOf(_phone);
        return code switch
        {
            "not_connected" => $"{phone} isn't connected.",
            "timeout" => $"{phone} didn't answer. Try again.",
            "cancelled" => "Cancelled.",
            "interrupted" => $"It stopped: {phone} disconnected.",
            "read_only" => $"Turn on Allow other devices to change files here on {phone} to add files.",
            "not_found" => "This item is no longer on the phone.",
            "place_unavailable" => $"Bridgey on {phone} lost access to this folder. Grant it again on the phone.",
            "busy" => $"{phone} is busy. Try again in a moment.",
            "insufficient_space" => "There isn't enough free space.",
            "policy" => $"Turn on Let other devices browse this phone in Bridgey on {phone}.",
            "no_folder" => "Choose where received files go in Settings > Files.",
            _ => $"Something went wrong on {phone}.",
        };
    }

    private static string Detail(long size, long modified)
    {
        var parts = new List<string>();
        if (size > 0) parts.Add(Sizes.Text(size));
        if (modified > 0) parts.Add(When(modified));
        return string.Join(" · ", parts);
    }

    /// <summary>"Today, 15:20", "Yesterday, 09:10", "3 Nov 2026".</summary>
    internal static string When(long ms)
    {
        var at = DateTimeOffset.FromUnixTimeMilliseconds(ms).ToLocalTime();
        var today = DateTimeOffset.Now.ToLocalTime().Date;
        if (at.Date == today) return $"Today, {at:HH:mm}";
        if (at.Date == today.AddDays(-1)) return $"Yesterday, {at:HH:mm}";
        return at.ToString("d MMM yyyy");
    }

    internal static long Long(JsonNode? node)
    {
        try { return node?.GetValue<long>() ?? 0; }
        catch (Exception e) when (e is FormatException or InvalidOperationException) { return 0; }
    }

    internal static string? Str(JsonNode? node)
    {
        try { return node?.GetValue<string>(); }
        catch (Exception e) when (e is FormatException or InvalidOperationException) { return null; }
    }

    internal static bool Bool(JsonNode? node)
    {
        try { return node?.GetValue<bool>() == true; }
        catch (Exception e) when (e is FormatException or InvalidOperationException) { return false; }
    }
}

/// <summary>Byte sizes as Windows shows them: "2.4 MB".</summary>
public static class Sizes
{
    public static string Text(long bytes) => bytes switch
    {
        < 1024 => $"{bytes} bytes",
        < 1024 * 1024 => $"{bytes / 1024.0:0.#} KB",
        < 1024L * 1024 * 1024 => $"{bytes / 1024.0 / 1024:0.#} MB",
        _ => $"{bytes / 1024.0 / 1024 / 1024:0.##} GB",
    };
}

/// <summary>One row: a place, a folder, a file or a photo.</summary>
public sealed partial class PhoneFileItem(PhoneFilesViewModel owner) : ObservableObject
{
    private byte[]? _thumbnail;

    public required string Name { get; init; }
    public string Detail { get; init; } = "";
    public bool IsFolder { get; init; }
    public bool IsPlace { get; init; }
    public string? PlaceId { get; init; }
    /// <summary>The phone's reference to it (places have none: they open, they don't download).</summary>
    public JsonObject? Ref { get; init; }
    public bool HasThumb { get; init; }
    public bool CanDownload => Ref is not null;

    /// <summary>Segoe Fluent Icons: a place, a folder, a picture or a document.</summary>
    public string Glyph => IsPlace ? "\uE8DA" : IsFolder ? "\uE8B7" : HasThumb ? "\uEB9F" : "\uE8A5";

    public byte[]? Thumbnail
    {
        get => _thumbnail;
        set
        {
            if (Set(ref _thumbnail, value))
            {
                Raise(nameof(HasThumbnail));
                Raise(nameof(ShowsGlyph));
            }
        }
    }

    public bool HasThumbnail => _thumbnail is not null;
    public bool ShowsGlyph => _thumbnail is null;

    /// <summary>What Narrator reads, and what UI Automation calls the row.</summary>
    public string Label => Detail.Length > 0 ? $"{Name}, {Detail}" : Name;

    public void Open() => owner.Open(this);

    public override string ToString() => Name;
}

/// <summary>A step of the way back up from the open folder.</summary>
public sealed class Crumb(PhoneFilesViewModel owner, string title, string? place, string path)
{
    public string Title { get; } = title;
    public string? Place { get; } = place;
    public string Path { get; } = path;
    public void Go() => owner.GoTo(this);
    public override string ToString() => Title;
}

/// <summary>A download or upload from the Phone files page.</summary>
public sealed partial class FileActivity(PhoneFilesViewModel owner, string id, bool download, string device) : ObservableObject
{
    private string _text = "";
    private double _progress;
    private bool _running = true;
    private bool _failed;
    private string? _folder;

    public string Id { get; } = id;
    public bool IsDownload { get; } = download;
    public string DeviceId { get; } = device;
    public required string Title { get; init; }

    public string Heading => IsDownload ? $"Downloading {Title}" : $"Adding {Title}";

    public string Text
    {
        get => _text;
        set => Set(ref _text, value);
    }

    /// <summary>0 to 100.</summary>
    public double Progress
    {
        get => _progress;
        private set => Set(ref _progress, value);
    }

    public bool Running
    {
        get => _running;
        private set
        {
            if (!Set(ref _running, value)) return;
            Raise(nameof(Finished));
            Raise(nameof(CanShow));
        }
    }

    public bool Finished => !_running;

    public bool Failed
    {
        get => _failed;
        private set => Set(ref _failed, value);
    }

    /// <summary>Where a download landed, for Show in folder.</summary>
    public string? Folder
    {
        get => _folder;
        private set
        {
            if (Set(ref _folder, value)) Raise(nameof(CanShow));
        }
    }

    public bool CanShow => !_running && IsDownload && _folder is not null && !_failed;

    public override string ToString() => Heading;

    internal void Update(JsonNode d, string phone)
    {
        var state = PhoneFilesViewModel.Str(d["state"]) ?? "";
        var files = PhoneFilesViewModel.Long(d["files"]);
        var done = PhoneFilesViewModel.Long(d["filesDone"]);
        var bytes = PhoneFilesViewModel.Long(d["bytes"]);
        var total = PhoneFilesViewModel.Long(d["total"]);
        if (total > 0) Progress = Math.Clamp(bytes * 100.0 / total, 0, 100);
        if (PhoneFilesViewModel.Str(d["folder"]) is { } folder) Folder = folder;
        var counted = files > 1 ? $"{done} of {files} files, {Sizes.Text(bytes)} of {Sizes.Text(total)}" : total > 0 ? $"{Sizes.Text(bytes)} of {Sizes.Text(total)}" : "";
        switch (state)
        {
            case "hashing":
                Text = "Getting ready";
                break;
            case "started":
            case "offered":
                Text = "Preparing on the phone";
                break;
            case "waiting":
                Text = $"Waiting for {phone}";
                break;
            case "receiving":
            case "sending":
                Text = counted;
                break;
            case "finishing":
                Text = "Finishing";
                break;
            case "done":
                Running = false;
                Progress = 100;
                Text = IsDownload ? (PhoneFilesViewModel.Long(d["renamed"]) > 0 ? "Done. Items with names already in the folder were numbered." : "Done") : "Done";
                break;
            case "incomplete":
                Running = false;
                Failed = PhoneFilesViewModel.Long(d["filesDone"]) == 0;
                Text = PhoneFilesViewModel.Long(d["failed"]) is var f and > 0 ? $"Done, but {f} {(f == 1 ? "item" : "items")} didn't make it" : "Stopped part way";
                break;
            case "cancelled":
                Running = false;
                Text = "Cancelled";
                break;
            default:
                Running = false;
                Failed = true;
                Text = owner.Problem(PhoneFilesViewModel.Str(d["error"]) ?? "");
                break;
        }
    }

    public void Cancel() => owner.Cancel(this);
    public void Clear() => owner.Clear(this);
    public void ShowFolder() => owner.ShowFolder(this);
}
