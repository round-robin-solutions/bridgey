using Bridgey.Platform;
using Bridgey.ViewModels;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;

namespace Bridgey.Views;

/// <summary>
/// The phone's text messages: conversations on the left (unread first), the open one on the right with its pictures,
/// and a composer. Enter sends; Shift+Enter starts a new line; Ctrl+N starts a new message.
/// </summary>
public sealed partial class MessagesPage : UserControl
{
    public MessagesViewModel Messages => App.Model.Messages;

    public MessagesPage()
    {
        InitializeComponent();
        Motion.ShowHide(NoticeBar);
        Messages.PropertyChanged += (_, e) =>
        {
            // The conversation opening or closing fades and rises in.
            if (e.PropertyName is nameof(MessagesViewModel.Selected) or nameof(MessagesViewModel.Composing)) Motion.Enter(ThreadPanel, rise: 8, milliseconds: 180);
            if (e.PropertyName == nameof(MessagesViewModel.Composing) && Messages.Composing) ToBox.Focus(FocusState.Programmatic);
        };
        Messages.Messages.CollectionChanged += (_, _) => ScrollToNewest();
        Loaded += (_, _) =>
        {
            Messages.Refresh();
            ScrollToNewest();
        };
    }

    /// <summary>Opens the newest message when the conversation changes or a message arrives.</summary>
    private void ScrollToNewest()
    {
        if (Messages.Messages.Count == 0) return;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (Messages.Messages.Count > 0) MessageList.ScrollIntoView(Messages.Messages[^1], ScrollIntoViewAlignment.Leading);
        });
    }

    public static HorizontalAlignment Side(bool incoming) => incoming ? HorizontalAlignment.Left : HorizontalAlignment.Right;

    public static Windows.UI.Text.FontWeight Weight(bool unread) => unread ? FontWeights.SemiBold : FontWeights.Normal;

    public static Visibility Not(bool value) => value ? Visibility.Collapsed : Visibility.Visible;

    public static Visibility Both(bool sims, bool group) => sims && !group ? Visibility.Visible : Visibility.Collapsed;

    public static Visibility Any(string? text) => string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;

    /// <summary>A picture from the phone (JPEG or PNG, at most 28 KiB), decoded by Windows in memory.</summary>
    public static ImageSource? Picture(byte[]? bytes)
    {
        if (bytes is null) return null;
        var image = new BitmapImage();
        _ = Load(image, bytes);
        return image;
    }

    private static async Task Load(BitmapImage image, byte[] bytes)
    {
        try
        {
            using var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream))
            {
                writer.WriteBytes(bytes);
                await writer.StoreAsync();
                writer.DetachStream();
            }
            stream.Seek(0);
            await image.SetSourceAsync(stream);
        }
        catch (Exception e)
        {
            App.Log($"Picture failed: {e.Message}");
        }
    }

    private void OnFilterChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args) =>
        Messages.FilterIndex = sender.Items.IndexOf(sender.SelectedItem);

    private void OnNewMessage(object sender, RoutedEventArgs e) => Messages.NewMessage();

    private void OnSend(object sender, RoutedEventArgs e)
    {
        Messages.Send();
        DraftBox.Focus(FocusState.Programmatic);
    }

    private void OnDraftKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != Windows.System.VirtualKey.Enter) return;
        var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        if (shift) return;
        e.Handled = true;
        Messages.Send();
    }

    private void OnContactClicked(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ContactItem contact) contact.Pick();
        DraftBox.Focus(FocusState.Programmatic);
    }

    private void OnOlderConversations(object sender, RoutedEventArgs e) => Messages.LoadOlder();

    private void OnOlderMessages(object sender, RoutedEventArgs e) => Messages.LoadOlderMessages();

    private void OnNoticeClosed(InfoBar sender, object args) => Messages.DismissNotice();

    private void OnOpenSettings(object sender, RoutedEventArgs e) => App.Instance.Window?.OpenSettings("messages");
}
