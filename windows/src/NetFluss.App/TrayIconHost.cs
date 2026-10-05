// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Drawing;
using System.Windows;
using System.Windows.Controls;
using H.NotifyIcon;
using NetFluss.Core;
using NetFluss.Tray;

namespace NetFluss.App;

/// <summary>
/// Owns the notification-area icon and repaints it on every monitor tick.
///
/// <para><b>The GDI contract.</b> <c>Bitmap.GetHicon()</c> hands back an unmanaged icon that
/// nothing will ever free for us. At one tick per second this leaks ~86,000 handles a day
/// and hits the 10,000-per-process GDI limit within three hours, at which point the app
/// stops drawing anything at all. So: assign the new icon first, then destroy the previous
/// handle — never the current one, which the shell is still painting from.</para>
/// </summary>
public sealed class TrayIconHost : IDisposable
{
    private readonly TaskbarIcon _icon;
    private readonly TrayMeterRenderer _renderer = new();
    private readonly NetworkMonitorService _monitor;

    private nint _currentIconHandle;
    private Icon? _currentIcon;
    private int _lastRenderedSize;
    private string _lastRenderedText = string.Empty;

    internal TrayIconHost(NetworkMonitorService monitor, TrayMeterOptions options, Popover.AppCommands commands)
    {
        _monitor = monitor;
        Options = options;

        _icon = new TaskbarIcon
        {
            ToolTipText = "NetFluss",
            ContextMenu = SurfaceMenu.Build(commands),
        };

        _icon.TrayLeftMouseUp += (_, _) => LeftClicked?.Invoke(this, EventArgs.Empty);

        // Keyboard users reach the notification area with Win+B and the arrow keys; Enter or
        // Space on the icon must open the popover just as a click does.
        _icon.TrayKeyboardSelect += (_, _) => LeftClicked?.Invoke(this, EventArgs.Empty);
        _icon.TrayBalloonTipClicked += (_, _) => NotificationClicked?.Invoke(this, EventArgs.Empty);
        CreateIcon();

        _monitor.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(NetworkMonitorService.Totals))
            {
                Update(_monitor.Totals);
            }
        };

        Update(_monitor.Totals);
    }

    /// <summary>
    /// Adds the icon to the notification area. That fails while Explorer is starting or
    /// restarting — at sign-in NetFluss can be up first — and a failure here used to abort
    /// the app's whole startup, leaving a process with nothing on screen that still held the
    /// single-instance lock. Instead it tries again every two seconds until the shell is there.
    /// </summary>
    private void CreateIcon()
    {
        try
        {
            _icon.ForceCreate();
            _created = true;
            _retry?.Stop();
            Redraw();
        }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            if (_retry is null)
            {
                CrashLog.Write("tray", e);
                _retry = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
                _retry.Tick += (_, _) => CreateIcon();
            }

            _retry.Start();
        }
    }

    private bool _created;
    private System.Windows.Threading.DispatcherTimer? _retry;

    public event EventHandler? LeftClicked;

    /// <summary>Raised when the user clicks a notification this icon showed.</summary>
    public event EventHandler? NotificationClicked;

    /// <summary>
    /// A Windows notification from the tray icon. Needs the icon present, which is the
    /// default; with it hidden the caller falls back to the popover footer.
    /// </summary>
    public void Notify(string title, string message)
    {
        if (IsVisible)
        {
            _icon.ShowNotification(title, message, H.NotifyIcon.Core.NotificationIcon.Info);
        }
    }

    public TrayMeterOptions Options { get; set; }

    /// <summary>
    /// Whether the notification-area icon is shown at all.
    ///
    /// <para>Shown by default even when another surface carries the numbers, because this is
    /// where a Windows user looks for a background app's menu — including the only way to
    /// quit it. Only the explicit <c>HideTrayIcon</c> preference takes it away, and the app
    /// puts it straight back if the overlay loses its anchor.</para>
    /// </summary>
    public bool IsVisible
    {
        get => _icon.Visibility == Visibility.Visible;
        set
        {
            if (value == IsVisible)
            {
                return;
            }

            _icon.Visibility = value ? Visibility.Visible : Visibility.Collapsed;

            // A hidden icon is not repainted, so one coming back needs a fresh frame.
            if (value)
            {
                Redraw();
            }
        }
    }

    /// <summary>
    /// Repaints even when the rate text has not changed. <see cref="Update"/> skips a tick
    /// whose label matches the last one, which is the right call on an idle machine but
    /// would swallow a colour or layout change made in Preferences — the user would toggle
    /// a setting and see nothing happen until traffic moved.
    /// </summary>
    public void Redraw()
    {
        _lastRenderedText = string.Empty;
        _lastRenderedSize = 0;
        Update(_monitor.Totals);
    }

    public void Update(RateTotals totals)
    {
        // Every change below is a synchronous message to Explorer. A hidden icon, or one the
        // shell has not taken yet, has nothing to show.
        if (!_created || !IsVisible)
        {
            return;
        }

        var size = Dpi.TrayIconSize();
        var options = Options with { Size = size };

        // Repainting an identical bitmap costs a GDI round trip and a shell redraw for
        // nothing. On an idle machine this skips the overwhelming majority of ticks — and
        // with the taskbar meter carrying the rates, the icon is a fixed glyph that never
        // needs repainting for traffic at all.
        var text = options.Layout == TrayMeterLayout.Icon
            ? "icon"
            : string.Concat(
                RateFormatter.FormatCompact(totals.RxRateBps, options.UseBits),
                "/",
                RateFormatter.FormatCompact(totals.TxRateBps, options.UseBits));

        if (size == _lastRenderedSize && text == _lastRenderedText && _currentIcon is not null)
        {
            UpdateTooltip(totals, options);
            return;
        }

        var handle = _renderer.RenderIconHandle(totals, options);
        var previousHandle = _currentIconHandle;
        var previousIcon = _currentIcon;
        var icon = Icon.FromHandle(handle);

        try
        {
            _icon.Icon = icon;
        }
        catch (InvalidOperationException)
        {
            // The shell refused the update — Explorer restarting or hung. Keep the icon it
            // still has, free the one it did not take, and try again on the next tick.
            icon.Dispose();
            Dpi.DestroyIcon(handle);
            _lastRenderedText = string.Empty;
            return;
        }

        _lastRenderedSize = size;
        _lastRenderedText = text;
        _currentIconHandle = handle;
        _currentIcon = icon;

        // Only now is the old handle unreferenced by the shell.
        previousIcon?.Dispose();
        if (previousHandle != nint.Zero)
        {
            Dpi.DestroyIcon(previousHandle);
        }

        UpdateTooltip(totals, options);
    }

    /// <summary>
    /// VPN state for the tooltip while the VPN indicator is switched on; null leaves it out.
    /// The 16 px icon has no room for the mark itself, so the tooltip carries it.
    /// </summary>
    public void SetVpnStatus((bool Active, string? Country)? status)
    {
        _vpnStatus = status;
        UpdateTooltip(_monitor.Totals, Options);
    }

    private (bool Active, string? Country)? _vpnStatus;

    /// <summary>Upload above download, matching the order of the rows in the icon itself.</summary>
    private void UpdateTooltip(RateTotals totals, TrayMeterOptions options)
    {
        var text = string.Concat(
            "NetFluss\n↑ ",
            RateFormatter.FormatRate(totals.TxRateBps, options.UseBits),
            "\n↓ ",
            RateFormatter.FormatRate(totals.RxRateBps, options.UseBits));

        if (_vpnStatus is { } vpn)
        {
            var state = Localization.L(vpn.Active ? "VPN connected" : "No VPN connected");
            text += "\n" + (vpn.Country is { Length: > 0 } country ? $"{state} ({country})" : state);
        }

        // Only when it reads differently, and with live rates at most every few seconds: each
        // change is another synchronous message to Explorer, and a tooltip is read on hover.
        var now = Environment.TickCount64;
        if (text == _lastTooltip || (_vpnStatus == _lastTooltipVpn && now - _lastTooltipAt < TooltipIntervalMs))
        {
            return;
        }

        try
        {
            _icon.ToolTipText = text;
            _lastTooltip = text;
            _lastTooltipVpn = _vpnStatus;
            _lastTooltipAt = now;
        }
        catch (InvalidOperationException)
        {
            // Explorer is not answering; the next tick tries again.
        }
    }

    private const long TooltipIntervalMs = 3000;
    private string _lastTooltip = string.Empty;
    private (bool Active, string? Country)? _lastTooltipVpn;
    private long _lastTooltipAt;

    public void Dispose()
    {
        _icon.Dispose();
        _currentIcon?.Dispose();

        if (_currentIconHandle != nint.Zero)
        {
            Dpi.DestroyIcon(_currentIconHandle);
            _currentIconHandle = nint.Zero;
        }
    }
}
