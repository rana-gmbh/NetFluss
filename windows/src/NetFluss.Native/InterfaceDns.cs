// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Runtime.InteropServices;
using NetFluss.Core;

namespace NetFluss.Native;

/// <summary>
/// Per-adapter DNS through <c>SetInterfaceDnsSettings</c> (Windows 10 2004+), the documented
/// API rather than a netsh command line. Needs administrator, so it is called by the helper
/// service; the unelevated app falls back to one elevated netsh run per change.
///
/// <para><b>DNS-over-HTTPS</b> is the same call with <c>DNS_INTERFACE_SETTINGS3</c>, which
/// adds one <c>DNS_SERVER_PROPERTY</c> per server pointing at its template. Windows 11 only:
/// version 3 shipped with build 22000, so on Windows 10 none of the version-3 paths run.</para>
/// </summary>
public static unsafe class InterfaceDns
{
    internal const uint SettingsVersion1 = 1;
    internal const uint SettingsVersion3 = 3;
    internal const ulong SettingIPv6 = 0x0001;
    internal const ulong SettingNameServer = 0x0002;
    internal const ulong SettingDoh = 0x1000;

    /// <summary>DNS_SERVER_PROPERTY_VERSION1.</summary>
    internal const uint ServerPropertyVersion1 = 1;

    /// <summary>DNS_SERVER_PROPERTY_TYPE.DnsServerDohProperty.</summary>
    internal const int DnsServerDohProperty = 1;

    private const uint ErrorCallNotImplemented = 120;

    /// <summary>
    /// Sets the IPv4 and IPv6 resolvers. An empty list for a family puts that family back on
    /// DHCP — both are always written, because a leftover IPv6 resolver keeps answering and
    /// makes a change to IPv4 look like it did nothing.
    /// </summary>
    /// <param name="clearEncryption">
    /// Also drop any DoH settings on the adapter (Windows 11). Without this a plain preset with
    /// a DoH preset's addresses would quietly stay encrypted: Windows keeps DoH per server
    /// address, not per write.
    /// </param>
    /// <returns>0 on success, otherwise the Win32 error.</returns>
    public static uint Set(Guid adapter, IReadOnlyList<string> servers, bool clearEncryption = false)
    {
        var (v4, v6) = Split(servers);

        var status = clearEncryption ? SetPlainFamily(adapter, v4, ipv6: false) : SetFamily(adapter, v4, ipv6: false);
        if (status != 0)
        {
            return status;
        }

        status = clearEncryption ? SetPlainFamily(adapter, v6, ipv6: true) : SetFamily(adapter, v6, ipv6: true);
        if (status != 0)
        {
            return status;
        }

        FlushResolverCache();
        return 0;
    }

    /// <summary>
    /// Sets the resolvers with DNS-over-HTTPS on every one of them, "encrypted only": the
    /// template given, no fallback to plain DNS. A family without servers goes back to DHCP,
    /// as with plain DNS.
    /// </summary>
    /// <returns>0 on success, otherwise the Win32 error.</returns>
    public static uint SetDoh(Guid adapter, IReadOnlyList<string> servers, string template)
    {
        var (v4, v6) = Split(servers);

        var status = v4.Count > 0 ? SetDohFamily(adapter, v4, template, ipv6: false) : SetPlainFamily(adapter, v4, ipv6: false);
        if (status != 0)
        {
            return status;
        }

        status = v6.Count > 0 ? SetDohFamily(adapter, v6, template, ipv6: true) : SetPlainFamily(adapter, v6, ipv6: true);
        if (status != 0)
        {
            return status;
        }

        FlushResolverCache();
        return 0;
    }

    /// <summary>
    /// Drops the adapter's DoH settings and keeps its servers — what uninstalling the helper
    /// leaves behind on an adapter NetFluss had encrypted. Best effort.
    /// </summary>
    public static void ClearDoh(Guid adapter)
    {
        foreach (var ipv6 in new[] { false, true })
        {
            if (ReadFamily(adapter, ipv6) is { Servers.Count: > 0 } family && family.Doh.Count > 0)
            {
                _ = SetFamily3(adapter, family.Servers, null, ipv6);
            }
        }

        FlushResolverCache();
    }

