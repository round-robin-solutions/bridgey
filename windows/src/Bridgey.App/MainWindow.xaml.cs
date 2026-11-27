using Bridgey.Platform;
using Bridgey.ViewModels;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

namespace Bridgey;

/// <summary>
/// The window: Mica where Windows has it, the edition's title bar, Home, Notifications, Messages, Calls, Pair a device and
/// Settings, and the phone's call card over every page. Pages are made
/// once and kept, and change with a short fade and rise. Closing hides it to the notification area.
/// </summary>
public sealed partial class MainWindow : Window
{
    public const string HomePage = "home", PairPage = "pair", SettingsPage = "settings", SetupPage = "setup", NotificationsPage = "notifications", MessagesPage = "messages", CallsPage = "calls";

    private readonly Dictionary<string, FrameworkElement> _pages = new();
    private string _current = "";
    private bool _navigating;

    public MainWindow()
    {
        InitializeComponent();
        Title = Edition.DisplayName;
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.SetIcon(Paths.Asset("Bridgey.ico"));
        AppWindow.TitleBar.ButtonBackgroundColor = Colors.Transparent;
        AppWindow.TitleBar.ButtonInactiveBackgroundColor = Colors.Transparent;

        if (MicaController.IsSupported()) SystemBackdrop = new MicaBackdrop();
        else BackdropFallback.Visibility = Visibility.Visible;

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var scale = Win32.GetDpiForWindow(hwnd) / 96.0;
        if (scale <= 0) scale = 1;
        // 1040 x 720, or less on a small screen.
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Resize(new SizeInt32(Math.Min((int)(1040 * scale), area.Width - (int)(48 * scale)), Math.Min((int)(720 * scale), area.Height - (int)(48 * scale))));
        AppWindow.Move(new PointInt32(area.X + Math.Max(0, (area.Width - AppWindow.Size.Width) / 2), area.Y + Math.Max(0, (area.Height - AppWindow.Size.Height) / 2)));
        AppWindow.Closing += OnClosing;

        ApplyTheme();
        Motion.ShowHide(CallCard);
        Navigate(App.Model.Settings.SetupDone ? HomePage : SetupPage);
    }

    /// <summary>Light, dark or Windows' choice, for the content and the caption buttons.</summary>
    public void ApplyTheme()
    {
        Root.RequestedTheme = App.Model.Settings.Values.Theme switch
        {
            AppTheme.Light => ElementTheme.Light,
            AppTheme.Dark => ElementTheme.Dark,
            _ => ElementTheme.Default,
        };
        var dark = Root.ActualTheme == ElementTheme.Dark;
        AppWindow.TitleBar.ButtonForegroundColor = dark ? Colors.White : Colors.Black;
        AppWindow.TitleBar.ButtonHoverForegroundColor = dark ? Colors.White : Colors.Black;
        AppWindow.TitleBar.ButtonHoverBackgroundColor = dark ? ColorHelper.FromArgb(0x20, 0xFF, 0xFF, 0xFF) : ColorHelper.FromArgb(0x14, 0x00, 0x00, 0x00);
        AppWindow.TitleBar.ButtonInactiveForegroundColor = dark ? ColorHelper.FromArgb(0x80, 0xFF, 0xFF, 0xFF) : ColorHelper.FromArgb(0x80, 0x00, 0x00, 0x00);
    }

    public void ShowAnimated()
    {
        var wasVisible = AppWindow.IsVisible;
        AppWindow.Show();
        Activate();
        if (!wasVisible) Motion.Enter(Chrome);
    }

