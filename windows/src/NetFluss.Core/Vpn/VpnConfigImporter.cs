// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Globalization;
using System.IO.Compression;
using System.Text;

namespace NetFluss.Core.Vpn;

/// <summary>A file of an imported profile, by its path relative to the profile directory.</summary>
public sealed record VpnConfigFile(string Name, byte[] Data);

public sealed record VpnImportResult(
    string SuggestedName,
    IReadOnlyList<VpnConfigFile> Files,
    IReadOnlyList<VpnServer> Servers,
    string PrimaryFileName,
    bool RequiresCredentials,
    IReadOnlyList<string> Warnings);

public sealed class VpnImportException(string message) : Exception(message);

/// <summary>
/// Turns imported VPN configs into a profile — the macOS <c>VPNConfigImporter</c>. Accepts
/// a single config, a folder, or a .zip (how providers ship "router" profiles, one file
/// per server); every config becomes a selectable server. OpenVPN configs that point at
/// sidecar files (<c>ca ca.crt</c>) bring those along.
/// </summary>
public static class VpnConfigImporter
{
    private const int MaxFileBytes = 5 * 1024 * 1024;
    private const int MaxFiles = 2000;

    private static readonly HashSet<string> FileDirectives =
        ["ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2", "pkcs12", "crl-verify", "extra-certs", "dh", "secret"];

    /// <summary>Directives only patched OpenVPN builds understand; stock OpenVPN exits on them.</summary>
    private static readonly HashSet<string> UnsupportedDirectives = ["scramble"];

    private sealed record Parsed(string? Host, int? Port, string? Transport, bool RequiresCredentials);

    public static VpnImportResult ImportOpenVpn(string path)
    {
        var result = Import(path, "ovpn", collectSidecars: true, ParseOpenVpn, Unsupported);

        // Say now what the helper would refuse at connect time, rather than letting the user
        // find out from a failed connection.
        var refused = result.Files
            .Where(f => f.Name.EndsWith(".ovpn", StringComparison.OrdinalIgnoreCase))
            .Select(f => VpnConfigPolicy.UnsafeOpenVpnDirective(Decode(f.Data)))
            .FirstOrDefault(r => r is not null);

        // A patched-only directive already has its own, more specific warning.
        return refused is null || UnsupportedDirectives.Contains(refused)
            ? result
            : result with
            {
                Warnings =
                [
                    .. result.Warnings,
                    Localization.L("This config uses “{0}”, which NetFluss does not run with administrator rights, so connecting will be refused. Ask your provider for a standard client config.", refused),
                ],
            };
    }

    public static VpnImportResult ImportWireGuard(string path)
    {
        var result = Import(path, "conf", collectSidecars: false, ParseWireGuard, _ => []);

        // Said at import, naming the line, rather than discovered from a failed connection.
        var refused = result.Files
            .Where(f => f.Name.EndsWith(".conf", StringComparison.OrdinalIgnoreCase))
            .Select(f => VpnConfigPolicy.UnsafeWireGuardLine(Decode(f.Data)))
            .FirstOrDefault(r => r is not null);

        return refused is null ? result : result with { Warnings = [.. result.Warnings, refused.Describe()] };
    }

    private static VpnImportResult Import(string path, string extension, bool collectSidecars, Func<string, Parsed> parse, Func<string, IEnumerable<string>> unsupported)
    {
        if (Directory.Exists(path))
        {
            return ImportTree(ReadTree(path), extension, Path.GetFileName(path.TrimEnd('\\', '/')), parse, unsupported);
        }

        if (!File.Exists(path))
        {
            throw new VpnImportException(Localization.L("Could not read the configuration: {0}.", Path.GetFileName(path)));
        }

        if (Path.GetExtension(path).Equals(".zip", StringComparison.OrdinalIgnoreCase))
        {
            return ImportTree(ReadZip(path), extension, Path.GetFileNameWithoutExtension(path), parse, unsupported);
        }

        return ImportSingle(path, collectSidecars, parse, unsupported);
    }

    private static VpnImportResult ImportSingle(string path, bool collectSidecars, Func<string, Parsed> parse, Func<string, IEnumerable<string>> unsupported)
    {
        var data = ReadLimited(path) ?? throw new VpnImportException(Localization.L("Could not read the configuration: {0}.", Path.GetFileName(path)));
        var text = Decode(data);
        var name = Path.GetFileName(path);
        var files = new List<VpnConfigFile> { new(name, data) };

        if (collectSidecars)
        {
            var directory = Path.GetDirectoryName(path)!;
            foreach (var reference in ReferencedFiles(text).Where(IsSafeRelative))
            {
                if (ReadLimited(Path.Combine(directory, reference)) is { } sidecar)
                {
                    files.Add(new VpnConfigFile(Normalize(reference), sidecar));
                }
            }
        }

        var parsed = parse(text);
        var label = Path.GetFileNameWithoutExtension(path);
        var server = new VpnServer { Label = label, Host = parsed.Host ?? label, Port = parsed.Port, Transport = parsed.Transport, ConfigFileName = name };
        return new VpnImportResult(label, files, [server], name, parsed.RequiresCredentials, Warnings([.. unsupported(text)]));
    }

