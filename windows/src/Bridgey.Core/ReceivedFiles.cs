namespace Bridgey;

/// <summary>
/// What Open does with a received file. A paired device chooses the name, so a file that would run code (a program,
/// script, shortcut, installer or disk image) is shown in Explorer instead of opened, as Android never opens a
/// package (0.10 L3; security review 1.0). The file also carries the mark of the web (bridgey_core writes it), so
/// Windows' own checks apply when the person opens it from there.
/// </summary>
public static class ReceivedFiles
{
    // Windows' high-risk attachment types, plus packages and images that mount or install.
    private static readonly HashSet<string> Runnable = new(StringComparer.OrdinalIgnoreCase)
    {
        ".ade", ".adp", ".app", ".application", ".appref-ms", ".appx", ".appxbundle", ".asp", ".aspx", ".asx", ".bas",
        ".bat", ".bgi", ".cab", ".cer", ".chm", ".cmd", ".cnt", ".com", ".cpl", ".crt", ".csh", ".der", ".diagcab",
        ".dll", ".exe", ".fxp", ".gadget", ".grp", ".hlp", ".hpj", ".hta", ".htc", ".img", ".inf", ".ins", ".iso",
        ".isp", ".its", ".jar", ".jnlp", ".js", ".jse", ".ksh", ".library-ms", ".lnk", ".mad", ".maf", ".mag", ".mam",
        ".maq", ".mar", ".mas", ".mat", ".mau", ".mav", ".maw", ".mcf", ".mda", ".mdb", ".mde", ".mdt", ".mdw", ".mdz",
        ".msc", ".msh", ".msh1", ".msh1xml", ".msh2", ".msh2xml", ".mshxml", ".msi", ".msix", ".msixbundle", ".msp",
        ".mst", ".msu", ".ops", ".osd", ".pcd", ".pif", ".pl", ".plg", ".prf", ".prg", ".printerexport", ".ps1",
        ".ps1xml", ".ps2", ".ps2xml", ".psc1", ".psc2", ".psd1", ".psdm1", ".psm1", ".pst", ".py", ".pyc", ".pyo",
        ".pyw", ".pyz", ".pyzw", ".reg", ".scf", ".scr", ".sct", ".search-ms", ".searchconnector-ms",
        ".settingcontent-ms", ".shb", ".shs", ".sys", ".theme", ".themepack", ".tmp", ".url", ".vb", ".vbe", ".vbp",
        ".vbs", ".vhd", ".vhdx", ".vsmacros", ".vsw", ".webpnp", ".website", ".ws", ".wsc", ".wsf", ".wsh", ".xbap",
        ".xll", ".xnk",
    };

    /// <summary>True when Open may hand the file to its default app; false when it should only be shown in Explorer.</summary>
    public static bool OpensDirectly(string path)
    {
        // Windows ignores trailing dots and spaces, so "setup.exe." runs as "setup.exe".
        var name = Path.GetFileName(path).TrimEnd('.', ' ');
        // An alternate data stream ("a.txt:evil.exe") or a name Windows would not show as given is never opened.
        if (name.Length == 0 || name.Contains(':')) return false;
        return !Runnable.Contains(Path.GetExtension(name));
    }
}
