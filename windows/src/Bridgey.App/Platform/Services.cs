using System.Numerics;
using System.Security.Cryptography;
using Bridgey.ViewModels;
using Microsoft.UI.Composition;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.Win32;
using Windows.ApplicationModel.DataTransfer;
using Windows.UI.ViewManagement;

namespace Bridgey.Platform;

/// <summary>The identity and trusted devices, encrypted with DPAPI for this Windows user, one file per value.</summary>
internal sealed class ProtectedStore(string folder) : ISecretStore
{
    private static readonly byte[] Entropy = "bridgey-rr-windows-v1"u8.ToArray();

    private string PathOf(string key)
    {
        if (key.Length == 0 || !key.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_')) throw new ArgumentException("bad key");
        return Path.Combine(folder, key + ".dat");
    }

    public byte[]? Load(string key)
    {
        var path = PathOf(key);
        return File.Exists(path) ? ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy, DataProtectionScope.CurrentUser) : null;
    }

    public void Store(string key, byte[] value)
    {
        Directory.CreateDirectory(folder);
        var path = PathOf(key);
        File.WriteAllBytes(path + ".tmp", ProtectedData.Protect(value, Entropy, DataProtectionScope.CurrentUser));
        File.Move(path + ".tmp", path, overwrite: true);
    }

    public void Remove(string key) => File.Delete(PathOf(key));
}

internal sealed class UiDispatcher(DispatcherQueue queue) : IUiDispatcher
{
    public void Post(Action action) => queue.TryEnqueue(() => action());
}

internal sealed class Alerts : IAlertService
{
    public void Ping(string deviceName) => Win32.MessageBeep(Win32.MB_ICONASTERISK);
}

/// <summary>The Windows clipboard. Text other apps mark as private (password managers) is never sent automatically.</summary>
internal sealed class WindowsClipboard : IClipboardService
{
    public void SetText(string text)
    {
        try
        {
            var package = new DataPackage();
            package.SetText(text);
            Clipboard.SetContent(package);
            Clipboard.Flush();
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or UnauthorizedAccessException)
        {
            // Another app holds the clipboard; the text is still in the activity list.
        }
    }

    public async Task<(string? Text, bool Private)> ReadAsync()
    {
        try
        {
            var view = Clipboard.GetContent();
            var isPrivate = view.Contains("ExcludeClipboardContentFromMonitorProcessing") || view.Contains("CanIncludeInClipboardHistory") || view.Contains("CanUploadToCloudClipboard");
            var text = view.Contains(StandardDataFormats.Text) ? await view.GetTextAsync() : null;
            return (text, isPrivate);
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or UnauthorizedAccessException)
        {
            return (null, false);
        }
    }

    public void Watch(Action changed) => Clipboard.ContentChanged += (_, _) => changed();
}

/// <summary>Starting Bridgey when this Windows user signs in (HKCU Run), in the notification area only.</summary>
internal static class SignIn
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static void Apply(bool on)
    {
        // A separate profile (tests) never touches the user's sign-in items.
        if (Paths.IsSeparateProfile || Environment.ProcessPath is not { } exe) return;
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
            if (on) key.SetValue(Edition.DisplayName, $"\"{exe}\" --background");
            else key.DeleteValue(Edition.DisplayName, throwOnMissingValue: false);
        }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException or System.Security.SecurityException)
        {
        }
    }
}

/// <summary>
/// Motion on transform and opacity only, skipped when Windows' "Animation effects" is off or Settings > General >
/// Reduce motion is on.
/// </summary>
internal static class Motion
{
    private static readonly UISettings WindowsSettings = new();

    public static bool Enabled => WindowsSettings.AnimationsEnabled && !(App.Model?.Settings.ReduceMotion ?? false);

    private static CompositionEasingFunction Ease(Compositor c) => c.CreateCubicBezierEasingFunction(new Vector2(0.2f, 0.9f), new Vector2(0.25f, 1f));

