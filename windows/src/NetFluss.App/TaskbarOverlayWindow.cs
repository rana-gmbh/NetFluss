// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using NetFluss.Core;

namespace NetFluss.App;

/// <summary>
/// A rate readout placed over the taskbar, beside the notification area.
///
/// <para>This is NetFluss's answer to the one thing Windows took away. macOS gives the meter
/// a variable-width <c>NSStatusItem</c>; Windows had the DeskBand API for the same job and
/// removed it in Windows 11 with no replacement, which is what killed NetSpeedMonitor. The
/// only remaining way to put a real "↓ 4.72 MB/s ↑ 834 KB/s" line on the taskbar is to find
/// the shell's own windows and place a topmost window over them.</para>
///
/// <para><b>Everything here is best-effort by construction.</b> The window sits on
/// undocumented geometry, so it re-anchors on every signal that the ground may have moved —
/// Explorer restarting, a display change, a DPI change, the taskbar auto-hiding — and hides
/// itself rather than guessing when the taskbar cannot be found. If it can never anchor, the
/// app falls back to the notification-area meter, which is why that meter still exists.</para>
/// </summary>
internal sealed class TaskbarOverlayWindow : Window
{
    /// <summary>
    /// Re-anchor cadence. The shell sends no notification for auto-hide sliding, taskbar
    /// resizing, or a tray icon appearing and pushing the free space along, so a slow poll
    /// is the only way to stay put. One second matches the meter's own tick, so this costs
    /// nothing measurable.
    /// </summary>
    private static readonly TimeSpan ReanchorInterval = TimeSpan.FromSeconds(1);

    private readonly MeterReadout _readout = new();
    private readonly DispatcherTimer _reanchor;
    private readonly NetworkMonitorService _monitor;

    private uint _taskbarCreatedMessage;
    private TaskbarPlacement? _placement;
    private int _desiredWidth = 150;
    private int _baseWidth = 150;
    private int _accessoryWidth;

