using Bridgey.Platform;
using Bridgey.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Bridgey.Views;

public sealed partial class HomePage : UserControl
{
    public MainViewModel Model => App.Model;

    public HomePage()
    {
        InitializeComponent();
        Motion.ShowHide(RequestBar);
        Motion.ShowHide(NoticeBar);
        TargetBox.SelectedItem = Model.Target;
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
}
