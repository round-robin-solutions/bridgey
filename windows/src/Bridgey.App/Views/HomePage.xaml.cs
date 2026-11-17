using Bridgey.Platform;
using Bridgey.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace Bridgey.Views;

public sealed partial class HomePage : UserControl
{
    public MainViewModel Model => App.Model;

    public HomePage()
    {
        InitializeComponent();
        Motion.ShowHide(RequestBar);
        Motion.ShowHide(NoticeBar);
        Motion.ShowHide(RingingBar);
        Motion.ShowHide(DropOverlay);
        // Compiled bindings fill the list when the page loads; select the target then.
        Loaded += (_, _) => TargetBox.SelectedItem = Model.Target;
        Model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(MainViewModel.Target) && !ReferenceEquals(TargetBox.SelectedItem, Model.Target)) TargetBox.SelectedItem = Model.Target;
        };
    }

    private void OnTargetChanged(object sender, SelectionChangedEventArgs e)
    {
        if (TargetBox.SelectedItem is DeviceItem device) Model.Target = device;
    }

    private void OnSend(object sender, RoutedEventArgs e) => Model.SendDraft();

    private void OnDraftKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter && Model.CanSendDraft)
        {
            Model.SendDraft();
            e.Handled = true;
        }
    }

    private void OnPair(object sender, RoutedEventArgs e) => App.Instance.Pair();

    private void OnAllowRequest(object sender, RoutedEventArgs e) => Model.AllowPairingRequest();

    private void OnRequestClosed(InfoBar sender, object args) => Model.DismissPairingRequest();

    private void OnNoticeClosed(InfoBar sender, object args) => Model.DismissNotice();

    private void OnStopRinging(object sender, RoutedEventArgs e) => Model.StopRinging();

    // Files dropped on the page go to the send bar's device; dropped on a device card, to that device.

    private static bool HasFiles(DragEventArgs e) => e.DataView.Contains(StandardDataFormats.StorageItems);

    private void Accept(DragEventArgs e, DeviceItem? device)
    {
        if (!HasFiles(e) || device is not { FilesReady: true })
        {
            e.AcceptedOperation = DataPackageOperation.None;
            return;
        }
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.Caption = $"Send to {device.Name}";
        e.DragUIOverride.IsGlyphVisible = false;
        DropText.Text = $"Drop to send to {device.Name}";
        DropOverlay.Visibility = Visibility.Visible;
    }

    private void OnDragOver(object sender, DragEventArgs e) => Accept(e, Model.Target);

    private void OnDeviceDragOver(object sender, DragEventArgs e)
    {
        Accept(e, (sender as FrameworkElement)?.Tag as DeviceItem);
        e.Handled = true;
    }

    private void OnDragLeave(object sender, DragEventArgs e) => DropOverlay.Visibility = Visibility.Collapsed;

    private async void OnDrop(object sender, DragEventArgs e) => await Send(e, Model.Target);

    private async void OnDeviceDrop(object sender, DragEventArgs e)
    {
        e.Handled = true;
        await Send(e, (sender as FrameworkElement)?.Tag as DeviceItem);
    }

    private async Task Send(DragEventArgs e, DeviceItem? device)
    {
        DropOverlay.Visibility = Visibility.Collapsed;
        if (device is null || !HasFiles(e)) return;
        var deferral = e.GetDeferral();
        try
        {
            var items = await e.DataView.GetStorageItemsAsync();
            var files = items.OfType<StorageFile>().Select(f => f.Path).Where(p => !string.IsNullOrEmpty(p)).ToList();
            if (items.OfType<StorageFolder>().Any()) Model.SendFiles(device, items.OfType<StorageFolder>().Select(f => f.Path));
            if (files.Count > 0) Model.SendFiles(device, files);
        }
        catch (Exception ex)
        {
            App.Log($"Drop failed: {ex.Message}");
        }
        finally
        {
            deferral.Complete();
        }
    }
}
