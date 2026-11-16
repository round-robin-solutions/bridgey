using Bridgey.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Bridgey.Views;

/// <summary>First run: name this PC, choose whether Bridgey starts at sign-in, then pair.</summary>
public sealed partial class SetupPage : UserControl
{
    public SettingsViewModel Settings => App.Model.Settings;

    public SetupPage() => InitializeComponent();

    private void OnContinue(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrWhiteSpace(NameBox.Text)) Settings.DeviceName = NameBox.Text;
        App.Instance.FinishSetup();
    }
}