    private void OnClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (App.Instance.Quitting) return;
        args.Cancel = true;
        if (App.Model.Settings.KeepRunningInTray) Motion.Leave(Chrome, () => AppWindow.Hide());
        else App.Instance.Quit();
    }

    private FrameworkElement Page(string key)
    {
        if (_pages.TryGetValue(key, out var page)) return page;
        page = key switch
        {
            PairPage => new Views.PairPage(),
            SettingsPage => new Views.SettingsPage(),
            SetupPage => new Views.SetupPage(),
            NotificationsPage => new Views.NotificationsPage(),
            MessagesPage => new Views.MessagesPage(),
            CallsPage => new Views.CallsPage(),
            _ => new Views.HomePage(),
        };
        _pages[key] = page;
        return page;
    }

    /// <summary>Shows a page; the pairing page allows pairing while it is open.</summary>
    public void Navigate(string key)
    {
        if (key == _current) return;
        if (_current == PairPage) App.Model.Pairing.Closed();
        if (key == PairPage) App.Model.Pairing.Opened();
        _current = key;
        var page = Page(key);
        PageHost.Children.Clear();
        PageHost.Children.Add(page);
        Motion.Enter(page, rise: 16, milliseconds: 240);

        // Setup hides the navigation until it is done.
        var setup = key == SetupPage;
        Nav.IsPaneVisible = !setup;
        _navigating = true;
        Nav.SelectedItem = Nav.MenuItems.Concat(Nav.FooterMenuItems).OfType<NavigationViewItem>().FirstOrDefault(i => (string)i.Tag == key);
        _navigating = false;
    }

    /// <summary>Settings, at one section (Text messages from the Messages page).</summary>
    public void OpenSettings(string section)
    {
        ShowAnimated();
        Navigate(SettingsPage);
        if (Page(SettingsPage) is Views.SettingsPage settings) settings.Show(section);
    }

    public ViewModels.CallsViewModel Calls => App.Model.Calls;

    private void OnHideCall(object sender, RoutedEventArgs e) => Calls.Card?.Hide();

    /// <summary>A conversation from a text message notification.</summary>
    public void OpenConversation(string deviceId, long threadId)
    {
        ShowAnimated();
        Navigate(MessagesPage);
        App.Model.Messages.Open(deviceId, threadId);
    }

    private nint Hwnd => WinRT.Interop.WindowNative.GetWindowHandle(this);

    /// <summary>Windows' file picker, several files at once. Empty when the person cancels.</summary>
    public async Task<IReadOnlyList<string>> PickFiles()
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker { ViewMode = Windows.Storage.Pickers.PickerViewMode.List };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
        try
        {
            var files = await picker.PickMultipleFilesAsync();
            return files?.Select(f => f.Path).Where(p => !string.IsNullOrEmpty(p)).ToList() ?? [];
        }
        catch (Exception e)
        {
            App.Log($"File picker failed: {e.Message}");
            return [];
        }
    }

    /// <summary>Windows' folder picker, for where received files go. Null when the person cancels.</summary>
    public async Task<string?> PickFolder()
    {
        var picker = new Windows.Storage.Pickers.FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
        try { return (await picker.PickSingleFolderAsync())?.Path; }
        catch (Exception e)
        {
            App.Log($"Folder picker failed: {e.Message}");
            return null;
        }
    }

    /// <summary>"Send 3 files to": one of the connected devices that can take files, or null.</summary>
    public async Task<DeviceItem?> ChooseDevice(int count, IReadOnlyList<DeviceItem> devices)
    {
        var choices = new RadioButtons();
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(choices, "ChooseDevice");
        foreach (var d in devices) choices.Items.Add(new RadioButton { Content = d.Name, Tag = d });
        choices.SelectedIndex = 0;
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            RequestedTheme = Root.ActualTheme,
            Title = count == 1 ? "Send 1 file to" : $"Send {count} files to",
            Content = choices,
            PrimaryButtonText = "Send",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        var result = await dialog.ShowAsync();
        return result == ContentDialogResult.Primary && choices.SelectedItem is RadioButton { Tag: DeviceItem device } ? device : null;
    }

    /// <summary>A question with one action (Install) and Cancel.</summary>
    public async Task<bool> Confirm(string title, string text, string action)
    {
        ShowAnimated();
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            RequestedTheme = Root.ActualTheme,
            Title = title,
            Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = action,
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(dialog, "ConfirmDialog");
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    private void OnNavSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (_navigating || args.SelectedItem is not NavigationViewItem { Tag: string key }) return;
        Navigate(key);
    }
}
