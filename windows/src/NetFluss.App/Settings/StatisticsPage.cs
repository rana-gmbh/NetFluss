// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Windows;
using System.Windows.Controls;
using NetFluss.Core;

namespace NetFluss.App.Settings;

/// <summary>Statistics — the macOS Statistics pane, plus opening and resetting the history.</summary>
internal static class StatisticsPage
{
    internal static FrameworkElement Build(PreferencesContext context)
    {
        var settings = context.Settings;
        var page = new StackPanel();

        page.Children.Add(Kit.Header(Kit.L("Statistics")));
        page.Children.Add(Kit.Card(
            Kit.L("Collect historical statistics"),
            Kit.L("Keeps minute, hourly and daily totals per adapter on this PC, for the Statistics window and the Data Usage section. Off by default; collecting costs one subtraction per adapter per tick."),
            Kit.Switch(settings, nameof(AppSettings.CollectStatistics))));

        var usage = Kit.Card(
            Kit.L("Display usage summary on popover"),
            Kit.L("Shows today's and this month's upload, download, and total data in the popover. Requires historical statistics collection."),
            Kit.Switch(settings, nameof(AppSettings.ShowUsageSummary)));
        Kit.EnableWhen(usage, settings, nameof(AppSettings.CollectStatistics));
        page.Children.Add(usage);

        page.Children.Add(Kit.Card(
            Kit.L("Collect app statistics"),
            Kit.L("Top download and upload apps come from Windows' own data usage records — the numbers behind Settings → Network & internet → Data usage. It costs nothing to keep on, goes back to before NetFluss was installed, and is updated by Windows about once an hour."),
            Kit.Switch(settings, nameof(AppSettings.CollectAppStatistics))));

        AddProxyNodes(context, page);

        page.Children.Add(Kit.Header(Kit.L("History")));
        page.Children.Add(Kit.Card(
            Kit.L("Bandwidth Statistics"),
            Kit.L("Download and upload history by adapter and by app, from the last hour to the last year."),
            Kit.Button(Kit.L("Open…"), context.Commands.ShowStatistics)));

        // A destructive action gets a confirmation step inline rather than a modal dialog.
        var status = Kit.Caption(string.Empty);
        var confirm = Kit.Button(Kit.L("Delete history"), () => { }, accent: true);
        var cancel = Kit.Button(Kit.L("Cancel"), () => { });
        cancel.Margin = new Thickness(8, 0, 0, 0);
        var confirmRow = Kit.Row(confirm, cancel);
        confirmRow.Visibility = Visibility.Collapsed;
        var reset = Kit.Button(Kit.L("Reset Statistics…"), () => { });

        reset.Click += (_, _) =>
        {
            reset.Visibility = Visibility.Collapsed;
            confirmRow.Visibility = Visibility.Visible;
            status.Text = Kit.L("This deletes all recorded adapter history. Windows' own app records are not affected.");
        };
        cancel.Click += (_, _) =>
        {
            reset.Visibility = Visibility.Visible;
            confirmRow.Visibility = Visibility.Collapsed;
            status.Text = string.Empty;
        };
        confirm.Click += (_, _) =>
        {
            context.Statistics.Reset();
            reset.Visibility = Visibility.Visible;
            confirmRow.Visibility = Visibility.Collapsed;
            status.Text = Kit.L("Statistics were reset.");
        };

        var left = new StackPanel();
        left.Children.Add(Kit.Text(Kit.L("Reset Statistics")));
        left.Children.Add(Kit.Caption(Kit.L("Starts the adapter history over from now.")));
        left.Children.Add(status);
        page.Children.Add(Kit.Card(left, new Grid { Children = { reset, confirmRow } }));

        return page;
    }

    /// <summary>
    /// Per-proxy-node statistics from the Clash API (macOS 2.7): the switch, the controller's
    /// address and secret, and a test. The secret goes to Credential Manager, never the
    /// settings file.
    /// </summary>
    private static void AddProxyNodes(PreferencesContext context, StackPanel page)
    {
        var settings = context.Settings;

        var nodes = Kit.Card(
            Kit.L("Collect proxy node statistics"),
            Kit.L("Records how much traffic each outbound node carried, for clients that expose the Clash API — sing-box, mihomo, Clash Verge and others. Useful with a metered subscription."),
            Kit.Switch(settings, nameof(AppSettings.CollectProxyNodeStatistics)));
        Kit.EnableWhen(nodes, settings, nameof(AppSettings.CollectStatistics));
        page.Children.Add(nodes);

        // ---- Address ----
        var host = new TextBox { Width = 220, Text = settings.ClashApiHost };
        System.Windows.Automation.AutomationProperties.SetName(host, Kit.L("Controller address"));
        var placeholder = Kit.Caption(Kit.L("Host:port of the Clash API (default 127.0.0.1:9090)"));
        host.LostFocus += (_, _) => settings.ClashApiHost = host.Text;
        var hostCard = Kit.Card(Kit.L("Controller address"), placeholder.Text, host);

        // ---- Secret ----
        var secretState = Kit.Caption(string.Empty);
        var secret = new PasswordBox { Width = 220 };
        System.Windows.Automation.AutomationProperties.SetName(secret, Kit.L("Controller secret"));
        void ShowSecretState() => secretState.Text = StatisticsService.HasProxySecret ? Kit.L("Configured") : Kit.L("None");
        var save = Kit.Button(Kit.L("Save"), () =>
        {
            context.Statistics.SaveProxySecret(secret.Password);
            secret.Clear();
            ShowSecretState();
        });
        save.Margin = new Thickness(8, 0, 0, 0);
        var secretLeft = new StackPanel();
        secretLeft.Children.Add(Kit.Text(Kit.L("Controller secret")));
        secretLeft.Children.Add(secretState);
        var secretCard = Kit.Card(secretLeft, Kit.Row(secret, save));
        ShowSecretState();

        // ---- Test ----
        var testStatus = Kit.Caption(string.Empty);
        testStatus.Margin = new Thickness(10, 0, 0, 0);
        Button? test = null;
        test = Kit.Button(Kit.L("Test connection"), async () =>
        {
            settings.ClashApiHost = host.Text;
            test!.IsEnabled = false;
            testStatus.Text = string.Empty;
            var (ok, message) = await StatisticsService.TestProxyControllerAsync(settings.ClashApiHost);
            testStatus.Text = message;
            testStatus.SetResourceReference(TextBlock.ForegroundProperty, ok ? "SecondaryTextBrush" : "WarningBrush");
            test.IsEnabled = true;
        });

        var testPanel = new StackPanel();
        testPanel.Children.Add(Kit.Row(test, testStatus));
        var note = Kit.Caption(Kit.L("The Clash API is off unless your client sets external-controller. In sing-box that is experimental.clash_api.external_controller in the config; most GUI clients enable it on 127.0.0.1:9090 already."));
        note.Margin = new Thickness(0, 10, 0, 0);
        testPanel.Children.Add(note);
        var testCard = Kit.Panel(testPanel);

        var details = new StackPanel();
        details.Children.Add(hostCard);
        details.Children.Add(secretCard);
        details.Children.Add(testCard);
        page.Children.Add(details);

        void Refresh() => details.Visibility = settings.CollectStatistics && settings.CollectProxyNodeStatistics
            ? Visibility.Visible
            : Visibility.Collapsed;

        Kit.Watch(page, settings, changed =>
        {
            if (changed is nameof(AppSettings.CollectStatistics) or nameof(AppSettings.CollectProxyNodeStatistics))
            {
                Refresh();
            }
        });
        Refresh();
    }
}