    internal TaskbarOverlayWindow(NetworkMonitorService monitor)
    {
        _monitor = monitor;

        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        AllowsTransparency = true;

        // Very nearly transparent, and the "very nearly" is load-bearing.
        //
        // The taskbar may be acrylic, tinted by the wallpaper, or a flat colour, so only the
        // glyphs themselves should be painted. But AllowsTransparency makes this a layered
        // window, and a layered window does not hit-test pixels with zero alpha — a fully
        // transparent background means every click sails through to the taskbar underneath.
        // That silently cost the overlay both its left-click popover and its right-click
        // menu, which on a machine with the tray icon hidden left no way into Preferences
        // and no way to quit. One unit of alpha is invisible and hit-tests everywhere.
        Background = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0));
        Topmost = true;
        Focusable = false;
        ShowActivated = false;
        SizeToContent = SizeToContent.Manual;

        Content = _readout;

        // Left-click opens the popover, exactly as the tray icon does, so the two surfaces
        // behave the same way and neither has to be learned separately.
        MouseLeftButtonUp += (_, _) => Clicked?.Invoke(this, EventArgs.Empty);

        // Right-click has to open the full menu, not just Preferences. This may be the only
        // NetFluss surface on screen, so it is also the only way out of the app.
        MouseRightButtonUp += (_, e) =>
        {
            if (ContextMenu is null)
            {
                return;
            }

            // WS_EX_NOACTIVATE means this window never takes focus, and a WPF context menu
            // on an unfocusable owner closes itself the moment it opens. Placing it on the
            // mouse and letting it capture instead is what keeps it up.
            ContextMenu.Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint;
            ContextMenu.PlacementTarget = this;
            ContextMenu.IsOpen = true;
            e.Handled = true;
        };

        _reanchor = new DispatcherTimer(DispatcherPriority.Background) { Interval = ReanchorInterval };
        _reanchor.Tick += (_, _) => Reanchor();

        SourceInitialized += OnSourceInitialized;
    }

    /// <summary>Raised on left click, to toggle the popover.</summary>
    internal event EventHandler? Clicked;

    /// <summary>
    /// Raised when the taskbar cannot be anchored to at all, so the app can fall back to the
    /// notification-area meter instead of leaving the user with no meter.
    /// </summary>
    internal event EventHandler? AnchorLost;

    /// <summary>
    /// The taskbar is back after <see cref="AnchorLost"/> — or there for the first time, when
    /// NetFluss started before it. The app puts the tray icon back the way the meter wants it.
    /// </summary>
    internal event EventHandler? AnchorRegained;

    /// <summary>Not anchored yet, or lost: the next successful placement is a regain.</summary>
    private bool _unanchored = true;

    private bool _closed;

    /// <summary>True while the overlay is actually placed on the taskbar.</summary>
    internal bool IsAnchored => _placement is not null;

    internal void ApplySettings(AppSettings settings, ThemeColor download, ThemeColor upload)
    {
        _readout.Layout = settings.ReadoutStyle;
        _readout.ApplyAppearance(settings.ReadoutFontSize, download, upload, download);

        // Width follows the style and the type size: "↓ 999 MB/s ↑ 999 MB/s" needs room the
        // stacked layout does not, and a fixed width would either clip or waste taskbar.
        _baseWidth = settings.ReadoutStyle switch
        {
            ReadoutStyle.Total => (int)(settings.ReadoutFontSize * 8),
            ReadoutStyle.Dashboard => (int)(settings.ReadoutFontSize * 19),
            ReadoutStyle.DashboardBasic => (int)(settings.ReadoutFontSize * 12),
            ReadoutStyle.Stacked => (int)(settings.ReadoutFontSize * 9),
            _ => (int)(settings.ReadoutFontSize * 17),
        };
        _desiredWidth = _baseWidth + _accessoryWidth;

        Update(_monitor.Totals, settings.UseBits);
        Reanchor();
    }

    internal void Update(RateTotals totals, bool useBits, DashboardMetrics? dashboard = null) => _readout.Update(totals, useBits, dashboard);

    /// <summary>Shows or clears the VPN mark and country, widening the overlay to fit them.</summary>
    internal void SetAccessories(MeterAccessories? accessories, double fontSize)
    {
        _readout.SetAccessories(accessories);
        _accessoryWidth = (int)Math.Ceiling(MeterReadout.AccessoryWidth(accessories, fontSize));
        var width = _baseWidth + _accessoryWidth;
        if (width != _desiredWidth)
        {
            _desiredWidth = width;
            Reanchor();
        }
    }

    internal void Start()
    {
        Show();
        Reanchor();
        _reanchor.Start();
    }

    internal void Stop()
    {
        _reanchor.Stop();
        Hide();
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        var handle = new WindowInteropHelper(this).Handle;

        // WS_EX_TOOLWINDOW keeps it out of Alt-Tab; WS_EX_NOACTIVATE stops a click stealing
        // focus from whatever the user is typing in. Without the latter, clicking the meter
        // would deactivate their editor.
        var exStyle = GetWindowLong(handle, GwlExStyle);
        SetWindowLong(handle, GwlExStyle, exStyle | WsExToolWindow | WsExNoActivate);

        _taskbarCreatedMessage = TaskbarAnchor.TaskbarCreatedMessage();
        HwndSource.FromHwnd(handle)?.AddHook(WndProc);
    }

    private nint WndProc(nint hwnd, int msg, nint wParam, nint lParam, ref bool handled)
    {
        // Explorer restarted, the display changed, or this window moved to a monitor with a
        // different scale. Each of them invalidates the geometry the overlay is sitting on.
        if (msg == WmDisplayChange || msg == WmDpiChanged || (uint)msg == _taskbarCreatedMessage)
        {
            Dispatcher.BeginInvoke(Reanchor, DispatcherPriority.Background);
        }

        return nint.Zero;
    }

    private void Reanchor()
    {
        // Queued from a display change or a restarted Explorer, it can arrive after the meter
        // surface was switched and this window closed — where touching it throws.
        if (_closed)
        {
            return;
        }

        // Never paint over a game or a presentation. The overlay is topmost, so this is the
        // difference between a meter and a defect report.
        if (TaskbarAnchor.IsFullScreenAppActive())
        {
            Visibility = Visibility.Hidden;
            return;
        }

        var placement = TaskbarAnchor.Locate(_desiredWidth);
        if (placement is not { } target)
        {
            // Hidden rather than closed: an auto-hidden taskbar comes back, and so should the
            // meter. Only a placement that never succeeds is worth falling back over.
            Visibility = Visibility.Hidden;

            if (_placement is not null)
            {
                _placement = null;
                _unanchored = true;
                AnchorLost?.Invoke(this, EventArgs.Empty);
            }

            return;
        }

        _placement = target;
        Visibility = Visibility.Visible;

        if (_unanchored)
        {
            _unanchored = false;
            AnchorRegained?.Invoke(this, EventArgs.Empty);
        }

        var handle = new WindowInteropHelper(this).Handle;
        if (handle == nint.Zero)
        {
            return;
        }

        // Positioned in physical pixels through SetWindowPos rather than through Left/Top:
        // WPF's properties are device-independent units resolved against this window's own
        // DPI, which is precisely the value that is wrong while it is being moved between
        // monitors of different scale.
        SetWindowPos(
            handle,
            HwndTopmost,
            target.Left,
            target.Top,
            target.Width,
            target.Height,
            SwpNoActivate | SwpShowWindow);
    }

    protected override void OnClosed(EventArgs e)
    {
        _closed = true;
        _reanchor.Stop();
        base.OnClosed(e);
    }

    private const int GwlExStyle = -20;
    private const int WsExToolWindow = 0x00000080;
    private const int WsExNoActivate = 0x08000000;
    private const int WmDisplayChange = 0x007E;
    private const int WmDpiChanged = 0x02E0;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpShowWindow = 0x0040;
    private static readonly nint HwndTopmost = -1;

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern nint GetWindowLong(nint window, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static extern nint SetWindowLong(nint window, int index, nint value);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(nint window, nint insertAfter, int x, int y, int cx, int cy, uint flags);
}
