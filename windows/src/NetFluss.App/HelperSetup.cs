// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using NetFluss.Core;

namespace NetFluss.App;

/// <summary>
/// The "Install helper" and "Remove helper" buttons: one elevated run of the helper's own
/// installer, which the user approves in a UAC prompt. The macOS equivalent is the
/// SMAppService approval for the privileged helper.
/// </summary>
internal static class HelperSetup
{
    /// <summary>The helper as shipped beside the app, before it is copied into Program Files.</summary>
    internal static string? BundledHelper
    {
        get
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Helper", "NetFluss.Service.exe");
            return File.Exists(path) ? path : null;
        }
    }

    internal static Task<string?> InstallAsync() => RunAsync("install");

    internal static Task<string?> UninstallAsync() => RunAsync("uninstall");

    /// <summary>Runs the installer elevated; returns null on success or a message to show.</summary>
    private static async Task<string?> RunAsync(string verb)
    {
        var helper = verb == "install" ? BundledHelper : InstalledOrBundled();
        if (helper is null)
        {
            return Localization.L("The helper is missing from this copy of NetFluss.");
        }

        try
        {
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = helper,
                Arguments = verb,
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
            });

            if (process is null)
            {
                return Localization.L("Could not start the elevated helper.");
            }

            if (!await ProcessWait.ForExitAsync(process, ProcessWait.Install))
            {
                return ProcessWait.TimedOutMessage;
            }

            return process.ExitCode == 0
                ? null
                : Localization.L("The helper could not be installed (error {0}).", process.ExitCode);
        }
        catch (Win32Exception e) when (e.NativeErrorCode == 1223)
        {
            return Localization.L("Cancelled.");
        }
        catch (Win32Exception e)
        {
            return e.Message;
        }
    }

    /// <summary>
    /// The bundled copy first: the uninstaller deletes the Program Files folder, which it
    /// cannot do while running from inside it.
    /// </summary>
    private static string? InstalledOrBundled()
    {
        if (BundledHelper is { } bundled)
        {
            return bundled;
        }

        var installed = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            "NetFluss",
            "Helper",
            "NetFluss.Service.exe");

        return File.Exists(installed) ? installed : null;
    }
}
