using System.Text;
using System.Text.Json;

namespace Bridgey;

// Browser support (docs/browser-extensions.md). Bridgey's extension for Chrome, Edge, Firefox and Brave reaches this
// app through native messaging: the browser starts bridgey-browser-host.exe (rust/browser-host, next to Bridgey.exe)
// for each message, and the helper asks this app over a named pipe only this Windows user can open. Settings > Media
// and actions > Browser extensions writes the host manifests and the per-user registry keys the browsers read, and
// turns the pipe on. Only two requests exist: the device list, and one address (http, https, mailto or tel) to one
// device. This file is the part that runs and is tested on any platform; Bridgey.App has the pipe and the registry.

/// <summary>What kind of address came from the browser.</summary>
public enum BrowserAddressKind
{
    /// <summary>An http or https link, under the rules every device applies to links.</summary>
    Web,
    /// <summary>The addresses of a mailto: link, joined with ", " (they go to the device's clipboard).</summary>
    Mailto,
    /// <summary>The number of a tel: link (phones call it; this PC cannot ask them to yet).</summary>
    Tel,
}

public sealed record BrowserAddress(BrowserAddressKind Kind, string Value)
{
    public const int MaxBytes = 4096;

    public static BrowserAddress? Parse(string value)
    {
        if (string.IsNullOrEmpty(value) || Encoding.UTF8.GetByteCount(value) > MaxBytes || value.Any(c => c < 0x21 || c > 0x7E)) return null;
        var lower = value.ToLowerInvariant();
        if (lower.StartsWith("http:", StringComparison.Ordinal) || lower.StartsWith("https:", StringComparison.Ordinal))
            return ViewModels.MainViewModel.IsWebLink(value) && !value.Contains('\\') ? new(BrowserAddressKind.Web, value) : null;
        if (lower.StartsWith("mailto:", StringComparison.Ordinal))
        {
            var part = value[7..].Split('?', 2)[0];
            string decoded;
            try { decoded = Uri.UnescapeDataString(part); }
            catch (UriFormatException) { return null; }
            var addresses = decoded.Split(',').Select(a => a.Trim()).ToList();
            return decoded.Length > 0 && addresses.All(IsPlainEmail) ? new(BrowserAddressKind.Mailto, string.Join(", ", addresses)) : null;
        }
        if (lower.StartsWith("tel:", StringComparison.Ordinal))
        {
            var number = Uri.UnescapeDataString(value[4..].Split(';', 2)[0]);
            if (number.Length == 0 || !number.All(c => char.IsAsciiDigit(c) || "+-(). ".Contains(c))) return null;
            var plus = number.Count(c => c == '+');
            if (plus > 1 || (plus == 1 && !number.TrimStart().StartsWith('+'))) return null;
            var digits = new string(number.Where(char.IsAsciiDigit).ToArray());
            return digits.Length is >= 3 and <= 15 ? new(BrowserAddressKind.Tel, (plus == 1 ? "+" : "") + digits) : null;
        }
        return null;
    }

    private static bool IsPlainEmail(string address)
    {
        var parts = address.Split('@');
        return parts.Length == 2 && parts[0].Length > 0 && parts[1].Length > 0 && address.Length <= 254
            && address.All(c => c > 0x20 && c < 0x7F && !"<>\"(),;:[]\\".Contains(c));
    }
}

/// <summary>One request line from bridgey-browser-host. Strict: one flat object, exact keys, no repeats, version 1.</summary>
public abstract record BrowserHostRequest
{
    public const int MaxBytes = 8192;

    public sealed record Devices : BrowserHostRequest;

    public sealed record Send(string Device, BrowserAddress Address) : BrowserHostRequest;

    public static BrowserHostRequest? Parse(ReadOnlySpan<byte> line)
    {
        if (line.Length == 0 || line.Length > MaxBytes) return null;
        var fields = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        try
        {
            var reader = new Utf8JsonReader(line, new JsonReaderOptions { MaxDepth = 2 });
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject) return null;
            while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
            {
                var name = reader.GetString()!;
                if (!reader.Read() || reader.TokenType is JsonTokenType.StartObject or JsonTokenType.StartArray) return null;
                if (!fields.TryAdd(name, JsonElement.ParseValue(ref reader))) return null;
            }
            if (reader.TokenType != JsonTokenType.EndObject || reader.Read()) return null;
        }
        catch (JsonException)
        {
            return null;
        }
        if (!fields.TryGetValue("version", out var version) || version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var v) || v != 1) return null;
        if (!fields.TryGetValue("type", out var type) || type.ValueKind != JsonValueKind.String) return null;
        switch (type.GetString())
        {
            case "devices" when fields.Count == 2:
                return new Devices();
            case "send" when fields.Count == 4 && fields.TryGetValue("device", out var device) && device.ValueKind == JsonValueKind.String
                             && fields.TryGetValue("url", out var url) && url.ValueKind == JsonValueKind.String:
                var id = device.GetString()!;
                if (!IsDeviceId(id) || BrowserAddress.Parse(url.GetString()!) is not { } address) return null;
                return new Send(id, address);
            default:
                return null;
        }
    }

    public static bool IsDeviceId(string id) => id.Length is > 0 and <= 64 && id.All(c => char.IsAsciiLetterOrDigit(c) || c == '-');
}

