// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using NetFluss.Core;

namespace NetFluss.App;

/// <summary>
/// An always-on-top desktop panel showing the same readout as the taskbar overlay.
///
/// <para>The Windows form of the macOS <b>Pin</b> feature, and the one placement with no
/// platform risk at all: it owns its own window and depends on nothing undocumented. That
/// makes it the honest recommendation for anyone the taskbar overlay lets down — a second
/// monitor, an unusual shell, or a Windows update that moves the tray.</para>
///
/// <para>Independent of the meter surface rather than an alternative to it: a user can run
/// the tray meter and this together, which is how the Mac's Pin behaves.</para>
/// </summary>
internal sealed class FloatingWidgetWindow : Window
{
    private readonly MeterReadout _readout = new();
    private readonly Border _frame;
    private readonly AppSettings _settings;

    internal FloatingWidgetWindow(AppSettings settings)
    {
        _settings = settings;

        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        SizeToContent = SizeToContent.WidthAndHeight;

        _frame = new Border
        {
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(14, 9, 14, 9),
            Child = _readout,
        };

        Content = _frame;

        // Drag anywhere — there is no title bar to grab, and a widget the user cannot move is
        // a widget in the wrong place — but a plain click has to open the popover, the same
        // as clicking the tray icon or the taskbar meter.
        //
        // DragMove blocks until the button is released, so the two are told apart by whether
        // the window actually went anywhere. That beats a movement threshold on the mouse:
        // Windows applies its own drag threshold before the window starts following the
        // pointer, so a click with a pixel of hand-shake in it moves the mouse but not the
        // window, and is still a click.
        MouseLeftButtonDown += (_, e) =>
        {
            if (e.ButtonState != MouseButtonState.Pressed)
            {
                return;
            }

            var before = new Point(Left, Top);

            try
            {
                DragMove();
            }
            catch (InvalidOperationException)
            {
                // Raised when the button was already released before the drag began; that is
                // a click by definition, so fall through and treat it as one.
            }

            if (before == new Point(Left, Top))
            {
                Clicked?.Invoke(this, EventArgs.Empty);
                return;
            }

            // Remembered once the drag is over, so it survives a restart the way the macOS
            // pin does — not on every pixel of it, where each write saved settings.json.
            _settings.FloatingWidgetLeft = Left;
            _settings.FloatingWidgetTop = Top;
        };

        // Same reasoning as the overlay: this can be the only NetFluss window on screen.
        MouseRightButtonUp += (_, e) =>
        {
            if (ContextMenu is null)
            {
                return;
            }

            ContextMenu.Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint;
            ContextMenu.PlacementTarget = this;
            ContextMenu.IsOpen = true;
            e.Handled = true;
        };

    }

    /// <summary>Raised on a click that was not a drag, to toggle the popover.</summary>
    internal event EventHandler? Clicked;

    /// <summary>Alt+F4 on the widget: the user wants it gone, which is the Preferences switch.</summary>
    internal event EventHandler? CloseRequested;

    private bool _closeAllowed;

    /// <summary>Closes it for real; anything else asking to close it becomes <see cref="CloseRequested"/>.</summary>
    internal void CloseForGood()
    {
        _closeAllowed = true;
        Close();
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        if (!_closeAllowed)
        {
            // Closed here, the app would keep a dead window and never show the widget again.
            e.Cancel = true;
            CloseRequested?.Invoke(this, EventArgs.Empty);
        }

        base.OnClosing(e);
    }

    internal void ApplySettings(AppSettings settings, ThemeColor download, ThemeColor upload, SurfacePalette surface)
    {
        _readout.Layout = settings.ReadoutStyle;
        _readout.ApplyAppearance(settings.ReadoutFontSize + 3, download, upload, download);

        // Its own backdrop, unlike the overlay: this floats over arbitrary wallpaper and
        // windows, so it needs a surface of its own to stay readable. The colour comes from
        // the selected theme, so Dracula's panel is Dracula's grey rather than Windows'.
        _frame.Background = new SolidColorBrush(Color.FromArgb(
            0xE6,
            surface.Background.R,
            surface.Background.G,
            surface.Background.B));

        _frame.BorderBrush = new SolidColorBrush(surface.IsDark
            ? Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF)
            : Color.FromArgb(0x22, 0x00, 0x00, 0x00));

        _frame.BorderThickness = new Thickness(1);
    }

    internal void Update(RateTotals totals, bool useBits, DashboardMetrics? dashboard = null) => _readout.Update(totals, useBits, dashboard);

    /// <summary>The VPN mark and country after the rates; the widget sizes to its content.</summary>
    internal void SetAccessories(MeterAccessories? accessories) => _readout.SetAccessories(accessories);

    internal void Place()
    {
        if (_settings.FloatingWidgetLeft is { } left && _settings.FloatingWidgetTop is { } top)
        {
            Left = left;
            Top = top;
            ClampToScreen();
            return;
        }

        // First run: the lower-right corner, out of the way and near the taskbar clock where
        // the eye already goes for this kind of number.
        var workArea = SystemParameters.WorkArea;
        Left = workArea.Right - 220;
        Top = workArea.Bottom - 90;
    }

    /// <summary>
    /// A remembered position can be off-screen after a monitor is unplugged, which would
    /// leave the widget invisible and the preference apparently broken. On any monitor that
    /// still exists it stays where it was put — measured against that monitor, not the
    /// primary one, or a widget on a second screen jumped back at every start.
    /// </summary>
    private void ClampToScreen()
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle != nint.Zero && Screens.WindowRect(handle) is { } rect && Screens.MonitorWorkArea(handle) is { } work)
        {
            var centreX = (rect.Left + rect.Right) / 2;
            var centreY = (rect.Top + rect.Bottom) / 2;
            if (centreX >= work.Left && centreX < work.Right && centreY >= work.Top && centreY < work.Bottom)
            {
                return;
            }

            var width = rect.Right - rect.Left;
            var height = rect.Bottom - rect.Top;
            Screens.MoveWindow(
                handle,
                Math.Clamp(rect.Left, work.Left, Math.Max(work.Left, work.Right - width)),
                Math.Clamp(rect.Top, work.Top, Math.Max(work.Top, work.Bottom - height)));
            return;
        }

        var workArea = SystemParameters.WorkArea;

        if (Left < workArea.Left || Left > workArea.Right - 60)
        {
            Left = workArea.Right - 220;
        }

        if (Top < workArea.Top || Top > workArea.Bottom - 40)
        {
            Top = workArea.Bottom - 90;
        }
    }
}
