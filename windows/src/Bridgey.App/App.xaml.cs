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
    private readonly Notifications _notifications = new();
    private DispatcherQueueTimer? _pairingTimer;
    private DispatcherQueueTimer? _activityTimer;
    private DispatcherQueue? _queue;
    private bool _quitting;
    /// <summary>Files from Send to that arrived before any device could take them (Bridgey just started).</summary>
    private IReadOnlyList<string>? _pendingSend;

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

    internal MainWindow? Window => _window;

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
        var settingsModel = new SettingsViewModel(settings, s => _store.Save(s), Environment.MachineName) { DefaultReceiveFolder = ReceiveFolder.Default };
        var queue = _queue = DispatcherQueue.GetForCurrentThread();
        _notifications.Start();
        _notifications.Invoked += (arguments, input) => queue.TryEnqueue(() => NotificationAction(arguments, input));
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
        Model = new MainViewModel(client, settingsModel, new UiDispatcher(queue), _clipboard, new Alerts(_notifications, () => Model.Settings.Values), new ExplorerFiles(),
            new PhoneNotifier(_notifications), new ProtectedHistory(Paths.DataFolder), new CompanionAdvertiser());
        if (client is BridgeyClient native && !settings.FastTransfers) native.SetFastTransfers(false);
        Model.FilesRequested += device => _ = PickAndSend(device);
        Model.ChooseDeviceForFiles += (paths, devices) => _ = ChooseAndSend(paths, devices);
        Model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(MainViewModel.HasConnected) && Model.HasConnected) TrySendPending();
        };
        settingsModel.SendToMenuChanged += SendTo.Apply;
        SendTo.Apply(settings.SendToMenu);
        PowerWatch.Start((level, charging) => queue.TryEnqueue(() =>
        {
            try { client.SetBattery(level, charging); }
            catch (BridgeyException) { }
        }));

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

        Log("Client started; opening the window");
        _window = new MainWindow();
        _tray = new TrayIcon(this);
        _notifications.Fallback = _tray;
        Log("Window and notification area icon ready");
        _tray.SetTooltip(Model.StatusText);
        _pairingTimer = queue.CreateTimer();
        _pairingTimer.Interval = TimeSpan.FromMinutes(1);
        _pairingTimer.Tick += (_, _) => Model.Pairing.KeepAllowing();
        _pairingTimer.Start();
        _activityTimer = queue.CreateTimer();
        _activityTimer.Interval = TimeSpan.FromSeconds(2);
        _activityTimer.Tick += (_, _) => Model.ReportActivity(ActivityWatch.IdleSeconds(), ActivityWatch.Locked);
        _activityTimer.Start();

        var send = SendCommand.Paths(commandLine.Skip(1));
        if ((!commandLine.Contains("--background") && send is null) || !settings.SetupDone) _window.ShowAnimated();
        if (commandLine.Contains("--tray-menu")) queue.TryEnqueue(() => _tray.ShowMenu());
        if (send is not null) queue.TryEnqueue(() => SendFromShell(send));
    }

    /// <summary>Files from Explorer's Send to. Just after start no device is connected yet: wait up to 20 s for one.</summary>
    private void SendFromShell(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return;
        if (Model.Devices.Any(d => d.FilesReady) || Model.Devices.Count == 0)
        {
            Model.SendFilesFromShell(paths);
            return;
        }
        _pendingSend = paths;
        var timer = _queue!.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(20);
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            if (_pendingSend is { } waiting)
            {
                _pendingSend = null;
                _window?.ShowAnimated();
                Model.SendFilesFromShell(waiting);
            }
        };
        timer.Start();
    }

    private void TrySendPending()
    {
        if (_pendingSend is not { } paths) return;
        // Features arrive just after the connection; give them a moment.
        var timer = _queue!.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(1.5);
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            if (_pendingSend is null || !Model.Devices.Any(d => d.FilesReady)) return;
            _pendingSend = null;
            Model.SendFilesFromShell(paths);
        };
        timer.Start();
    }

    private async Task PickAndSend(DeviceItem device)
    {
        if (_window is null) return;
        _window.ShowAnimated();
        var paths = await _window.PickFiles();
        if (paths.Count > 0) Model.SendFiles(device, paths);
    }

    private async Task ChooseAndSend(IReadOnlyList<string> paths, IReadOnlyList<DeviceItem> devices)
    {
        if (_window is null) return;
        _window.ShowAnimated();
        if (await _window.ChooseDevice(paths.Count, devices) is { } device) Model.SendFiles(device, paths);
    }

    /// <summary>A notification's button: open or show a received file, stop the ring.</summary>
    private void NotificationAction(IDictionary<string, string> arguments, IDictionary<string, string> input)
    {
        arguments.TryGetValue("path", out var path);
        arguments.TryGetValue("device", out var device);
        arguments.TryGetValue("id", out var id);
        arguments.TryGetValue("token", out var token);
        input.TryGetValue("reply", out var reply);
        switch (arguments.TryGetValue("action", out var action) ? action : "")
        {
            case "phoneAction" or "phoneDismiss" or "copyCode" when device is not null && id is not null:
                Model.Notifications.FromBanner(device, id, action, token, reply);
                break;
            case "openNotifications":
                _window?.ShowAnimated();
                _window?.Navigate(MainWindow.NotificationsPage);
                break;
            case "open" when path is not null:
                new ExplorerFiles().Open(path);
                break;
            case "folder" when path is not null:
                new ExplorerFiles().ShowInFolder(path);
                break;
            case "stopRinging":
                Model.StopRinging();
                break;
            default:
                Open();
                break;
        }
    }

    // ITrayHost

    public IReadOnlyList<(string Id, string Name)> ClipboardTargets() =>
        Model.Devices.Where(d => d.ClipboardReady).Select(d => (d.Id, d.Name)).ToList();

    public IReadOnlyList<(string Id, string Name)> FileTargets() =>
        Model.Devices.Where(d => d.FilesReady).Select(d => (d.Id, d.Name)).ToList();

    public void SendFiles(string deviceId)
    {
        if (Model.Devices.FirstOrDefault(d => d.Id == deviceId) is { } device) _ = PickAndSend(device);
    }

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
            if (SendCommand.Parse(command) is { } paths)
            {
                SendFromShell(paths);
                return;
            }
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
        _activityTimer?.Stop();
        Model.StopRinging();
        _notifications.Dispose();
        _tray?.Dispose();
        _window?.Close();
        Model.Dispose();
        Exit();
    }
}
