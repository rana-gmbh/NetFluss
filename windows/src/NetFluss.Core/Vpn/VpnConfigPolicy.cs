// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Text;

namespace NetFluss.Core.Vpn;

/// <summary>
/// What the helper accepts before it runs a user-imported config as LocalSystem.
///
/// <para><b>An allowlist, not a denylist.</b> OpenVPN has a few hundred options and new ones
/// arrive with every release; a list of known-bad ones (the first version of this) missed
/// <c>providers</c>, <c>engine</c> and <c>pkcs11-providers</c>, which load code, and
/// <c>win-sys</c>, which moves the system tools OpenVPN runs. So only directives a client
/// config actually needs pass, every argument that names a file must name one inside the
/// profile folder, and everything else is refused by name. <c>--script-security 1</c> (set by
/// the helper after the config) still keeps up/down scripts from running.</para>
///
/// <para><b>Parsed the way OpenVPN parses.</b> The check is only as good as its agreement
/// with OpenVPN's own tokenizer, so <see cref="Tokenize"/> follows <c>parse_line</c>: quotes
/// and backslash escapes are resolved before the name is looked at, inline blocks must close,
/// and <c>&lt;connection&gt;</c> blocks — which hold directives — are checked like the rest.
/// Anything this parser and OpenVPN might read differently is refused.</para>
/// </summary>
/// <summary>A WireGuard config line NetFluss will not run: 1-based, with the key it found (0 for the whole file).</summary>
public sealed record WireGuardRefusal(int Line, string Key)
{
    /// <summary>For the user: which line, and what to do about it.</summary>
    public string Describe() => Line == 0
        ? Localization.L("This WireGuard config was refused because it contains a NUL byte. Fix it and re-import.")
        : Localization.L("This WireGuard config was refused because line {0} (“{1}”) is not a setting NetFluss runs with administrator rights. Remove that line and re-import.", Line, Key);

    /// <summary>For the helper's reply and its log, which stay in English.</summary>
    public string DescribeInvariant() => Line == 0
        ? "This WireGuard config was refused because it contains a NUL byte. Fix it and re-import."
        : $"This WireGuard config was refused because line {Line} ('{Key}') is not a setting NetFluss runs with administrator rights. Remove that line and re-import.";
}

public static partial class VpnConfigPolicy
{
    // Declared before Allowed: static fields initialize in order, and Allowed is built from this.
    /// <summary>File-reading directives, with the argument positions that are paths.</summary>
    private static readonly Dictionary<string, int[]> FileArguments = new(StringComparer.Ordinal)
    {
        ["ca"] = [1], ["cert"] = [1], ["key"] = [1], ["pkcs12"] = [1], ["tls-auth"] = [1], ["tls-crypt"] = [1],
        ["tls-crypt-v2"] = [1], ["crl-verify"] = [1], ["extra-certs"] = [1], ["dh"] = [1], ["secret"] = [1],
        ["auth-user-pass"] = [1], ["askpass"] = [1], ["http-proxy-user-pass"] = [1],
        // http-proxy server port [authfile|auto|auto-nct|none] [auth-method]; socks-proxy server port [authfile]
        ["http-proxy"] = [3], ["socks-proxy"] = [3],
    };

    /// <summary>Directives a client config may carry, and which of their arguments are files.</summary>
    private static readonly Dictionary<string, int[]> Allowed = Build(
        // Connection and transport
        "client", "dev", "dev-type", "dev-node", "proto", "remote", "remote-random", "remote-random-hostname",
        "port", "rport", "lport", "nobind", "bind", "float", "resolv-retry", "connect-retry", "connect-retry-max",
        "connect-timeout", "server-poll-timeout", "persist-key", "persist-tun", "persist-local-ip", "persist-remote-ip",
        "pull", "pull-filter", "route-nopull", "topology", "ifconfig", "ifconfig-ipv6", "tun-ipv6",
        "windows-driver", "disable-dco", "allow-recursive-routing", "explicit-exit-notify", "single-session",
        "http-proxy-retry", "socks-proxy-retry", "http-proxy-option", "proto-force", "multihome",
        // Routing and DNS (the tools these run stay at their System32 defaults: win-sys is not allowed)
        "redirect-gateway", "redirect-private", "route", "route-ipv6", "route-metric", "route-delay", "route-method",
        "ip-win32", "register-dns", "block-outside-dns", "block-ipv6", "dhcp-option", "dhcp-renew", "dhcp-release",
        "dhcp-pre-release", "tap-sleep",
        // TLS and crypto
        "tls-client", "tls-version-min", "tls-version-max", "tls-cipher", "tls-ciphersuites", "tls-groups", "tls-timeout",
        "tls-exit", "tls-cert-profile", "remote-cert-tls", "remote-cert-ku", "remote-cert-eku", "verify-x509-name",
        "ns-cert-type", "key-direction", "key-method", "cipher", "ciphers", "data-ciphers", "data-ciphers-fallback",
        "ncp-ciphers", "ncp-disable", "auth", "auth-nocache", "auth-retry", "auth-token", "auth-token-user",
        "hand-window", "tran-window", "replay-window", "mute-replay-warnings", "reneg-sec", "reneg-bytes", "reneg-pkts",
        "peer-fingerprint", "verify-hash", "x509-username-field", "x509-track", "push-peer-info", "opt-verify",
        // Keepalive, MTU, buffers, logging verbosity
        "keepalive", "ping", "ping-restart", "ping-exit", "ping-timer-rem", "inactive", "tun-mtu", "tun-mtu-extra",
        "link-mtu", "mssfix", "fragment", "mtu-disc", "mtu-test", "sndbuf", "rcvbuf", "txqueuelen", "fast-io",
        "comp-lzo", "compress", "allow-compression", "comp-noadapt", "verb", "mute", "suppress-timestamps",
        // Harmless with --script-security 1, and common in provider configs (macOS accepts them too)
        "script-security", "up", "down", "route-up", "route-pre-down", "ipchange", "tls-verify", "up-delay", "up-restart",
        "down-pre", "setenv", "setenv-safe", "ignore-unknown-option", "user", "group", "persist-key", "nice",
        "machine-readable-output", "remap-usr1", "redirect-gateway-ipv6",
        // Seen in provider and enterprise client configs; none loads code or names a file
        "allow-pull-fqdn", "ifconfig-nowarn", "route-gateway", "max-routes", "keysize", "tun-mtu-max", "socket-flags",
        "tcp-nodelay", "passtos", "cryptoapicert", "ecdh-curve", "static-challenge", "connect-freq");