    /// <summary>
    /// The DoH settings Windows holds for the adapter's servers, per family. A family that
    /// could not be read is reported as unknown rather than as "no DoH".
    /// </summary>
    public static (IReadOnlyList<DohServerSetting> Settings, bool Ipv4Known, bool Ipv6Known) ReadDoh(Guid adapter)
    {
        var settings = new List<DohServerSetting>();
        var v4 = ReadFamily(adapter, ipv6: false);
        var v6 = ReadFamily(adapter, ipv6: true);

        // The documentation asks for empty Flags on a read, which would leave IPv6 out of
        // reach; DNS_SETTING_IPV6 is passed anyway, and a read that comes back with IPv4
        // servers was answered for the wrong family and is not trusted.
        if (v6 is not null && v6.Servers.Any(server => !server.Contains(':')))
        {
            v6 = null;
        }

        settings.AddRange(v4?.Doh ?? []);
        settings.AddRange(v6?.Doh ?? []);
        return (settings, v4 is not null, v6 is not null);
    }

    private static (List<string> V4, List<string> V6) Split(IReadOnlyList<string> servers)
        => (servers.Where(s => !s.Contains(':')).ToList(), servers.Where(s => s.Contains(':')).ToList());

    private static uint SetFamily(Guid adapter, IReadOnlyList<string> servers, bool ipv6)
    {
        var nameServers = string.Join(',', servers);
        fixed (char* list = nameServers)
        {
            var settings = new DnsInterfaceSettings
            {
                Version = SettingsVersion1,
                Flags = SettingNameServer | (ipv6 ? SettingIPv6 : 0),
                NameServer = (nint)list,
            };

            try
            {
                return SetInterfaceDnsSettings(adapter, &settings);
            }
            catch (EntryPointNotFoundException)
            {
                // Windows 10 before 2004. ERROR_CALL_NOT_IMPLEMENTED tells the caller to
                // fall back to netsh.
                return ErrorCallNotImplemented;
            }
        }
    }

    /// <summary>
    /// Plain servers with every DoH setting of the family dropped. With servers that is one
    /// version-3 write carrying DNS_SETTING_DOH and no properties. Going back to DHCP needs a
    /// step first: DNS_SETTING_DOH wants servers to attach to, so any DoH left on the current
    /// servers is cleared while they are still set, and only then is the family emptied.
    /// </summary>
    private static uint SetPlainFamily(Guid adapter, IReadOnlyList<string> servers, bool ipv6)
    {
        if (servers.Count > 0)
        {
            // A Windows that refuses version 3 still gets its servers; there is no DoH on it
            // to clear.
            var status = SetFamily3(adapter, servers, null, ipv6);
            return status == 0 ? 0 : SetFamily(adapter, servers, ipv6);
        }

        if (ReadFamily(adapter, ipv6) is { Servers.Count: > 0 } current && current.Doh.Count > 0)
        {
            _ = SetFamily3(adapter, current.Servers, null, ipv6);
        }

        return SetFamily(adapter, servers, ipv6);
    }

    private static uint SetDohFamily(Guid adapter, IReadOnlyList<string> servers, string template, bool ipv6)
        => SetFamily3(adapter, servers, template, ipv6);

    /// <summary>
    /// One DNS_INTERFACE_SETTINGS3 write: the servers, and DoH with <paramref name="template"/>
    /// on each of them — or, with a null template, DoH switched off on all of them.
    /// </summary>
    private static uint SetFamily3(Guid adapter, IReadOnlyList<string> servers, string? template, bool ipv6)
    {
        var nameServers = string.Join(',', servers);
        var count = template is null ? 0 : servers.Count;

        // At most DnsValidator.MaximumServers entries: small enough for the stack, and
        // nothing here outlives the call.
        var properties = stackalloc DnsServerProperty[Math.Max(count, 1)];

        fixed (char* list = nameServers)
        fixed (char* url = template ?? string.Empty)
        {
            // One settings block shared by every server: they all use the same template.
            var doh = new DnsDohServerSettings { Template = (nint)url, Flags = DohServerSetting.FlagEnable };
            for (var i = 0; i < count; i++)
            {
                properties[i] = new DnsServerProperty
                {
                    Version = ServerPropertyVersion1,
                    ServerIndex = (uint)i,
                    Type = DnsServerDohProperty,
                    Property = (nint)(&doh),
                };
            }

            var settings = new DnsInterfaceSettings3
            {
                Version = SettingsVersion3,
                Flags = SettingNameServer | SettingDoh | (ipv6 ? SettingIPv6 : 0),
                NameServer = (nint)list,
                ServerPropertyCount = (uint)count,
                ServerProperties = count == 0 ? 0 : (nint)properties,
            };

            try
            {
                return SetInterfaceDnsSettings3(adapter, &settings);
            }
            catch (EntryPointNotFoundException)
            {
                return ErrorCallNotImplemented;
            }
        }
    }

