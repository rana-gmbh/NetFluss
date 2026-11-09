// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.IO;
using Microsoft.Win32;

namespace NetFluss.App;

/// <summary>
/// Start-with-Windows, via the per-user Run key.
///
/// <para>The macOS app uses <c>SMAppService.mainApp.register()</c>, which needs no
/// privileges and is revocable from System Settings. The unpackaged Windows equivalent is
/// <c>HKCU\...\CurrentVersion\Run</c>: also per-user, also no elevation, and it shows up
/// under Task Manager's Startup tab where a user expects to find and disable it. The port
/// plan reserves an MSIX/Startup-task approach for a packaged build, which this is not.</para>
///
/// <para>Windows owns this state, not the settings file. If a user removes the entry from
/// Task Manager, the truth is the registry and the toggle has to reflect that — so this
/// always reads back rather than trusting what was last written.</para>
/// </summary>
internal static class LaunchAtLogin
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ApprovedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    private const string ValueName = "NetFluss";

    /// <summary>
    /// Whether Task Manager or Settings → Apps → Startup has switched the entry off. The Run
    /// value stays, so the switch would read "on" while Windows skips NetFluss at sign-in —
    /// the Windows form of the macOS 2.7.1 "waiting for approval" state. Windows records the
    /// choice in StartupApproved: an odd first byte means disabled.
    /// </summary>
    internal static bool IsDisabledByWindows()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(ApprovedKey);
            return key?.GetValue(ValueName) is byte[] { Length: > 0 } state && (state[0] & 1) == 1;
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    internal static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string command && command.Contains("NetFluss", StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>
    /// Writes or removes the Run entry. Null on success, else why not — shown under the switch
    /// rather than swallowed, so it never just flips back with no explanation (macOS 2.7.1).
    /// </summary>
    internal static string? Set(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
            if (!enabled)
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
                return null;
            }

            if (ExecutablePath() is not { } path)
            {
                return Localization.L("This copy of NetFluss is not running from its own program file, so Windows cannot start it at sign-in.");
            }

            // Quoted: the default install path contains a space, and an unquoted Run
            // entry would have Windows try to launch "C:\Program".
            key.SetValue(ValueName, $"\"{path}\"", RegistryValueKind.String);
            return null;
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            // A locked-down profile can forbid this.
            return e.Message;
        }
    }

    private static string? ExecutablePath()
    {
        var path = Environment.ProcessPath;

        // Under `dotnet run` this is the SDK host, not NetFluss — registering that would
        // start the wrong program at login.
        return path is not null && Path.GetFileNameWithoutExtension(path)
            .Equals("NetFluss", StringComparison.OrdinalIgnoreCase)
            ? path
            : null;
    }
}