    /// <summary>Inline blocks: file contents — or, for &lt;connection&gt;, more directives.</summary>
    private static readonly HashSet<string> InlineBlocks =
    [
        "ca", "cert", "key", "pkcs12", "tls-auth", "tls-crypt", "tls-crypt-v2", "crl-verify", "extra-certs", "dh",
        "secret", "auth-user-pass", "http-proxy-user-pass", "peer-fingerprint", "connection",
    ];

    /// <summary>Keyword values a file argument may take instead of a path.</summary>
    private static readonly HashSet<string> FileKeywords = ["[inline]", "none", "auto", "auto-nct", "stdin"];

    private static Dictionary<string, int[]> Build(params string[] names)
    {
        var allowed = new Dictionary<string, int[]>(StringComparer.Ordinal);
        foreach (var name in names)
        {
            allowed[name] = [];
        }

        foreach (var (name, positions) in FileArguments)
        {
            allowed[name] = positions;
        }

        return allowed;
    }

    /// <summary>
    /// Null when the config may run, else what stops it: the directive name, or a short
    /// reason when the config cannot be read unambiguously.
    /// </summary>
    public static string? UnsafeOpenVpnDirective(string text)
    {
        var lines = text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        return Check(lines, allowConnection: true);
    }

    private static string? Check(IReadOnlyList<string> lines, bool allowConnection)
    {
        for (var i = 0; i < lines.Count; i++)
        {
            var line = lines[i];
            var trimmed = line.Trim();

            // An inline block, exactly as OpenVPN opens one: a line that is "<tag>".
            if (trimmed.StartsWith('<'))
            {
                if (!trimmed.EndsWith('>') || trimmed.StartsWith("</", StringComparison.Ordinal))
                {
                    return "malformed inline block";
                }

                var tag = trimmed[1..^1];
                if (!InlineBlocks.Contains(tag) || (tag == "connection" && !allowConnection))
                {
                    return "<" + tag + ">";
                }

                var close = "</" + tag + ">";
                var end = -1;
                for (var j = i + 1; j < lines.Count; j++)
                {
                    if (lines[j].Trim() == close)
                    {
                        end = j;
                        break;
                    }
                }

                if (end < 0)
                {
                    return "unclosed <" + tag + ">";
                }

                // A connection block holds directives; every other block is file content.
                if (tag == "connection" && Check([.. lines.Skip(i + 1).Take(end - i - 1)], allowConnection: false) is { } inner)
                {
                    return inner;
                }

                i = end;
                continue;
            }

            var tokens = Tokenize(line);
            if (tokens is null)
            {
                return "unparseable line";
            }

            if (tokens.Count == 0)
            {
                continue;
            }

            var name = tokens[0].StartsWith("--", StringComparison.Ordinal) ? tokens[0][2..] : tokens[0];
            if (!Allowed.TryGetValue(name, out var fileArguments))
            {
                return name;
            }

            foreach (var position in fileArguments)
            {
                if (position < tokens.Count && !FileKeywords.Contains(tokens[position]) && !VpnConfigImporter.IsSafeRelative(tokens[position]))
                {
                    return name;
                }
            }
        }

        return null;
    }

