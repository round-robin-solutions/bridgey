using Bridgey.Platform;
using Bridgey.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Bridgey.Views;

public sealed partial class PairPage : UserControl
{
    public PairingViewModel Pairing => App.Model.Pairing;

    public PairPage()
    {
        InitializeComponent();
        foreach (var panel in new UIElement[] { ChoosePanel, BusyPanel, CodePanel, DonePanel, FailedPanel }) Motion.ShowHide(panel);
    }

    private void OnPairByAddress(object sender, RoutedEventArgs e) => Pairing.PairByAddress();

    private void OnAddressKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != Windows.System.VirtualKey.Enter || !Pairing.CanPairByAddress) return;
        Pairing.PairByAddress();
        e.Handled = true;
    }

    private void OnCancel(object sender, RoutedEventArgs e) => Pairing.Cancel();

    private void OnConfirm(object sender, RoutedEventArgs e) => Pairing.Confirm();

    private void OnReject(object sender, RoutedEventArgs e) => Pairing.Reject();

    private void OnAgain(object sender, RoutedEventArgs e) => Pairing.Reset();

    private void OnHome(object sender, RoutedEventArgs e)
    {
        Pairing.Reset();
        App.Instance.Home();
    }
}
