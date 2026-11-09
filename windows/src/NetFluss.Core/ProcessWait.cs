// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.ComponentModel;
using System.Diagnostics;

namespace NetFluss.Core;

/// <summary>
/// A bounded wait for a system command (macOS 2.7.2: "system commands can no longer hang the
/// app"). netsh, PowerShell and the helper installer normally finish in seconds; one that does
/// not must not leave a button saying "Applying…" for ever.
/// </summary>
public static class ProcessWait
{
    /// <summary>What a short system command (netsh, PowerShell) gets.</summary>
    public static readonly TimeSpan Command = TimeSpan.FromSeconds(60);

    /// <summary>What an install or uninstall gets: it registers a service and may copy files.</summary>
    public static readonly TimeSpan Install = TimeSpan.FromMinutes(3);

    /// <summary>
    /// Waits for <paramref name="process"/> to exit, at most <paramref name="timeout"/>. False on
    /// a timeout, after trying to end the process tree — which fails, harmlessly, for an elevated
    /// process this one may not touch; the caller stops waiting either way.
    /// </summary>
    public static async Task<bool> ForExitAsync(Process process, TimeSpan timeout)
    {
        using var cancellation = new CancellationTokenSource(timeout);
        try
        {
            await process.WaitForExitAsync(cancellation.Token).ConfigureAwait(false);
            return true;
        }
        catch (OperationCanceledException)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (Exception e) when (e is Win32Exception or InvalidOperationException or NotSupportedException)
            {
            }

            return false;
        }
    }

    /// <summary>The message for a command that ran out of time.</summary>
    public static string TimedOutMessage => Localization.L("The command did not finish in time.");
}
