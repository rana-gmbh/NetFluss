// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using Microsoft.Win32;
using NetFluss.Core;

namespace NetFluss.Native;

/// <summary>
/// The parts of <see cref="EncryptedDnsCapabilities"/> anyone can read: the Windows build and
/// the DoH policy. The helper adds the DoT runtime check; the app uses this alone for the
/// badges it shows before the helper is there.
/// </summary>
public static class EncryptedDnsPlatform
{
    private const string PolicyKey = @"SOFTWARE\Policies\Microsoft\Windows NT\DNSClient";

    /// <summary>The real build: .NET reports the true OS version, with no compatibility shim.</summary>
    public static int Build => Environment.OSVersion.Version.Build;

    /// <summary>The DoHPolicy a Group Policy or MDM profile set, or null when none is.</summary>
    public static int? DohPolicy()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(PolicyKey);
            return key?.GetValue("DoHPolicy") as int?;
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            // Unreadable is treated as unset: the helper finds out for certain when Windows
            // refuses the write.
            return null;
        }
    }

    /// <summary>
    /// What this PC should support, assuming DoT works from build 26100 on. Only the helper
    /// can confirm that, by running netsh.
    /// </summary>
    public static EncryptedDnsCapabilities Assumed()
        => EncryptedDnsCapabilities.Evaluate(Build, DohPolicy(), dotRuntime: Build >= EncryptedDnsCapabilities.DotMinimumBuild);
}
