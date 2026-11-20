// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using NetFluss.Core;

namespace NetFluss.App;

/// <summary>
/// The words for encrypted presets, shared by the popover and Preferences so a preset reads
/// the same everywhere: the badge for what this PC lacks, and the line under a preset's name.
/// </summary>
internal static class EncryptedDnsText
{
    /// <summary>Why a transport cannot be used here, as a short badge; empty when it can.</summary>
    internal static string Block(EncryptedDnsBlock block) => block switch
    {
        EncryptedDnsBlock.NeedsWindows11 => Localization.L("Needs Windows 11"),
        EncryptedDnsBlock.NeedsWindows11Version24H2 => Localization.L("Needs Windows 11 24H2"),
        EncryptedDnsBlock.Policy => Localization.L("Turned off by your administrator"),
        EncryptedDnsBlock.NotOnThisPc => Localization.L("Not available on this PC"),
        _ => string.Empty,
    };

    /// <summary>The badge for a preset on this PC, or empty for a plain or usable one.</summary>
    internal static string Block(DnsPreset preset, EncryptedDnsCapabilities capabilities)
        => preset.Encryption is { } encryption ? Block(capabilities.BlockFor(encryption.Transport)) : string.Empty;

    /// <summary>
    /// The secondary line: the URL or host for an encrypted preset (as on macOS — the servers
    /// say little there), the servers for a plain one.
    /// </summary>
    internal static string Detail(DnsPreset preset)
        => preset.Encryption is { } encryption
            ? encryption.Endpoint
            : preset.IsAutomatic ? Localization.L("Automatic (DHCP)") : string.Join(", ", preset.Servers);

    /// <summary>
    /// The encrypted-DNS status line, worded as on macOS: which encrypted preset is on, or
    /// that a plain one is in use.
    /// </summary>
    internal static string Status(AppSettings settings, DnsAdapterState? state, string? activePresetId)
    {
        if (state?.Encryption is not { } encryption)
        {
            return Localization.L("Off: a plain DNS preset is in use.");
        }

        var active = settings.AllDnsPresets().FirstOrDefault(preset => preset.Id == activePresetId && preset.IsEncrypted);
        return Localization.L("On: {0}", active is not null
            ? settings.DnsPresetDisplayName(active)
            : $"{DnsTransports.ShortName(encryption.Transport)} {encryption.Endpoint}");
    }
}
