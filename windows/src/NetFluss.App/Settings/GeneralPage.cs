// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using NetFluss.Core;
using NetFluss.Native;

namespace NetFluss.App.Settings;

/// <summary>
/// General — the macOS General pane: system access (Location, the helper), language,
/// units, start with Windows, refresh interval and update checks.
/// </summary>
internal static class GeneralPage
{
    internal static FrameworkElement Build(PreferencesContext context, Window owner)
    {
        var settings = context.Settings;
        var page = new StackPanel();

        page.Children.Add(Kit.Header(Kit.L("System access")));
        page.Children.Add(LocationCard());
        page.Children.Add(HelperCard(context));

        page.Children.Add(Kit.Header(Kit.L("Language")));
        page.Children.Add(Kit.Card(
            Kit.L("Language"),
            Kit.L("System Default follows the language selected in Windows."),
            Kit.Combo(settings, nameof(AppSettings.Language),
            [
                new Choice(AppLanguage.System, Localization.DisplayName(AppLanguage.System)),
                new Choice(AppLanguage.English, "English"),
                new Choice(AppLanguage.German, "Deutsch"),
                new Choice(AppLanguage.SimplifiedChinese, "简体中文"),
                new Choice(AppLanguage.TraditionalChinese, "繁體中文"),
            ])));

        page.Children.Add(Kit.Header(Kit.L("Units")));
        page.Children.Add(Kit.Card(
            Kit.L("Display rates in bits per second"),
            Kit.L("Bytes per second, or bits as ISPs quote them."),
            Kit.Switch(settings, nameof(AppSettings.UseBits))));

        page.Children.Add(Kit.Header(Kit.L("Launch")));
        CheckBox? launch = null;
        launch = Kit.Switch(LaunchAtLogin.IsEnabled(), on =>
        {
            // Windows owns this one, not the settings file: the Run key is what actually
            // starts the app, and the user can remove it from Task Manager behind our back.
            // So write it, then show what the registry now says.
            LaunchAtLogin.Set(on);
            launch!.IsChecked = LaunchAtLogin.IsEnabled();
        });
        page.Children.Add(Kit.Card(Kit.L("Start with Windows"), Kit.L("Adds NetFluss to your sign-in apps, where Task Manager can also turn it off."), launch));

        page.Children.Add(Kit.Header(Kit.L("Refresh")));
        page.Children.Add(Kit.Card(
            Kit.L("Refresh interval"),
            Kit.L("Longer intervals use less battery on an idle machine."),
            Kit.Combo(settings, nameof(AppSettings.RefreshIntervalSeconds),
            [
                new Choice(0.5, "0.5 s"),
                new Choice(1.0, "1 s"),
                new Choice(2.0, "2 s"),
                new Choice(3.0, "3 s"),
                new Choice(5.0, "5 s"),
            ], 120)));

        page.Children.Add(Kit.Header(Kit.L("Update")));
        var check = Kit.Button(Kit.L("Check for Updates"), context.Commands.ShowAbout);
        check.Margin = new Thickness(0, 0, 12, 0);
        page.Children.Add(Kit.Card(
            Kit.L("Check for updates automatically"),
            Kit.L("Once a day, NetFluss looks for a new Windows release on GitHub and tells you once when one is available. You can also check any time in About."),
            Kit.Row(check, Kit.Switch(settings, nameof(AppSettings.AutomaticUpdateChecks)))));

        // The installer asks about the same two things; SignPath Foundation's privacy rules
        // want every lookup the user did not ask for to be described and to be switchable off.
        page.Children.Add(Kit.Header(Kit.L("Privacy")));
        var policy = Kit.Button(Kit.L("Privacy Policy"), () => Open(PrivacyPolicyUrl));
        policy.Margin = new Thickness(0, 0, 12, 0);
        page.Children.Add(Kit.Card(
            Kit.L("Look up public IP addresses and countries"),
            Kit.L("Shows your public address and its country (api.ipify.org, ipwho.is) and the countries of the servers in Network Slice (api.country.is). These services see the addresses asked about. When off, they stay empty."),
            Kit.Row(policy, Kit.Switch(settings, nameof(AppSettings.AllowIpLookups)))));

        var footer = Kit.Caption(Kit.L("Settings are stored in {0}", SettingsStore.DefaultPath));
        footer.Margin = new Thickness(2, 18, 0, 0);
        page.Children.Add(footer);

        _ = owner;
        return page;
    }

    /// <summary>
    /// Windows 11 24H2 put Wi-Fi scan results behind the Location permission — the same gate
    /// macOS puts on CoreWLAN — so the Wi-Fi switcher cannot list networks without it.
    /// </summary>
    private static Border LocationCard()
    {
        var status = Kit.Caption(string.Empty);
        var button = Kit.Button(Kit.L("Open Location Settings…"), () => Open("ms-settings:privacy-location"));

        void Refresh()
        {
            using var client = WlanClient.TryOpen();
            var radio = client?.Interfaces().FirstOrDefault();
            if (client is null || radio is null)
            {
                status.Text = Kit.L("No Wi-Fi adapter found.");
                button.Visibility = Visibility.Collapsed;
                return;
            }

            var access = client.AvailableNetworks(radio.Id).Access;
            status.Text = access == WlanAccess.LocationDenied
                ? Kit.L("Denied — open Settings to allow NetFluss under “Let desktop apps access your location”.")
                : Kit.L("Granted");
            status.SetResourceReference(TextBlock.ForegroundProperty, access == WlanAccess.LocationDenied ? "WarningBrush" : "ActiveBrush");
        }

        Refresh();
        var text = new StackPanel();
        text.Children.Add(Kit.Text(Kit.L("Location access")));
        text.Children.Add(Kit.Caption(Kit.L("Required to list nearby Wi-Fi networks. Windows uses the same gate for its own Wi-Fi menu.")));
        text.Children.Add(status);

        return Kit.Card(text, button);
    }

