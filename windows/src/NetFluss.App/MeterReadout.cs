// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using NetFluss.Core;

namespace NetFluss.App;

/// <summary>
/// The rate readout used by the taskbar overlay and the floating widget.
///
/// <para>This is the thing the notification area cannot give us. Freed from a 16 px square,
/// the rates can be laid out the way the macOS menu bar lays them out — full units, real
/// hinted text, arrows that cost nothing because there is width to spare.</para>
///
/// <para>Built in code rather than XAML because both hosts size themselves around it and
/// need to measure it before they have a window to lay out in.</para>
/// </summary>
internal sealed class MeterReadout : UserControl
{
    private readonly TextBlock _downloadText = new();
    private readonly TextBlock _uploadText = new();
    private readonly TextBlock _downloadArrow = new() { Text = "↓" };
    private readonly TextBlock _uploadArrow = new() { Text = "↑" };
    private readonly Grid _root = new();

    private ReadoutStyle _style = ReadoutStyle.Unified;

    // The Dashboard styles' own parts: a dark capsule, the ring, and compact numbers.
    private readonly Border _capsule = new()
    {
        CornerRadius = new CornerRadius(10),
        BorderThickness = new Thickness(1),
        Padding = new Thickness(8, 1, 8, 1),
        VerticalAlignment = VerticalAlignment.Center,
        Background = Frozen(Color.FromArgb(0xC7, 0, 0, 0)),
        BorderBrush = Frozen(Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF)),
    };

    private readonly RingGauge _ring = new();
    private readonly TextBlock _dashTotal = new();
    private readonly TextBlock _dashDown = new();
    private readonly TextBlock _dashUp = new();
    private readonly DashboardRing _ringProgress = new();
    private Color _downloadColor = Colors.DodgerBlue;
    private Color _uploadColor = Colors.SeaGreen;

    /// <summary>The VPN mark and exit country, right of the rates — the 2.6 menu bar accessories.</summary>
    private readonly StackPanel _accessories = new()
    {
        Orientation = Orientation.Horizontal,
        VerticalAlignment = VerticalAlignment.Center,
        Margin = new Thickness(6, 0, 0, 0),
    };

    private double _fontSize = 11;

    /// <summary>"left", "center" or "right" — see <see cref="AppSettings.RateAlignment"/>.</summary>
    private string _alignment = "center";

    /// <summary>
    /// The widest rate a slot ever has to hold. Consolas is monospaced, so the longest string
    /// sets the width; "99.9 MB/s" is the longest the formatter produces.
    /// </summary>
    private static readonly string[] RateSamples = ["99.9 MB/s", "9.99 GB/s", "99.9 Mb/s", "999 KB/s"];

    /// <summary>The widest compact Dashboard figure.</summary>
    private static readonly string[] CompactSamples = ["99.9", "9.99", "999"];

    internal MeterReadout()
    {
        Focusable = false;
        IsTabStop = false;

        foreach (var block in new[] { _downloadArrow, _downloadText, _uploadArrow, _uploadText })
        {
            block.VerticalAlignment = VerticalAlignment.Center;
            TextOptions.SetTextFormattingMode(block, TextFormattingMode.Display);
            TextOptions.SetTextRenderingMode(block, TextRenderingMode.ClearType);
        }

        // Tabular figures, so the numbers do not jitter sideways every tick as digits change
        // width. The macOS side gets this from the monospaced font design setting.
        var tabular = new FontFamily("Consolas, Cascadia Mono, Segoe UI");
        _downloadText.FontFamily = tabular;
        _uploadText.FontFamily = tabular;

        // The rates in one column, the accessories in the next, so a mark never shifts the
        // numbers' own alignment and disappears without leaving a gap.
        var outer = new Grid();
        outer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        outer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(_root, 0);
        Grid.SetColumn(_accessories, 1);
        outer.Children.Add(_root);
        outer.Children.Add(_accessories);

        Content = outer;
        BuildLayout();

        // The rates are drawn, not text a screen reader would otherwise find: name the meter,
        // and keep the readings in ItemStatus, which Narrator reads alongside the name.
        System.Windows.Automation.AutomationProperties.SetName(this, "NetFluss");
    }

    /// <summary>
    /// How the rates sit in their column (macOS 2.7.1). Centred re-centres on every width
    /// change, so the arrows slide whenever "0.00 B/s" becomes "1.02 KB/s"; Left and Right
    /// give each number a fixed-width slot so the arrows stay put, and Right also lines the
    /// numbers up so the units stay put too.
    /// </summary>
    internal string Alignment
    {
        get => _alignment;
        set
        {
            var normalized = value is "left" or "right" ? value : "center";
            if (_alignment == normalized)
            {
                return;
            }

            _alignment = normalized;
            BuildLayout();
        }
    }

    /// <summary>
    /// Shows the marks after the rates, in the macOS 2.7 order — link, VPN, country, resolver —
    /// or clears them.
    ///
    /// <para>The country is shown as its ISO code in a small badge where macOS draws the flag
    /// emoji: Windows' emoji font has no flags and would render two boxed letters.</para>
    /// </summary>
    internal void SetAccessories(MeterAccessories? accessories)
    {
        _accessories.Children.Clear();
        _accessorySummary = string.Empty;
        if (accessories is null)
        {
            _accessories.Visibility = Visibility.Collapsed;
            AccessoriesWidth = 0;
            UpdateAutomationStatus();
            return;
        }

        var summary = new List<string>();
        var size = accessories.MarkSize;

        void Add(FrameworkElement element)
        {
            element.VerticalAlignment = VerticalAlignment.Center;
            element.Margin = new Thickness(_accessories.Children.Count > 0 ? 5 : 0, 0, 0, 0);
            _accessories.Children.Add(element);
        }

        if (accessories.Link is { } link)
        {
            var state = Localization.L(link.Health switch
            {
                LinkHealth.Online => "Online",
                LinkHealth.Limited => "Limited connection",
                _ => "Offline",
            });

            // The state in words as well as colour, for anyone who cannot tell the three apart.
            var name = link.Ssid ?? link.InterfaceName;
            var tooltip = string.IsNullOrEmpty(name) ? state : $"{name}: {state}";
            var mark = LinkMark(link, accessories.LinkColor, size);
            mark.ToolTip = tooltip;
            Add(mark);
            summary.Add(tooltip);
        }

        if (accessories.VpnKind is { } kind)
        {
            var mark = VpnMark(kind, accessories.VpnActive, accessories.VpnColor, size);
            var state = Localization.L(accessories.VpnActive ? "VPN connected" : "No VPN connected");
            mark.ToolTip = state;
            Add(mark);
            summary.Add(state);
        }

        if (!string.IsNullOrEmpty(accessories.Country))
        {
            Add(new Border
            {
                Child = new TextBlock
                {
                    Text = accessories.Country,
                    FontSize = Math.Max(8, Math.Round(size * 0.7)),
                    FontWeight = FontWeights.SemiBold,
                    Foreground = Freeze(accessories.IdleColor),
                    VerticalAlignment = VerticalAlignment.Center,
                },
                CornerRadius = new CornerRadius(3),
                Padding = new Thickness(3, 0, 3, 0),
                BorderThickness = new Thickness(1),
                BorderBrush = Freeze(accessories.IdleColor, 0x66),
            });
            summary.Add(accessories.Country);
        }

        if (!string.IsNullOrEmpty(accessories.Resolver))
        {
            Add(new TextBlock
            {
                Text = accessories.Resolver,
                FontSize = Math.Max(9, size - 4),
                FontWeight = FontWeights.Medium,
                Foreground = Freeze(accessories.ResolverColor),
                ToolTip = "DNS: " + accessories.Resolver,
            });
            summary.Add("DNS " + accessories.Resolver);
        }

        _accessories.Visibility = _accessories.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        // Measured, not estimated: four mark styles, a code badge and a free-length resolver
        // name make any formula wrong for somebody, and a host sized too small clips the end.
        _accessories.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        AccessoriesWidth = _accessories.DesiredSize.Width + _accessories.Margin.Left;
        _accessorySummary = string.Join(", ", summary);
        UpdateAutomationStatus();
    }

    /// <summary>Width the accessories currently need, in DIPs, so the hosts can size around them.</summary>
    internal double AccessoriesWidth { get; private set; }

    private string _accessorySummary = string.Empty;
    private string _rateSummary = string.Empty;

    private void UpdateAutomationStatus()
        => System.Windows.Automation.AutomationProperties.SetItemStatus(
            this,
            string.IsNullOrEmpty(_accessorySummary) ? _rateSummary : $"{_rateSummary}. {_accessorySummary}");

    /// <summary>
    /// The Wi-Fi, cable or network glyph in the state's colour. Limited carries an "!" badge
    /// and offline a slash, so the state is in the shape too and never in colour alone.
    /// </summary>
    private static FrameworkElement LinkMark(LinkStatus link, ThemeColor color, double size)
    {
        var brush = Freeze(color);
        var grid = new Grid { Width = size + 2, Height = size + 2 };
        grid.Children.Add(new TextBlock
        {
            Text = link.Medium switch
            {
                LinkMedium.WiFi => Glyph.Wifi,
                LinkMedium.Ethernet => Glyph.Ethernet,
                _ => Glyph.Network,
            },
            FontFamily = Ui.IconFont,
            FontSize = size,
            Foreground = brush,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        });

        if (link.Health == LinkHealth.Limited)
        {
            grid.Children.Add(new TextBlock
            {
                Text = "!",
                FontSize = Math.Max(7, size * 0.62),
                FontWeight = FontWeights.Black,
                Foreground = brush,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Bottom,
                Margin = new Thickness(0, 0, -size * 0.18, -size * 0.12),
            });
        }
        else if (link.Health == LinkHealth.Offline)
        {
            grid.Children.Add(Slash(brush, size + 2));
        }

        return grid;
    }

    /// <summary>
    /// The four VPN styles, sized independently of the rates. The chosen colour applies in both
    /// states, dimmed to 45 % while the tunnel is down — the hollow dot, outline shield, slashed
    /// globe and part-cut bars already say "off", and a swatch that only showed with a tunnel up
    /// looked broken to anyone configuring it without one.
    /// </summary>
    private static FrameworkElement VpnMark(string kind, bool active, ThemeColor color, double size)
    {
        var brush = Freeze(color, active ? (byte)0xFF : (byte)0x73);

        switch (kind)
        {
            case "dot":
                var diameter = Math.Max(5, Math.Round(size * 0.6));
                return new System.Windows.Shapes.Ellipse
                {
                    Width = diameter,
                    Height = diameter,
                    Fill = active ? brush : Brushes.Transparent,
                    Stroke = active ? null : brush,
                    StrokeThickness = 1.5,
                };

            case "globe":
                var globe = new Grid { Width = size + 3, Height = size + 2 };
                globe.Children.Add(new TextBlock
                {
                    Text = Glyph.Globe,
                    FontFamily = Ui.IconFont,
                    FontSize = size,
                    Foreground = brush,
                    HorizontalAlignment = HorizontalAlignment.Left,
                    VerticalAlignment = VerticalAlignment.Center,
                });

                if (active)
                {
                    // A shield badge in the corner: macOS's network.badge.shield.half.filled.
                    globe.Children.Add(new TextBlock
                    {
                        Text = Glyph.Shield,
                        FontFamily = Ui.IconFont,
                        FontSize = Math.Max(6, size * 0.55),
                        FontWeight = FontWeights.Bold,
                        Foreground = brush,
                        HorizontalAlignment = HorizontalAlignment.Right,
                        VerticalAlignment = VerticalAlignment.Bottom,
                    });
                }
                else
                {
                    globe.Children.Add(Slash(brush, size + 2));
                }

                return globe;

            case "bars":
                return BarsMark(brush, active, size);

            default:
                return new TextBlock
                {
                    Text = active ? Glyph.Vpn : Glyph.Shield,
                    FontFamily = Ui.IconFont,
                    FontSize = size,
                    Foreground = brush,
                };
        }
    }

    /// <summary>
    /// The "Bars" style: macOS's own VPN menu artwork — a rounded frame with four bars cut into
    /// it, fully when connected and part-way when not. macOS reads the artwork from its VPN menu
    /// extra; Windows has no such file, so this is the drawn copy the Mac also carries.
    /// </summary>
    private static FrameworkElement BarsMark(Brush brush, bool active, double height)
    {
        var width = Math.Round(height * 18 / 14);
        var frame = new Rect(0, height * 0.07, width, height * 0.86);
        var inner = new Rect(
            frame.X + (frame.Width * 0.2),
            frame.Y + (frame.Height * 0.28),
            frame.Width * 0.6,
            frame.Height * 0.44);
        var gap = inner.Width * 0.12;
        var barWidth = (inner.Width - (gap * 3)) / 4;

        var bars = new GeometryGroup();
        for (var index = 0; index < 4; index++)
        {
            bars.Children.Add(new RectangleGeometry(new Rect(inner.X + (index * (barWidth + gap)), inner.Y, barWidth, inner.Height)));
        }

        bars.Freeze();

        // Even-odd: each bar inside the frame becomes a hole.
        var cut = new GeometryGroup { FillRule = FillRule.EvenOdd };
        cut.Children.Add(new RectangleGeometry(frame, frame.Height * 0.3, frame.Height * 0.3));
        cut.Children.Add(bars);
        cut.Freeze();

        var canvas = new Grid { Width = width, Height = height };
        canvas.Children.Add(new System.Windows.Shapes.Path { Data = cut, Fill = brush });

        if (!active)
        {
            // Off only cuts part-way: the bars keep 40 % of the frame's colour.
            canvas.Children.Add(new System.Windows.Shapes.Path { Data = bars, Fill = brush, Opacity = 0.4 });
        }

        return canvas;
    }

    private static System.Windows.Shapes.Line Slash(Brush brush, double size)
        => new()
        {
            X1 = size * 0.08,
            Y1 = size * 0.92,
            X2 = size * 0.92,
            Y2 = size * 0.08,
            Stroke = brush,
            StrokeThickness = Math.Max(1.2, size / 10),
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
        };

    internal ReadoutStyle Layout
    {
        get => _style;
        set
        {
            if (_style == value)
            {
                return;
            }

            _style = value;
            BuildLayout();
        }
    }

    internal void ApplyAppearance(double fontSize, ThemeColor download, ThemeColor upload, ThemeColor secondary)
    {
        _fontSize = fontSize;
        var downloadBrush = Freeze(download);
        var uploadBrush = Freeze(upload);
        var secondaryBrush = Freeze(secondary);

        _downloadText.Foreground = downloadBrush;
        _uploadText.Foreground = uploadBrush;
        _downloadArrow.Foreground = downloadBrush;
        _uploadArrow.Foreground = uploadBrush;

        // The stacked style halves the line height, so it needs a smaller face to fit the
        // same taskbar; the macOS stack style does exactly this.
        var effective = _style == ReadoutStyle.Stacked ? Math.Max(8, fontSize - 2) : fontSize;

        foreach (var block in new[] { _downloadText, _uploadText })
        {
            block.FontSize = effective;
        }

        foreach (var block in new[] { _downloadArrow, _uploadArrow })
        {
            block.FontSize = Math.Max(8, effective - 1);
        }

        // The macOS dashboard: numbers a point smaller, the total a point larger and semibold.
        _downloadColor = Color.FromRgb(download.R, download.G, download.B);
        _uploadColor = Color.FromRgb(upload.R, upload.G, upload.B);
        _dashDown.FontSize = _dashUp.FontSize = Math.Max(8, fontSize - 1);
        _dashTotal.FontSize = Math.Min(18, fontSize + 1);
        _ring.Width = _ring.Height = Math.Max(12, Math.Round((fontSize - 1) * 1.35) + 1);

        // Every style, not just the Dashboards: a fixed-width rate slot is sized from the font,
        // so a size change has to remeasure it.
        BuildLayout();

        _ = secondaryBrush;
    }

    internal void Update(RateTotals totals, bool useBits, DashboardMetrics? dashboard = null)
    {
        if (_style is ReadoutStyle.Dashboard or ReadoutStyle.DashboardBasic)
        {
            UpdateDashboard(dashboard ?? DashboardMetrics.Local(totals), useBits);
            return;
        }
        string summary;
        if (_style == ReadoutStyle.Total)
        {
            _downloadText.Text = RateFormatter.FormatRate(totals.RxRateBps + totals.TxRateBps, useBits);
            summary = _downloadText.Text;
        }
        else
        {
            _downloadText.Text = RateFormatter.FormatRate(totals.RxRateBps, useBits);
            _uploadText.Text = RateFormatter.FormatRate(totals.TxRateBps, useBits);
            summary = $"{Localization.L("Download")} {_downloadText.Text}, {Localization.L("Upload")} {_uploadText.Text}";
        }

        if (summary != _rateSummary)
        {
            _rateSummary = summary;
            UpdateAutomationStatus();
        }
    }

    private void BuildLayout()
    {
        _root.Children.Clear();
        _root.ColumnDefinitions.Clear();
        _root.RowDefinitions.Clear();

        switch (_style)
        {
            case ReadoutStyle.Dashboard or ReadoutStyle.DashboardBasic:
                _root.Children.Add(BuildDashboard());
                break;

            case ReadoutStyle.Total:
                var total = Row(_downloadArrow, _downloadText, showArrow: false);
                total.HorizontalAlignment = HorizontalAlignment.Right;
                _root.Children.Add(total);
                break;

            case ReadoutStyle.Stacked:
                // One tight block, centred on the taskbar's height. Two star-height rows put
                // each line in its own half of the bar — pushed to the top and bottom edges with
                // a band of nothing between them, which read as two unrelated numbers.
                var stack = new StackPanel
                {
                    Orientation = Orientation.Vertical,
                    VerticalAlignment = VerticalAlignment.Center,
                    HorizontalAlignment = HorizontalAlignment.Right,
                };

                // Upload above download, matching the tray meter.
                stack.Children.Add(Row(_uploadArrow, _uploadText, showArrow: true));
                stack.Children.Add(Row(_downloadArrow, _downloadText, showArrow: true));
                _root.Children.Add(stack);
                break;

            default:
                var unified = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    VerticalAlignment = VerticalAlignment.Center,
                    HorizontalAlignment = HorizontalAlignment.Right,
                };

                unified.Children.Add(Row(_uploadArrow, _uploadText, showArrow: true));
                unified.Children.Add(new FrameworkElement { Width = UnifiedGap });
                unified.Children.Add(Row(_downloadArrow, _downloadText, showArrow: true));
                _root.Children.Add(unified);
                break;
        }

        RatesWidth = MeasureRates();
    }

    private const double UnifiedGap = 12;

    private const double ArrowGap = 3;

    /// <summary>
    /// The width the rates need at their widest — "↑ 99.9 MB/s" — so the taskbar overlay can
    /// be exactly that wide instead of guessing from the font size and leaving a band of empty
    /// taskbar beside the numbers. NaN for the Dashboards, which size themselves.
    /// </summary>
    internal double RatesWidth { get; private set; } = double.NaN;

    private double MeasureRates()
    {
        if (_style is ReadoutStyle.Dashboard or ReadoutStyle.DashboardBasic)
        {
            return double.NaN;
        }

        var number = Widest(_downloadText, RateSamples);
        if (_style == ReadoutStyle.Total)
        {
            return number;
        }

        var rate = Widest(_uploadArrow, ["↑", "↓"]) + ArrowGap + number;
        return _style == ReadoutStyle.Stacked ? rate : (2 * rate) + UnifiedGap;
    }

    /// <summary>
    /// The width of a rate slot when the alignment fixes it, or NaN for Centred, which sizes
    /// to the text. Measured in the slot's own font, so it holds at every size.
    /// </summary>
    private double SlotWidth(TextBlock prototype, string[] samples)
    {
        return _alignment == "center" ? double.NaN : Widest(prototype, samples);
    }

    /// <summary>The width of the widest sample in <paramref name="prototype"/>'s font.</summary>
    private static double Widest(TextBlock prototype, string[] samples)
    {
        var typeface = new Typeface(prototype.FontFamily, prototype.FontStyle, prototype.FontWeight, prototype.FontStretch);
        var widest = 0.0;
        foreach (var sample in samples)
        {
            var text = new FormattedText(
                sample,
                System.Globalization.CultureInfo.InvariantCulture,
                FlowDirection.LeftToRight,
                typeface,
                prototype.FontSize,
                Brushes.Black,
                1.0);
            widest = Math.Max(widest, text.WidthIncludingTrailingWhitespace);
        }

        return Math.Ceiling(widest) + 1;
    }

    /// <summary>"◔  Σ 12.4  |  ↓ 11.0  |  ↑ 1.4" in the capsule; Basic drops the ring and the total.</summary>
    private FrameworkElement BuildDashboard()
    {
        var white = Frozen(Color.FromArgb(0xF2, 0xFF, 0xFF, 0xFF));
        var dim = Frozen(Color.FromArgb(0x80, 0xFF, 0xFF, 0xFF));
        var size = Math.Max(8, _fontSize - 1);

        TextBlock Part(string text, Brush brush, double fontSize)
        {
            var block = new TextBlock { Text = text, Foreground = brush, FontSize = fontSize, VerticalAlignment = VerticalAlignment.Center };
            TextOptions.SetTextFormattingMode(block, TextFormattingMode.Display);
            return block;
        }

        foreach (var block in new[] { _dashTotal, _dashDown, _dashUp })
        {
            (block.Parent as Panel)?.Children.Remove(block);
            block.VerticalAlignment = VerticalAlignment.Center;
            block.FontFamily = _downloadText.FontFamily;
            TextOptions.SetTextFormattingMode(block, TextFormattingMode.Display);

            // Fixed slots here too: the capsule is centred, so a number changing width used
            // to slide the ring and every separator along with it.
            block.Width = SlotWidth(block, CompactSamples);
            block.TextAlignment = _alignment == "right" ? TextAlignment.Right : TextAlignment.Left;
        }

        (_ring.Parent as Panel)?.Children.Remove(_ring);
        _dashTotal.Foreground = white;
        _dashTotal.FontWeight = FontWeights.SemiBold;

        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (_style == ReadoutStyle.Dashboard)
        {
            _ring.Margin = new Thickness(0, 0, 6, 0);
            _ring.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(_ring);
            row.Children.Add(Part("Σ ", white, Math.Min(18, _fontSize + 1)));
            row.Children.Add(_dashTotal);
            row.Children.Add(Part("  |  ", dim, size));
        }

        row.Children.Add(Part("↓ ", Frozen(_downloadColor), size));
        row.Children.Add(_dashDown);
        row.Children.Add(Part("  |  ", dim, size));
        row.Children.Add(Part("↑ ", Frozen(_uploadColor), size));
        row.Children.Add(_dashUp);

        _capsule.Child = row;
        _capsule.HorizontalAlignment = HorizontalAlignment.Center;
        return _capsule;
    }

    private void UpdateDashboard(DashboardMetrics metrics, bool useBits)
    {
        var (total, down, up) = metrics.CompactTexts(useBits);
        _dashTotal.Text = total;
        _dashDown.Text = down;
        _dashUp.Text = up;
        _dashDown.Foreground = Frozen(_downloadColor);
        _dashUp.Foreground = Frozen(_uploadColor);
        _capsule.ToolTip = metrics.SourceKey.StartsWith("router:", StringComparison.Ordinal)
            ? Localization.L("Router traffic in {0}", metrics.Unit(useBits))
            : metrics.Unit(useBits);

        if (_style == ReadoutStyle.Dashboard)
        {
            // The ring blends from the download ink to the upload ink by upload's share.
            var share = metrics.Total > 0 ? metrics.Tx / metrics.Total : 0.5;
            _ring.Set(_ringProgress.Progress(metrics, DateTimeOffset.UtcNow), Blend(_downloadColor, _uploadColor, share));
        }
    }

    private static Color Blend(Color from, Color to, double amount)
    {
        byte Mix(byte a, byte b) => (byte)Math.Round(a + ((b - a) * Math.Clamp(amount, 0, 1)));
        return Color.FromRgb(Mix(from.R, to.R), Mix(from.G, to.G), Mix(from.B, to.B));
    }

    private static SolidColorBrush Frozen(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    /// <summary>
    /// One rate: the arrow, then the number in its slot. With a fixed slot both lines of the
    /// Stacked style are the same width, so their arrows share one column.
    /// </summary>
    private StackPanel Row(TextBlock arrow, TextBlock value, bool showArrow)
    {
        // Rebuild rather than reparent: a TextBlock can only have one parent, and these are
        // reused across layout changes when the user switches style.
        Detach(arrow);
        Detach(value);

        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = _alignment switch
            {
                "left" => HorizontalAlignment.Left,
                "right" => HorizontalAlignment.Right,
                _ => HorizontalAlignment.Center,
            },
        };

        if (showArrow)
        {
            arrow.Margin = new Thickness(0, 0, ArrowGap, 0);
            arrow.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(arrow);
        }

        var width = SlotWidth(value, RateSamples);
        if (double.IsNaN(width))
        {
            value.TextAlignment = TextAlignment.Left;
            row.Children.Add(value);
        }
        else
        {
            value.TextAlignment = _alignment == "right" ? TextAlignment.Right : TextAlignment.Left;
            row.Children.Add(new Border { Width = width, Child = value, VerticalAlignment = VerticalAlignment.Center });
        }

        return row;
    }

    private static void Detach(FrameworkElement element)
    {
        switch (element.Parent)
        {
            case Panel panel:
                panel.Children.Remove(element);
                break;
            case Border border:
                border.Child = null;
                break;
        }
    }

    private static SolidColorBrush Freeze(ThemeColor color, byte alpha = 0xFF)
    {
        var brush = new SolidColorBrush(Color.FromArgb(alpha, color.R, color.G, color.B));
        brush.Freeze();
        return brush;
    }
}

