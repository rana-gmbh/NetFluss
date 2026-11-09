// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;
using NetFluss.App.Vpn;
using NetFluss.Core;
using NetFluss.Core.Vpn;
using NetFluss.Native;

namespace NetFluss.App.Settings;

/// <summary>
/// VPN — the macOS <c>VPNPreferencesContent</c>: import OpenVPN and WireGuard profiles, add
/// Windows' own VPN connections (IKEv2 / IPsec / L2TP), the diagnostics log, and the
/// profile list with servers, options and credentials.
/// </summary>
internal static class VpnPage
{
    internal static FrameworkElement Build(PreferencesContext context)
    {
        var settings = context.Settings;
        var vpn = context.Vpn;
        var page = new StackPanel();

        // ---- Import ----------------------------------------------------------------------
        page.Children.Add(Kit.Header(Kit.L("VPN")));
        page.Children.Add(Kit.Card(Kit.L("Show VPN in popover"), null, Kit.Switch(settings, nameof(AppSettings.ShowVpn))));

        // The indicator is set up on the Taskbar page, beside the meter it sits on, as on
        // macOS — but this is where people look for it, so say where it is and how it is set.
        var indicatorState = Kit.Caption(string.Empty);
        indicatorState.VerticalAlignment = VerticalAlignment.Center;
        indicatorState.Margin = new Thickness(0, 0, 12, 0);
        void ShowIndicatorState() => indicatorState.Text = settings.VpnIndicator switch
        {
            "dot" => Kit.L("Dot"),
            "shield" => Kit.L("Shield"),
            "globe" => Kit.L("Globe"),
            "bars" => Kit.L("Bars"),
            _ => Kit.L("Off"),
        };
        ShowIndicatorState();

        var openTaskbar = Kit.Button(Kit.L("Taskbar settings…"), () =>
        {
            if (Window.GetWindow(page) is PreferencesWindow preferences)
            {
                preferences.SelectTab("taskbar");
                preferences.Dispatcher.BeginInvoke(preferences.ScrollToEnd, System.Windows.Threading.DispatcherPriority.Loaded);
            }
        });

        page.Children.Add(Kit.Card(
            Kit.L("VPN indicator"),
            Kit.L("Shows on the taskbar meter and the widget whether a VPN is connected."),
            new StackPanel { Orientation = Orientation.Horizontal, Children = { indicatorState, openTaskbar } }));

        Kit.Watch(page, settings, name =>
        {
            if (name is null or nameof(AppSettings.VpnIndicator))
            {
                ShowIndicatorState();
            }
        });

        var importStatus = Kit.Caption(string.Empty);
        importStatus.TextWrapping = TextWrapping.Wrap;
        importStatus.Visibility = Visibility.Collapsed;

        void Report(string? message, bool warning)
        {
            importStatus.Text = message ?? string.Empty;
            importStatus.SetResourceReference(TextBlock.ForegroundProperty, warning ? "WarningBrush" : "ActiveBrush");
            importStatus.Visibility = message is null ? Visibility.Collapsed : Visibility.Visible;
        }

        void Import(VpnProtocol kind, bool folder)
        {
            string? path;
            if (folder)
            {
                var dialog = new OpenFolderDialog();
                path = dialog.ShowDialog(Window.GetWindow(page)) == true ? dialog.FolderName : null;
            }
            else
            {
                var extension = kind == VpnProtocol.OpenVpn ? "ovpn" : "conf";
                var dialog = new OpenFileDialog
                {
                    Filter = $"{kind.DisplayName()} (*.{extension};*.zip)|*.{extension};*.zip",
                    CheckFileExists = true,
                };
                path = dialog.ShowDialog(Window.GetWindow(page)) == true ? dialog.FileName : null;
            }

            if (path is null)
            {
                return;
            }

            try
            {
                var (profile, warnings) = vpn.Import(kind, path);
                Report(warnings.FirstOrDefault() ?? Kit.L("Added “{0}”.", profile.Name), warnings.Count > 0);
            }
            catch (VpnImportException e)
            {
                Report(e.Message, warning: true);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Report(Kit.L("Could not read the configuration: {0}.", e.Message), warning: true);
            }
        }

        var importButtons = new WrapPanel();
        foreach (var (label, kind, folder) in new[]
                 {
                     ("Import OpenVPN profile…", VpnProtocol.OpenVpn, false),
                     ("Import WireGuard profile…", VpnProtocol.WireGuard, false),
                     ("Import a folder of profiles…", VpnProtocol.OpenVpn, true),
                 })
        {
            var button = Kit.Button(Kit.L(label), () => Import(kind, folder));
            button.Margin = new Thickness(0, 0, 8, 8);
            importButtons.Children.Add(button);
        }

        var importPanel = new StackPanel();
        importPanel.Children.Add(importButtons);
        importPanel.Children.Add(Kit.Caption(Kit.L("Import a single config file, or a folder or .zip of them (e.g. a provider's router profiles). Each config becomes a selectable server.")));
        importPanel.Children.Add(importStatus);

        // What OpenVPN and WireGuard need on Windows, so a failed connect never has to explain it.
        var requirements = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
        importPanel.Children.Add(requirements);
        page.Children.Add(Kit.Panel(importPanel));

        // ---- System VPN ----------------------------------------------------------------------
        page.Children.Add(Kit.Header(Kit.L("System VPN (IKEv2 / IPsec / L2TP)")));
        var systemCaption = Kit.Caption(string.Empty);
        systemCaption.TextWrapping = TextWrapping.Wrap;
        var systemList = new ComboBox { MinWidth = 240 };
        var addSystem = Kit.Button(Kit.L("Add system VPN…"), () =>
        {
            if (systemList.SelectedItem is string entry)
            {
                vpn.AddSystem(entry);
            }
        });
        addSystem.Margin = new Thickness(8, 0, 0, 0);
        var refresh = Kit.IconButton(Glyph.Refresh, Kit.L("Refresh system VPNs"), () => RefreshSystem());
        refresh.Margin = new Thickness(4, 0, 0, 0);

        void RefreshSystem()
        {
            var entries = RasVpn.Entries().Select(e => e.Name).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            systemList.ItemsSource = entries;
            systemList.SelectedIndex = entries.Count > 0 ? 0 : -1;
            systemList.IsEnabled = addSystem.IsEnabled = entries.Count > 0;
            systemCaption.Text = entries.Count == 0
                ? Kit.L("No Windows VPN connections found. Set one up in Windows Settings → Network & internet → VPN, or add an IKEv2 VPN here.")
                : Kit.L("Adds a VPN connection set up in Windows Settings, so NetFluss can connect it from the popover.");
        }

        var systemPanel = new StackPanel();
        systemPanel.Children.Add(Kit.Row(systemList, addSystem, refresh));
        systemPanel.Children.Add(systemCaption);
        page.Children.Add(Kit.Panel(systemPanel));

        // ---- Add IKEv2 ---------------------------------------------------------------------------
        var ikeForm = Ikev2Form(context);
        page.Children.Add(Kit.Card(Kit.L("Add IKEv2 VPN…"),
            Kit.L("Creates an IKEv2 connection in Windows (username and password, EAP-MSCHAPv2) that NetFluss connects directly. The password is stored in Windows Credential Manager. If the server uses a private CA, import its certificate into the Trusted Root store first."),
            Kit.Button(Kit.L("Add…"), () => ikeForm.Visibility = ikeForm.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible),
            ikeForm));

        // ---- Diagnostics ---------------------------------------------------------------------------
        page.Children.Add(Kit.Header(Kit.L("VPN Diagnostics")));
        var copied = Kit.Caption(Kit.L("Copied to clipboard."));
        copied.Visibility = Visibility.Collapsed;
        var diagnostics = Kit.Row(
            Kit.Button(Kit.L("Copy VPN diagnostics"), () =>
            {
                VpnDiagnosticsLog.LogEnvironment(context.Helper.IsConnected, context.Helper.HelperVersion);
                copied.Visibility = Ui.Copy(VpnDiagnosticsLog.Read()) ? Visibility.Visible : Visibility.Collapsed;
            }),
            Kit.Button(Kit.L("Open VPN log folder"), () =>
            {
                Directory.CreateDirectory(Path.GetDirectoryName(VpnDiagnosticsLog.FilePath)!);
                Process.Start(new ProcessStartInfo { FileName = Path.GetDirectoryName(VpnDiagnosticsLog.FilePath)!, UseShellExecute = true })?.Dispose();
            }).Margin(8, 0, 0, 0),
            Kit.Button(Kit.L("Clear VPN log"), () =>
            {
                VpnDiagnosticsLog.Clear();
                copied.Visibility = Visibility.Collapsed;
            }).Margin(8, 0, 0, 0));
        var diagnosticsPanel = new StackPanel();
        diagnosticsPanel.Children.Add(diagnostics);
        diagnosticsPanel.Children.Add(copied);
        diagnosticsPanel.Children.Add(Kit.Caption(Kit.L("If a VPN connection fails, copy this log and send it — it records the installed tools, Windows' VPN connections, and the connection tool's full output.")));
        page.Children.Add(Kit.Panel(diagnosticsPanel));

        // ---- Profiles -----------------------------------------------------------------------------
        var profilesHeader = Kit.Header(Kit.L("Profiles"));
        var profiles = new StackPanel();
        page.Children.Add(profilesHeader);
        page.Children.Add(profiles);

        Guid? editing = null;

        void RefreshProfiles()
        {
            // Rebuilding while a name is being typed would steal the caret; skip until it commits.
            if (profiles.IsKeyboardFocusWithin && Keyboard.FocusedElement is TextBox or PasswordBox)
            {
                return;
            }

            profiles.Children.Clear();
            profilesHeader.Visibility = vpn.Profiles.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            for (var i = 0; i < vpn.Profiles.Count; i++)
            {
                profiles.Children.Add(ProfileCard(context, vpn.Profiles[i], i, editing == vpn.Profiles[i].Id, id =>
                {
                    editing = id;
                    page.Dispatcher.BeginInvoke(RefreshProfiles);
                }));
            }

            requirements.Children.Clear();
            Requirement(requirements, "OpenVPN Community", VpnTools.OpenVpnPath() is not null, "https://openvpn.net/community-downloads/");
            Requirement(requirements, "WireGuard for Windows", VpnTools.WireGuardPath() is not null, "https://www.wireguard.com/install/");
            var helper = context.Helper.SupportsVpn;
            var line = Kit.Caption((helper ? "✓ " : "• ") + Kit.L(helper
                ? "The NetFluss helper is installed — OpenVPN and WireGuard connections can start."
                : context.Helper.IsConnected
                    ? "The installed NetFluss helper predates the VPN client. Update it under General → System access to connect OpenVPN and WireGuard profiles."
                    : "OpenVPN and WireGuard connections run through the NetFluss helper (General → System access)."));
            line.SetResourceReference(TextBlock.ForegroundProperty, helper ? "SecondaryTextBrush" : "WarningBrush");
            requirements.Children.Add(line);
        }

        void OnChanged(object? sender, EventArgs e) => page.Dispatcher.BeginInvoke(RefreshProfiles);
        page.Loaded += (_, _) =>
        {
            vpn.Changed += OnChanged;
            RefreshSystem();
            RefreshProfiles();
        };
        page.Unloaded += (_, _) => vpn.Changed -= OnChanged;
        return page;
    }

