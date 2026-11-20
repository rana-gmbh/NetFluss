// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using NetFluss.Core;

namespace NetFluss.App.Settings;

/// <summary>
/// DNS — the macOS DNS Switcher pane: the popover switcher, the presets with visibility and
/// order, custom presets of up to four servers — plain, DoH or DoT — and applying one from
/// here. Encrypted presets this PC cannot use stay listed, greyed out with the reason.
/// </summary>
internal static class DnsPage
{
    private const int MaximumCustomServers = 4;

    internal static FrameworkElement Build(PreferencesContext context)
    {
        var settings = context.Settings;
        var page = new StackPanel();

        page.Children.Add(Kit.Header(Kit.L("DNS Switcher")));
        page.Children.Add(Kit.Card(
            Kit.L("Show DNS switcher in popover"),
            context.Privileged.IsSilent
                ? Kit.L("The NetFluss helper is installed, so DNS changes apply without asking.")
                : Kit.L("Changing DNS needs administrator rights: each change asks for approval, unless the optional NetFluss helper is installed (General → System access)."),
            Kit.Switch(settings, nameof(AppSettings.ShowDnsSwitcher))));

        // ---- Adapter -------------------------------------------------------------
        var current = Kit.Caption(string.Empty);
        var adapterText = new StackPanel();
        adapterText.Children.Add(Kit.Text(Kit.L("Adapter")));
        adapterText.Children.Add(Kit.Caption(Kit.L("Which adapter the switcher changes. Automatic follows the one carrying the internet connection.")));
        adapterText.Children.Add(current);

        var adapters = DnsController.Read()
            .Where(state => Guid.TryParse(state.AdapterId, out _))
            .Select(state => new Choice(Guid.Parse(state.AdapterId).ToString("B"), state.AdapterName))
            .Prepend(new Choice(string.Empty, Kit.L("Automatic")))
            .ToList();

        page.Children.Add(Kit.Card(adapterText, Kit.Combo(settings, nameof(AppSettings.DnsAdapterId), adapters, 220)));

        // ---- Presets -------------------------------------------------------------
        page.Children.Add(Kit.Header(Kit.L("Presets")));
        var status = Kit.Caption(string.Empty);
        var presets = new ReorderList((id, index) => settings.MoveDnsPreset(id, index));
        presets.Margin = new Thickness(0, 8, 0, 0);

        var presetPanel = new StackPanel();
        presetPanel.Children.Add(Kit.Caption(Kit.L("Switch a preset off to keep it out of the popover. A green check marks the one in use.")));
        presetPanel.Children.Add(presets);
        presetPanel.Children.Add(status);
        page.Children.Add(Kit.Panel(presetPanel));

        // ---- Encrypted DNS ----------------------------------------------------------
        var encryptedState = Kit.Caption(string.Empty);
        var encryptedText = new StackPanel();
        encryptedText.Children.Add(Kit.Text(Kit.L("Encrypted DNS")));
        encryptedText.Children.Add(encryptedState);
        encryptedText.Children.Add(Kit.Caption(Kit.L("DoH and DoT presets use the encrypted DNS built into Windows 11 and are set through the NetFluss helper, which also takes them back. DoT needs Windows 11 24H2 or later. The encrypted presets start hidden in the popover; switch them on in the list above.")));
        page.Children.Add(Kit.Card(encryptedText, null));

        // ---- Custom preset ---------------------------------------------------------
        page.Children.Add(Kit.Header(Kit.L("Add Custom DNS…")));
        var name = new TextBox { Width = 200 };
        var endpoint = new TextBox { Width = 300, Margin = new Thickness(0, 6, 0, 0) };
        var servers = Enumerable.Range(0, MaximumCustomServers).Select(_ => new TextBox { Width = 200, Margin = new Thickness(0, 6, 0, 0) }).ToList();
        var addStatus = Kit.Caption(string.Empty);

        // Plain, DoH or DoT, as the macOS sheet's segmented control. The protocol names are
        // not translated there either.
        DnsTransport? kind = null;
        var kinds = new[]
        {
            new Choice(string.Empty, Kit.L("Plain DNS")),
            new Choice(DnsTransports.HttpsWire, "DNS-over-HTTPS"),
            new Choice(DnsTransports.TlsWire, "DNS-over-TLS"),
        };
        var endpointLabel = Kit.Text(string.Empty, 13);
        endpointLabel.Margin = new Thickness(0, 6, 0, 0);
        var formCaption = Kit.Caption(string.Empty);

        void ShowKind()
        {
            var encrypted = kind is not null;
            endpointLabel.Visibility = encrypted ? Visibility.Visible : Visibility.Collapsed;
            endpoint.Visibility = endpointLabel.Visibility;
            endpointLabel.Text = kind == DnsTransport.Tls ? Kit.L("Server name") : Kit.L("URL");
            AutomationProperties.SetName(endpoint, kind == DnsTransport.Tls
                ? Kit.L("Server name (e.g. dns.example.com)")
                : Kit.L("URL (e.g. https://dns.example.com/dns-query)"));
            endpoint.ToolTip = AutomationProperties.GetName(endpoint);
            formCaption.Text = encrypted
                ? Kit.L("macOS connects to the IP and checks the server name against its certificate.") + " " +
                  Kit.L("At least one server address is needed. Without an IPv6 address, IPv6 keeps the network's own resolver.")
                : Kit.L("Up to four IPv4 or IPv6 servers. A preset with only IPv4 also puts IPv6 back on automatic, so a leftover IPv6 resolver cannot keep answering.");
        }

        var kindCombo = Kit.Combo(kinds, string.Empty, value =>
        {
            kind = DnsTransports.FromWire(value as string);
            addStatus.Text = string.Empty;
            ShowKind();
        }, 200);
        AutomationProperties.SetName(kindCombo, Kit.L("Protocol"));

        var add = Kit.Button(Kit.L("Add"), () =>
        {
            var list = servers.Select(box => box.Text.Trim()).Where(text => text.Length > 0).ToList();
            var result = settings.AddDnsPreset(name.Text, list, kind, kind is null ? null : endpoint.Text);
            if (!result.IsValid)
            {
                addStatus.Text = Kit.L(result.Error ?? "Could not add that preset.");
                addStatus.SetResourceReference(TextBlock.ForegroundProperty, "WarningBrush");
                return;
            }

            name.Text = string.Empty;
            endpoint.Text = string.Empty;
            servers.ForEach(box => box.Text = string.Empty);
            addStatus.Text = Kit.L("Preset added.");
            addStatus.SetResourceReference(TextBlock.ForegroundProperty, "ActiveBrush");
        }, accent: true);
        add.HorizontalAlignment = HorizontalAlignment.Left;
        add.Margin = new Thickness(0, 12, 0, 0);

        // Rows: name, protocol, URL or host, then the servers.
        const int firstServerRow = 3;
        var form = new Grid();
        form.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(110) });
        form.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        for (var i = 0; i < MaximumCustomServers + firstServerRow; i++)
        {
            form.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        }

        var nameLabel = Kit.Text(Kit.L("Name"), 13);
        form.Children.Add(nameLabel);
        Grid.SetColumn(name, 1);
        form.Children.Add(name);

        var kindLabel = Kit.Text(Kit.L("Protocol"), 13);
        kindLabel.Margin = new Thickness(0, 6, 0, 0);
        kindCombo.Margin = new Thickness(0, 6, 0, 0);
        kindCombo.HorizontalAlignment = HorizontalAlignment.Left;
        Grid.SetRow(kindLabel, 1);
        Grid.SetRow(kindCombo, 1);
        Grid.SetColumn(kindCombo, 1);
        form.Children.Add(kindLabel);
        form.Children.Add(kindCombo);

        Grid.SetRow(endpointLabel, 2);
        Grid.SetRow(endpoint, 2);
        Grid.SetColumn(endpoint, 1);
        form.Children.Add(endpointLabel);
        form.Children.Add(endpoint);

        for (var i = 0; i < MaximumCustomServers; i++)
        {
            var label = Kit.Text(Kit.L("Server {0}", i + 1), 13);
            label.Margin = new Thickness(0, 6, 0, 0);
            Grid.SetRow(label, i + firstServerRow);
            Grid.SetRow(servers[i], i + firstServerRow);
            Grid.SetColumn(servers[i], 1);
            form.Children.Add(label);
            form.Children.Add(servers[i]);
        }

        ShowKind();
        var formPanel = new StackPanel();
        formPanel.Children.Add(formCaption);
        form.Margin = new Thickness(0, 10, 0, 0);
        formPanel.Children.Add(form);
        formPanel.Children.Add(add);
        formPanel.Children.Add(addStatus);
        page.Children.Add(Kit.Panel(formPanel));

        string? TargetId() => !string.IsNullOrEmpty(settings.DnsAdapterId) && DnsController.AdapterName(settings.DnsAdapterId) is not null
            ? settings.DnsAdapterId
            : context.Monitor.Addresses.PrimaryAdapterId;

        var applying = false;

        void Refresh()
        {
            var target = TargetId();
            var targetName = target is null ? null : DnsController.AdapterName(target);
            var staticServers = target is null ? [] : DnsController.StaticServers(target);
            var state = target is null ? DnsAdapterState.Plain(staticServers) : DnsController.ReadState(target, staticServers, context.Privileged.DotServers);
            var active = DnsController.ActivePresetId(settings.AllDnsPresets(), state);
            var capabilities = context.Privileged.EncryptedCapabilities;
            encryptedState.Text = EncryptedDnsText.Status(settings, state, active);

            current.Text = targetName is null
                ? Kit.L("No adapter with an internet connection was found.")
                : staticServers.Count == 0
                    ? Kit.L("{0} is on automatic DNS.", targetName)
                    : Kit.L("{0} uses {1}.", targetName, string.Join(", ", staticServers));

            presets.SetRows(settings.OrderedDnsPresets().Select(preset =>
            {
                var visible = Kit.Switch(!settings.HiddenDnsPresets.Contains(preset.Id), on => settings.SetDnsPresetHidden(preset.Id, !on));
                visible.Margin = new Thickness(0, 0, 12, 0);
                visible.ToolTip = Kit.L("Show in the popover");

                var check = Kit.Icon(active == preset.Id ? Glyph.CheckCircle : string.Empty, 14, "ActiveBrush");
                check.Width = 22;

                var displayName = settings.DnsPresetDisplayName(preset);
                var blocked = EncryptedDnsText.Block(preset, capabilities);
                var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
                text.Children.Add(preset.IsBuiltIn
                    ? RenamableName(settings, preset, displayName, active == preset.Id)
                    : Kit.Text(displayName, 14, "TextBrush", active == preset.Id ? FontWeights.SemiBold : FontWeights.Normal));
                text.Children.Add(Kit.Caption(preset.Encryption is { } encryption
                    ? $"{DnsTransports.ShortName(encryption.Transport)} · {EncryptedDnsText.Detail(preset)}"
                    : EncryptedDnsText.Detail(preset)));
                if (blocked.Length > 0)
                {
                    // Kept in the list, greyed, with the reason: hiding it would make the
                    // preset look like it never existed on this PC.
                    var badge = Kit.Caption(blocked);
                    badge.SetResourceReference(TextBlock.ForegroundProperty, "WarningBrush");
                    text.Children.Add(badge);
                    text.Opacity = 0.6;
                }

                var apply = Kit.Button(Kit.L("Apply"), async () =>
                {
                    if (applying || target is null || targetName is null)
                    {
                        return;
                    }

                    // A pick from here on the adapter the rules act on holds on this network,
                    // the same as one from the popover.
                    if (target == context.Dns.AdapterId)
                    {
                        context.AutoDns.RecordManualOverride();
                    }

                    applying = true;
                    status.Text = context.Privileged.IsSilent || preset.IsEncrypted
                        ? Kit.L("Applying {0}…", displayName)
                        : Kit.L("Applying {0}… confirm the administrator prompt.", displayName);
                    var result = await context.Privileged.SetDnsAsync(target, targetName, preset);
                    applying = false;
                    status.Text = result.Message;
                    status.SetResourceReference(TextBlock.ForegroundProperty, result.Succeeded ? "ActiveBrush" : "WarningBrush");
                    context.Dns.Refresh();
                    Refresh();
                });
                apply.IsEnabled = active != preset.Id && targetName is not null && blocked.Length == 0;
                apply.Margin = new Thickness(8, 0, 0, 0);

                var actions = Kit.Row(apply);
                if (!preset.IsBuiltIn)
                {
                    var delete = Kit.IconButton("", Kit.L("Delete"), () => settings.RemoveDnsPreset(preset.Id));
                    delete.Margin = new Thickness(4, 0, 0, 0);
                    actions.Children.Add(delete);
                }

                var row = new Grid();
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                Grid.SetColumn(check, 1);
                Grid.SetColumn(text, 2);
                Grid.SetColumn(actions, 3);
                row.Children.Add(visible);
                row.Children.Add(check);
                row.Children.Add(text);
                row.Children.Add(actions);
                return (preset.Id, (FrameworkElement)row);
            }));
        }

        Kit.Watch(page, settings, changed =>
        {
            if (changed is nameof(AppSettings.CustomDnsPresets) or nameof(AppSettings.HiddenDnsPresets) or nameof(AppSettings.DnsPresetOrder)
                or nameof(AppSettings.DnsAdapterId) or nameof(AppSettings.DnsPresetCustomNames))
            {
                Refresh();
            }
        });

        // The helper's word on DoT and on what this PC can do arrives without a settings change.
        void OnEncryptedStatus(object? sender, EventArgs e) => Refresh();
        page.Loaded += (_, _) => context.Privileged.EncryptedStatusChanged += OnEncryptedStatus;
        page.Unloaded += (_, _) => context.Privileged.EncryptedStatusChanged -= OnEncryptedStatus;

        Refresh();
        BuildAutomatic(context, page);
        return page;
    }

    /// <summary>
    /// A built-in profile's name with a pencil beside it; the pencil swaps the name for a text
    /// field. Only the name changes — the servers stay fixed, so "Home" can never quietly
    /// point somewhere other than the Cloudflare it was renamed from (macOS 2.7).
    /// </summary>
    private static FrameworkElement RenamableName(AppSettings settings, DnsPreset preset, string displayName, bool isActive)
    {
        var host = new ContentControl { Focusable = false };
        var label = Kit.Text(displayName, 14, "TextBrush", isActive ? FontWeights.SemiBold : FontWeights.Normal);

        void ShowLabel()
        {
            var edit = Kit.IconButton(Glyph.Edit, Kit.L("Rename"), StartEditing);
            edit.Margin = new Thickness(6, 0, 0, 0);
            edit.Padding = new Thickness(4, 2, 4, 2);
            edit.FontSize = 12;
            AutomationProperties.SetName(edit, Kit.L("Rename"));
            host.Content = Kit.Row(label, edit);
        }

        void StartEditing()
        {
            var box = new TextBox { Text = displayName, Width = 200, MaxLength = 40 };
            AutomationProperties.SetName(box, Kit.L("Name"));
            var done = false;

            void Commit(bool keep)
            {
                if (done)
                {
                    return;
                }

                done = true;
                if (keep && box.Text.Trim() != displayName)
                {
                    // Raises the change that rebuilds the list with the new name.
                    settings.RenameDnsPreset(preset.Id, box.Text);
                }
                else
                {
                    ShowLabel();
                }
            }

            box.KeyDown += (_, e) =>
            {
                if (e.Key == System.Windows.Input.Key.Enter)
                {
                    Commit(keep: true);
                    e.Handled = true;
                }
                else if (e.Key == System.Windows.Input.Key.Escape)
                {
                    Commit(keep: false);
                    e.Handled = true;
                }
            };
            box.LostKeyboardFocus += (_, _) => Commit(keep: true);
            box.ToolTip = Kit.L("Leave empty to restore the original name.");

            host.Content = box;
            box.Loaded += (_, _) =>
            {
                box.Focus();
                box.SelectAll();
            };
        }

        ShowLabel();
        return host;
    }

    // ===================================== Automatic DNS =====================================

    /// <summary>
    /// "On this network, use this resolver" — the macOS 2.7 Automatic DNS section: a rule per
    /// Wi-Fi network, optionally pinned to one access point, a catch-all for every other
    /// network, and a live line saying what the engine is doing and why.
    /// </summary>
    private static void BuildAutomatic(PreferencesContext context, StackPanel page)
    {
        var settings = context.Settings;
        var auto = context.AutoDns;

        page.Children.Add(Kit.Header(Kit.L("Automatic DNS")));
        page.Children.Add(Kit.Card(
            Kit.L("Switch DNS automatically by network"),
            Kit.L("Picks a resolver from the Wi-Fi network you join — one for home, another for public networks. Needs the privileged helper, otherwise every switch would ask for your password."),
            Kit.Switch(settings, nameof(AppSettings.DnsAutoSwitchEnabled))));

        var rules = new StackPanel();
        var currentLabel = Kit.Caption(string.Empty);
        currentLabel.Margin = new Thickness(10, 0, 0, 0);
        var noNetwork = Kit.Caption(Kit.L("No Wi-Fi network name is available. Join a Wi-Fi network, or allow Location access below — macOS withholds the network name without it."));
        var add = Kit.Button(Kit.L("Add current network"), () =>
        {
            if (auto.CurrentNetwork is not { } network || settings.DnsRules.Any(rule => rule.Ssid == network.Ssid))
            {
                return;
            }

            settings.SetDnsRules([.. settings.DnsRules, new DnsRule { Ssid = network.Ssid, PresetId = "system" }]);
        });

        var rulesPanel = new StackPanel();
        rulesPanel.Children.Add(rules);
        rulesPanel.Children.Add(Kit.Row(add, currentLabel));
        noNetwork.Margin = new Thickness(0, 6, 0, 0);
        rulesPanel.Children.Add(noNetwork);
        var rulesCard = Kit.Panel(rulesPanel);
        page.Children.Add(rulesCard);

        var fallback = Kit.Combo(settings, nameof(AppSettings.DnsRuleFallbackPresetId), PresetChoices(settings, withLeaveUnchanged: true), 200);
        var fallbackCard = Kit.Card(
            Kit.L("Any other network"),
            Kit.L("Applied on networks without a rule of their own, including wired ones. This is what stops a public resolver following you home."),
            fallback);
        page.Children.Add(fallbackCard);

        var status = Kit.Caption(string.Empty);
        status.Margin = new Thickness(2, 8, 0, 0);
        page.Children.Add(status);

        void RefreshRules()
        {
            rules.Children.Clear();
            var bssid = auto.CurrentNetwork?.Bssid;
            var choices = PresetChoices(settings, withLeaveUnchanged: false).ToList();

            foreach (var rule in settings.DnsRules)
            {
                var current = rule;
                void Replace(DnsRule updated) => settings.SetDnsRules(settings.DnsRules.Select(r => r.Id == current.Id ? updated : r));

                var enabled = Kit.Switch(rule.Enabled, on => Replace(current with { Enabled = on }));
                enabled.Margin = new Thickness(0, 0, 12, 0);
                AutomationProperties.SetName(enabled, rule.Ssid);

                var name = Kit.Text(rule.Ssid, 14, "TextBrush", FontWeights.SemiBold);
                name.TextTrimming = TextTrimming.CharacterEllipsis;
                name.TextWrapping = TextWrapping.NoWrap;

                var preset = Kit.Combo(choices, rule.PresetId, value => Replace(current with { PresetId = (string)value }), 180);
                AutomationProperties.SetName(preset, Kit.L("DNS preset"));

                var delete = Kit.IconButton(Glyph.Delete, Kit.L("Delete"), () => settings.SetDnsRules(settings.DnsRules.Where(r => r.Id != current.Id)));
                delete.Margin = new Thickness(4, 0, 0, 0);

                var top = new Grid();
                top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                Grid.SetColumn(name, 1);
                Grid.SetColumn(preset, 2);
                Grid.SetColumn(delete, 3);
                top.Children.Add(enabled);
                top.Children.Add(name);
                top.Children.Add(preset);
                top.Children.Add(delete);

                // Pinning needs the access point the machine is on now; an existing pin can
                // always be released.
                var pinned = !string.IsNullOrEmpty(rule.Bssid);
                var pin = new CheckBox
                {
                    IsChecked = pinned,
                    IsEnabled = pinned || (bssid is not null && auto.CurrentNetwork?.Ssid == rule.Ssid),
                    Margin = new Thickness(0, 6, 0, 0),
                    Content = pinned ? $"{Kit.L("Only this access point")} ({rule.Bssid})" : Kit.L("Only this access point"),
                };
                pin.SetResourceReference(Control.ForegroundProperty, "SecondaryTextBrush");
                pin.Click += (_, _) => Replace(current with { Bssid = pin.IsChecked == true ? bssid : null });

                var row = new StackPanel { Margin = new Thickness(0, 0, 0, 12) };
                row.Children.Add(top);
                row.Children.Add(pin);
                rules.Children.Add(row);
            }
        }

        void RefreshState()
        {
            var on = settings.DnsAutoSwitchEnabled;
            foreach (var element in new FrameworkElement[] { rulesCard, fallbackCard, status })
            {
                element.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
            }

            var network = auto.CurrentNetwork;
            add.IsEnabled = network is { } n && settings.DnsRules.All(rule => rule.Ssid != n.Ssid);
            currentLabel.Text = network?.Ssid ?? string.Empty;
            noNetwork.Visibility = network is null ? Visibility.Visible : Visibility.Collapsed;
            status.Text = Explain(settings, auto.State);
        }

        Kit.Watch(page, settings, changed =>
        {
            if (changed is nameof(AppSettings.DnsRules) or nameof(AppSettings.CustomDnsPresets) or nameof(AppSettings.DnsPresetCustomNames))
            {
                RefreshRules();
            }

            if (changed is nameof(AppSettings.CustomDnsPresets) or nameof(AppSettings.DnsPresetCustomNames))
            {
                // Keep the catch-all's list in step with renamed and added profiles.
                var selected = fallback.SelectedValue;
                fallback.ItemsSource = PresetChoices(settings, withLeaveUnchanged: true).ToList();
                fallback.SelectedValue = selected;
            }

            RefreshState();
        });

        // The engine's state, and the network the rules see, change with no settings change.
        void OnAutoChanged(object? sender, EventArgs e) => RefreshState();
        var lastNetwork = auto.CurrentNetwork;
        void OnTick(object? sender, EventArgs e)
        {
            var network = auto.CurrentNetwork;
            if (network != lastNetwork)
            {
                lastNetwork = network;
                RefreshRules();
                RefreshState();
            }
        }

        page.Loaded += (_, _) =>
        {
            auto.Changed += OnAutoChanged;
            context.Monitor.Ticked += OnTick;
        };
        page.Unloaded += (_, _) =>
        {
            auto.Changed -= OnAutoChanged;
            context.Monitor.Ticked -= OnTick;
        };

        RefreshRules();
        RefreshState();
    }

    private static IEnumerable<Choice> PresetChoices(AppSettings settings, bool withLeaveUnchanged)
    {
        if (withLeaveUnchanged)
        {
            yield return new Choice(string.Empty, Kit.L("Leave unchanged"));
        }

        foreach (var preset in settings.OrderedDnsPresets())
        {
            yield return new Choice(preset.Id, settings.DnsPresetDisplayName(preset));
        }
    }

    /// <summary>
    /// The engine's state in words, so a resolver the app changed by itself is never left
    /// unexplained.
    /// </summary>
    private static string Explain(AppSettings settings, DnsAutoSwitchState state)
    {
        string Name(string? id) => settings.AllDnsPresets().FirstOrDefault(preset => preset.Id == id) is { } preset
            ? settings.DnsPresetDisplayName(preset)
            : id ?? string.Empty;

        return state.Kind switch
        {
            DnsAutoSwitchKind.NeedsHelper => Kit.L("Install the privileged helper to let NetFluss change DNS without asking each time."),
            DnsAutoSwitchKind.SuspendedByVpn => Kit.L("Paused: a VPN profile is controlling DNS right now."),
            DnsAutoSwitchKind.WaitingForPortal => Kit.L("Waiting for {0} to let you online before changing DNS.", state.Ssid),
            DnsAutoSwitchKind.WaitingForNetwork => Kit.L("Waiting for a connection to {0} before changing DNS.", state.Ssid),
            DnsAutoSwitchKind.Applied when string.IsNullOrEmpty(state.Ssid) => Kit.L("Using {0} on this network.", Name(state.PresetId)),
            DnsAutoSwitchKind.Applied => Kit.L("Using {0} on {1}.", Name(state.PresetId), state.Ssid),
            DnsAutoSwitchKind.EncryptedDnsUnavailable => Kit.L("{0} needs encrypted DNS, which this build of NetFluss can't set up.", Name(state.PresetId)),
            DnsAutoSwitchKind.ManualOverride when string.IsNullOrEmpty(state.Ssid) => Kit.L("Chosen by hand on this network. The rules apply again on the next network you join."),
            DnsAutoSwitchKind.ManualOverride => Kit.L("Chosen by hand on {0}. The rules apply again on the next network you join.", state.Ssid),
            _ => Kit.L("No rule applies to the current network."),
        };
    }
}
