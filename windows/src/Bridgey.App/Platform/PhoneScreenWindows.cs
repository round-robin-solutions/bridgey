using Bridgey.ViewModels;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

namespace Bridgey.Platform;

/// <summary>
/// One window per phone for its screen (Views/PhoneScreenView): Mica where Windows has it, the edition's title bar,
/// sized to the phone's shape. Closing the window stops the stream; Stop in it closes the window.
/// </summary>
internal static class PhoneScreenWindows
{
    private sealed record Open(Window Window, Views.PhoneScreenView View)
    {
        public bool Closed { get; set; }
    }

    private static readonly Dictionary<string, Open> Shown = new();

    public static void Show(PhoneScreenItem item)
    {
        if (Shown.TryGetValue(item.DeviceId, out var existing))
        {
            existing.Window.Activate();
            return;
        }
        var view = new Views.PhoneScreenView(item)
        {
            RequestedTheme = App.Model.Settings.Values.Theme switch
            {
                AppTheme.Light => ElementTheme.Light,
                AppTheme.Dark => ElementTheme.Dark,
                _ => ElementTheme.Default,
            },
        };
        var window = new Window { Content = view, Title = item.Title, ExtendsContentIntoTitleBar = true };
        window.SetTitleBar(view.TitleBarElement);
        window.AppWindow.SetIcon(Paths.Asset("Bridgey.ico"));
        var bar = window.AppWindow.TitleBar;
        bar.ButtonBackgroundColor = Colors.Transparent;
        bar.ButtonInactiveBackgroundColor = Colors.Transparent;
        // The caption buttons follow the window's light or dark, as the main window's do.
        view.Loaded += (_, _) =>
        {
            var dark = view.ActualTheme == ElementTheme.Dark;
            bar.ButtonForegroundColor = dark ? Colors.White : Colors.Black;
            bar.ButtonHoverForegroundColor = dark ? Colors.White : Colors.Black;
            bar.ButtonHoverBackgroundColor = dark ? ColorHelper.FromArgb(0x20, 0xFF, 0xFF, 0xFF) : ColorHelper.FromArgb(0x14, 0x00, 0x00, 0x00);
            bar.ButtonInactiveForegroundColor = dark ? ColorHelper.FromArgb(0x80, 0xFF, 0xFF, 0xFF) : ColorHelper.FromArgb(0x80, 0x00, 0x00, 0x00);
        };
        if (MicaController.IsSupported()) window.SystemBackdrop = new MicaBackdrop();
        else view.ShowBackdropFallback();

        // A phone's shape: 760 pixels tall (less on a small screen), and wide enough for the bar.
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
        var scale = Win32.GetDpiForWindow(hwnd) / 96.0;
        if (scale <= 0) scale = 1;
        var area = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var height = Math.Min((int)(760 * scale), area.Height - (int)(48 * scale));
        var picture = height - (int)(100 * scale);
        var aspect = item.Width > 0 && item.Height > 0 ? item.Width / (double)item.Height : 9 / 19.5;
        var width = Math.Min(Math.Max((int)(picture * aspect), (int)(540 * scale)), area.Width - (int)(48 * scale));
        window.AppWindow.Resize(new SizeInt32(width, height));
        // Centred in the work area, so the bar is never below the screen's edge.
        window.AppWindow.Move(new PointInt32(area.X + Math.Max(0, (area.Width - width) / 2), area.Y + Math.Max(0, (area.Height - height) / 2)));

        var open = new Open(window, view);
        Shown[item.DeviceId] = open;
        window.Closed += (_, _) =>
        {
            open.Closed = true;
            Shown.Remove(item.DeviceId);
            view.Shutdown();
            item.Close();
        };
        item.CloseRequested += () => window.DispatcherQueue.TryEnqueue(() =>
        {
            if (!open.Closed) window.Close();
        });
        window.Activate();
    }

    /// <summary>Bridgey is quitting.</summary>
    public static void CloseAll()
    {
        foreach (var open in Shown.Values.ToList())
            if (!open.Closed) open.Window.Close();
    }
}
