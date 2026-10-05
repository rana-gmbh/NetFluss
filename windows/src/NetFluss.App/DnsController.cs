// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Diagnostics;
using System.IO;
using System.Net.NetworkInformation;
using NetFluss.Core;

namespace NetFluss.App;

/// <summary>What an adapter's resolvers currently are.</summary>
internal sealed record DnsState(string AdapterId, string AdapterName, IReadOnlyList<string> Servers);

/// <summary>Outcome of an apply, in a form the UI can show verbatim.</summary>
internal sealed record DnsApplyResult(bool Succeeded, string Message)
{
    internal static DnsApplyResult Ok(string message) => new(true, message);

    internal static DnsApplyResult Fail(string message) => new(false, message);
}

/// <summary>
/// Applies DNS settings. Implemented today by elevating on demand; the Phase 2 service will
/// implement the same interface and the UI will not know the difference.
/// </summary>
internal interface IDnsApplier
{
    Task<DnsApplyResult> ApplyAsync(string adapterName, IReadOnlyList<string> servers);
}

/// <summary>
/// Reads and writes per-adapter DNS.
///
/// <para><b>Reading needs no privileges</b> — <see cref="NetworkInterface"/> reports the
/// active resolvers — so the whole UI, including the active-preset checkmark, works in a
/// perfectly ordinary unelevated session. Only applying is gated.</para>
///
/// <para><b>Writing needs administrator.</b> <c>SetInterfaceDnsSettings</c> requires it, and
/// the port plan puts DNS switching in the elevated service for exactly that reason. Until
/// that service exists, an apply elevates a single short-lived <c>netsh</c> run, so the user
/// sees one UAC prompt per change rather than the app demanding admin at launch. Running the
/// whole app elevated would be the wrong trade: a meter that sits in the tray all day should
/// not hold administrator rights so that a rarely-used setting can be changed.</para>
/// </summary>
internal sealed class DnsController : IDnsApplier
{
    /// <summary>Current resolvers for every adapter that has any, keyed by interface GUID.</summary>
    internal static IReadOnlyList<DnsState> Read()
    {
        var states = new List<DnsState>();

        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback)
                {
                    continue;
                }

                IReadOnlyList<string> servers;
                try
                {
                    servers = [.. nic.GetIPProperties().DnsAddresses.Select(address => address.ToString())];
                }
                catch (NetworkInformationException)
                {
                    // An adapter can disappear between enumeration and query.
                    continue;
                }

