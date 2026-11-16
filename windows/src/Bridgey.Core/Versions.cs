using System.Globalization;
using System.Text.RegularExpressions;

namespace Bridgey;

/// <summary>
/// The edition's version names (scripts/rr/versions.py, UpdateLogic.kt, UpdateLogic.swift): 1.0.0 Stable,
/// 1.0.0-beta.2 Beta, 1.0.0-nightly.20261116 Nightly; local builds are 1.0.0-dev.
/// </summary>
public static partial class Versions
{
    private static readonly string[] Months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

    [GeneratedRegex(@"^(\d+)\.(\d+)\.(\d+)(?:-rr\.(\d+))?(?:-(beta|nightly)\.(\d+))?$")]
    private static partial Regex Parts();

    /// <summary>
    /// The short label people see: 1.0.0 is "1.0", 1.0.1 "1.0.1", 1.1.0-beta.2 "1.1 Beta 2",
    /// 1.0.0-nightly.20261116 "1.0 Nightly 16 Nov". Anything else comes back unchanged.
    /// </summary>
    public static string Display(string name)
    {
        var m = Parts().Match(name ?? "");
        if (!m.Success) return name ?? "";
        var (major, minor, patch) = (m.Groups[1].Value, m.Groups[2].Value, m.Groups[3].Value);
        var core = $"{major}.{minor}.{patch}";
        var channel = m.Groups[5].Success ? m.Groups[5].Value : "stable";
        if (channel == "nightly" && m.Groups[6].Value.Length != 8) return name!;
        var @base = m.Groups[4].Success ? $"{core}-rr.{m.Groups[4].Value}" : patch == "0" ? $"{major}.{minor}" : core;
        if (channel == "beta") return $"{@base} Beta {m.Groups[6].Value}";
        if (channel == "nightly")
        {
            var number = int.Parse(m.Groups[6].Value, CultureInfo.InvariantCulture);
            int day = number % 100, month = number / 100 % 100;
            return month is >= 1 and <= 12 && day is >= 1 and <= 31 ? $"{@base} Nightly {day} {Months[month - 1]}" : $"{@base} Nightly {number}";
        }
        return @base;
    }

    /// <summary>"1.0 Beta 1", or "1.0.0-dev" on a local build.</summary>
    public static string ShortLabel => Display(Edition.VersionName);

    /// <summary>"1.0.0-beta.1 (263201050)" for About.</summary>
    public static string FullLabel => $"{Edition.VersionName} ({Edition.BuildNumber})";
}