    /// <summary>One family's static servers and their DoH settings, or null when unreadable.</summary>
    private static FamilyReadback? ReadFamily(Guid adapter, bool ipv6)
    {
        var settings = new DnsInterfaceSettings3
        {
            Version = SettingsVersion3,
            Flags = ipv6 ? SettingIPv6 : 0,
        };

        uint status;
        try
        {
            status = GetInterfaceDnsSettings3(adapter, &settings);
        }
        catch (EntryPointNotFoundException)
        {
            return null;
        }

        if (status != 0)
        {
            return null;
        }

        try
        {
            var names = settings.NameServer == 0 ? string.Empty : Marshal.PtrToStringUni(settings.NameServer) ?? string.Empty;
            var servers = names.Split([',', ' '], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            var doh = new List<DohServerSetting>();

            if (settings.ServerProperties != 0)
            {
                var properties = (DnsServerProperty*)settings.ServerProperties;
                for (var i = 0; i < settings.ServerPropertyCount; i++)
                {
                    var property = properties[i];
                    if (property.Type != DnsServerDohProperty || property.Property == 0 || property.ServerIndex >= servers.Length)
                    {
                        continue;
                    }

                    var setting = (DnsDohServerSettings*)property.Property;
                    var template = setting->Template == 0 ? null : Marshal.PtrToStringUni(setting->Template);
                    doh.Add(new DohServerSetting(servers[property.ServerIndex], template, setting->Flags));
                }
            }

            return new FamilyReadback(servers, doh);
        }
        finally
        {
            try
            {
                FreeInterfaceDnsSettings3(&settings);
            }
            catch (EntryPointNotFoundException)
            {
            }
        }
    }

    private sealed record FamilyReadback(IReadOnlyList<string> Servers, IReadOnlyList<DohServerSetting> Doh);

    /// <summary>
    /// Stale answers would otherwise keep resolving from the cache after the switch.
    /// <c>DnsFlushResolverCache</c> is exported but undocumented — what ipconfig /flushdns
    /// itself calls — so a missing export is tolerated rather than fatal.
    /// </summary>
    private static void FlushResolverCache()
    {
        try
        {
            _ = DnsFlushResolverCache();
        }
        catch (EntryPointNotFoundException)
        {
        }
    }

    /// <summary>DNS_INTERFACE_SETTINGS (version 1), 64 bytes on x64/ARM64.</summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct DnsInterfaceSettings
    {
        public uint Version;
        public ulong Flags;
        public nint Domain;
        public nint NameServer;
        public nint SearchList;
        public uint RegistrationEnabled;
        public uint RegisterAdapterName;
        public uint EnableLlmnr;
        public uint QueryAdapterName;
        public nint ProfileNameServer;
    }

    /// <summary>
    /// DNS_INTERFACE_SETTINGS3, 112 bytes on x64/ARM64: version 1's members, then
    /// DisableUnconstrainedQueries and SupplementalSearchList (the version-2 additions), then
    /// the two server-property arrays.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct DnsInterfaceSettings3
    {
        public uint Version;
        public ulong Flags;
        public nint Domain;
        public nint NameServer;
        public nint SearchList;
        public uint RegistrationEnabled;
        public uint RegisterAdapterName;
        public uint EnableLlmnr;
        public uint QueryAdapterName;
        public nint ProfileNameServer;
        public uint DisableUnconstrainedQueries;
        public nint SupplementalSearchList;
        public uint ServerPropertyCount;
        public nint ServerProperties;
        public uint ProfileServerPropertyCount;
        public nint ProfileServerProperties;
    }

    /// <summary>
    /// DNS_SERVER_PROPERTY, 24 bytes on x64/ARM64. <c>Property</c> is a union whose only member
    /// is a pointer to DNS_DOH_SERVER_SETTINGS.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct DnsServerProperty
    {
        public uint Version;
        public uint ServerIndex;
        public int Type;
        public nint Property;
    }

    /// <summary>DNS_DOH_SERVER_SETTINGS, 16 bytes on x64/ARM64.</summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct DnsDohServerSettings
    {
        public nint Template;
        public ulong Flags;
    }

    [DllImport("iphlpapi.dll")]
    private static extern uint SetInterfaceDnsSettings(Guid adapter, DnsInterfaceSettings* settings);

    [DllImport("iphlpapi.dll", EntryPoint = "SetInterfaceDnsSettings")]
    private static extern uint SetInterfaceDnsSettings3(Guid adapter, DnsInterfaceSettings3* settings);

    [DllImport("iphlpapi.dll", EntryPoint = "GetInterfaceDnsSettings")]
    private static extern uint GetInterfaceDnsSettings3(Guid adapter, DnsInterfaceSettings3* settings);

    [DllImport("iphlpapi.dll", EntryPoint = "FreeInterfaceDnsSettings")]
    private static extern void FreeInterfaceDnsSettings3(DnsInterfaceSettings3* settings);

    [DllImport("dnsapi.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DnsFlushResolverCache();
}
