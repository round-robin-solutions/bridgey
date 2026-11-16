namespace Bridgey.Platform;

/// <summary>
/// Where the app keeps its settings and protected pairing data. BRIDGEY_DATA_DIR (tests, a second profile) gives a
/// separate install: its own data, its own single instance, and nothing written to the registry.
/// </summary>
internal static class Paths
{
    public static readonly string? Override = Environment.GetEnvironmentVariable("BRIDGEY_DATA_DIR") is { Length: > 0 } d ? d : null;

    public static string DataFolder { get; } = Override ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), Edition.DisplayName);

    /// <summary>A separate data folder: a test or a second profile.</summary>
    public static bool IsSeparateProfile => Override is not null;

    /// <summary>Short and stable per data folder, so each profile has its own single-instance names.</summary>
    public static string ProfileTag { get; } = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(DataFolder.ToLowerInvariant())))[..8];

    public static string Asset(string name) => Path.Combine(AppContext.BaseDirectory, "Assets", name);
}
