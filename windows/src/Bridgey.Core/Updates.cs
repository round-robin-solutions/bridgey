using System.Text.Json;
using System.Text.Json.Serialization;
using Bridgey.Native;

namespace Bridgey;

/// <summary>An update the channel feed offers (rust/client/src/update.rs, <c>Offer::to_json</c>).</summary>
public sealed class UpdateOffer
{
    public string Version { get; set; } = "";
    public ulong Build { get; set; }
    public string Url { get; set; } = "";
    public string Sha256 { get; set; } = "";
    public ulong Size { get; set; }
    public string Signature { get; set; } = "";
    public string Notes { get; set; } = "";
    public string NotesUrl { get; set; } = "";
}

internal sealed class UpdateReply
{
    public bool Ok { get; set; }
    public UpdateOffer? Offer { get; set; }
    public string? Error { get; set; }
}

/// <summary>
/// Self-update rules from bridgey_core: what a channel feed offers this PC, and whether a download is the one the feed
/// named (size, SHA-256, and the Ed25519 signature by the release key that signs the Mac's updates).
/// </summary>
public static unsafe class UpdateLogic
{
    public static readonly string[] Channels = ["stable", "beta", "nightly"];

    /// <summary>The channel a build follows when the person has not chosen one: its own (dev builds follow Beta).</summary>
    public static string DefaultChannel(string versionName) =>
        versionName.Contains("-nightly.", StringComparison.Ordinal) ? "nightly"
        : versionName.Contains("-beta.", StringComparison.Ordinal) || versionName.EndsWith("-dev", StringComparison.Ordinal) ? "beta"
        : "stable";

    private static string? Take(byte* text)
    {
        if (text == null) return null;
        try { return System.Runtime.InteropServices.Marshal.PtrToStringUTF8((nint)text); }
        finally { NativeMethods.bridgey_string_free(text); }
    }

    /// <summary>The offer, or null when nothing is newer. Throws <see cref="InvalidDataException"/> for a feed not to trust.</summary>
    public static UpdateOffer? Check(string feed, string channel, string arch, ulong currentBuild, string trustedPrefix, string appId)
    {
        var json = Take(NativeMethods.bridgey_update_check(feed, appId, channel, arch, currentBuild, trustedPrefix)) ?? throw new InvalidDataException("the update check failed");
        var reply = JsonSerializer.Deserialize(json, UpdateJson.Default.UpdateReply) ?? throw new InvalidDataException("the update check failed");
        if (!reply.Ok) throw new InvalidDataException(reply.Error ?? "the feed can't be trusted");
        return reply.Offer;
    }

    /// <summary>Null when the download checks out, else what is wrong.</summary>
    public static string? Verify(string path, UpdateOffer offer, string publicKey) =>
        Take(NativeMethods.bridgey_update_verify(path, offer.Sha256, offer.Size, offer.Signature, publicKey));
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(UpdateReply))]
internal sealed partial class UpdateJson : JsonSerializerContext;
