// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using NetFluss.App.Popover;
using NetFluss.Core;

namespace NetFluss.App;

/// <summary>
/// The popover: every enabled section in the user's order, between a pin button and a
/// footer. Port of the macOS <c>MenuBarView</c> inside its <c>NSPopover</c>.
///
/// <para><b>Height.</b> The popover hugs its content and grows up to a limit, as the macOS
/// one does: dragging the bottom edge sets the limit rather than a fixed height, so a short
/// popover is never padded out with empty background and a long one scrolls.</para>
///
/// <para><b>Placement.</b> Beside whichever surface was clicked, on whichever edge the
/// taskbar is docked to, kept fully inside that monitor's work area — the Windows form of
/// the Mac's edge-aware placement under the status item.</para>
/// </summary>
public partial class PopoverWindow : Window
{
    /// <summary>Gap between the popover and the taskbar, matching Windows 11 flyouts.</summary>
    private const double EdgeMarginDips = 12;

    private readonly PopoverContext _context;
    private readonly List<IPopoverSection> _sections;
    private IReadOnlyList<PopoverSection> _shownOrder = [];
    private Rect _anchor;
    private TaskbarEdge _edge = TaskbarEdge.Bottom;
    private bool _keepOpen;
    private bool _active;
    private bool _heightDragged;

    /// <summary>The height limit is lifted for an edge drag in progress.</summary>
    private bool _limitLifted;

    internal PopoverWindow(PopoverContext context)
    {
        InitializeComponent();

        _context = context;
        _sections =
        [
            new TotalsSection(context),
            new AdaptersSection(context),
            new ConnectionSection(context),
            new DnsSection(context),
            new WifiSection(context),
            new TopAppsSection(context),
            new UsageSection(context),
            new TimerSection(context),
            new RouterSection(context),
            new VpnSection(context),
        ];

        Width = context.Settings.PopoverWidth;
        BuildFooter();

        PinButton.Click += (_, _) => TogglePin();
        FooterStatus.MouseLeftButtonUp += (_, _) =>
        {
            if (FooterStatus.Text.Length > 0)
            {
                Dismiss(_context.Commands.ShowAbout);
            }
        };

        // Pinned, the header is the title bar: drag it to move the window.
        Header.MouseLeftButtonDown += (_, e) =>
        {
            if (_context.Settings.PopoverPinned && e.ButtonState == MouseButtonState.Pressed)
            {
                DragMove();
                _context.Settings.PinnedLeft = Left;
                _context.Settings.PinnedTop = Top;
            }
        };

        // Dismiss-on-deactivate, matching NSPopover — except while pinned, and while a DNS
        // change is waiting on its UAC prompt, which takes the focus away by design.
        Deactivated += (_, _) =>
        {
            if (!IsVisible || _context.Settings.PopoverPinned || _keepOpen)
            {
                return;
            }

            HideAndNotify();
        };

        _context.Dns.ApplyingChanged += (_, applying) =>
        {
            _keepOpen = applying;
            if (!applying && IsVisible && !_context.Settings.PopoverPinned)
            {
                // Back from the elevation prompt: take focus again so clicking away still
                // dismisses the popover.
                Activate();
            }
        };

        _context.Monitor.Ticked += (_, _) => RefreshSections();
        SizeChanged += (_, _) => KeepAnchored();

        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            RoundCorners(handle);
            HwndSource.FromHwnd(handle)?.AddHook(WndProc);
        };

