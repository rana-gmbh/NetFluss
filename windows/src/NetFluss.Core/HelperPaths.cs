// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

namespace NetFluss.Core;

/// <summary>
/// Where the helper service lives: its binaries and the VPN staging folder, both under
/// Program Files, where only administrators can write.
///
/// <para><b>A folder of its own, never the app's.</b> Up to 2.7.2-beta.2 the helper ran from
/// <c>Program Files\NetFluss\Helper</c>. NetFluss normally installs per user, but anyone
/// who picked <c>Program Files\NetFluss</c> on Setup's folder page made that the app's own
/// <c>Helper</c> folder, and the next Setup failed to replace the running service's
/// executable (issue #70). <c>NetFluss Helper</c> is not a folder Setup accepts.</para>
/// </summary>
public sealed record HelperPaths(string ProgramFiles)
{
    public const string RootName = "NetFluss Helper";

    public static HelperPaths Current { get; } =
        new(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles));

    /// <summary><c>Program Files\NetFluss Helper</c>.</summary>
    public string Root => Path.Combine(ProgramFiles, RootName);

    /// <summary>The service's executable and the files it needs, nothing else.</summary>
    public string Binaries => Path.Combine(Root, "Bin");

    public string ServiceExecutable => Path.Combine(Binaries, "NetFluss.Service.exe");

    /// <summary>
    /// Beside <see cref="Binaries"/>, not inside it: installing replaces that folder and
    /// deletes whatever the new helper does not ship.
    /// </summary>
    public string VpnStaging => Path.Combine(Root, "VpnStaging");

    /// <summary>The folder that held both up to 2.7.2-beta.2.</summary>
    public string LegacyRoot => Path.Combine(ProgramFiles, "NetFluss");

    public string LegacyBinaries => Path.Combine(LegacyRoot, "Helper");

    public string LegacyVpnStaging => Path.Combine(LegacyRoot, "VpnStaging");

    /// <summary>
    /// Whether the old helper folder may be deleted once the helper has moved. Not when NetFluss
    /// itself is installed in <see cref="LegacyRoot"/>: there it is the app's own
    /// <c>Helper</c> folder, which Setup ships and the app installs the helper from.
    /// </summary>
    public bool MayRemoveLegacyBinaries(string appDirectory, Func<string, bool> fileExists)
        => !IsSameOrInside(appDirectory, LegacyRoot)
           && !fileExists(Path.Combine(LegacyRoot, "NetFluss.exe"));

    /// <summary>Whether <paramref name="path"/> is <paramref name="folder"/> or lies inside it.</summary>
    public static bool IsSameOrInside(string path, string folder)
    {
        var p = Normalize(path);
        var f = Normalize(folder);
        return p.Equals(f, StringComparison.OrdinalIgnoreCase)
               || p.StartsWith(f + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    private static string Normalize(string path)
        => Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
}