/// <summary>
/// What the meter shows after the rates, in the macOS 2.7 order: the link indicator, the VPN
/// mark, the exit country and the active resolver. Each is optional and independently set.
/// </summary>
internal sealed record MeterAccessories(
    LinkStatus? Link,
    ThemeColor LinkColor,
    string? VpnKind,
    bool VpnActive,
    ThemeColor VpnColor,
    double MarkSize,
    string? Country,
    ThemeColor IdleColor,
    string? Resolver,
    ThemeColor ResolverColor)
{
    /// <summary>
    /// Builds the accessories from the settings and the live state, or null when nothing is
    /// switched on — the overwhelmingly common case, which must cost nothing.
    /// </summary>
    /// <param name="resolverName">The active DNS profile's display name, or null when it is System Default.</param>
    internal static MeterAccessories? From(
        AppSettings settings,
        bool vpnActive,
        string? country,
        ThemeColor idle,
        LinkStatus? link,
        string? resolverName)
    {
        var showLink = settings.LinkIndicator && link is not null;
        var showVpn = settings.VpnIndicator != "off" && (vpnActive || settings.VpnShowWhenOff);

        // The country reads as the tunnel's exit, so it can be limited to the times one is up.
        var showCountry = settings.ShowCountryFlag && !string.IsNullOrEmpty(country) &&
                          (vpnActive || !settings.CountryFlagOnlyWithVpn);

        // Only while it is not System Default: quiet on a network left alone.
        var showResolver = settings.ShowResolver && !string.IsNullOrEmpty(resolverName);

        if (!showLink && !showVpn && !showCountry && !showResolver)
        {
            return null;
        }

        var green = ThemeColor.FromHex("2EA043");
        var vpnColor = AccentPalette.Resolve(settings.VpnIndicatorColor, settings.VpnIndicatorColorHex, green) ?? green;
        var resolverColor = AccentPalette.Resolve(settings.ResolverColor, settings.ResolverColorHex, idle) ?? idle;

        return new MeterAccessories(
            showLink ? link : null,
            showLink ? settings.ResolveLinkColor(link!.Health) : idle,
            showVpn ? settings.VpnIndicator : null,
            vpnActive,
            vpnColor,
            settings.VpnIndicatorSize,
            showCountry ? country : null,
            idle,
            showResolver ? resolverName : null,
            resolverColor);
    }
}