    private static void Requirement(Panel into, string tool, bool installed, string url)
    {
        var text = Kit.Caption((installed ? "✓ " : "• ") + (installed
            ? Kit.L("{0} is installed.", tool)
            : Kit.L("{0} is not installed; it is needed for those profiles.", tool)));
        text.SetResourceReference(TextBlock.ForegroundProperty, installed ? "SecondaryTextBrush" : "WarningBrush");
        if (installed)
        {
            into.Children.Add(text);
            return;
        }

        var link = Kit.Button(Kit.L("Download…"), () => UpdateNotifier.Open(new Uri(url)));
        link.Margin = new Thickness(8, 0, 0, 0);
        link.Padding = new Thickness(8, 2, 8, 2);
        var row = Kit.Row(text, link);
        row.Margin = new Thickness(0, 2, 0, 2);
        into.Children.Add(row);
    }

    /// <summary>The inline IKEv2 form: name, server, username, password.</summary>
    private static FrameworkElement Ikev2Form(PreferencesContext context)
    {
        var name = new TextBox { Width = 260 };
        var server = new TextBox { Width = 260 };
        var username = new TextBox { Width = 260 };
        var password = new PasswordBox { Width = 260 };
        var status = Kit.Caption(string.Empty);
        status.TextWrapping = TextWrapping.Wrap;

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(160) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var rows = new (string Label, Control Field)[]
        {
            ("Name", name),
            ("Server (host or IP)", server),
            ("Username", username),
            ("Password", password),
        };
        for (var i = 0; i < rows.Length; i++)
        {
            grid.RowDefinitions.Add(new RowDefinition());
            var label = Kit.Text(Kit.L(rows[i].Label), 13);
            label.Margin = new Thickness(0, 6, 0, 0);
            rows[i].Field.Margin = new Thickness(0, 6, 0, 0);
            Grid.SetRow(label, i);
            Grid.SetRow(rows[i].Field, i);
            Grid.SetColumn(rows[i].Field, 1);
            grid.Children.Add(label);
            grid.Children.Add(rows[i].Field);
        }

        var panel = new StackPanel { Visibility = Visibility.Collapsed };
        var add = Kit.Button(Kit.L("Add"), () => { }, accent: true);
        add.Click += async (_, _) =>
        {
            if (name.Text.Trim().Length == 0 || server.Text.Trim().Length == 0 || username.Text.Trim().Length == 0)
            {
                status.Text = Kit.L("Fill in the name, server and username.");
                status.SetResourceReference(TextBlock.ForegroundProperty, "WarningBrush");
                return;
            }

            add.IsEnabled = false;
            status.Text = Kit.L("Creating the Windows VPN connection…");
            status.SetResourceReference(TextBlock.ForegroundProperty, "SecondaryTextBrush");
            var error = await context.Vpn.AddIkev2Async(name.Text, server.Text, username.Text, password.Password);
            add.IsEnabled = true;
            if (error is not null)
            {
                status.Text = error;
                status.SetResourceReference(TextBlock.ForegroundProperty, "WarningBrush");
                return;
            }

            name.Text = server.Text = username.Text = string.Empty;
            password.Clear();
            status.Text = string.Empty;
            panel.Visibility = Visibility.Collapsed;
        };
        add.Margin = new Thickness(0, 12, 0, 0);
        add.HorizontalAlignment = HorizontalAlignment.Left;

        panel.Children.Add(grid);
        panel.Children.Add(add);
        panel.Children.Add(status);
        return panel;
    }

