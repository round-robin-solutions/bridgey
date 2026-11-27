using Bridgey.Platform;
using Bridgey.ViewModels;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Media.Core;
using Windows.Media.MediaProperties;
using Windows.Media.Playback;
using Windows.Security.Cryptography;
using Windows.System;

namespace Bridgey.Views;

/// <summary>
/// One phone's screen: the picture letterboxed, decoded by Windows' own H.264 decoder from frames pulled out of
/// bridgey_core (never through the event queue), what the phone is doing in plain words, and control. While
/// controlling, presses, drags and the wheel go to the phone as fractions of its screen; keys and typing go when the
/// phone takes them (Android 13 and later).
/// </summary>
public sealed partial class PhoneScreenView : UserControl
{
    public PhoneScreenItem Item { get; }

    private MediaPlayer? _player;
    private MediaStreamSource? _source;
    private ulong _playing;
    private long _firstCapture = -1;
    private byte[] _buffer = new byte[512 * 1024];
    private readonly CancellationTokenSource _closing = new();
    /// <summary>The first half of a character outside the Basic Multilingual Plane (an emoji), until its second half.</summary>
    private char? _high;

    public PhoneScreenView(PhoneScreenItem item)
    {
        Item = item;
        InitializeComponent();
        Motion.ShowHide(StatusPanel);
        Motion.ShowHide(SlowerPill);
        Motion.ShowHide(NavigationBar);
        Item.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(PhoneScreenItem.Stream)) DispatcherQueue.TryEnqueue(Play);
            if (e.PropertyName == nameof(PhoneScreenItem.IsControlling) && Item.IsControlling) InputLayer.Focus(FocusState.Programmatic);
        };
        Loaded += (_, _) =>
        {
            Motion.Enter(Root, rise: 10, milliseconds: 220);
            Play();
        };
    }

    public UIElement TitleBarElement => TitleBar;

    /// <summary>The edition's window colour where Windows has no Mica.</summary>
    public void ShowBackdropFallback() => BackdropFallback.Visibility = Visibility.Visible;

    public static Visibility Both(bool a, bool b) => a && b ? Visibility.Visible : Visibility.Collapsed;

    public static Visibility Either(bool a, bool b) => a || b ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>The window closed: frames stop and the stream ends.</summary>
    public void Shutdown()
    {
        _closing.Cancel();
        Item.LiftAll();
        StopPlayer();
    }

    // MARK: The picture

    /// <summary>A new stream: a live H.264 source Windows decodes, fed from the frame pump.</summary>
    private void Play()
    {
        if (Item.Stream == 0 || Item.Stream == _playing || _closing.IsCancellationRequested) return;
        StopPlayer();
        _playing = Item.Stream;
        _firstCapture = -1;
        var properties = VideoEncodingProperties.CreateH264();
        properties.Width = (uint)Math.Max(16, Item.Width);
        properties.Height = (uint)Math.Max(16, Item.Height);
        var source = new MediaStreamSource(new VideoStreamDescriptor(properties)) { IsLive = true, CanSeek = false, BufferTime = TimeSpan.Zero };
        var stream = _playing;
        source.Starting += (_, args) => args.Request.SetActualStartPosition(TimeSpan.Zero);
        source.SampleRequested += (_, args) => Sample(stream, args);
        var player = new MediaPlayer { RealTimePlayback = true, AutoPlay = true, IsMuted = true };
        player.MediaFailed += (_, args) =>
        {
            App.Log($"Phone screen decoder failed: {args.Error} {args.ExtendedErrorCode?.HResult:x8}");
            Item.DecoderFailed();
        };
        player.Source = MediaSource.CreateFromMediaStreamSource(source);
        _source = source;
        _player = player;
        Player.SetMediaPlayer(player);
        player.Play();
    }

    private void StopPlayer()
    {
        _playing = 0;
        Player.SetMediaPlayer(null);
        _player?.Dispose();
        _player = null;
        _source = null;
    }

    /// <summary>Windows asks for the next frame: waits for one from the phone (off the UI thread), or ends the stream.</summary>
    private void Sample(ulong stream, MediaStreamSourceSampleRequestedEventArgs args)
    {
        var request = args.Request;
        var deferral = request.GetDeferral();
        _ = Task.Run(() =>
        {
            try
            {
                while (!_closing.IsCancellationRequested && stream == _playing)
                {
                    var rc = Item.TakeFrame(_buffer, 250, out var length, out var capture, out var flags);
                    if (rc == BridgeyException.TooLarge && length <= 8 * 1024 * 1024)
                    {
                        _buffer = new byte[length];
                        continue;
                    }
                    if (rc < 0) break;
                    if (rc == 0) continue;
                    if (_firstCapture < 0) _firstCapture = capture;
                    var sample = MediaStreamSample.CreateFromBuffer(CryptographicBuffer.CreateFromByteArray(_buffer.AsSpan(0, length).ToArray()),
                        TimeSpan.FromTicks(Math.Max(0, capture - _firstCapture) * 10));
                    sample.KeyFrame = (flags & 1) != 0;
                    request.Sample = sample;
                    return;
                }
                // The stream ended or the window closed: no sample ends playback.
                request.Sample = null;
            }
            catch (Exception e)
            {
                App.Log($"Phone screen frame failed: {e.Message}");
            }
            finally
            {
                deferral.Complete();
            }
        });
    }

    // MARK: Control

    private void OnControl(object sender, RoutedEventArgs e) => Item.BeginControl();

    private void OnStopControl(object sender, RoutedEventArgs e)
    {
        Item.LiftAll();
        Item.EndControl();
    }

    private void OnStop(object sender, RoutedEventArgs e) => Item.Stop();

    private void OnBack(object sender, RoutedEventArgs e) => Item.Back();

    private void OnHome(object sender, RoutedEventArgs e) => Item.Home();

    private void OnRecents(object sender, RoutedEventArgs e) => Item.Recents();

    private void Touch(PointerRoutedEventArgs e, string phase)
    {
        if (!Item.IsControlling) return;
        var point = e.GetCurrentPoint(InputLayer);
        if (phase == "move" && !point.IsInContact) return;
        if (Item.Touch(e.Pointer.PointerId, phase, InputLayer.ActualWidth, InputLayer.ActualHeight, point.Position.X, point.Position.Y)) e.Handled = true;
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        InputLayer.Focus(FocusState.Pointer);
        if (!Item.IsControlling) return;
        // A right click is Back, as on a phone's mouse.
        if (e.GetCurrentPoint(InputLayer).Properties.IsRightButtonPressed)
        {
            Item.Back();
            e.Handled = true;
            return;
        }
        InputLayer.CapturePointer(e.Pointer);
        Touch(e, "down");
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e) => Touch(e, "move");

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        Touch(e, "up");
        InputLayer.ReleasePointerCapture(e.Pointer);
    }

    private void OnPointerCanceled(object sender, PointerRoutedEventArgs e) => Touch(e, "up");

    /// <summary>The wheel: one notch moves the content about 80 view pixels, as the content follows the fingers.</summary>
    private void OnPointerWheel(object sender, PointerRoutedEventArgs e)
    {
        if (!Item.IsControlling) return;
        var point = e.GetCurrentPoint(InputLayer);
        var notches = point.Properties.MouseWheelDelta / 120.0;
        var (dx, dy) = point.Properties.IsHorizontalMouseWheel ? (-notches * 80, 0.0) : (0.0, notches * 80);
        if (Item.Scroll(InputLayer.ActualWidth, InputLayer.ActualHeight, point.Position.X, point.Position.Y, dx, dy)) e.Handled = true;
    }

    private static readonly Dictionary<VirtualKey, string> Keys = new()
    {
        [VirtualKey.Enter] = "enter", [VirtualKey.Tab] = "tab", [VirtualKey.Back] = "backspace", [VirtualKey.Escape] = "escape",
        [VirtualKey.Left] = "left", [VirtualKey.Right] = "right", [VirtualKey.Up] = "up", [VirtualKey.Down] = "down",
        [VirtualKey.Home] = "home", [VirtualKey.End] = "end", [VirtualKey.PageUp] = "page_up", [VirtualKey.PageDown] = "page_down",
        [VirtualKey.Delete] = "delete",
    };

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!Item.CanType || !Keys.TryGetValue(e.Key, out var key)) return;
        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        if (Item.Press(key, shift)) e.Handled = true;
    }

    /// <summary>Typed characters go as text; Control and Alt shortcuts stay on this PC.</summary>
    private void OnCharacter(UIElement sender, CharacterReceivedRoutedEventArgs e)
    {
        if (!Item.CanType || char.IsControl(e.Character)) return;
        var ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        if (ctrl) return;
        if (char.IsHighSurrogate(e.Character))
        {
            _high = e.Character;
            e.Handled = true;
            return;
        }
        var text = char.IsLowSurrogate(e.Character) ? _high is { } high ? $"{high}{e.Character}" : "" : e.Character.ToString();
        _high = null;
        if (text.Length > 0 && Item.Type(text)) e.Handled = true;
    }

    private void OnLostFocus(object sender, RoutedEventArgs e) => Item.LiftAll();
}
