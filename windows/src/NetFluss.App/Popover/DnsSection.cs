// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Windows;
using System.Windows.Controls;
using NetFluss.Core;

namespace NetFluss.App.Popover;

/// <summary>
/// The DNS switcher — port of the macOS <c>DNSSwitcherSection</c>. Encrypted presets carry a
/// lock and their DoH/DoT tag; those this PC cannot use at all are not offered here (Preferences
/// lists them greyed out with the reason).
/// </summary>
internal sealed class DnsSection : IPopoverSection
{
    private static readonly TimeSpan RereadInterval = TimeSpan.FromSeconds(30);

    private readonly PopoverContext _context;
    private readonly TextBlock _adapter;
    private readonly StackPanel _rows = new() { Margin = new Thickness(8, 0, 8, 0) };
    private readonly Grid _error;
    private readonly TextBlock _errorText;
    private readonly Button _helperButton;
    private DateTime _lastRead = DateTime.MinValue;
    private string _signature = string.Empty;
    private bool _installing;

    internal DnsSection(PopoverContext context)
    {
        _context = context;
        _context.Dns.Changed += (_, _) => Rebuild();

        var title = Ui.SectionTitle(PopoverContext.L("DNS"));
        _adapter = Ui.Label(string.Empty, 11, Ui.Tertiary);
        _adapter.Margin = new Thickness(0, 10, 14, 6);
        _adapter.HorizontalAlignment = HorizontalAlignment.Right;

        var header = Ui.Columns(Ui.Auto, Ui.Star);
        header.Children.Add(title.At(0));
        header.Children.Add(_adapter.At(1));

        _errorText = Ui.Wrapping(string.Empty, 11);
        _helperButton = Ui.LinkButton(PopoverContext.L("Install helper…"), InstallHelper).Margin(0, 4, 0, 0);
        var warning = Ui.Icon(Glyph.Warning, 11, Ui.Orange);
        warning.VerticalAlignment = VerticalAlignment.Top;
        warning.Margin = new Thickness(0, 2, 6, 0);
        _error = Ui.Columns(Ui.Auto, Ui.Star);
        _error.Margin = new Thickness(14, 4, 14, 0);
        _error.Children.Add(warning.At(0));
        _error.Children.Add(Ui.Column(_errorText, _helperButton).At(1));

        View = Ui.Column(header, _rows, _error).Margin(0, 0, 0, 8);
    }

    public PopoverSection Kind => PopoverSection.Dns;

    public FrameworkElement View { get; }

    public void SetActive(bool active)
    {
        if (active)
        {
            // Opening the popover is the moment the user is about to look; read now rather
            // than show a checkmark that may be half a minute old.
            _lastRead = DateTime.UtcNow;
            _context.Dns.Refresh();
        }
    }

    public void Refresh()
    {
        if (DateTime.UtcNow - _lastRead >= RereadInterval && !_context.Dns.IsApplying)
        {
            _lastRead = DateTime.UtcNow;
            _context.Dns.Refresh();
        }
    }

    private void Rebuild()
    {
        var dns = _context.Dns;

        // An encrypted preset this PC can never use is not offered; one that only needs the
        // helper is, and picking it says so.
        var capabilities = _context.Privileged.EncryptedCapabilities;
        var presets = _context.Settings.VisibleDnsPresets()
            .Where(preset => preset.Encryption is not { } encryption || capabilities.Supports(encryption.Transport))
            .ToList();

        _adapter.Text = dns.AdapterName ?? string.Empty;
        _errorText.Text = dns.Error ?? string.Empty;
        _error.Visibility = string.IsNullOrEmpty(dns.Error) ? Visibility.Collapsed : Visibility.Visible;
        _helperButton.Visibility = dns.ErrorNeedsHelper ? Visibility.Visible : Visibility.Collapsed;
        _helperButton.Content = _installing
            ? PopoverContext.L("Installing…")
            : _context.Helper.IsConnected && !_context.Helper.IsCurrentVersion
                ? PopoverContext.L(_context.Helper.IsNewerThanApp ? "Reinstall helper…" : "Update helper…")
                : PopoverContext.L("Install helper…");
        _helperButton.IsEnabled = !_installing;

        // Rows are rebuilt only when what they show changed, so hovering one is not undone
        // by a background re-read that found nothing new.
        var signature = string.Join('|', presets.Select(p => p.Id + "=" + _context.Settings.DnsPresetDisplayName(p))) + $"#{dns.ActivePresetId}#{dns.ApplyingPresetId}#{dns.AdapterId}";
        if (signature == _signature)
        {
            return;
        }

        _signature = signature;
        _rows.Children.Clear();

        foreach (var preset in presets)
        {
            var isActive = dns.ActivePresetId == preset.Id;
            var isApplying = dns.ApplyingPresetId == preset.Id;

            var mark = Ui.Icon(isActive ? Glyph.CheckCircle : Glyph.Circle, 13, isActive ? Ui.Green : Ui.Secondary);
            mark.Width = 18;
            mark.Margin = new Thickness(0, 0, 8, 0);

            var displayName = _context.Settings.DnsPresetDisplayName(preset);
            var name = Ui.Label(displayName, 12, Ui.Text, isActive ? FontWeights.SemiBold : FontWeights.Normal);
            var servers = Ui.Label(EncryptedDnsText.Detail(preset), 10, Ui.Secondary);
            servers.TextTrimming = TextTrimming.CharacterEllipsis;

            var title = (FrameworkElement)name;
            if (preset.Encryption is { } encryption)
            {
                // Lock plus "DoH"/"DoT", as the macOS badge: an encrypted preset reads as one
                // at a glance. The tag is left off when the name already says it.
                var shortName = DnsTransports.ShortName(encryption.Transport);
                var badge = Ui.Row(Ui.Icon(Glyph.Lock, 9, Ui.Secondary));
                if (!displayName.Contains(shortName, StringComparison.Ordinal))
                {
                    var tag = Ui.Label(shortName, 9, Ui.Secondary);
                    tag.Margin = new Thickness(3, 0, 0, 0);
                    badge.Children.Add(tag);
                }

                badge.Margin = new Thickness(5, 0, 0, 0);
                badge.ToolTip = PopoverContext.L("Encrypted DNS");
                title = Ui.Row(name, badge);
            }

            var content = Ui.Columns(Ui.Auto, Ui.Star, Ui.Auto);
            content.Children.Add(mark.At(0));
            content.Children.Add(Ui.Column(title, servers).At(1));

            if (isApplying)
            {
                var busy = Ui.Icon(Glyph.Refresh, 11, Ui.Secondary);
                busy.Opacity = 0.6;
                content.Children.Add(busy.At(2));
            }

            var row = Ui.RowButton(content, () => _ = dns.ApplyAsync(preset));
            row.IsEnabled = !isActive && !dns.IsApplying && dns.AdapterName is not null;

            if (isActive)
            {
                row.SetResourceReference(Control.BackgroundProperty, "PopoverAccentSoftBrush");
            }

            _rows.Children.Add(row);
        }
    }

    /// <summary>The helper the last pick needed, installed from right here (as Top Apps does).</summary>
    private async void InstallHelper()
    {
        if (_installing)
        {
            return;
        }

        _installing = true;
        Rebuild();

        var error = await HelperSetup.InstallAsync();
        _installing = false;

        if (error is null)
        {
            await _context.Helper.ProbeAsync(TimeSpan.FromSeconds(10));
            _context.Dns.ClearError();
        }

        Rebuild();
        if (error is not null)
        {
            // After the rebuild, which would put the pick's own message back.
            _errorText.Text = error;
        }
    }
}
