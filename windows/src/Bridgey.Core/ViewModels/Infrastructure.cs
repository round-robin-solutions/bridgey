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

/// <summary>Sounds and attention: a ping plays one short sound.</summary>
public interface IAlertService
{
    void Ping(string deviceName);
}