    private static VpnImportResult ImportTree(List<VpnConfigFile> files, string extension, string suggestedName, Func<string, Parsed> parse, Func<string, IEnumerable<string>> unsupported)
    {
        var configs = files.Where(f => f.Name.EndsWith("." + extension, StringComparison.OrdinalIgnoreCase))
            .OrderBy(f => f.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (configs.Count == 0)
        {
            throw new VpnImportException(Localization.L("No .{0} configuration files were found.", extension));
        }

        var servers = new List<VpnServer>();
        var requiresCredentials = false;
        var found = new List<string>();
        foreach (var config in configs)
        {
            var text = Decode(config.Data);
            var parsed = parse(text);
            requiresCredentials |= parsed.RequiresCredentials;
            found.AddRange(unsupported(text).Where(d => !found.Contains(d)));
            var label = Path.GetFileNameWithoutExtension(config.Name);
            servers.Add(new VpnServer { Label = label, Host = parsed.Host ?? label, Port = parsed.Port, Transport = parsed.Transport, ConfigFileName = config.Name });
        }

        return new VpnImportResult(suggestedName, files, servers, configs[0].Name, requiresCredentials, Warnings(found));
    }

    private static List<VpnConfigFile> ReadTree(string root)
    {
        var files = new List<VpnConfigFile>();
        foreach (var path in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
        {
            var relative = Normalize(Path.GetRelativePath(root, path));
            if (Skip(relative))
            {
                continue;
            }

            if (ReadLimited(path) is { } data)
            {
                files.Add(new VpnConfigFile(relative, data));
            }

            if (files.Count > MaxFiles)
            {
                break;
            }
        }

        return files;
    }

    private static List<VpnConfigFile> ReadZip(string path)
    {
        try
        {
            using var archive = ZipFile.OpenRead(path);
            var files = new List<VpnConfigFile>();
            foreach (var entry in archive.Entries)
            {
                // Directories, oversized entries and anything trying to climb out are skipped:
                // the entry name becomes a path under the profile directory.
                var relative = Normalize(entry.FullName);
                if (entry.Length == 0 && relative.EndsWith('/') || entry.Length > MaxFileBytes || !IsSafeRelative(relative) || Skip(relative))
                {
                    continue;
                }

                using var stream = entry.Open();
                using var buffer = new MemoryStream();
                stream.CopyTo(buffer);
                files.Add(new VpnConfigFile(relative, buffer.ToArray()));
                if (files.Count > MaxFiles)
                {
                    break;
                }
            }

            return files;
        }
        catch (InvalidDataException)
        {
            throw new VpnImportException(Localization.L("Could not read the configuration: {0}.", Path.GetFileName(path)));
        }
    }

    private static bool Skip(string relative)
        => relative.StartsWith("__MACOSX/", StringComparison.Ordinal) || Path.GetFileName(relative).StartsWith("._", StringComparison.Ordinal);

    private static byte[]? ReadLimited(string path)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists && info.Length <= MaxFileBytes ? File.ReadAllBytes(path) : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static string Decode(byte[] data) => Encoding.UTF8.GetString(data).TrimStart('﻿');

    private static string Normalize(string relative) => relative.Replace('\\', '/');

    /// <summary>A relative path that stays inside its directory.</summary>
    public static bool IsSafeRelative(string relative)
    {
        var normalized = Normalize(relative);
        return normalized.Length > 0 && !Path.IsPathRooted(normalized) && !normalized.Contains(':', StringComparison.Ordinal) &&
               !normalized.Split('/').Any(part => part is ".." or ".");
    }

    // ===================================== OpenVPN =====================================

    /// <summary>
    /// The directives of a config, tokenized as OpenVPN does it (<see cref="VpnConfigPolicy.Tokenize"/>).
    /// File-content blocks are skipped; a &lt;connection&gt; block's directives are included,
    /// since that is where some providers put their remotes.
    /// </summary>
    internal static IEnumerable<string[]> Directives(string text)
    {
        string? block = null;
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (block is not null && block != "connection")
            {
                if (line == $"</{block}>")
                {
                    block = null;
                }

                continue;
            }

            if (line == "</connection>")
            {
                block = null;
                continue;
            }

            if (line.Length > 1 && line[0] == '<' && line.EndsWith('>') && !line.StartsWith("</", StringComparison.Ordinal))
            {
                block = line[1..^1];
                continue;
            }

            var tokens = VpnConfigPolicy.Tokenize(line);
            if (tokens is { Count: > 0 })
            {
                if (tokens[0].StartsWith("--", StringComparison.Ordinal))
                {
                    tokens[0] = tokens[0][2..];
                }

                yield return [.. tokens];
            }
        }
    }

    public static IEnumerable<string> ReferencedFiles(string text)
    {
        foreach (var tokens in Directives(text))
        {
            if (FileDirectives.Contains(tokens[0]) && tokens.Length >= 2)
            {
                var reference = tokens[1].Trim('"', '\'');
                if (reference.Length > 0 && reference != "[inline]" && !reference.Equals("none", StringComparison.OrdinalIgnoreCase))
                {
                    yield return reference;
                }
            }
        }
    }

    private static IEnumerable<string> Unsupported(string text)
        => Directives(text).Select(t => t[0]).Where(UnsupportedDirectives.Contains).Distinct();

    private static List<string> Warnings(List<string> directives)
    {
        if (directives.Count == 0)
        {
            return [];
        }

        var list = string.Join(", ", directives.Select(d => $"“{d}”"));
        return
        [
            directives.Count == 1
                ? Localization.L("This config uses the {0} option, which is part of a third-party patched OpenVPN (used by some providers for obfuscation). The bundled OpenVPN doesn't support it, so this profile won't connect. Ask your provider for a standard OpenVPN or WireGuard config.", list)
                : Localization.L("This config uses the {0} options, which are part of a third-party patched OpenVPN (used by some providers for obfuscation). The bundled OpenVPN doesn't support them, so this profile won't connect. Ask your provider for a standard OpenVPN or WireGuard config.", list),
        ];
    }

    private static Parsed ParseOpenVpn(string text)
    {
        string? host = null;
        int? remotePort = null, globalPort = null;
        string? remoteProto = null, globalProto = null;
        var credentials = false;

        foreach (var tokens in Directives(text))
        {
            switch (tokens[0])
            {
                case "remote" when host is null:
                    host = tokens.ElementAtOrDefault(1);
                    remotePort = Int(tokens.ElementAtOrDefault(2));
                    remoteProto = Proto(tokens.ElementAtOrDefault(3));
                    break;
                case "port":
                    globalPort = Int(tokens.ElementAtOrDefault(1));
                    break;
                case "proto":
                    globalProto = Proto(tokens.ElementAtOrDefault(1));
                    break;
                case "auth-user-pass":
                    credentials = true;
                    break;
            }
        }

        return new Parsed(host, remotePort ?? globalPort, remoteProto ?? globalProto, credentials);
    }

    private static int? Int(string? text) => int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var value) ? value : null;