    /// <summary>
    /// The optional helper service: what it is for, whether it is there, and one button to
    /// install, update or remove it — the macOS "Install Privileged Helper…" row.
    /// </summary>
    private static Border HelperCard(PreferencesContext context)
    {
        var status = Kit.Caption(string.Empty);
        var install = Kit.Button(string.Empty, () => { });
        var remove = Kit.Button(Kit.L("Remove"), () => { });
        remove.Margin = new Thickness(8, 0, 0, 0);
        var busy = false;

        void Refresh()
        {
            var helper = context.Helper;
            if (busy)
            {
                status.Text = Kit.L("Installing…");
                install.IsEnabled = remove.IsEnabled = false;
                return;
            }

            install.IsEnabled = remove.IsEnabled = true;
            if (!helper.IsConnected)
            {
                status.Text = Kit.L("Not installed. DNS changes and Ethernet resets ask for administrator approval each time, and Top Apps is unavailable.");
                status.SetResourceReference(TextBlock.ForegroundProperty, "SecondaryTextBrush");
                install.Content = Kit.L("Install Privileged Helper…");
                remove.Visibility = Visibility.Collapsed;
            }
            else if (!helper.SupportsVpn)
            {
                // Still serving traffic, but too old for the VPN client.
                status.Text = Kit.L("Installed, version {0} — an update adds the VPN client's OpenVPN and WireGuard support.", helper.HelperVersion ?? "?");
                status.SetResourceReference(TextBlock.ForegroundProperty, "WarningBrush");
                install.Content = Kit.L("Update helper…");
                remove.Visibility = Visibility.Visible;
            }
            else if (!helper.IsCurrentVersion && helper.IsNewerThanApp)
            {
                // Reinstalling installs this version's helper — the right fix only if this copy
                // is the one meant to run, so updating NetFluss is offered first.
                status.Text = Kit.L("Installed, version {0} — newer than this NetFluss ({1}). Update NetFluss, or reinstall the helper from this version.", helper.HelperVersion ?? "?", HelperClient.AppVersion);
                status.SetResourceReference(TextBlock.ForegroundProperty, "WarningBrush");
                install.Content = Kit.L("Reinstall helper…");
                remove.Visibility = Visibility.Visible;
            }
            else if (!helper.IsCurrentVersion)
            {
                status.Text = Kit.L("Installed, version {0} — out of date.", helper.HelperVersion ?? "?");
                status.SetResourceReference(TextBlock.ForegroundProperty, "WarningBrush");
                install.Content = Kit.L("Update helper…");
                remove.Visibility = Visibility.Visible;
            }
            else
            {
                status.Text = Kit.L("Installed and running, version {0}.", helper.HelperVersion ?? "?");
                status.SetResourceReference(TextBlock.ForegroundProperty, "ActiveBrush");
                install.Content = Kit.L("Reinstall…");
                remove.Visibility = Visibility.Visible;
            }
        }

        async void Run(Func<Task<string?>> action)
        {
            busy = true;
            Refresh();
            var error = await action();
            if (error is null)
            {
                await context.Helper.ProbeAsync(TimeSpan.FromSeconds(8));
            }

            busy = false;
            Refresh();
            if (error is not null)
            {
                status.Text = error;
                status.SetResourceReference(TextBlock.ForegroundProperty, "WarningBrush");
            }
        }

        install.Click += (_, _) => Run(HelperSetup.InstallAsync);
        remove.Click += (_, _) => Run(HelperSetup.UninstallAsync);

        var text = new StackPanel();
        text.Children.Add(Kit.Text(Kit.L("NetFluss helper")));
        text.Children.Add(Kit.Caption(Kit.L("An optional background service that shows which apps use the network (Top Apps, Network Slice) and changes DNS without asking each time. Installing it needs administrator approval once.")));
        text.Children.Add(status);

        context.Helper.EnsureConnecting();
        Refresh();

        var card = Kit.Card(text, Kit.Row(install, remove));

        void OnConnection(object? sender, EventArgs e) => Refresh();
        card.Loaded += (_, _) => context.Helper.ConnectionChanged += OnConnection;
        card.Unloaded += (_, _) => context.Helper.ConnectionChanged -= OnConnection;
        return card;
    }

    internal const string PrivacyPolicyUrl = "https://github.com/rana-gmbh/NetFluss/blob/main/PRIVACY.md";

    private static void Open(string uri)
    {
        try
        {
            Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true });
        }
        catch (System.ComponentModel.Win32Exception)
        {
        }
    }
}