    /// <summary>One profile: name, order, delete, server, options and credentials.</summary>
    private static FrameworkElement ProfileCard(PreferencesContext context, VpnProfile profile, int index, bool editingCredentials, Action<Guid?> setEditing)
    {
        var vpn = context.Vpn;

        var name = new TextBox { Text = profile.Name, MinWidth = 260 };
        void Commit() => vpn.Rename(profile, name.Text);
        name.LostFocus += (_, _) => Commit();
        name.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter)
            {
                Commit();
                Keyboard.ClearFocus();
            }
        };

        var subtitle = profile.Kind == VpnProtocol.Ikev2
            ? Kit.L("System VPN · {0}", profile.NativeEntryName ?? profile.Kind.DisplayName())
            : Kit.L("{0} · {1} server(s)", profile.Kind.DisplayName(), profile.Servers.Count);
        var left = new StackPanel();
        left.Children.Add(name);
        left.Children.Add(Kit.Caption(subtitle));

        var up = Kit.IconButton(Glyph.ChevronUp, Kit.L("Move up"), () => vpn.Move(profile, index - 1));
        up.IsEnabled = index > 0;
        var down = Kit.IconButton(Glyph.ChevronDown, Kit.L("Move down"), () => vpn.Move(profile, index + 1));
        down.IsEnabled = index < vpn.Profiles.Count - 1;
        var delete = Kit.IconButton(Glyph.Delete, Kit.L("Delete"), () => _ = vpn.DeleteAsync(profile));
        var actions = Kit.Row(up, down, delete);
        actions.VerticalAlignment = VerticalAlignment.Top;

        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(actions, 1);
        head.Children.Add(left);
        head.Children.Add(actions);

        var body = new StackPanel();
        body.Children.Add(head);

        FrameworkElement Option(string label, FrameworkElement control)
        {
            var row = new Grid { Margin = new Thickness(0, 10, 0, 0) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var text = Kit.Text(Kit.L(label), 13);
            text.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(control, 1);
            row.Children.Add(text);
            row.Children.Add(control);
            return row;
        }

        if (profile.Servers.Count > 1)
        {
            body.Children.Add(Option("Server", Kit.Combo(
                profile.Servers.Select((s, i) => new Choice(i, s.Label)), profile.SelectedServerIndex,
                value => vpn.SelectServer(profile, (int)value), 240)));
        }

        body.Children.Add(Option("Reconnect automatically",
            Kit.Switch(profile.Options.AutoReconnect, on => vpn.SetOptions(profile, o => o with { AutoReconnect = on }))));
        body.Children.Add(Option("Connect when NetFluss starts",
            Kit.Switch(profile.Options.ConnectOnLaunch, on => vpn.SetOptions(profile, o => o with { ConnectOnLaunch = on }))));
        body.Children.Add(Option("Use custom DNS while connected",
            Kit.Switch(profile.Options.UseProfileDns, on => vpn.SetOptions(profile, o => o with { UseProfileDns = on }))));

        if (profile.Options.UseProfileDns)
        {
            var presets = context.Settings.AllDnsPresets().Where(p => p.Servers.Count > 0)
                .Select(p => new Choice(p.Id, Kit.L(p.Name)))
                .Prepend(new Choice(string.Empty, Kit.L("Choose a DNS preset")));
            body.Children.Add(Option("DNS preset", Kit.Combo(presets, profile.Options.DnsPresetId ?? string.Empty,
                value => vpn.SetOptions(profile, o => o with { DnsPresetId = value as string is { Length: > 0 } id ? id : null }), 220)));
        }

        // Credentials: OpenVPN auth-user-pass, IKEv2 profiles, and system VPNs that do not save their own.
        if (profile.RequiresCredentials || profile.Kind == VpnProtocol.Ikev2)
        {
            var stored = vpn.HasCredentials(profile);
            var state = Kit.Caption(Kit.L(stored ? "Credentials stored" : profile.RequiresCredentials ? "Credentials required" : "Uses the credentials saved in Windows"));
            state.SetResourceReference(TextBlock.ForegroundProperty, stored || !profile.RequiresCredentials ? "SecondaryTextBrush" : "WarningBrush");
            var edit = Kit.Button(Kit.L("Edit…"), () => setEditing(editingCredentials ? null : profile.Id));
            var row = Option("Credentials", Kit.Row(state, edit.Margin(10, 0, 0, 0)));
            body.Children.Add(row);

            if (editingCredentials)
            {
                body.Children.Add(CredentialForm(context, profile, () => setEditing(null)));
            }
        }

        return Kit.Panel(body);
    }

    private static FrameworkElement CredentialForm(PreferencesContext context, VpnProfile profile, Action done)
    {
        var username = new TextBox { Width = 240, Text = profile.Ikev2Username ?? string.Empty };
        var password = new PasswordBox { Width = 240 };
        var grid = new Grid { Margin = new Thickness(0, 10, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition());
        grid.RowDefinitions.Add(new RowDefinition());
        var userLabel = Kit.Text(Kit.L("Username"), 13);
        var passLabel = Kit.Text(Kit.L("Password"), 13);
        passLabel.Margin = password.Margin = new Thickness(0, 6, 0, 0);
        Grid.SetColumn(username, 1);
        Grid.SetRow(passLabel, 1);
        Grid.SetRow(password, 1);
        Grid.SetColumn(password, 1);
        grid.Children.Add(userLabel);
        grid.Children.Add(username);
        grid.Children.Add(passLabel);
        grid.Children.Add(password);

        var save = Kit.Button(Kit.L("Save credentials"), () =>
        {
            context.Vpn.SetCredentials(profile, username.Text.Trim(), password.Password);
            password.Clear();
            done();
        }, accent: true);
        var cancel = Kit.Button(Kit.L("Cancel"), done);
        var buttons = Kit.Row(cancel, save.Margin(8, 0, 0, 0));
        buttons.Margin = new Thickness(0, 10, 0, 0);

        var panel = new StackPanel();
        panel.Children.Add(grid);
        panel.Children.Add(buttons);
        username.Loaded += (_, _) => username.Focus();
        return panel;
    }
}