    private static string? Proto(string? proto) => proto?.ToLowerInvariant() switch
    {
        null => null,
        var p when p.StartsWith("tcp", StringComparison.Ordinal) => "tcp",
        var p when p.StartsWith("udp", StringComparison.Ordinal) => "udp",
        var p => p,
    };

    // ===================================== WireGuard =====================================

    /// <summary>"key = value" pairs of a WireGuard config, with the section each belongs to.</summary>
    public static IEnumerable<(string Section, string Key, string Value)> WireGuardValues(string text)
    {
        var section = string.Empty;
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            var comment = line.IndexOf('#');
            if (comment >= 0)
            {
                line = line[..comment].Trim();
            }

            if (line.StartsWith('[') && line.EndsWith(']'))
            {
                section = line[1..^1].Trim();
                continue;
            }

            var equals = line.IndexOf('=');
            if (equals > 0)
            {
                yield return (section, line[..equals].Trim(), line[(equals + 1)..].Trim());
            }
        }
    }

    private static Parsed ParseWireGuard(string text)
    {
        string? host = null;
        int? port = null;
        var endpoint = WireGuardValues(text).FirstOrDefault(v => v.Key.Equals("Endpoint", StringComparison.OrdinalIgnoreCase)).Value;
        if (endpoint is not null)
        {
            if (endpoint.StartsWith('[') && endpoint.IndexOf(']') is var close and > 0)
            {
                host = endpoint[1..close];
                var colon = endpoint.LastIndexOf(':');
                port = colon > close ? Int(endpoint[(colon + 1)..]) : null;
            }
            else if (endpoint.LastIndexOf(':') is var colon and > 0)
            {
                host = endpoint[..colon];
                port = Int(endpoint[(colon + 1)..]);
            }
            else
            {
                host = endpoint;
            }
        }

        // WireGuard is always UDP, and keys rather than passwords authenticate it.
        return new Parsed(host, port, "udp", false);
    }

    /// <summary>The <c>[Interface] DNS</c> servers (addresses only; search domains dropped).</summary>
    public static IReadOnlyList<string> WireGuardDns(string text)
        => [.. WireGuardValues(text)
            .Where(v => v.Section.Equals("Interface", StringComparison.OrdinalIgnoreCase) && v.Key.Equals("DNS", StringComparison.OrdinalIgnoreCase))
            .SelectMany(v => v.Value.Split(','))
            .Select(s => s.Trim())
            .Where(s => System.Net.IPAddress.TryParse(s, out _))];

    /// <summary>The first <c>[Interface] Address</c>, without its prefix length.</summary>
    public static string? WireGuardAddress(string text)
        => WireGuardValues(text)
            .Where(v => v.Section.Equals("Interface", StringComparison.OrdinalIgnoreCase) && v.Key.Equals("Address", StringComparison.OrdinalIgnoreCase))
            .SelectMany(v => v.Value.Split(','))
            .Select(s => s.Trim().Split('/')[0])
            .FirstOrDefault(s => s.Length > 0);
}
