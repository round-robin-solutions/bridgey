using Bridgey.Platform;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Bridgey;

/// <summary>One Bridgey per Windows user (per data folder): a second launch hands its command to the first.</summary>
public static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        using var mutex = new Mutex(initiallyOwned: true, "Local\\" + TrayIcon.ClassName, out var first);
        if (!first)
        {
            var command = args.Contains("--tray-menu") ? TrayIcon.CommandMenu
                : args.Contains("--quit") ? TrayIcon.CommandQuit
                : args.Contains("--pair") ? TrayIcon.CommandPair
                : args.Contains("--background") ? "" : TrayIcon.CommandShow;
            // Wait a little for the first instance's window while it is still starting.
            for (var i = 0; i < 20 && command.Length > 0 && !TrayIcon.Forward(command); i++) Thread.Sleep(250);
            return 0;
        }
        // Nothing to quit or to show a menu for: never start Bridgey just to do that.
        if (args.Contains("--quit")) return 0;
        Application.Start(_ =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App();
        });
        return 0;
    }
}
