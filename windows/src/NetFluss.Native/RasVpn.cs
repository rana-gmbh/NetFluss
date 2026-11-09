// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace NetFluss.Native;

/// <summary>A VPN connection configured in Windows (Settings → Network → VPN).</summary>
public sealed record RasEntry(string Name, string Phonebook);

/// <summary>
/// Windows' own VPN stack — the counterpart of the macOS <c>NativeVPN</c> and NEVPNManager
/// paths. Connections listed under Settings → VPN are Remote Access phonebook entries; they
/// are dialled with <c>RasDial</c>, which takes the password in memory rather than on a
/// command line (the macOS 2.5 hardening kept it out of argv for the same reason).
///
/// <para>No administrator rights are needed: entries live in the user's own phonebook.</para>
/// </summary>
public static class RasVpn
{
    private const int RasMaxEntryName = 256;
    private const int RasMaxDeviceType = 16;
    private const int RasMaxDeviceName = 128;
    private const int RasMaxPhoneNumber = 128;
    private const int UnLen = 256;
    private const int PwLen = 256;
    private const int DnLen = 15;
    private const int MaxPath = 260;
    private const int ErrorBufferTooSmall = 603;
    private const int RascsConnected = 0x2000;

    /// <summary>The VPN connections in the user's and the machine's phonebooks.</summary>
    public static IReadOnlyList<RasEntry> Entries()
    {
        var size = Marshal.SizeOf<RasEntryName>();
        var count = 16;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var entries = new RasEntryName[count];
            entries[0].dwSize = size;
            var bytes = size * count;
            var result = RasEnumEntriesW(null, null, entries, ref bytes, out var found);
            if (result == ErrorBufferTooSmall)
            {
                count = Math.Max(found, bytes / size) + 1;
                continue;
            }

            return result != 0
                ? []
                : [.. entries.Take(found).Select(e => new RasEntry(e.szEntryName, e.szPhonebookPath))];
        }

