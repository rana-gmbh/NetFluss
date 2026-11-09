// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Windows;
using System.Windows.Controls;
using NetFluss.Core;

namespace NetFluss.App.Popover;

/// <summary>The DNS switcher — port of the macOS <c>DNSSwitcherSection</c>.</summary>
internal sealed class DnsSection : IPopoverSection
{
    private static readonly TimeSpan RereadInterval = TimeSpan.FromSeconds(30);

    private readonly PopoverContext _context;
    private readonly TextBlock _adapter;
    private readonly StackPanel _rows = new() { Margin = new Thickness(8, 0, 8, 0) };
    private readonly Grid _error;
    private readonly TextBlock _errorText;
    private DateTime _lastRead = DateTime.MinValue;
    private string _signature = string.Empty;

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
        var warning = Ui.Icon(Glyph.Warning, 11, Ui.Orange);
        warning.VerticalAlignment = VerticalAlignment.Top;
        warning.Margin = new Thickness(0, 2, 6, 0);
        _error = Ui.Columns(Ui.Auto, Ui.Star);
        _error.Margin = new Thickness(14, 4, 14, 0);
        _error.Children.Add(warning.At(0));
        _error.Children.Add(_errorText.At(1));

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
        var presets = _context.Settings.VisibleDnsPresets();

        _adapter.Text = dns.AdapterName ?? string.Empty;
        _errorText.Text = dns.Error ?? string.Empty;
        _error.Visibility = string.IsNullOrEmpty(dns.Error) ? Visibility.Collapsed : Visibility.Visible;

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

            var name = Ui.Label(_context.Settings.DnsPresetDisplayName(preset), 12, Ui.Text, isActive ? FontWeights.SemiBold : FontWeights.Normal);
            var servers = Ui.Label(
                preset.IsAutomatic ? PopoverContext.L("Automatic (DHCP)") : string.Join(", ", preset.Servers),
                10,
                Ui.Secondary);

            var content = Ui.Columns(Ui.Auto, Ui.Star, Ui.Auto);
            content.Children.Add(mark.At(0));
            content.Children.Add(Ui.Column(name, servers).At(1));

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
}
