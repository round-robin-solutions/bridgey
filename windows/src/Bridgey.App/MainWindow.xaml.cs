using Bridgey.Platform;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

namespace Bridgey;

/// <summary>
/// The window: Mica where Windows has it, the edition's title bar, Home, Pair a device and Settings. Pages are made
/// once and kept, and change with a short fade and rise. Closing hides it to the notification area.
/// </summary>
public sealed partial class MainWindow : Window
{
    public const string HomePage = "home", PairPage = "pair", SettingsPage = "settings", SetupPage = "setup";

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

    private void OnNavSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (_navigating || args.SelectedItem is not NavigationViewItem { Tag: string key }) return;
        Navigate(key);
    }
}
