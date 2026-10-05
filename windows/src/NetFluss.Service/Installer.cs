// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Runtime.InteropServices;
using System.Security.Principal;
using NetFluss.Core;

namespace NetFluss.Service;

/// <summary>
/// Installs and removes the helper service. Run elevated, by the app, on the user's request.
///
/// <para><b>The binary is copied into Program Files before it is registered.</b> A portable
/// or per-user NetFluss lives somewhere the user can write, and a LocalSystem service whose
/// executable a user can replace is a privilege-escalation hole: swap the file, wait for the
/// next start, own the machine. Program Files is writable only by administrators, so the
/// service always runs from there, whatever folder the app itself was started from.</para>
/// </summary>
internal static unsafe class Installer
{
    private const string DisplayName = "NetFluss Helper";
    private const string Description =
        "Lets NetFluss show per-app network traffic and change DNS without asking each time. " +
        "Optional: NetFluss works without it.";

    private const uint ScManagerAllAccess = 0xF003F;
    private const uint ServiceAllAccess = 0xF01FF;
    private const uint ServiceWin32OwnProcess = 0x10;
    private const uint ServiceAutoStart = 0x2;
    private const uint ServiceErrorNormal = 0x1;
    private const uint ServiceConfigDescription = 1;
    private const uint ServiceConfigFailureActions = 2;
    private const uint ServiceConfigDelayedAutoStart = 3;
    private const uint ServiceControlStop = 1;
    private const uint ServiceStopped = 1;
    private const uint ErrorServiceDoesNotExist = 1060;
    private const uint ErrorServiceMarkedForDelete = 1072;

