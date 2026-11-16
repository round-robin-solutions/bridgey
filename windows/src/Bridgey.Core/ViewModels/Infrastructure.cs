using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace Bridgey.ViewModels;

/// <summary>INotifyPropertyChanged without reflection, for compiled bindings and NativeAOT.</summary>
public abstract partial class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        return true;
    }

    protected void Raise([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>Runs work on the UI thread (the WinUI DispatcherQueue; inline in tests).</summary>
public interface IUiDispatcher
{
    void Post(Action action);
}

public sealed class InlineDispatcher : IUiDispatcher
{
    public void Post(Action action) => action();
}

/// <summary>The Windows clipboard, as far as the view models need it.</summary>
public interface IClipboardService
{
    void SetText(string text);
}

/// <summary>Sounds and attention: a ping plays one short sound; find device rings until stopped.</summary>
public interface IAlertService
{
    void Ping(string deviceName);
    /// <summary>A file arrived: a notification with Open and Show in folder.</summary>
    void FileReceived(string deviceName, string fileName, string path);
    /// <summary>Another device rings this PC until <see cref="StopRinging"/>.</summary>
    void StartRinging(string deviceName);
    void StopRinging();
}

/// <summary>Opening received files and their folder (Explorer on Windows).</summary>
public interface IFileService
{
    void Open(string path);
    void ShowInFolder(string path);
}

/// <summary>Opens a web link in the default browser; false when Windows could not.</summary>
public interface ILinkOpener
{
    bool Open(string url);
}

/// <summary>This PC's player (Windows' media controls), for the phone's media buttons.</summary>
public interface IMediaHost
{
    /// <summary>What plays changed (null: nothing plays). Raised on any thread.</summary>
    event Action<MediaState?>? Changed;
    void Start();
    void Stop();
    /// <summary>toggle, pause, next, previous, seek (seconds) or volume (0 to 100); true when the player did it.</summary>
    Task<bool> RunAsync(string action, long? value);
}