                states.Add(new DnsState(nic.Id, nic.Name, servers));
            }
        }
        catch (NetworkInformationException)
        {
            return [];
        }

        return states;
    }

    /// <summary>
    /// The resolvers configured <em>statically</em> on an adapter, IPv4 then IPv6; empty
    /// means the adapter takes DNS from DHCP.
    ///
    /// <para>This is what decides which preset gets the checkmark, and the live list from
    /// <see cref="Read"/> cannot: an adapter on automatic DNS still reports the resolver DHCP
    /// handed it — usually the router — so "System Default" would never match and the
    /// checkmark would never be shown for the most common configuration of all. Windows keeps
    /// the static list separately in the TCP/IP parameters, readable without elevation.</para>
    /// </summary>
    internal static IReadOnlyList<string> StaticServers(string adapterId)
    {
        if (!Guid.TryParse(adapterId, out var guid))
        {
            return [];
        }

        var servers = new List<string>();
        foreach (var stack in new[] { "Tcpip", "Tcpip6" })
        {
            try
            {
                using var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                    $@"SYSTEM\CurrentControlSet\Services\{stack}\Parameters\Interfaces\{guid:B}");

                if (key?.GetValue("NameServer") is string value)
                {
                    servers.AddRange(DnsValidator.Parse(value));
                }
            }
            catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException)
            {
                // Unreadable means unknown, which the UI shows as no checkmark at all —
                // better than a confident wrong one.
            }
        }

        return servers;
    }

    /// <summary>The Windows connection name for an interface GUID, which is what netsh addresses.</summary>
    internal static string? AdapterName(string adapterId)
    {
        if (!Guid.TryParse(adapterId, out var wanted))
        {
            return null;
        }

        try
        {
            return NetworkInterface.GetAllNetworkInterfaces()
                .FirstOrDefault(nic => Guid.TryParse(nic.Id, out var id) && id == wanted)
                ?.Name;
        }
        catch (NetworkInformationException)
        {
            return null;
        }
    }

    /// <summary>The preset whose servers are exactly the adapter's static list, if any.</summary>
    internal static string? ActivePresetId(IReadOnlyList<DnsPreset> presets, IReadOnlyList<string> staticServers)
        => presets.FirstOrDefault(preset => preset.Matches(staticServers))?.Id;

    public async Task<DnsApplyResult> ApplyAsync(string adapterName, IReadOnlyList<string> servers)
    {
        // Validated again here, not only in the UI. This method builds a command line for a
        // process that will run as administrator, so it does not get to assume its caller
        // checked anything.
        var validation = DnsValidator.Validate(servers);
        if (!validation.IsValid)
        {
            return DnsApplyResult.Fail(validation.Error ?? Localization.L("Invalid servers."));
        }

        // The adapter name reaches the command line too, so it must be one Windows itself
        // reported rather than anything typed. A name containing a quote could otherwise
        // close the argument and append commands to an elevated shell.
        if (!NetworkInterface.GetAllNetworkInterfaces().Any(nic => nic.Name == adapterName))
        {
            return DnsApplyResult.Fail(Localization.L("No adapter named '{0}'.", adapterName));
        }

        if (adapterName.Contains('"') || adapterName.Contains('%'))
        {
            return DnsApplyResult.Fail(Localization.L("That adapter's name cannot be used from a script."));
        }

        // No script file: a .cmd written to %TEMP% and run elevated could be rewritten by any
        // process of this user while the UAC prompt is open. The commands travel on the
        // command line instead, which nothing can change once the prompt has started.
        var command = BuildCommand(adapterName, servers);

        try
        {
            // "runas" is what raises the UAC prompt. Without UseShellExecute it is ignored
            // and the process simply starts unelevated, where every netsh call fails.
            // /d skips the user's cmd AutoRun, which would otherwise run elevated too; /s /c
            // takes everything inside the outer quotes literally.
            var info = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, "cmd.exe"),
                Arguments = $"/d /s /c \"{command}\"",
                WorkingDirectory = Environment.SystemDirectory,
                UseShellExecute = true,
                Verb = "runas",
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
            };

            using var process = Process.Start(info);
            if (process is null)
            {
                return DnsApplyResult.Fail(Localization.L("Could not start the elevated helper."));
            }

            await process.WaitForExitAsync();

            return process.ExitCode == 0
                ? DnsApplyResult.Ok(servers.Count == 0
                    ? Localization.L("{0} is back on automatic DNS.", adapterName)
                    : Localization.L("{0} now uses {1}.", adapterName, string.Join(", ", servers)))
                : DnsApplyResult.Fail(Localization.L("netsh exited with code {0}.", process.ExitCode));
        }
        catch (System.ComponentModel.Win32Exception e) when (e.NativeErrorCode == 1223)
        {
            // ERROR_CANCELLED — the user dismissed the UAC prompt. Not a failure worth
            // dressing up as one.
            return DnsApplyResult.Fail(Localization.L("Cancelled. DNS was not changed."));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return DnsApplyResult.Fail(e.Message);
        }
    }

    /// <summary>
    /// The netsh commands, chained for one elevated cmd. IPv4 and IPv6 are separate stores in
    /// Windows, so a preset carrying both has to write both — and "System Default" has to clear
    /// both, or an IPv6 resolver left behind would keep answering and the change would look
    /// like it did nothing.
    ///
    /// <para>The IPv4 steps are joined with &amp;&amp;: if one fails, the chain stops and cmd exits
    /// with netsh's code, so a failure is reported as one. IPv6 is best effort — an adapter
    /// with IPv6 turned off refuses those commands, and that is not a failed switch. Programs
    /// are named by full path: a bare "netsh" is looked up through the current folder and the
    /// user's PATH first. The adapter name has no quote or %, and inside quotes cmd takes
    /// &amp; | &lt; &gt; ^ literally; the servers are canonical addresses.</para>
    /// </summary>
    internal static string BuildCommand(string adapterName, IReadOnlyList<string> servers)
    {
        var netsh = "\"" + Path.Combine(Environment.SystemDirectory, "netsh.exe") + "\"";
        var ipconfig = "\"" + Path.Combine(Environment.SystemDirectory, "ipconfig.exe") + "\"";

        List<string> Family(string family, List<string> list)
        {
            if (list.Count == 0)
            {
                return [$"{netsh} interface {family} set dnsservers name=\"{adapterName}\" source=dhcp"];
            }

            var commands = new List<string> { $"{netsh} interface {family} set dnsservers name=\"{adapterName}\" static {list[0]} primary validate=no" };
            for (var i = 1; i < list.Count; i++)
            {
                commands.Add($"{netsh} interface {family} add dnsservers name=\"{adapterName}\" address={list[i]} index={i + 1} validate=no");
            }

            return commands;
        }

        var v4 = Family("ipv4", [.. servers.Where(s => !s.Contains(':'))]);
        var v6 = Family("ipv6", [.. servers.Where(s => s.Contains(':'))]);

        // Stale entries would otherwise keep resolving from cache after the switch; it runs
        // last, so its exit code (0) is the chain's when IPv4 went through.
        return $"{string.Join(" && ", v4)} && ({string.Join(" & ", v6)} & {ipconfig} /flushdns)";
    }
}