        ApplyLayout();
    }

    /// <summary>Raised after a dismiss, so the tray toggle can suppress an instant reopen.</summary>
    public event EventHandler? Hidden;

    internal bool IsPinned => _context.Settings.PopoverPinned;

    /// <summary>
    /// Repaints for the selected theme. Card, divider and hover are derived from the palette
    /// rather than carried in it: they are the same surface lifted or dropped a little, and
    /// asking every theme to specify them would be four more chances to leave one out.
    /// </summary>
    public void ApplyTheme(SurfacePalette surface, ThemeColor download, ThemeColor upload)
    {
        ThemeBrushes.Apply(Resources, surface, download, upload);
        ThemeBrushes.ApplyFrame(this, surface.IsDark);
        _darkFrame = surface.IsDark;
    }

    private bool _darkFrame = true;

    /// <summary>Re-reads section order, visibility and size from the settings.</summary>
    internal void ApplyLayout()
    {
        var settings = _context.Settings;
        var order = settings.SectionOrder().Where(settings.IsSectionEnabled).ToList();

        if (!order.SequenceEqual(_shownOrder))
        {
            SectionHost.Children.Clear();
            foreach (var kind in order)
            {
                var section = _sections.FirstOrDefault(s => s.Kind == kind);
                if (section is null)
                {
                    continue;
                }

                if (SectionHost.Children.Count > 0)
                {
                    SectionHost.Children.Add(Ui.Divider());
                }

                SectionHost.Children.Add(section.View);
            }

            // Sections that left the popover stop sampling; ones that joined start, if open.
            foreach (var section in _sections)
            {
                section.SetActive(_active && order.Contains(section.Kind));
            }

            _shownOrder = order;
        }

        _context.Monitor.WantsCountry = settings.ConnectionMode == ConnectionDisplayMode.Flow || settings.ShowVpn;

        PinButton.Content = settings.PopoverPinned ? Glyph.Pinned : Glyph.Pin;
        PinButton.ToolTip = settings.PopoverPinned ? PopoverContext.L("Unpin window") : PopoverContext.L("Pin as window");
        if (settings.PopoverPinned)
        {
            PinButton.SetResourceReference(Control.ForegroundProperty, Ui.Accent);
        }
        else
        {
            PinButton.ClearValue(Control.ForegroundProperty);
        }

        PinnedTitle.Visibility = settings.PopoverPinned ? Visibility.Visible : Visibility.Collapsed;
        Header.Cursor = settings.PopoverPinned ? Cursors.SizeAll : null;

        RefreshSections();
    }

    /// <summary>Opens the popover beside <paramref name="anchor"/>, a rectangle in physical pixels.</summary>
    internal void ShowAt(Rect anchor)
    {
        _anchor = anchor;

        if (_context.Settings.PopoverPinned && _context.Settings.PinnedLeft is { } left && _context.Settings.PinnedTop is { } top)
        {
            ShowPinned(left, top);
            return;
        }

        PrepareHeightLimit(anchor);
        Show();
        RefreshSections();
        UpdateLayout();
        PlaceBesideAnchor();
        Activate();
        ActivateSectionsAfterFirstFrame();
    }

    /// <summary>
    /// Switching the sections on starts their lookups — the Wi-Fi radio and network list,
    /// addresses, DNS — which are synchronous Windows calls that can take a good part of a
    /// second with busy Wi-Fi or many virtual adapters. They used to run before the popover
    /// appeared; now it appears at once with what NetFluss already knows, and fills in.
    /// </summary>
    private void ActivateSectionsAfterFirstFrame()
        => Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, () =>
        {
            if (IsVisible)
            {
                SetSectionsActive(true);
            }
        });

    /// <summary>
    /// Lays the popover out off-screen, live but never activated, for <see cref="Snapshot"/>.
    /// </summary>
    internal void ShowOffScreen()
    {
        PrepareHeightLimit(DefaultSnapshotAnchor());
        SetSectionsActive(true);
        ShowActivated = false;
        Left = Snapshot.OffScreen;
        Top = Snapshot.OffScreen;
        Show();
    }

    /// <summary>For snapshots: scrolls to the end, or puts a section ("vpn") at the top.</summary>
    internal void ScrollTo(string target)
    {
        if (target == "bottom")
        {
            Scroller.ScrollToEnd();
        }
        else if (_sections.FirstOrDefault(s => s.Kind.ToString().Equals(target, StringComparison.OrdinalIgnoreCase)) is { View.IsLoaded: true } section)
        {
            var top = section.View.TransformToAncestor(SectionHost).Transform(default).Y;
            Scroller.ScrollToVerticalOffset(top);
        }

        UpdateLayout();
    }

    internal void HideOffScreen()
    {
        Hide();
        SetSectionsActive(false);
        ShowActivated = true;
    }

    private static Rect DefaultSnapshotAnchor()
        => Screens.MonitorFromPoint(0, 0) is { } info
            ? new Rect(info.Work.Right - 40, info.Work.Bottom - 8, 16, 8)
            : new Rect(0, 0, 16, 16);

    /// <summary>Shows the pinned window where it was left, kept on a monitor that still exists.</summary>
    private void ShowPinned(double left, double top)
    {
        Left = left;
        Top = top;
        Show();
        RefreshSections();
        ActivateSectionsAfterFirstFrame();
        UpdateLayout();

        // The monitor it was pinned on may be gone; bring it back to the nearest work area.
        var handle = new WindowInteropHelper(this).Handle;
        if (Screens.MonitorWorkArea(handle) is { } work)
        {
            var scale = Screens.DpiScale(handle);
            var widthPx = (int)Math.Round(ActualWidth * scale);
            var heightPx = (int)Math.Round(ActualHeight * scale);
            if (Screens.WindowRect(handle) is { } rect &&
                (rect.Left < work.Left || rect.Top < work.Top || rect.Right > work.Right || rect.Bottom > work.Bottom))
            {
                var x = Math.Clamp(rect.Left, work.Left, Math.Max(work.Left, work.Right - widthPx));
                var y = Math.Clamp(rect.Top, work.Top, Math.Max(work.Top, work.Bottom - heightPx));
                Screens.MoveWindow(handle, x, y);
            }
        }

        Activate();
    }

    private void SetSectionsActive(bool active)
    {
        if (_active == active)
        {
            return;
        }

        _active = active;
        _context.Monitor.DetailMonitoring = active;

        foreach (var section in _sections)
        {
            section.SetActive(active && _shownOrder.Contains(section.Kind));
        }

        if (active)
        {
            RefreshSections();
        }
    }

    internal void HideAndNotify()
    {
        Hide();
        SetSectionsActive(false);
        Hidden?.Invoke(this, EventArgs.Empty);
    }

    private void TogglePin()
    {
        var pin = !_context.Settings.PopoverPinned;
        _context.Store.Batch(settings =>
        {
            settings.PopoverPinned = pin;
            if (pin)
            {
                settings.PinnedLeft = Left;
                settings.PinnedTop = Top;
            }
        });

        ApplyLayout();

        if (!pin)
        {
            // Unpinning turns it back into a popover, which belongs beside its anchor.
            PlaceBesideAnchor();
            Activate();
        }
    }

    private void RefreshSections()
    {
        if (!IsVisible && !_active)
        {
            return;
        }

        foreach (var section in _sections)
        {
            if (_shownOrder.Contains(section.Kind))
            {
                section.Refresh();
            }
        }
    }

    private void BuildFooter()
    {
        var commands = _context.Commands;

        Button Add(string glyph, string tooltip, Action action)
        {
            var button = Ui.IconButton(glyph, tooltip, action, 13);
            button.Width = 30;
            button.Height = 28;
            FooterButtons.Children.Add(button);
            return button;
        }

        Add(Glyph.Chart, PopoverContext.L("Bandwidth Statistics"), () => Dismiss(commands.ShowStatistics));
        Add(Glyph.Speed, PopoverContext.L("Speed Test…"), () => Dismiss(commands.ShowSpeedTest));
        Add(Glyph.Settings, PopoverContext.L("Preferences"), () => Dismiss(commands.ShowPreferences));

        Button? more = null;
        more = Add(Glyph.More, PopoverContext.L("More"), () =>
        {
            var menu = SurfaceMenu.Build(commands);
            menu.PlacementTarget = more;
            menu.Placement = System.Windows.Controls.Primitives.PlacementMode.Top;
            menu.IsOpen = true;
        });
    }

    /// <summary>Closes the (unpinned) popover before opening a window, so it does not sit on top of it.</summary>
    private void Dismiss(Action open)
    {
        if (!_context.Settings.PopoverPinned)
        {
            HideAndNotify();
        }

        open();
    }

    /// <summary>Footer status line, used for an available update.</summary>
    internal void SetFooterStatus(string? text)
    {
        FooterStatus.Text = text ?? string.Empty;
        FooterStatus.Cursor = string.IsNullOrEmpty(text) ? null : Cursors.Hand;
        FooterStatus.SetResourceReference(TextBlock.ForegroundProperty, string.IsNullOrEmpty(text) ? Ui.Tertiary : Ui.Accent);
    }

    // ================================ Placement ================================

    private void PrepareHeightLimit(Rect anchor)
    {
        var monitor = Screens.MonitorFromPoint((int)(anchor.Left + (anchor.Width / 2)), (int)(anchor.Top + (anchor.Height / 2)));
        if (monitor is not { } info)
        {
            return;
        }

        var scale = info.Dpi / 96.0;
        var available = ((info.Work.Bottom - info.Work.Top) / scale) - (2 * EdgeMarginDips);
        MaxHeight = Math.Max(MinHeight, Math.Min(_context.Settings.PopoverHeight, available));
        _edge = info.Edge;
    }

    private void PlaceBesideAnchor()
    {
        var handle = new WindowInteropHelper(this).Handle;
        var monitor = Screens.MonitorFromPoint((int)(_anchor.Left + (_anchor.Width / 2)), (int)(_anchor.Top + (_anchor.Height / 2)));
        if (handle == nint.Zero || monitor is not { } info || Screens.WindowRect(handle) is not { } rect)
        {
            return;
        }

        _edge = info.Edge;
        var work = info.Work;
        var scale = info.Dpi / 96.0;
        var margin = (int)Math.Round(EdgeMarginDips * scale);
        var width = rect.Right - rect.Left;
        var height = rect.Bottom - rect.Top;
        var centreX = (int)(_anchor.Left + (_anchor.Width / 2));
        var centreY = (int)(_anchor.Top + (_anchor.Height / 2));

        int x, y;
        switch (_edge)
        {
            case TaskbarEdge.Top:
                x = Math.Clamp(centreX - (width / 2), work.Left + margin, Math.Max(work.Left + margin, work.Right - width - margin));
                y = work.Top + margin;
                break;
            case TaskbarEdge.Left:
                x = work.Left + margin;
                y = Math.Clamp(centreY - (height / 2), work.Top + margin, Math.Max(work.Top + margin, work.Bottom - height - margin));
                break;
            case TaskbarEdge.Right:
                x = work.Right - width - margin;
                y = Math.Clamp(centreY - (height / 2), work.Top + margin, Math.Max(work.Top + margin, work.Bottom - height - margin));
                break;
            default:
                x = Math.Clamp(centreX - (width / 2), work.Left + margin, Math.Max(work.Left + margin, work.Right - width - margin));
                y = work.Bottom - height - margin;
                break;
        }

        Screens.MoveWindow(handle, x, y);
    }

    /// <summary>
    /// Keeps a bottom-docked popover's bottom edge fixed as its content grows or shrinks —
    /// a Wi-Fi list arriving should push the popover up, away from the taskbar, not down
    /// underneath it.
    /// </summary>
    private void KeepAnchored()
    {
        if (!IsVisible || _context.Settings.PopoverPinned || _edge != TaskbarEdge.Bottom || _heightDragged)
        {
            return;
        }

        PlaceBesideAnchor();
    }

    private nint WndProc(nint hwnd, int msg, nint wParam, nint lParam, ref bool handled)
    {
        const int WmNcLButtonDown = 0x00A1;
        const int WmSizing = 0x0214;
        const int WmExitSizeMove = 0x0232;

        switch (msg)
        {
            case WmNcLButtonDown:
                // HTTOP (12) .. HTBOTTOMRIGHT (17): a press on an edge that sizes vertically. It
                // comes before the sizing loop, which reads the size limits once as it starts.
                if (wParam.ToInt32() is >= 12 and <= 17)
                {
                    LiftHeightLimit();
                }

                break;

            case WmSizing:
                // WMSZ_TOP (3) .. WMSZ_BOTTOMRIGHT (8): any edge that moves vertically.
                var edge = wParam.ToInt32();
                if (edge >= 3)
                {
                    _heightDragged = true;
                }

                break;

            case WmExitSizeMove:
                OnResizeFinished();
                break;
        }

        return nint.Zero;
    }

    /// <summary>
    /// The saved height is the popover's MaxHeight, which would stop a drag from making it
    /// any taller — only shorter. For the drag the limit becomes the work area, and the
    /// window stops sizing itself to its content, so the edge follows the pointer.
    /// </summary>
    private void LiftHeightLimit()
    {
        if (_limitLifted)
        {
            return;
        }

        _limitLifted = true;
        Height = ActualHeight;
        SizeToContent = SizeToContent.Manual;
        MaxHeight = Math.Max(MinHeight, WorkAreaHeight());
    }

    /// <summary>The most the popover can be on the monitor it is on, in DIPs.</summary>
    private double WorkAreaHeight()
    {
        var handle = new WindowInteropHelper(this).Handle;
        return handle != nint.Zero && Screens.MonitorWorkArea(handle) is { } work
            ? ((work.Bottom - work.Top) / Screens.DpiScale(handle)) - (2 * EdgeMarginDips)
            : double.PositiveInfinity;
    }

    /// <summary>
    /// Persists a resize. A vertical drag sets the height limit and hands sizing back to the
    /// content; a horizontal one only changes the width. Saved once at the end of the drag,
    /// not per pointer move.
    /// </summary>
    private void OnResizeFinished()
    {
        var height = ActualHeight;
        var vertical = _heightDragged;
        _heightDragged = false;

        _context.Store.Batch(settings =>
        {
            settings.PopoverWidth = ActualWidth;
            if (vertical)
            {
                settings.PopoverHeight = height;
            }
        });

        // Back to hugging the content, under the new limit — or the old one, after a press
        // that only changed the width or did not move at all.
        _limitLifted = false;
        MaxHeight = Math.Max(MinHeight, Math.Min(_context.Settings.PopoverHeight, WorkAreaHeight()));
        SizeToContent = SizeToContent.Height;
    }

    private static void RoundCorners(nint handle)
    {
        const int DwmwaWindowCornerPreference = 33;
        const int DwmwcpRound = 2;

        try
        {
            var preference = DwmwcpRound;
            _ = DwmSetWindowAttribute(handle, DwmwaWindowCornerPreference, ref preference, sizeof(int));
        }
        catch (DllNotFoundException)
        {
        }
    }

    private const int DwmwaUseImmersiveDarkMode = 20;

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);

    /// <summary>
    /// Alt+F4 hides rather than closes. There is one popover for the life of the app; once
    /// closed, WPF refuses to show it again, so every later click failed silently — while the
    /// sections it had switched on (Wi-Fi scans, router polling, the traffic trace) ran on,
    /// because hiding is what switches them off. Shutdown still closes it: WPF ignores Cancel
    /// while the application exits.
    /// </summary>
    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        e.Cancel = true;
        HideAndNotify();
        base.OnClosing(e);
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var handle = new WindowInteropHelper(this).Handle;
        var dark = _darkFrame ? 1 : 0;
        _ = DwmSetWindowAttribute(handle, DwmwaUseImmersiveDarkMode, ref dark, sizeof(int));
    }
}
