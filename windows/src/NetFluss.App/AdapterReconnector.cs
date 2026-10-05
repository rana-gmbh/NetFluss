// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net.NetworkInformation;
using NetFluss.Core;
using NetFluss.Native;

namespace NetFluss.App;

/// <summary>
/// The ↺ button on an adapter card: cycle the adapter off and back on. Port of the macOS
/// <c>NetworkMonitor.reconnect</c>, with the same split by adapter type.
///
/// <list type="bullet">
/// <item><b>Wi-Fi</b> disconnects and rejoins the same profile through the WLAN API —
/// unelevated, and without asking for the password, exactly as on the Mac.</item>
/// <item><b>Ethernet</b> has no per-user equivalent: disabling an adapter needs
/// administrator rights, so it elevates one short-lived <c>netsh</c> run, the same
/// one-prompt-per-action trade the DNS switcher makes.</item>
/// </list>
/// </summary>
internal static class AdapterReconnector
{
    internal static async Task<string?> ReconnectAsync(AdapterStatus adapter)
    {
        if (!Guid.TryParse(adapter.Id, out var id))
        {
            return null;
        }

        return adapter.Type == AdapterType.WiFi
            ? await Task.Run(() => ReconnectWifi(id))
            : await ReconnectWiredAsync(id);
    }

    private static string? ReconnectWifi(Guid id)
    {
        using var client = WlanClient.TryOpen();
        if (client is null)
        {
            return Localization.L("No Wi-Fi adapter found.");
        }

        var profile = client.CurrentConnection(id, out _)?.ProfileName;
        _ = client.Disconnect(id);

        if (profile is null)
        {
            // Nothing to rejoin by name; Windows' own auto-connect takes it from here.
            return null;
        }

        // Give the driver a moment to report the disconnect before asking it to reconnect,
        // or the request can be swallowed as a no-op against a still-associated radio.
        Thread.Sleep(1500);
        var status = client.Connect(id, profile);
        return status == 0 ? null : Localization.L("Windows refused the network settings (error {0}).", status);
    }

    private static async Task<string?> ReconnectWiredAsync(Guid id)
    {
        // The name reaches an elevated command line, so it must be one Windows reported and
        // must not be able to close its own quotes.
        var name = NetworkInterface.GetAllNetworkInterfaces()
            .FirstOrDefault(nic => Guid.TryParse(nic.Id, out var nicId) && nicId == id)?.Name;

        if (name is null || name.Contains('"') || name.Contains('%'))
        {
            return Localization.L("That adapter's name cannot be used from a script.");
        }

        // Full paths: a bare "netsh" is looked up through the current folder and the user's
        // PATH first. Once disabled, the adapter is enabled again whatever the wait did — a
        // failed timeout must never leave the PC offline — and cmd's exit code is netsh's.
        var netsh = "\"" + Path.Combine(Environment.SystemDirectory, "netsh.exe") + "\"";
        var timeout = "\"" + Path.Combine(Environment.SystemDirectory, "timeout.exe") + "\"";
        var command = $"{netsh} interface set interface name=\"{name}\" admin=disabled && " +
                      $"({timeout} /t 2 /nobreak >nul & {netsh} interface set interface name=\"{name}\" admin=enabled)";

        try
        {
            // /d skips the user's cmd AutoRun, which would otherwise run elevated as well.
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, "cmd.exe"),
                Arguments = $"/d /s /c \"{command}\"",
                WorkingDirectory = Environment.SystemDirectory,
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
            });

            if (process is null)
            {
                return Localization.L("Could not start the elevated helper.");
            }

            await process.WaitForExitAsync();
            return process.ExitCode == 0 ? null : Localization.L("Windows did not restart {0}.", name);
        }
        catch (Win32Exception e) when (e.NativeErrorCode == 1223)
        {
            // The user declined the UAC prompt; that is an answer, not an error.
            return null;
        }
    }
}
