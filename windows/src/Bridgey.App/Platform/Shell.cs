using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.Marshalling;
using Bridgey.ViewModels;
using static Bridgey.Platform.Win32;

namespace Bridgey.Platform;

/// <summary>Opening received files and showing them in Explorer.</summary>
internal sealed class ExplorerFiles : IFileService
{
    public void Open(string path)
    {
        // A program, script, shortcut or installer from a paired device is shown, never run with one click.
        if (!ReceivedFiles.OpensDirectly(path))
        {
            ShowInFolder(path);
            return;
        }
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or FileNotFoundException)
        {
            App.Log($"Open failed: {e.Message}");
        }
    }

    public void ShowInFolder(string path)
    {
        try
        {
            var start = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
            start.ArgumentList.Add($"/select,{path}");
            Process.Start(start);
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            App.Log($"Show in folder failed: {e.Message}");
        }
    }

    /// <summary>Opens a folder in Explorer, creating it first so the person never meets "not found".</summary>
    public static void OpenFolder(string folder)
    {
        try
        {
            Directory.CreateDirectory(folder);
            Process.Start(new ProcessStartInfo(folder) { UseShellExecute = true });
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            App.Log($"Open folder failed: {e.Message}");
        }
    }
}

/// <summary>Where received files go by default: Downloads\Bridgey.</summary>
internal static class ReceiveFolder
{
    public static string Default
    {
        get
        {
            if (Environment.GetEnvironmentVariable("BRIDGEY_RECEIVE_DIR") is { Length: > 0 } test) return test;
            var downloads = KnownFolder(DownloadsFolder) ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
            return Path.Combine(downloads, "Bridgey");
        }
    }
}

/// <summary>
/// Bridgey in Explorer's Send to menu: a shortcut in the user's SendTo folder that runs <c>Bridgey.exe --send</c> with
/// the chosen files. A separate profile (tests) uses BRIDGEY_SENDTO_DIR, or leaves the menu alone.
/// </summary>
internal static unsafe partial class SendTo
{
    private static readonly Guid ShellLinkClass = new("00021401-0000-0000-C000-000000000046");
    private static readonly Guid ShellLinkIid = new("000214F9-0000-0000-C000-000000000046");
    private const uint ClsctxInprocServer = 1;

    private static string? Folder => Environment.GetEnvironmentVariable("BRIDGEY_SENDTO_DIR") is { Length: > 0 } test ? test
        : Paths.IsSeparateProfile ? null
        : Environment.GetFolderPath(Environment.SpecialFolder.SendTo);

    public static string? ShortcutPath => Folder is { } folder ? Path.Combine(folder, "Bridgey.lnk") : null;

    public static void Apply(bool on)
    {
        if (ShortcutPath is not { } shortcut || Environment.ProcessPath is not { } exe) return;
        try
        {
            if (!on)
            {
                if (File.Exists(shortcut)) File.Delete(shortcut);
                return;
            }
            Directory.CreateDirectory(Path.GetDirectoryName(shortcut)!);
            Create(shortcut, exe, "--send", "Send to a phone or Mac with Bridgey");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or COMException or InvalidCastException)
        {
            App.Log($"Send to shortcut failed: {e.Message}");
        }
    }

    private static void Create(string shortcut, string target, string arguments, string description)
    {
        var clsid = ShellLinkClass;
        var iid = ShellLinkIid;
        nint instance;
        Marshal.ThrowExceptionForHR(CoCreateInstance(&clsid, 0, ClsctxInprocServer, &iid, &instance));
        try
        {
            var wrappers = new StrategyBasedComWrappers();
            var link = (IShellLinkW)wrappers.GetOrCreateObjectForComInstance(instance, CreateObjectFlags.None);
            link.SetPath(target);
            link.SetArguments(arguments);
            link.SetDescription(description);
            link.SetIconLocation(target, 0);
            link.SetWorkingDirectory(Path.GetDirectoryName(target)!);
            ((IPersistFile)link).Save(shortcut, true);
        }
        finally
        {
            Marshal.Release(instance);
        }
    }

    [GeneratedComInterface(StringMarshalling = StringMarshalling.Utf16)]
    [Guid("000214F9-0000-0000-C000-000000000046")]
    internal partial interface IShellLinkW
    {
        void GetPath(char* file, int length, nint findData, uint flags);
        void GetIDList(out nint list);
        void SetIDList(nint list);
        void GetDescription(char* name, int length);
        void SetDescription(string name);
        void GetWorkingDirectory(char* dir, int length);
        void SetWorkingDirectory(string dir);
        void GetArguments(char* args, int length);
        void SetArguments(string args);
        void GetHotkey(out ushort hotkey);
        void SetHotkey(ushort hotkey);
        void GetShowCmd(out int show);
        void SetShowCmd(int show);
        void GetIconLocation(char* path, int length, out int index);
        void SetIconLocation(string path, int index);
        void SetRelativePath(string path, uint reserved);
        void Resolve(nint hwnd, uint flags);
        void SetPath(string file);
    }

    [GeneratedComInterface(StringMarshalling = StringMarshalling.Utf16)]
    [Guid("0000010b-0000-0000-C000-000000000046")]
    internal partial interface IPersistFile
    {
        void GetClassID(out Guid clsid);
        [PreserveSig]
        int IsDirty();
        void Load(string file, uint mode);
        void Save(string file, [MarshalAs(UnmanagedType.Bool)] bool remember);
        void SaveCompleted(string file);
        void GetCurFile(out nint file);
    }
}

/// <summary>A sound that repeats until stopped (find device). Missing sounds fall back to the system's.</summary>
internal static unsafe class Sounds
{
    private static readonly string[] Ring = ["Alarm01.wav", "Ring01.wav", "Windows Notify System Generic.wav"];

    public static void StartRinging()
    {
        var media = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Media");
        foreach (var name in Ring)
        {
            var path = Path.Combine(media, name);
            if (!File.Exists(path)) continue;
            fixed (char* p = path)
                if (PlaySound(p, 0, SND_FILENAME | SND_ASYNC | SND_LOOP | SND_NODEFAULT)) return;
        }
        fixed (char* alias = "SystemExclamation") PlaySound(alias, 0, SND_ALIAS | SND_ASYNC | SND_LOOP);
    }

    public static void Stop() => PlaySound(null, 0, 0);
}
