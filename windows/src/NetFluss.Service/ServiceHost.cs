// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Runtime.InteropServices;
using NetFluss.Core;

namespace NetFluss.Service;

/// <summary>
/// The Service Control Manager plumbing, by hand: the dispatcher, the control handler and
/// status reporting are three Win32 calls, which is not worth a package dependency in a
/// binary that runs as LocalSystem.
/// </summary>
internal static unsafe class ServiceHost
{
    private const uint ServiceWin32OwnProcess = 0x10;
    private const uint StateStopped = 1;
    private const uint StateStartPending = 2;
    private const uint StateStopPending = 3;
    private const uint StateRunning = 4;
    private const uint AcceptStop = 0x1;
    private const uint AcceptShutdown = 0x4;
    private const uint ControlStop = 1;
    private const uint ControlInterrogate = 4;
    private const uint ControlShutdown = 5;
    private const uint ErrorFailedServiceControllerConnect = 1063;

    private static Func<HelperServer>? _factory;
    private static nint _statusHandle;
    private static readonly ManualResetEventSlim Stopping = new();
    private static nint _serviceName;

    internal static int Run(Func<HelperServer> factory)
    {
        _factory = factory;
        _serviceName = Marshal.StringToHGlobalUni(HelperProtocol.ServiceName);

        var table = stackalloc ServiceTableEntry[2];
        table[0] = new ServiceTableEntry
        {
            Name = _serviceName,
            Proc = (nint)(delegate* unmanaged<uint, nint, void>)&ServiceMain,
        };
        table[1] = default;

        if (!StartServiceCtrlDispatcherW(table))
        {
            var error = Marshal.GetLastPInvokeError();
            if (error == ErrorFailedServiceControllerConnect)
            {
                Console.Error.WriteLine("This is the NetFluss helper service. Run 'NetFluss.Service console' to run it in the foreground.");
                return 2;
            }

            return error;
        }

        return 0;
    }

    [UnmanagedCallersOnly]
    private static void ServiceMain(uint argc, nint argv)
    {
        _statusHandle = RegisterServiceCtrlHandlerExW(
            _serviceName,
            (nint)(delegate* unmanaged<uint, uint, nint, nint, uint>)&Handler,
            nint.Zero);

        if (_statusHandle == nint.Zero)
        {
            return;
        }

        Report(StateStartPending, 0, waitHint: 5000);

        HelperServer? server = null;
        try
        {
            server = _factory!();
            server.Start();
            Report(StateRunning, AcceptStop | AcceptShutdown);

            Stopping.Wait();
            Report(StateStopPending, 0, waitHint: 5000);
        }
        catch (Exception)
        {
            // Fall through to STOPPED with an exit code so the SCM's recovery action (restart)
            // applies, rather than leaving a service that says it runs and does nothing.
            try
            {
                server?.Dispose();
            }
            catch (Exception)
            {
            }

            Report(StateStopped, 0, exitCode: 1064);
            return;
        }

        // ServiceMain is called from native code: an exception escaping it ends the process at
        // once, the service manager never hears STOPPED, and a normal stop is logged as a crash.
        // Tearing down VPN tunnels can fail or take a while, so it gets a generous hint too.
        try
        {
            Report(StateStopPending, 0, waitHint: 60_000);
            server.Dispose();
        }
        catch (Exception)
        {
        }

        Report(StateStopped, 0);
    }

    [UnmanagedCallersOnly]
    private static uint Handler(uint control, uint eventType, nint eventData, nint context)
    {
        switch (control)
        {
            case ControlStop:
            case ControlShutdown:
                Report(StateStopPending, 0, waitHint: 5000);
                Stopping.Set();
                return 0;

            case ControlInterrogate:
                return 0;

            default:
                // ERROR_CALL_NOT_IMPLEMENTED
                return 120;
        }
    }

    private static void Report(uint state, uint accepted, uint waitHint = 0, uint exitCode = 0)
    {
        var status = new ServiceStatus
        {
            ServiceType = ServiceWin32OwnProcess,
            CurrentState = state,
            ControlsAccepted = accepted,
            Win32ExitCode = exitCode,
            WaitHint = waitHint,
        };

        _ = SetServiceStatus(_statusHandle, &status);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceTableEntry
    {
        public nint Name;
        public nint Proc;
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

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool StartServiceCtrlDispatcherW(ServiceTableEntry* table);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern nint RegisterServiceCtrlHandlerExW(nint serviceName, nint handler, nint context);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetServiceStatus(nint statusHandle, ServiceStatus* status);
}