    /// <summary>
    /// One config line split into tokens the way OpenVPN's <c>parse_line</c> does it:
    /// whitespace separates, "#" or ";" starts a comment where a token could start, double
    /// quotes group with backslash escapes, single quotes group literally, and a backslash
    /// outside quotes escapes the next character. Null for an unterminated quote.
    /// </summary>
    public static List<string>? Tokenize(string line)
    {
        var tokens = new List<string>();
        var current = new StringBuilder();
        var inToken = false;
        var i = 0;
        while (i < line.Length)
        {
            var c = line[i];
            if (!inToken && char.IsWhiteSpace(c))
            {
                i++;
                continue;
            }

            if (!inToken && (c == '#' || c == ';'))
            {
                break;
            }

            if (char.IsWhiteSpace(c))
            {
                tokens.Add(current.ToString());
                current.Clear();
                inToken = false;
                i++;
                continue;
            }

            inToken = true;
            if (c == '"' || c == '\'')
            {
                var quote = c;
                i++;
                var closed = false;
                while (i < line.Length)
                {
                    var q = line[i];
                    if (q == quote)
                    {
                        closed = true;
                        i++;
                        break;
                    }

                    if (quote == '"' && q == '\\' && i + 1 < line.Length)
                    {
                        current.Append(line[i + 1]);
                        i += 2;
                        continue;
                    }

                    current.Append(q);
                    i++;
                }

                if (!closed)
                {
                    return null;
                }

                continue;
            }

            if (c == '\\' && i + 1 < line.Length)
            {
                current.Append(line[i + 1]);
                i += 2;
                continue;
            }

            current.Append(c);
            i++;
        }

        if (inToken)
        {
            tokens.Add(current.ToString());
        }

        return tokens;
    }

    /// <summary>The keys a WireGuard config may carry — the macOS 2.7 allowlist.</summary>
    private static readonly HashSet<string> WireGuardKeys = new(StringComparer.OrdinalIgnoreCase)
    {
        "address", "allowedips", "dns", "endpoint", "fwmark", "listenport", "mtu",
        "persistentkeepalive", "presharedkey", "privatekey", "publickey", "saveconfig", "table",
    };

    private static readonly HashSet<string> WireGuardSections = new(StringComparer.OrdinalIgnoreCase) { "[interface]", "[peer]" };

    /// <summary>
    /// Why a WireGuard config may not run, naming the line, or null when it may.
    ///
    /// <para><c>PreUp</c>, <c>PostUp</c>, <c>PreDown</c> and <c>PostDown</c> run commands.
    /// WireGuard for Windows ignores them unless an administrator turned on
    /// DangerousScriptExecution — and a machine where that is on is exactly where a profile
    /// must not bring its own. They used to be stripped silently; macOS 2.7 refuses the config
    /// and says which line to remove, so the user knows the tunnel would not have run what the
    /// config asked for. An allowlist, as on macOS, so a key nobody thought of is refused
    /// rather than passed.</para>
    /// </summary>
    public static WireGuardRefusal? UnsafeWireGuardLine(string text)
    {
        if (text.Contains('\0', StringComparison.Ordinal))
        {
            return new WireGuardRefusal(0, "NUL");
        }

        var lines = text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
            var hash = line.IndexOf('#', StringComparison.Ordinal);
            var content = (hash >= 0 ? line[..hash] : line).Trim().TrimStart('﻿');
            if (content.Length == 0)
            {
                continue;
            }

            if (content.StartsWith('['))
            {
                if (!WireGuardSections.Contains(content))
                {
                    return new WireGuardRefusal(i + 1, content);
                }

                continue;
            }

            var equals = content.IndexOf('=', StringComparison.Ordinal);
            var key = (equals < 0 ? content : content[..equals]).Trim();
            if (equals < 0 || !WireGuardKeys.Contains(key))
            {
                return new WireGuardRefusal(i + 1, key);
            }
        }

        return null;
    }

    /// <summary>
    /// A tunnel name WireGuard for Windows accepts — it names the service and the adapter
    /// after the file: letters, digits and <c>_=+.-</c>, at most 32 characters.
    /// </summary>
    public static string WireGuardTunnelName(string name)
    {
        var builder = new StringBuilder();
        foreach (var c in name)
        {
            builder.Append(char.IsAsciiLetterOrDigit(c) || c is '_' or '=' or '+' or '.' or '-' ? c : '-');
        }

        var cleaned = builder.ToString().Trim('-', '.');
        if (cleaned.Length == 0)
        {
            cleaned = "NetFluss";
        }

        return cleaned.Length > 32 ? cleaned[..32] : cleaned;
    }

    /// <summary>The helper's own tunnels: everything it starts or stops carries this prefix.</summary>
    public const string HelperTunnelPrefix = "NetFluss-";

    /// <summary>The helper's name for a tunnel: always inside its own namespace.</summary>
    public static string HelperTunnelName(string? requested)
    {
        var name = WireGuardTunnelName(requested ?? "Tunnel");
        if (name.StartsWith(HelperTunnelPrefix, StringComparison.OrdinalIgnoreCase))
        {
            name = name[HelperTunnelPrefix.Length..];
        }

        return WireGuardTunnelName(HelperTunnelPrefix + (name.Length == 0 ? "Tunnel" : name));
    }
}