/// <summary>The Dashboard ring: a faint full circle and an arc clockwise from twelve o'clock.</summary>
internal sealed class RingGauge : FrameworkElement
{
    private double _progress;
    private Color _color = Colors.DodgerBlue;

    internal void Set(double progress, Color color)
    {
        if (Math.Abs(progress - _progress) < 0.005 && color == _color)
        {
            return;
        }

        _progress = progress;
        _color = color;
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        var size = Math.Min(ActualWidth, ActualHeight);
        if (size <= 4)
        {
            return;
        }

        const double Stroke = 2;
        var radius = (size / 2) - (Stroke / 2);
        var center = new Point(ActualWidth / 2, ActualHeight / 2);

        var track = new Pen(new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)), Stroke);
        track.Freeze();
        dc.DrawEllipse(null, track, center, radius, radius);

        if (_progress <= 0)
        {
            return;
        }

        var pen = new Pen(new SolidColorBrush(_color), Stroke) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        pen.Freeze();
        if (_progress >= 0.999)
        {
            dc.DrawEllipse(null, pen, center, radius, radius);
            return;
        }

        var angle = _progress * 2 * Math.PI;
        var start = new Point(center.X, center.Y - radius);
        var end = new Point(center.X + (radius * Math.Sin(angle)), center.Y - (radius * Math.Cos(angle)));
        var figure = new PathFigure { StartPoint = start, IsClosed = false };
        figure.Segments.Add(new ArcSegment(end, new Size(radius, radius), 0, _progress > 0.5, SweepDirection.Clockwise, true));
        var geometry = new PathGeometry([figure]);
        geometry.Freeze();
        dc.DrawGeometry(null, pen, geometry);
    }
}
