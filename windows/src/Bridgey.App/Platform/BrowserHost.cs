using System.IO.Pipes;
using System.Security.Principal;
using Bridgey.ViewModels;
using Microsoft.UI.Dispatching;
using Microsoft.Win32;

namespace Bridgey.Platform;

/// <summary>
/// Settings > Media and actions > Browser extensions (docs/browser-extensions.md): the host manifests in the data
/// folder, the per-user registry keys Chrome, Edge, Chromium, Brave and Firefox read, and the named pipe
/// bridgey-browser-host.exe asks. The pipe is for this Windows user only (CurrentUserOnly); the helper also checks
/// that the process serving it runs as the same user. A separate profile (BRIDGEY_DATA_DIR) never touches the registry.
/// </summary>
internal static class BrowserHost
{
    private static CancellationTokenSource? _serving;

    private static string HelperPath => Path.Combine(AppContext.BaseDirectory, BrowserRegistration.HelperFile);
    private static string ManifestFolder => Path.Combine(Paths.DataFolder, "NativeMessagingHosts");

    /// <summary>Turns browser support on or off and returns the line Settings shows under it.</summary>
    public static string Apply(bool on, Func<BrowserHostRequest, Task<byte[]>> handle, DispatcherQueue queue)
    {
        if (Paths.IsSeparateProfile) return "Not available in a separate profile.";
        var config = BrowserHostConfig.Load(Path.Combine(AppContext.BaseDirectory, "native-host.json"));
        if (config is null || !File.Exists(HelperPath))
        {
            Stop();
            return "Not available in this build.";
        }
        if (!on)
        {
            Stop();
            Unregister();
            return SettingsViewModel.BrowserSupportOff;
        }
        if (!Register(config)) return "Couldn't set up the browsers. Turn it off and on again.";
        Start(handle, queue);
        return "Set up for Chrome, Edge, Brave and Firefox. Add the extension in each browser.";
    }

    private static bool Register(BrowserHostConfig config)
    {
        try
        {
            Directory.CreateDirectory(ManifestFolder);
            foreach (var firefox in new[] { false, true })
            {
                var file = Path.Combine(ManifestFolder, BrowserRegistration.ManifestFile(firefox));
                File.WriteAllText(file, BrowserRegistration.Manifest(config, HelperPath, firefox));
            }
            foreach (var (_, keyPath, firefox) in BrowserRegistration.Keys)
            {
                using var key = Registry.CurrentUser.CreateSubKey(keyPath, writable: true);
                key.SetValue("", Path.Combine(ManifestFolder, BrowserRegistration.ManifestFile(firefox)));
            }
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            App.Log($"Browser support could not register: {e.Message}");
            return false;
        }
    }

    /// <summary>Removes the keys that name Bridgey's manifests (another app's keys stay) and the manifests.</summary>
    private static void Unregister()
    {
        try
        {
            foreach (var (_, keyPath, firefox) in BrowserRegistration.Keys)
            {
                using var key = Registry.CurrentUser.OpenSubKey(keyPath, writable: false);
                if (key?.GetValue("") is string value && value.EndsWith(BrowserRegistration.ManifestFile(firefox), StringComparison.OrdinalIgnoreCase))
                {
                    key.Dispose();
                    Registry.CurrentUser.DeleteSubKeyTree(keyPath, throwOnMissingSubKey: false);
                }
            }
            foreach (var firefox in new[] { false, true })
            {
                var file = Path.Combine(ManifestFolder, BrowserRegistration.ManifestFile(firefox));
                if (File.Exists(file)) File.Delete(file);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            App.Log($"Browser support could not unregister: {e.Message}");
        }
    }

    private static void Start(Func<BrowserHostRequest, Task<byte[]>> handle, DispatcherQueue queue)
    {
        if (_serving is not null || WindowsIdentity.GetCurrent().User?.Value is not { } sid) return;
        var serving = _serving = new CancellationTokenSource();
        var name = BrowserRegistration.PipeName(sid);
        _ = Task.Run(() => Serve(name, handle, queue, serving.Token));
    }

    public static void Stop()
    {
        _serving?.Cancel();
        _serving = null;
    }

    private static async Task Serve(string name, Func<BrowserHostRequest, Task<byte[]>> handle, DispatcherQueue queue, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            NamedPipeServerStream pipe;
            try
            {
                pipe = new NamedPipeServerStream(name, PipeDirection.InOut, 4, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // Every instance busy, or the name taken by someone else: try again shortly.
                App.Log($"Browser pipe unavailable: {e.Message}");
                try { await Task.Delay(TimeSpan.FromSeconds(2), token); }
                catch (OperationCanceledException) { return; }
                continue;
            }
            try
            {
                await pipe.WaitForConnectionAsync(token);
            }
            catch (Exception e) when (e is OperationCanceledException or IOException)
            {
                await pipe.DisposeAsync();
                if (token.IsCancellationRequested) return;
                continue;
            }
            _ = Task.Run(() => Answer(pipe, handle, queue, token));
        }
    }

    private static async Task Answer(NamedPipeServerStream pipe, Func<BrowserHostRequest, Task<byte[]>> handle, DispatcherQueue queue, CancellationToken token)
    {
        await using var _ = pipe;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        // A link waits up to 8 seconds for the device's answer.
        deadline.CancelAfter(TimeSpan.FromSeconds(12));
        byte[] reply;
        try
        {
            var line = await ReadLine(pipe, BrowserHostRequest.MaxBytes, deadline.Token);
            if (line is null || BrowserHostRequest.Parse(line) is not { } request)
            {
                reply = BrowserHostReply.Error("bad_request");
            }
            else
            {
                var answer = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
                if (!queue.TryEnqueue(async () =>
                {
                    try { answer.TrySetResult(await handle(request)); }
                    catch (Exception e) { App.Log($"Browser request failed: {e.Message}"); answer.TrySetResult(BrowserHostReply.Error("failed")); }
                }))
                {
                    answer.TrySetResult(BrowserHostReply.Error("failed"));
                }
                reply = await answer.Task.WaitAsync(deadline.Token);
            }
        }
        catch (OperationCanceledException)
        {
            reply = BrowserHostReply.Error("no_answer");
        }
        catch (IOException)
        {
            return;
        }
        try
        {
            await pipe.WriteAsync(reply, token);
            await pipe.FlushAsync(token);
        }
        catch (Exception e) when (e is IOException or OperationCanceledException)
        {
        }
    }

    /// <summary>One line without its newline, at most <paramref name="limit"/> bytes; null when it is longer or the pipe closes.</summary>
    private static async Task<byte[]?> ReadLine(Stream stream, int limit, CancellationToken token)
    {
        var line = new MemoryStream();
        var buffer = new byte[1024];
        while (true)
        {
            var count = await stream.ReadAsync(buffer, token);
            if (count == 0) return null;
            var end = Array.IndexOf(buffer, (byte)'\n', 0, count);
            line.Write(buffer, 0, end < 0 ? count : end);
            if (line.Length > limit) return null;
            if (end >= 0) return line.ToArray();
        }
    }
}
