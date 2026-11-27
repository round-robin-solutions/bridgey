using Bridgey.Platform;
using Bridgey.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Streams;

namespace Bridgey.Views;

/// <summary>
/// The phone's files: its photos and videos, recent documents, places and folders, with thumbnails. Double-click or
/// Enter opens a folder, Alt+Up goes back up; Download takes the selection to the received files folder (Download to…
/// asks where), Add files or a drop puts files from this PC in the folder being browsed.
/// </summary>
public sealed partial class PhoneFilesPage : UserControl
{
    public PhoneFilesViewModel Files => App.Model.PhoneFiles;

    public PhoneFilesPage()
    {
        InitializeComponent();
        Motion.ShowHide(NoticeBar);
        Motion.ShowHide(ActivityList);
        // A new folder or section fades and rises in.
        Files.Crumbs.CollectionChanged += (_, _) => Motion.Enter(FileList, rise: 8, milliseconds: 180);
        Files.ShowFolderRequested += ExplorerFiles.OpenFolder;
        Loaded += (_, _) =>
        {
            if (Files.HasPhone && !Files.HasItems && !Files.Loading) Files.Reload();
        };
    }

    /// <summary>A thumbnail from the phone (WebP or JPEG, at most 24 KiB), decoded by Windows in memory.</summary>
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
            App.Log($"Thumbnail failed: {e.Message}");
        }
    }

    private List<PhoneFileItem> Chosen() => FileList.SelectedItems.OfType<PhoneFileItem>().Where(i => i.CanDownload).ToList();

    private void OnSectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        Files.Section = sender.Items.IndexOf(sender.SelectedItem);
        Motion.Enter(FileList, rise: 8, milliseconds: 180);
    }

    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var any = Chosen().Count > 0;
        DownloadButton.IsEnabled = any;
        DownloadToButton.IsEnabled = any;
    }

    private void OnDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is PhoneFileItem item) item.Open();
    }

    private void OnListKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter && FileList.SelectedItem is PhoneFileItem { IsFolder: true } item)
        {
            item.Open();
            e.Handled = true;
        }
        else if (e.Key == Windows.System.VirtualKey.Back)
        {
            Files.Up();
            e.Handled = true;
        }
    }

    private void OnUp(object sender, RoutedEventArgs e) => Files.Up();

    private void OnCrumb(BreadcrumbBar sender, BreadcrumbBarItemClickedEventArgs args)
    {
        if (args.Item is Crumb crumb) crumb.Go();
    }

    private void OnMore(object sender, RoutedEventArgs e) => Files.LoadMore();

    private void OnDownload(object sender, RoutedEventArgs e) => Files.Download(Chosen());

    private async void OnDownloadTo(object sender, RoutedEventArgs e)
    {
        var items = Chosen();
        if (items.Count == 0 || App.Instance.Window is not { } window) return;
        if (await window.PickFolder() is { } folder) Files.Download(items, folder);
    }

    private async void OnUpload(object sender, RoutedEventArgs e)
    {
        if (App.Instance.Window is not { } window) return;
        var paths = await window.PickFiles();
        if (paths.Count > 0) Files.Upload(paths);
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        if (!Files.CanUpload || !e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.Caption = "Add to this folder";
    }

    private async void OnDrop(object sender, DragEventArgs e)
    {
        if (!Files.CanUpload || !e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        var files = items.OfType<StorageFile>().Select(f => f.Path).Where(p => !string.IsNullOrEmpty(p)).ToList();
        if (files.Count < items.Count) Files.Notice = "Folders can't be added yet. Add the files inside them.";
        if (files.Count > 0) Files.Upload(files);
    }

    private void OnNoticeClosed(InfoBar sender, object args) => Files.DismissNotice();
}
