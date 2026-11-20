// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Runtime.InteropServices;
using Xunit;

namespace NetFluss.Native.Tests;

/// <summary>
/// The DNS settings structures are hand-written from netioapi.h, and a wrong offset does not
/// throw: Windows reads a template pointer from the wrong place, or a count as a pointer, and
/// the call fails with ERROR_INVALID_PARAMETER at best. So the sizes and offsets of the 64-bit
/// layout — the only one NetFluss ships (x64 and ARM64) — are pinned here.
/// </summary>
public class InterfaceDnsLayoutTests
{
    [Fact]
    public void Version1_Layout()
    {
        Assert.True(Environment.Is64BitProcess, "NetFluss ships 64-bit only; these offsets are the 64-bit ones.");

        Assert.Equal(64, Marshal.SizeOf<InterfaceDns.DnsInterfaceSettings>());
        Assert.Equal(8, Offset<InterfaceDns.DnsInterfaceSettings>(nameof(InterfaceDns.DnsInterfaceSettings.Flags)));
        Assert.Equal(24, Offset<InterfaceDns.DnsInterfaceSettings>(nameof(InterfaceDns.DnsInterfaceSettings.NameServer)));
        Assert.Equal(56, Offset<InterfaceDns.DnsInterfaceSettings>(nameof(InterfaceDns.DnsInterfaceSettings.ProfileNameServer)));
    }

    /// <summary>
    /// DNS_INTERFACE_SETTINGS3: version 1's members, then DisableUnconstrainedQueries and
    /// SupplementalSearchList, then a ULONG count and a pointer for each property array — each
    /// count padded to the pointer after it.
    /// </summary>
    [Fact]
    public void Version3_Layout()
    {
        Assert.True(Environment.Is64BitProcess);

        Assert.Equal(112, Marshal.SizeOf<InterfaceDns.DnsInterfaceSettings3>());

        // It starts as version 1 does, member for member.
        Assert.Equal(0, Offset<InterfaceDns.DnsInterfaceSettings3>(nameof(InterfaceDns.DnsInterfaceSettings3.Version)));
        Assert.Equal(8, Offset<InterfaceDns.DnsInterfaceSettings3>(nameof(InterfaceDns.DnsInterfaceSettings3.Flags)));
        Assert.Equal(16, Offset<InterfaceDns.DnsInterfaceSettings3>(nameof(InterfaceDns.DnsInterfaceSettings3.Domain)));
        Assert.Equal(24, Offset<InterfaceDns.DnsInterfaceSettings3>(nameof(InterfaceDns.DnsInterfaceSettings3.NameServer)));
        Assert.Equal(32, Offset<InterfaceDns.DnsInterfaceSettings3>(nameof(InterfaceDns.DnsInterfaceSettings3.SearchList)));
        Assert.Equal(40, Offset<InterfaceDns.DnsInterfaceSettings3>(nameof(InterfaceDns.DnsInterfaceSettings3.RegistrationEnabled)));
        Assert.Equal(52, Offset<InterfaceDns.DnsInterfaceSettings3>(nameof(InterfaceDns.DnsInterfaceSettings3.QueryAdapterName)));
        Assert.Equal(56, Offset<InterfaceDns.DnsInterfaceSettings3>(nameof(InterfaceDns.DnsInterfaceSettings3.ProfileNameServer)));

        Assert.Equal(64, Offset<InterfaceDns.DnsInterfaceSettings3>(nameof(InterfaceDns.DnsInterfaceSettings3.DisableUnconstrainedQueries)));
        Assert.Equal(72, Offset<InterfaceDns.DnsInterfaceSettings3>(nameof(InterfaceDns.DnsInterfaceSettings3.SupplementalSearchList)));
        Assert.Equal(80, Offset<InterfaceDns.DnsInterfaceSettings3>(nameof(InterfaceDns.DnsInterfaceSettings3.ServerPropertyCount)));
        Assert.Equal(88, Offset<InterfaceDns.DnsInterfaceSettings3>(nameof(InterfaceDns.DnsInterfaceSettings3.ServerProperties)));
        Assert.Equal(96, Offset<InterfaceDns.DnsInterfaceSettings3>(nameof(InterfaceDns.DnsInterfaceSettings3.ProfileServerPropertyCount)));
        Assert.Equal(104, Offset<InterfaceDns.DnsInterfaceSettings3>(nameof(InterfaceDns.DnsInterfaceSettings3.ProfileServerProperties)));
    }

    /// <summary>DNS_SERVER_PROPERTY: three 32-bit members, padding, then the union's pointer.</summary>
    [Fact]
    public void ServerProperty_Layout()
    {
        Assert.True(Environment.Is64BitProcess);

        Assert.Equal(24, Marshal.SizeOf<InterfaceDns.DnsServerProperty>());
        Assert.Equal(4, Offset<InterfaceDns.DnsServerProperty>(nameof(InterfaceDns.DnsServerProperty.ServerIndex)));
        Assert.Equal(8, Offset<InterfaceDns.DnsServerProperty>(nameof(InterfaceDns.DnsServerProperty.Type)));
        Assert.Equal(16, Offset<InterfaceDns.DnsServerProperty>(nameof(InterfaceDns.DnsServerProperty.Property)));
    }

    [Fact]
    public void DohServerSettings_Layout()
    {
        Assert.True(Environment.Is64BitProcess);

        Assert.Equal(16, Marshal.SizeOf<InterfaceDns.DnsDohServerSettings>());
        Assert.Equal(0, Offset<InterfaceDns.DnsDohServerSettings>(nameof(InterfaceDns.DnsDohServerSettings.Template)));
        Assert.Equal(8, Offset<InterfaceDns.DnsDohServerSettings>(nameof(InterfaceDns.DnsDohServerSettings.Flags)));
    }

    /// <summary>The constants as netioapi.h defines them.</summary>
    [Fact]
    public void Constants_MatchTheHeader()
    {
        Assert.Equal(3u, InterfaceDns.SettingsVersion3);
        Assert.Equal(0x1000ul, InterfaceDns.SettingDoh);
        Assert.Equal(0x0001ul, InterfaceDns.SettingIPv6);
        Assert.Equal(0x0002ul, InterfaceDns.SettingNameServer);
        Assert.Equal(1u, InterfaceDns.ServerPropertyVersion1);
        Assert.Equal(1, InterfaceDns.DnsServerDohProperty);
        Assert.Equal(0x2ul, NetFluss.Core.DohServerSetting.FlagEnable);
        Assert.Equal(0x4ul, NetFluss.Core.DohServerSetting.FlagFallbackToUdp);
    }

    /// <summary>
    /// Reading an adapter's DoH settings must not throw, whatever the machine: on Windows 10 or
    /// an adapter without DoH it reports unknown or nothing, never garbage.
    /// </summary>
    [Fact]
    public void ReadingDoh_IsSafeOnEveryAdapter()
    {
        foreach (var nic in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
        {
            if (!Guid.TryParse(nic.Id, out var guid))
            {
                continue;
            }

            var (settings, _, _) = InterfaceDns.ReadDoh(guid);
            Assert.All(settings, setting => Assert.False(string.IsNullOrEmpty(setting.Server)));
        }
    }

    private static int Offset<T>(string field) => (int)Marshal.OffsetOf<T>(field);
}
