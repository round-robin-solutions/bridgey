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
        AppDomain.CurrentDomain.UnhandledException += (_, e) => App.Log($"Unhandled (domain): {e.ExceptionObject}");
        // The unpacked update finishing an install: no window, no single-instance lock (the old Bridgey is ending).
        if (args.Length == 4 && args[0] == "--install-update" && int.TryParse(args[3], out var pid))
            return UpdateInstaller.Run(args[1], args[2], pid);
        WinRT.ComWrappersSupport.InitializeComWrappers();
        using var mutex = new Mutex(initiallyOwned: true, "Local\\" + TrayIcon.ClassName, out var first);
        if (!first)
        {
            var command = SendCommand.Paths(args) is { } paths ? SendCommand.Format(paths)
                : args.Contains("--tray-menu") ? TrayIcon.CommandMenu
                : args.Contains("--quit") ? TrayIcon.CommandQuit
                : args.Contains("--pair") ? TrayIcon.CommandPair
                : args.Contains("--background") ? "" : TrayIcon.CommandShow;
            // Wait a little for the first instance's window while it is still starting.
            for (var i = 0; i < 20 && command.Length > 0 && !TrayIcon.Forward(command); i++) Thread.Sleep(250);
            return 0;
        }
        // Nothing to quit or to show a menu for: never start Bridgey just to do that.
        if (args.Contains("--quit")) return 0;
        App.Log($"Starting {Edition.VersionName} ({Edition.BuildNumber})");
        Application.Start(start =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            try
            {
                new App();
            }
            catch (Exception e)
            {
                App.Log($"App failed to start: {e}");
                throw;
            }
        });
        return 0;
    }
}
