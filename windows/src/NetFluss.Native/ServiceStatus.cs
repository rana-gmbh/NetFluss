// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Runtime.InteropServices;

namespace NetFluss.Native;

/// <summary>
/// Whether a Windows service is running — read with query-only rights, which every user
/// has, so the app can watch a WireGuard tunnel service without asking the helper.
/// </summary>
public static class ServiceStatus
{
    private const uint ScManagerConnect = 0x0001;
    private const uint ServiceQueryStatus = 0x0004;
    private const uint ServiceRunning = 0x00000004;

    public static bool IsRunning(string name)
    {
        var manager = OpenSCManagerW(null, null, ScManagerConnect);
        if (manager == nint.Zero)
        {
            return false;
        }

        try
        {
            var service = OpenServiceW(manager, name, ServiceQueryStatus);
            if (service == nint.Zero)
            {
                return false;
            }

            try
            {
                return QueryServiceStatus(service, out var status) && status.dwCurrentState == ServiceRunning;
            }
            finally
            {
                CloseServiceHandle(service);
            }
        }
        finally
        {
            CloseServiceHandle(manager);
        }
    }

    /// <summary>
    /// The process a running service lives in, or null when it is not running (or not
    /// installed). Lets a client check that a pipe it reached is served by that service.
    /// </summary>
    public static int? ProcessId(string name)
    {
        var manager = OpenSCManagerW(null, null, ScManagerConnect);
        if (manager == nint.Zero)
        {
            return null;
        }

        try
        {
            var service = OpenServiceW(manager, name, ServiceQueryStatus);
            if (service == nint.Zero)
            {
                return null;
            }

            try
            {
                var size = (uint)Marshal.SizeOf<ServiceStatusProcess>();
                return QueryServiceStatusEx(service, ScStatusProcessInfo, out var status, size, out _) &&
                       status.dwCurrentState == ServiceRunning && status.dwProcessId != 0
                    ? (int)status.dwProcessId
                    : null;
            }
            finally
            {
                CloseServiceHandle(service);
            }
        }
        finally
        {
            CloseServiceHandle(manager);
        }
    }

    /// <summary>The process at the server end of a connected pipe; null when Windows will not say.</summary>
    public static int? PipeServerProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe)
        => GetNamedPipeServerProcessId(pipe, out var pid) ? (int)pid : null;

    private const uint ScStatusProcessInfo = 0;

    /// <summary>SERVICE_STATUS_PROCESS: SERVICE_STATUS plus the process id and flags.</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceStatusProcess
    {
        public uint dwServiceType;
        public uint dwCurrentState;
        public uint dwControlsAccepted;
        public uint dwWin32ExitCode;
        public uint dwServiceSpecificExitCode;
        public uint dwCheckPoint;
        public uint dwWaitHint;
        public uint dwProcessId;
        public uint dwServiceFlags;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceStatusEx(nint service, uint infoLevel, out ServiceStatusProcess status, uint size, out uint needed);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint serverProcessId);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeServiceStatus
    {
        public uint dwServiceType;
        public uint dwCurrentState;
        public uint dwControlsAccepted;
        public uint dwWin32ExitCode;
        public uint dwServiceSpecificExitCode;
        public uint dwCheckPoint;
        public uint dwWaitHint;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint OpenSCManagerW(string? machine, string? database, uint access);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint OpenServiceW(nint manager, string name, uint access);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceStatus(nint service, out NativeServiceStatus status);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseServiceHandle(nint handle);
}
