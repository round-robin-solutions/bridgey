using Bridgey.Platform;
using Bridgey.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Bridgey.Views;

/// <summary>The phone's notifications: still on the phone (with its buttons, a reply box and Dismiss), then history.</summary>
public sealed partial class NotificationsPage : UserControl
{
    public NotificationsViewModel Notifications => App.Model.Notifications;
    public SettingsViewModel Settings => App.Model.Settings;

    public NotificationsPage()
    {
        InitializeComponent();
        Motion.ShowHide(NoticeBar);
    }

    private void OnClearHistory(object sender, RoutedEventArgs e) => Notifications.ClearHistory();

    private void OnNoticeClosed(InfoBar sender, object args) => Notifications.DismissNotice();
}
