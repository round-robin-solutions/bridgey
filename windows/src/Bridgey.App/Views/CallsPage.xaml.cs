using System.Diagnostics;
using Bridgey.Platform;
using Bridgey.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Bridgey.Views;

/// <summary>
/// The Calls window: a field and keypad on the left, recent calls or what was typed on the right. Enter calls the typed
/// number or the chosen row; Esc clears. The phone places each call, so its audio stays there.
/// </summary>
public sealed partial class CallsPage : UserControl
{
    public CallsViewModel Calls => App.Model.Calls;

    public CallsPage()
    {
        InitializeComponent();
        Motion.ShowHide(NoticeBar);
        Motion.ShowHide(SimBar);
        Loaded += (_, _) => QueryBox.Focus(FocusState.Programmatic);
    }

    public static InfoBarSeverity Severity(bool good) => good ? InfoBarSeverity.Success : InfoBarSeverity.Warning;

    public static double FieldSize(bool number) => number ? 20 : 15;

    public static Visibility Not(bool value) => value ? Visibility.Collapsed : Visibility.Visible;

    private void OnKey(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string key }) Calls.Press(key);
    }

    private void OnBackspace(object sender, RoutedEventArgs e) => Calls.Backspace();

    private void OnCall(object sender, RoutedEventArgs e) => Calls.CallPrimary();

    private void OnQueryKeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case Windows.System.VirtualKey.Enter:
                Calls.CallPrimary();
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.Escape:
                if (Calls.IsAskingSim) Calls.CancelSim();
                else Calls.Clear();
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.Down when Calls.Rows.Count > 0:
                // Down from the field moves into the list, as on the Mac.
                Calls.SelectedRow = Calls.Rows[0];
                RowList.Focus(FocusState.Keyboard);
                e.Handled = true;
                break;
        }
    }

    private void OnRowKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != Windows.System.VirtualKey.Enter || Calls.SelectedRow is not { } row) return;
        row.Call();
        e.Handled = true;
    }

    private void OnRowDoubleTapped(object sender, DoubleTappedRoutedEventArgs e) => Calls.SelectedRow?.Call();

    private void OnSimChosen(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: SimChoice sim }) Calls.CallWithSim(sim);
    }

    private void OnSimCancelled(InfoBar sender, object args) => Calls.CancelSim();

    private void OnNoticeClosed(InfoBar sender, object args) => Calls.DismissNotice();

    private void OnOpenSettings(object sender, RoutedEventArgs e) => App.Instance.Window?.OpenSettings("calls");

    private void OnCopyNumber(object sender, RoutedEventArgs e)
    {
        if (sender is not MenuFlyoutItem { Tag: string number }) return;
        var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
        package.SetText(number);
        Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
    }

    /// <summary>WhatsApp Desktop's chat for the number (whatsapp://send?phone=), when WhatsApp is on this PC.</summary>
    private void OnWhatsAppHere(object sender, RoutedEventArgs e)
    {
        if (sender is not MenuFlyoutItem { Tag: string number } || CallsViewModel.NormalisedNumber(number) is not { } normalised) return;
        try
        {
            Process.Start(new ProcessStartInfo($"whatsapp://send?phone={normalised.TrimStart('+')}") { UseShellExecute = true });
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            App.Log($"WhatsApp on this PC failed: {ex.Message}");
            Calls.ShowProblem("WhatsApp isn't on this PC.");
        }
    }
}