    internal static string InstallDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
        "NetFluss",
        "Helper");

    internal static int Install()
    {
        if (!IsAdministrator())
        {
            Console.Error.WriteLine("Installing the helper needs administrator rights.");
            return 5;
        }

        var manager = OpenSCManagerW(null, null, ScManagerAllAccess);
        if (manager == nint.Zero)
        {
            return Marshal.GetLastPInvokeError();
        }

        try
        {
            // Replace, not update in place: stop and delete any existing registration so the
            // files are not in use and the new binary path takes effect.
            RemoveService(manager);
            CopyFiles();

            var binary = Path.Combine(InstallDirectory, "NetFluss.Service.exe");
            var service = CreateServiceW(
                manager,
                HelperProtocol.ServiceName,
                DisplayName,
                ServiceAllAccess,
                ServiceWin32OwnProcess,
                ServiceAutoStart,
                ServiceErrorNormal,
                $"\"{binary}\"",
                null,
                nint.Zero,
                null,
                null,
                null);

            if (service == nint.Zero)
            {
                return Marshal.GetLastPInvokeError();
            }

            try
            {
                Configure(service);

                if (!StartServiceW(service, 0, nint.Zero))
                {
                    return Marshal.GetLastPInvokeError();
                }
            }
            finally
            {
                _ = CloseServiceHandle(service);
            }

            return 0;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine(e.Message);
            return 32;
        }
        finally
        {
            _ = CloseServiceHandle(manager);
        }
    }

    internal static int Uninstall()
    {
        if (!IsAdministrator())
        {
            Console.Error.WriteLine("Removing the helper needs administrator rights.");
            return 5;
        }

        var manager = OpenSCManagerW(null, null, ScManagerAllAccess);
        if (manager == nint.Zero)
        {
            return Marshal.GetLastPInvokeError();
        }

        try
        {
            RemoveService(manager);
        }
        finally
        {
            _ = CloseServiceHandle(manager);
        }

        try
        {
            if (Directory.Exists(InstallDirectory))
            {
                Directory.Delete(InstallDirectory, recursive: true);
            }

            var parent = Path.GetDirectoryName(InstallDirectory);

            // The VPN staging folder beside it: stopping the service removed every tunnel.
            var staging = parent is null ? null : Path.Combine(parent, "VpnStaging");
            if (staging is not null && Directory.Exists(staging) && !new DirectoryInfo(staging).Attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                Directory.Delete(staging, recursive: true);
            }

            if (parent is not null && Directory.Exists(parent) && !Directory.EnumerateFileSystemEntries(parent).Any())
            {
                Directory.Delete(parent);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // A file still held open; Windows releases it within moments of the stop, and a
            // leftover folder harms nothing.
        }

        return 0;
    }

    private static void CopyFiles()
    {
        var source = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        var target = InstallDirectory;

        if (string.Equals(Path.GetFullPath(source), Path.GetFullPath(target), StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        Directory.CreateDirectory(target);

        // Only the helper's own files, by name. The source is the per-user install folder,
        // which the user can write to: copying everything in it would let any program of the
        // user's drop a DLL (a version.dll, say) next to a service that runs as SYSTEM, where
        // Windows' search order loads it. Each file is opened without sharing write or delete
        // access, so it cannot be swapped while it is copied.
        var walk = new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint };
        var shipped = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var file in Directory.EnumerateFiles(source, "*", walk))
        {
            var relative = Path.GetRelativePath(source, file);
            if (!IsHelperFile(relative))
            {
                Console.Error.WriteLine($"skipped {relative}: not one of the helper's files");
                continue;
            }

            var destination = Path.Combine(target, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            using (var input = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (var output = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                input.CopyTo(output);
            }

            shipped.Add(relative);
        }

        // An update replaces the folder: what an older helper shipped and this one does not
        // would otherwise stay in Program Files for good.
        foreach (var file in Directory.EnumerateFiles(target, "*", walk))
        {
            if (!shipped.Contains(Path.GetRelativePath(target, file)))
            {
                try
                {
                    File.Delete(file);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                }
            }
        }

        foreach (var directory in Directory.EnumerateDirectories(target, "*", walk).OrderByDescending(d => d.Length))
        {
            if (!Directory.EnumerateFileSystemEntries(directory).Any())
            {
                Directory.Delete(directory);
            }
        }
    }

    /// <summary>
    /// The helper's own files: NetFluss.* executables, libraries, runtime configuration and
    /// symbols at the top level (a release is the single NetFluss.Service.exe; a development
    /// build has the separate assemblies), and NetFluss satellite resources in culture
    /// folders. Nothing else is copied into Program Files, whatever lies beside it.
    /// </summary>
    internal static bool IsHelperFile(string relative)
    {
        var parts = relative.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var name = parts[^1];
        if (!name.StartsWith("NetFluss.", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return parts.Length switch
        {
            1 => Path.GetExtension(name).ToLowerInvariant() is ".exe" or ".dll" or ".json" or ".pdb",
            2 => name.EndsWith(".resources.dll", StringComparison.OrdinalIgnoreCase) && IsCulture(parts[0]),
            _ => false,
        };
    }

    private static bool IsCulture(string folder)
    {
        try
        {
            return !string.IsNullOrEmpty(System.Globalization.CultureInfo.GetCultureInfo(folder, predefinedOnly: true).Name);
        }
        catch (System.Globalization.CultureNotFoundException)
        {
            return false;
        }
    }

    private static void RemoveService(nint manager)
    {
        var service = OpenServiceW(manager, HelperProtocol.ServiceName, ServiceAllAccess);
        if (service == nint.Zero)
        {
            return;
        }

        try
        {
            ServiceStatus status;
            _ = ControlService(service, ServiceControlStop, &status);

            // Wait for the stop, so the executable is not in use when it is replaced.
            for (var i = 0; i < 50; i++)
            {
                if (!QueryServiceStatus(service, &status) || status.CurrentState == ServiceStopped)
                {
                    break;
                }

                Thread.Sleep(200);
            }

            if (!DeleteService(service))
            {
                var error = (uint)Marshal.GetLastPInvokeError();
                if (error is not (ErrorServiceDoesNotExist or ErrorServiceMarkedForDelete))
                {
                    throw new IOException($"Could not remove the old helper (error {error}).");
                }
            }
        }
        finally
        {
            _ = CloseServiceHandle(service);
        }

        // DeleteService only marks for deletion; the record goes once the last handle closes.
        // Creating a new service of the same name before then fails, so give it a moment.
        Thread.Sleep(500);
    }

    private static void Configure(nint service)
    {
        fixed (char* text = Description)
        {
            var description = new ServiceDescription { Description = (nint)text };
            _ = ChangeServiceConfig2W(service, ServiceConfigDescription, &description);
        }

        // Delayed start: nothing needs the helper during sign-in, and the boot is busy enough.
        var delayed = new ServiceDelayedAutoStart { Delayed = 1 };
        _ = ChangeServiceConfig2W(service, ServiceConfigDelayedAutoStart, &delayed);

        // Restart on failure, three times, five seconds apart; reset the count daily.
        var actions = stackalloc ScAction[3];
        for (var i = 0; i < 3; i++)
        {
            actions[i] = new ScAction { Type = 1, Delay = 5000 }; // SC_ACTION_RESTART
        }

        var failure = new ServiceFailureActions
        {
            ResetPeriod = 86400,
            ActionCount = 3,
            Actions = (nint)actions,
        };

        _ = ChangeServiceConfig2W(service, ServiceConfigFailureActions, &failure);
    }

    private static bool IsAdministrator()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceStatus
    {
        public uint ServiceType;
        public uint CurrentState;
        public uint ControlsAccepted;
        public uint Win32ExitCode;
        public uint ServiceSpecificExitCode;
        public uint CheckPoint;
        public uint WaitHint;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceDescription
    {
        public nint Description;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceDelayedAutoStart
    {
        public int Delayed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ScAction
    {
        public uint Type;
        public uint Delay;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceFailureActions
    {
        public uint ResetPeriod;
        public nint RebootMessage;
        public nint Command;
        public uint ActionCount;
        public nint Actions;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint OpenSCManagerW(string? machine, string? database, uint access);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint OpenServiceW(nint manager, string name, uint access);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint CreateServiceW(
        nint manager,
        string name,
        string displayName,
        uint access,
        uint serviceType,
        uint startType,
        uint errorControl,
        string binaryPath,
        string? loadOrderGroup,
        nint tagId,
        string? dependencies,
        string? account,
        string? password);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool StartServiceW(nint service, uint argc, nint argv);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ControlService(nint service, uint control, ServiceStatus* status);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceStatus(nint service, ServiceStatus* status);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteService(nint service);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ChangeServiceConfig2W(nint service, uint infoLevel, void* info);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseServiceHandle(nint handle);
}