/// <summary>A device as the extension sees it: no addresses, battery or anything else.</summary>
public sealed record BrowserDevice(string Id, string Name, string Platform, bool Connected, bool Links, bool Calls);

/// <summary>This app's answer lines (newline-terminated JSON).</summary>
public static class BrowserHostReply
{
    public static byte[] Devices(IEnumerable<BrowserDevice> devices) => Line(w =>
    {
        w.WriteBoolean("ok", true);
        w.WriteStartArray("devices");
        foreach (var d in devices.Take(32))
        {
            w.WriteStartObject();
            w.WriteBoolean("calls", d.Calls);
            w.WriteBoolean("connected", d.Connected);
            w.WriteString("id", d.Id);
            w.WriteBoolean("links", d.Links);
            w.WriteString("name", d.Name.Length > 64 ? d.Name[..64] : d.Name);
            w.WriteString("platform", d.Platform);
            w.WriteEndObject();
        }
        w.WriteEndArray();
    });

    /// <summary>opened, waiting, calling, asking or copied.</summary>
    public static byte[] Sent(string result) => Line(w =>
    {
        w.WriteBoolean("ok", true);
        w.WriteString("result", result);
    });

    public static byte[] Error(string code) => Line(w =>
    {
        w.WriteString("error", code);
        w.WriteBoolean("ok", false);
    });

    private static byte[] Line(Action<Utf8JsonWriter> body)
    {
        using var stream = new MemoryStream();
        using (var w = new Utf8JsonWriter(stream))
        {
            w.WriteStartObject();
            body(w);
            w.WriteNumber("version", 1);
            w.WriteEndObject();
        }
        stream.WriteByte((byte)'\n');
        return stream.ToArray();
    }
}

/// <summary>The extension IDs and host name, from extensions/browser/native-host.json (next to Bridgey.exe).</summary>
public sealed record BrowserHostConfig(string Name, IReadOnlyList<string> ChromiumIds, IReadOnlyList<string> FirefoxIds)
{
    public const string HostName = "in.roundrobin.bridgey";

    public static BrowserHostConfig? Load(string path)
    {
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllBytes(path));
            var root = document.RootElement;
            if (root.GetProperty("name").GetString() != HostName) return null;
            var chromium = root.GetProperty("chromiumExtensionIds").EnumerateArray().Select(e => e.GetString() ?? "").ToList();
            var firefox = root.GetProperty("firefoxExtensionIds").EnumerateArray().Select(e => e.GetString() ?? "").ToList();
            if (chromium.Any(id => id.Length != 32 || id.Any(c => c < 'a' || c > 'p'))) return null;
            return new BrowserHostConfig(HostName, chromium, firefox);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or KeyNotFoundException or InvalidOperationException)
        {
            return null;
        }
    }
}

/// <summary>Where the browsers look for native messaging hosts on Windows, and what is written there.</summary>
public static class BrowserRegistration
{
    /// <summary>The per-user registry keys (under HKEY_CURRENT_USER) whose default value names a host manifest.</summary>
    public static IReadOnlyList<(string Browser, string Key, bool Firefox)> Keys { get; } =
    [
        ("Google Chrome", $@"Software\Google\Chrome\NativeMessagingHosts\{BrowserHostConfig.HostName}", false),
        ("Microsoft Edge", $@"Software\Microsoft\Edge\NativeMessagingHosts\{BrowserHostConfig.HostName}", false),
        ("Chromium", $@"Software\Chromium\NativeMessagingHosts\{BrowserHostConfig.HostName}", false),
        ("Brave", $@"Software\BraveSoftware\Brave-Browser\NativeMessagingHosts\{BrowserHostConfig.HostName}", false),
        ("Firefox", $@"Software\Mozilla\NativeMessagingHosts\{BrowserHostConfig.HostName}", true),
    ];

    public const string HelperFile = "bridgey-browser-host.exe";

    /// <summary>The manifest file names in the data folder's NativeMessagingHosts folder.</summary>
    public static string ManifestFile(bool firefox) => $"{BrowserHostConfig.HostName}.{(firefox ? "firefox" : "chromium")}.json";

    public static string Manifest(BrowserHostConfig config, string helperPath, bool firefox)
    {
        using var stream = new MemoryStream();
        using (var w = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true }))
        {
            w.WriteStartObject();
            w.WriteString("name", config.Name);
            w.WriteString("description", "Bridgey by Round Robin: sends links from this browser to your devices");
            w.WriteString("path", helperPath);
            w.WriteString("type", "stdio");
            if (firefox)
            {
                w.WriteStartArray("allowed_extensions");
                foreach (var id in config.FirefoxIds) w.WriteStringValue(id);
            }
            else
            {
                w.WriteStartArray("allowed_origins");
                foreach (var id in config.ChromiumIds) w.WriteStringValue($"chrome-extension://{id}/");
            }
            w.WriteEndArray();
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(stream.ToArray()) + "\n";
    }

    /// <summary>The helper's pipe for a Windows user: in.roundrobin.bridgey.browser.&lt;SID&gt; (rust/browser-host has the same).</summary>
    public static string PipeName(string userSid) => $"{BrowserHostConfig.HostName}.browser.{userSid}";
}