    /// <summary>Opacity 0 to 1 and a short rise, for windows, pages and panels as they open.</summary>
    public static void Enter(UIElement element, float rise = 12f, int milliseconds = 220)
    {
        var visual = ElementCompositionPreview.GetElementVisual(element);
        ElementCompositionPreview.SetIsTranslationEnabled(element, true);
        visual.StopAnimation("Opacity");
        visual.StopAnimation("Translation");
        if (!Enabled)
        {
            visual.Opacity = 1;
            visual.Properties.InsertVector3("Translation", Vector3.Zero);
            return;
        }
        var c = visual.Compositor;
        var opacity = c.CreateScalarKeyFrameAnimation();
        opacity.InsertKeyFrame(0f, 0f);
        opacity.InsertKeyFrame(1f, 1f, Ease(c));
        opacity.Duration = TimeSpan.FromMilliseconds(milliseconds);
        var move = c.CreateVector3KeyFrameAnimation();
        move.InsertKeyFrame(0f, new Vector3(0, rise, 0));
        move.InsertKeyFrame(1f, Vector3.Zero, Ease(c));
        move.Duration = TimeSpan.FromMilliseconds(milliseconds);
        visual.StartAnimation("Opacity", opacity);
        visual.StartAnimation("Translation", move);
    }

    /// <summary>Fades out and sinks a little, then runs <paramref name="done"/> (hiding the window).</summary>
    public static void Leave(UIElement element, Action done, int milliseconds = 140)
    {
        if (!Enabled)
        {
            done();
            return;
        }
        var visual = ElementCompositionPreview.GetElementVisual(element);
        ElementCompositionPreview.SetIsTranslationEnabled(element, true);
        var c = visual.Compositor;
        var batch = c.CreateScopedBatch(CompositionBatchTypes.Animation);
        var opacity = c.CreateScalarKeyFrameAnimation();
        opacity.InsertKeyFrame(1f, 0f);
        opacity.Duration = TimeSpan.FromMilliseconds(milliseconds);
        var move = c.CreateVector3KeyFrameAnimation();
        move.InsertKeyFrame(1f, new Vector3(0, 6, 0));
        move.Duration = TimeSpan.FromMilliseconds(milliseconds);
        visual.StartAnimation("Opacity", opacity);
        visual.StartAnimation("Translation", move);
        batch.End();
        batch.Completed += (_, _) => done();
    }

    /// <summary>Panels that appear and disappear (the code, banners) fade and rise as their visibility changes.</summary>
    public static void ShowHide(UIElement element)
    {
        if (!Enabled)
        {
            ElementCompositionPreview.SetImplicitShowAnimation(element, null);
            ElementCompositionPreview.SetImplicitHideAnimation(element, null);
            return;
        }
        ElementCompositionPreview.SetIsTranslationEnabled(element, true);
        var c = ElementCompositionPreview.GetElementVisual(element).Compositor;
        var show = c.CreateAnimationGroup();
        var fadeIn = c.CreateScalarKeyFrameAnimation();
        fadeIn.Target = "Opacity";
        fadeIn.InsertKeyFrame(0f, 0f);
        fadeIn.InsertKeyFrame(1f, 1f, Ease(c));
        fadeIn.Duration = TimeSpan.FromMilliseconds(200);
        var rise = c.CreateVector3KeyFrameAnimation();
        rise.Target = "Translation";
        rise.InsertKeyFrame(0f, new Vector3(0, 8, 0));
        rise.InsertKeyFrame(1f, Vector3.Zero, Ease(c));
        rise.Duration = TimeSpan.FromMilliseconds(200);
        show.Add(fadeIn);
        show.Add(rise);
        var fadeOut = c.CreateScalarKeyFrameAnimation();
        fadeOut.Target = "Opacity";
        fadeOut.InsertKeyFrame(1f, 0f);
        fadeOut.Duration = TimeSpan.FromMilliseconds(120);
        ElementCompositionPreview.SetImplicitShowAnimation(element, show);
        ElementCompositionPreview.SetImplicitHideAnimation(element, fadeOut);
    }
}
