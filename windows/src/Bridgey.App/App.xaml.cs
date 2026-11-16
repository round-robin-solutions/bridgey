using Bridgey.Platform;
using Bridgey.ViewModels;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Bridgey;

/// <summary>
/// Starts the session client, the notification area icon and the window. Bridgey keeps running in the notification
/// area when the window closes (Settings > General); Quit is in the icon's menu.
/// </summary>
public partial class App : Application, ITrayHost
{
    public static MainViewModel Model { get; private set; } = null!;
    public static App Instance => (App)Current;

    private MainWindow? _window;
    private TrayIcon? _tray;
    private SettingsStore? _store;
    private readonly WindowsClipboard _clipboard = new();
    private DispatcherQueueTimer? _pairingTimer;
    private bool _quitting;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) =>
        {
            Log($"Unhandled: {e.Exception}");
            e.Handled = true;
        };
    }

    public bool Quitting => _quitting;

    internal static void Log(string line)
    {
        try
        {
            Directory.CreateDirectory(Paths.DataFolder);
            File.AppendAllText(Path.Combine(Paths.DataFolder, "bridgey.log"), $"{DateTimeOffset.Now:O} {line}{Environment.NewLine}");
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var commandLine = Environment.GetCommandLineArgs();
        _store = new SettingsStore(Paths.DataFolder);
        var settings = _store.Load();
        var settingsModel = new SettingsViewModel(settings, s => _store.Save(s), Environment.MachineName);
        var queue = DispatcherQueue.GetForCurrentThread();
        IBridgeyClient client;
        try
        {
            ushort.TryParse(Environment.GetEnvironmentVariable("BRIDGEY_PORT"), out var port);
            client = BridgeyClient.Start(new ClientOptions
            {
                DeviceName = settingsModel.DeviceName,
                Port = port,
                Discovery = Environment.GetEnvironmentVariable("BRIDGEY_DISCOVERY") != "0",
            }, new ProtectedStore(Paths.DataFolder));
        }
        catch (Exception e) when (e is BridgeyException or DllNotFoundException or InvalidOperationException)
        {
            Log($"Start failed: {e}");
            Win32.ShowError($"Bridgey couldn't start. {e.Message}");
            Exit();
            return;
        }
        Model = new MainViewModel(client, settingsModel, new UiDispatcher(queue), _clipboard, new Alerts());
        try { client.SetFeature(null, "clipboard", settings.Clipboard); }
        catch (BridgeyException) { }

        Model.ClipboardRequested += async device =>
        {
            var (text, _) = await _clipboard.ReadAsync();
            Model.SendClipboardText(device, text);
        };
        _clipboard.Watch(() => queue.TryEnqueue(async () =>
        {
            if (!Model.Settings.AutomaticClipboard) return;
            var (text, isPrivate) = await _clipboard.ReadAsync();
            Model.LocalCopy(text, isPrivate);
        }));
        Model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(MainViewModel.StatusText)) _tray?.SetTooltip(Model.StatusText);
        };
        settingsModel.StartAtSignInChanged += SignIn.Apply;
        settingsModel.AppearanceChanged += () =>
        {
            _window?.ApplyTheme();
            Win32.SetMenuTheme((int)Model.Settings.Values.Theme);
        };
        SignIn.Apply(settings.StartAtSignIn);
        Win32.SetMenuTheme((int)settings.Theme);

        _window = new MainWindow();
        _tray = new TrayIcon(this);
        _tray.SetTooltip(Model.StatusText);
        _pairingTimer = queue.CreateTimer();
        _pairingTimer.Interval = TimeSpan.FromMinutes(1);
        _pairingTimer.Tick += (_, _) => Model.Pairing.KeepAllowing();
        _pairingTimer.Start();

        if (!commandLine.Contains("--background") || !settings.SetupDone) _window.ShowAnimated();
        if (commandLine.Contains("--tray-menu")) queue.TryEnqueue(() => _tray.ShowMenu());
    }

    // ITrayHost

    public IReadOnlyList<(string Id, string Name)> ClipboardTargets() =>
        Model.Devices.Where(d => d.ClipboardReady).Select(d => (d.Id, d.Name)).ToList();

    public void Open() => _window?.ShowAnimated();

    public void Pair()
    {
        _window?.ShowAnimated();
        _window?.Navigate(MainWindow.PairPage);
    }

    public void Home() => _window?.Navigate(MainWindow.HomePage);

    /// <summary>First-run setup is done: on to pairing.</summary>
    public void FinishSetup()
    {
        Model.Settings.SetupDone = true;
        _window?.Navigate(MainWindow.PairPage);
    }

    public void Settings()
    {
        _window?.ShowAnimated();
        _window?.Navigate(MainWindow.SettingsPage);
    }

    public void AllowPairing() => Model.AllowPairing();

    public async void SendClipboard(string deviceId)
    {
        if (Model.Devices.FirstOrDefault(d => d.Id == deviceId) is not { } device) return;
        var (text, _) = await _clipboard.ReadAsync();
        Model.SendClipboardText(device, text);
    }

    /// <summary>A command from a second launch. It runs after WM_COPYDATA returns, so the sender never waits on a menu.</summary>
    public void Command(string command)
    {
        DispatcherQueue.GetForCurrentThread().TryEnqueue(() =>
        {
            switch (command)
            {
                case TrayIcon.CommandMenu: _tray?.ShowMenu(); break;
                case TrayIcon.CommandPair: Pair(); break;
                case TrayIcon.CommandQuit: Quit(); break;
                default: Open(); break;
            }
        });
    }

    public void Quit()
    {
        if (_quitting) return;
        _quitting = true;
        _pairingTimer?.Stop();
        _tray?.Dispose();
        _window?.Close();
        Model.Dispose();
        Exit();
    }
}
