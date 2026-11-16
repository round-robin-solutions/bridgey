using Bridgey.Platform;
using Bridgey.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Bridgey.Views;

/// <summary>Settings in the edition's sections, a list on the left and one section at a time on the right.</summary>
public sealed partial class SettingsPage : UserControl
{
    public MainViewModel Model => App.Model;
    public SettingsViewModel Settings => App.Model.Settings;
    public List<SettingsSection> Sections { get; } = new(SettingsViewModel.Sections);
    public Uri UpstreamUri => new(Settings.UpstreamUrl);
    public Uri EditionUri => new(Settings.RepositoryUrl);

    public SettingsPage()
    {
        InitializeComponent();
        // Compiled bindings fill the list when the page loads.
        Loaded += (_, _) =>
        {
            if (SectionList.SelectedIndex < 0) SectionList.SelectedIndex = 0;
        };
    }

    /// <summary>Opens one section (used by the notification area menu and tests).</summary>
    public void Show(string key)
    {
        var index = Sections.FindIndex(s => s.Key == key);
        if (index >= 0) SectionList.SelectedIndex = index;
    }

    private void OnSectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SectionList.SelectedItem is not SettingsSection section) return;
        SectionTitle.Text = section.Title;
        foreach (var child in SectionPanels())
        {
            child.Visibility = (child.Tag as string) == section.Key ? Visibility.Visible : Visibility.Collapsed;
        }
        LaterSection.Visibility = section.Available ? Visibility.Collapsed : Visibility.Visible;
        Motion.Enter(SectionPanel, rise: 8, milliseconds: 180);
    }

    private IEnumerable<FrameworkElement> SectionPanels() =>
        new FrameworkElement[] { ThisPc, DevicesSection, ClipboardSection, PrivacySection, GeneralSection, AboutSection };

    private void OnNameCommitted(object sender, RoutedEventArgs e) => Settings.DeviceName = NameBox.Text;

    private void OnNameKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != Windows.System.VirtualKey.Enter) return;
        Settings.DeviceName = NameBox.Text;
        e.Handled = true;
    }

    private void OnAllowPairing(object sender, RoutedEventArgs e) => Model.AllowPairing();
}