        return [];
    }

    /// <summary>
    /// Connects an entry and waits for the outcome. Null on success, else Windows' own
    /// explanation ("The remote connection was not made because…"). Blocks: call it off
    /// the UI thread.
    /// </summary>
    public static string? Dial(string entry, string? username, string? password)
    {
        var parameters = new RasDialParams
        {
            dwSize = Marshal.SizeOf<RasDialParams>(),
            szEntryName = entry,
            szPhoneNumber = string.Empty,
            szCallbackNumber = string.Empty,
            szUserName = username ?? string.Empty,
            szPassword = password ?? string.Empty,
            szDomain = string.Empty,
        };

        // Without explicit credentials, use what Windows saved for the entry.
        if (username is null && password is null &&
            RasGetEntryDialParamsW(null, ref parameters, out _) != 0)
        {
            parameters.szEntryName = entry;
        }

        var handle = nint.Zero;
        var result = RasDialW(nint.Zero, null, ref parameters, 0, nint.Zero, ref handle);
        parameters.szPassword = string.Empty;
        if (result == 0)
        {
            return null;
        }

        // A failed dial still holds a handle that must be released.
        if (handle != nint.Zero)
        {
            _ = RasHangUpW(handle);
        }

        return ErrorText(result);
    }

    /// <summary>Hangs up every connection of an entry.</summary>
    public static void HangUp(string entry)
    {
        foreach (var connection in Connections().Where(c => c.Name.Equals(entry, StringComparison.OrdinalIgnoreCase)))
        {
            _ = RasHangUpW(connection.Handle);

            // RasHangUp returns at once; the line is truly down when the handle is invalid.
            var status = new RasConnStatus { dwSize = Marshal.SizeOf<RasConnStatus>() };
            for (var i = 0; i < 30 && RasGetConnectStatusW(connection.Handle, ref status) == 0; i++)
            {
                Thread.Sleep(100);
            }
        }
    }

    /// <summary>Whether an entry is connected right now.</summary>
    public static bool IsConnected(string entry)
    {
        foreach (var connection in Connections().Where(c => c.Name.Equals(entry, StringComparison.OrdinalIgnoreCase)))
        {
            var status = new RasConnStatus { dwSize = Marshal.SizeOf<RasConnStatus>() };
            if (RasGetConnectStatusW(connection.Handle, ref status) == 0 && status.rasconnstate == RascsConnected)
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>The live connections: entry name and handle.</summary>
    public static IReadOnlyList<(string Name, nint Handle)> Connections()
    {
        var size = Marshal.SizeOf<RasConn>();
        var count = 8;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var connections = new RasConn[count];
            connections[0].dwSize = size;
            var bytes = size * count;
            var result = RasEnumConnectionsW(connections, ref bytes, out var found);
            if (result == ErrorBufferTooSmall)
            {
                count = Math.Max(found, bytes / size) + 1;
                continue;
            }

            return result != 0 ? [] : [.. connections.Take(found).Select(c => (c.szEntryName, c.hrasconn))];
        }

        return [];
    }

    /// <summary>Windows' sentence for a RAS error code.</summary>
    public static string ErrorText(int code)
    {
        var buffer = new StringBuilder(512);
        return RasGetErrorStringW(code, buffer, buffer.Capacity) == 0 && buffer.Length > 0
            ? buffer.ToString().Trim()
            : $"Windows VPN error {code}.";
    }

    /// <summary>
    /// Creates an IKEv2 connection (EAP-MSCHAPv2, username and password) in the user's
    /// phonebook through the VpnClient module — the documented way to build a VPN entry,
    /// and one that needs no administrator rights. The password is not part of it: NetFluss
    /// keeps it in Credential Manager and hands it to <see cref="Dial"/>.
    /// </summary>
    public static async Task<string?> CreateIkev2Async(string name, string server)
    {
        var script =
            $"Add-VpnConnection -Name {Quote(name)} -ServerAddress {Quote(server)} -TunnelType Ikev2 " +
            "-EncryptionLevel Required -AuthenticationMethod Eap -RememberCredential:$false -Force -ErrorAction Stop";
        return await PowerShellAsync(script);
    }

    /// <summary>Removes a connection NetFluss created.</summary>
    public static Task<string?> RemoveAsync(string name)
        => PowerShellAsync($"Remove-VpnConnection -Name {Quote(name)} -Force -ErrorAction Stop");

    /// <summary>
    /// A PowerShell single-quoted literal: inside one, only a doubled quote is special, so
    /// a name like <c>Joe's VPN'; Remove-Item …</c> stays a name.
    /// </summary>
    public static string Quote(string value)
    {
        // PowerShell also closes a single-quoted string on the typographic quotes ‘ ’ ‚ ‛;
        // doubling escapes each of them just as it does the ASCII one.
        var escaped = new StringBuilder(value.Length + 2);
        foreach (var c in value)
        {
            escaped.Append(c);
            if (c is '\'' or '‘' or '’' or '‚' or '‛')
            {
                escaped.Append(c);
            }
        }

        return "'" + escaped + "'";
    }

    private static async Task<string?> PowerShellAsync(string script)
    {
        var info = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"),
            CreateNoWindow = true,
            UseShellExecute = false,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            StandardOutputEncoding = Encoding.UTF8,
        };

        // Success is the exit code alone: with stderr redirected, PowerShell writes its progress
        // records there (as "#< CLIXML") even when the command works. A failure is caught and
        // its message written to stdout, in UTF-8 so a German or Chinese message survives.
        var wrapped =
            "$ProgressPreference = 'SilentlyContinue'; [Console]::OutputEncoding = [Text.Encoding]::UTF8; " +
            $"try {{ {script} }} catch {{ [Console]::Out.Write($_.Exception.Message); exit 1 }}";
        info.ArgumentList.Add("-NoProfile");
        info.ArgumentList.Add("-NonInteractive");
        info.ArgumentList.Add("-ExecutionPolicy");
        info.ArgumentList.Add("Bypass");
        info.ArgumentList.Add("-EncodedCommand");
        info.ArgumentList.Add(Convert.ToBase64String(Encoding.Unicode.GetBytes(wrapped)));

        using var process = Process.Start(info);
        if (process is null)
        {
            return "Could not run PowerShell.";
        }

        var output = process.StandardOutput.ReadToEndAsync();
        _ = process.StandardError.ReadToEndAsync();
        if (!await NetFluss.Core.ProcessWait.ForExitAsync(process, NetFluss.Core.ProcessWait.Command))
        {
            return NetFluss.Core.ProcessWait.TimedOutMessage;
        }

        var text = (await output).Trim();
        if (process.ExitCode == 0)
        {
            return null;
        }

        var first = text.Split('\n').FirstOrDefault(l => l.Trim().Length > 0)?.Trim();
        return string.IsNullOrEmpty(first) ? $"PowerShell exited with {process.ExitCode}." : first;
    }

    // ===================================== Interop =====================================

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 4)]
    private struct RasEntryName
    {
        public int dwSize;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = RasMaxEntryName + 1)]
        public string szEntryName;

        public int dwFlags;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = MaxPath + 1)]
        public string szPhonebookPath;
    }

    /// <summary>The WINVER 0x601 layout; RAS accepts it on every supported Windows.</summary>
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 4)]
    private struct RasConn
    {
        public int dwSize;
        public nint hrasconn;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = RasMaxEntryName + 1)]
        public string szEntryName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = RasMaxDeviceType + 1)]
        public string szDeviceType;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = RasMaxDeviceName + 1)]
        public string szDeviceName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = MaxPath)]
        public string szPhonebook;

        public int dwSubEntry;
        public Guid guidEntry;
        public int dwFlags;
        public long luid;
        public Guid guidCorrelationId;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 4)]
    private struct RasDialParams
    {
        public int dwSize;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = RasMaxEntryName + 1)]
        public string szEntryName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = RasMaxPhoneNumber + 1)]
        public string szPhoneNumber;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = RasMaxPhoneNumber + 1)]
        public string szCallbackNumber;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = UnLen + 1)]
        public string szUserName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = PwLen + 1)]
        public string szPassword;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = DnLen + 1)]
        public string szDomain;

        public int dwSubEntry;
        public nint dwCallbackId;
        public int dwIfIndex;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 4)]
    private struct RasConnStatus
    {
        public int dwSize;
        public int rasconnstate;
        public int dwError;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = RasMaxDeviceType + 1)]
        public string szDeviceType;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = RasMaxDeviceName + 1)]
        public string szDeviceName;
    }

    [DllImport("rasapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int RasEnumEntriesW(string? reserved, string? phonebook, [In, Out] RasEntryName[] entries, ref int size, out int count);

    [DllImport("rasapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int RasEnumConnectionsW([In, Out] RasConn[] connections, ref int size, out int count);

    [DllImport("rasapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int RasDialW(nint extensions, string? phonebook, ref RasDialParams parameters, int notifierType, nint notifier, ref nint connection);

    [DllImport("rasapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int RasGetEntryDialParamsW(string? phonebook, ref RasDialParams parameters, out bool passwordSaved);

    [DllImport("rasapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int RasHangUpW(nint connection);

    [DllImport("rasapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int RasGetConnectStatusW(nint connection, ref RasConnStatus status);

    [DllImport("rasapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int RasGetErrorStringW(int error, StringBuilder buffer, int size);
}
