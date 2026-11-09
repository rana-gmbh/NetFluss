// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using Microsoft.Win32;
using NetFluss.Core;

namespace NetFluss.App;

/// <summary>
/// Installs an update in place — the Windows counterpart of the macOS Sparkle 2 updates:
/// download this architecture's setup from the GitHub release, check it against the
/// release's SHA256SUMS.txt — itself signed, as Sparkle's appcast items are — run it
/// silently, and let it relaunch NetFluss.
///
/// <para>Neither check is optional. Without a valid <see cref="UpdateSignature"/> on the list
/// and a listed hash that matches the bytes, the update is refused and the user is pointed
/// at the release page instead — an installer that runs unattended must be exactly the one
/// Rana published, not merely one that sits in the release.</para>
/// </summary>
internal static class UpdateInstaller
{
    /// <summary>Matches AppId in windows/Packaging/NetFluss.iss.</summary>
    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\{6F3C9A41-2E7B-4D58-9C1A-5B0E8D2F7A13}_is1";

    /// <summary>
    /// Whether this copy came from the installer, so a setup can replace it. A portable copy
    /// (the zip) or a development build is left alone and offered the download instead.
    /// </summary>
    internal static bool IsInstalledCopy()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(UninstallKey);
            return key?.GetValue("InstallLocation") is string location &&
                   string.Equals(Path.GetFullPath(location).TrimEnd('\\'), AppContext.BaseDirectory.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or ArgumentException)
        {
            return false;
        }
    }

    internal static bool CanInstall(AvailableUpdate update) => update.Installer is not null && update.Checksums is not null && IsInstalledCopy();

    /// <summary>A setup on disk whose bytes matched the signed checksum list.</summary>
    internal sealed record VerifiedSetup(string Version, string Path, string Hash);

    /// <summary>
    /// Downloads, verifies and starts the setup. Null once the setup is running (the caller
    /// then quits); otherwise the reason it was not.
    /// </summary>
    internal static async Task<string?> InstallAsync(AvailableUpdate update, IProgress<double> progress, CancellationToken cancellation)
    {
        var (setup, error) = await DownloadAsync(update, progress, cancellation);
        return setup is null ? error : Launch(setup);
    }

    /// <summary>
    /// Fetches this architecture's setup into %LOCALAPPDATA%\NetFluss\Updates and checks it
    /// against the signed checksum list. A setup already downloaded for this version is
    /// reused when it still matches, so an update found in the background installs at once.
    /// </summary>
    internal static async Task<(VerifiedSetup? Setup, string? Error)> DownloadAsync(AvailableUpdate update, IProgress<double>? progress, CancellationToken cancellation)
    {
        if (update.Installer is not { } installer || update.Checksums is not { } checksums)
        {
            return (null, Localization.L("This release has no installer for this PC."));
        }

        // An unsigned release is never installed: the checksums only prove the installer is
        // the one listed, and only the signature proves the list is the one Rana published.
        if (update.Signature is not { } signatureUrl)
        {
            return (null, Localization.L("The update could not be verified, so it was not installed."));
        }

        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("NetFluss-Windows/" + UpdateNotifier.CurrentVersion);

        try
        {
            var fileName = Path.GetFileName(installer.AbsolutePath);
            var sumsBytes = await http.GetByteArrayAsync(checksums, cancellation);
            var signature = await http.GetStringAsync(signatureUrl, cancellation);
            if (!UpdateSignature.Verify(sumsBytes, signature) ||
                UpdateLookup.ExpectedHash(System.Text.Encoding.UTF8.GetString(sumsBytes), fileName) is not { } expected)
            {
                return (null, Localization.L("The update could not be verified, so it was not installed."));
            }

            // Not %TEMP%: Application Control and many company policies refuse to run programs
            // from there. NetFluss's own folder in the user's profile is where it runs from anyway.
            var updates = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NetFluss", "Updates");
            var folder = Path.Combine(updates, update.Version);
            if (Directory.Exists(updates))
            {
                // Setups from earlier updates; the one that is running now is not among them.
                foreach (var old in Directory.EnumerateDirectories(updates))
                {
                    if (string.Equals(Path.GetFullPath(old), Path.GetFullPath(folder), StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }

                    try
                    {
                        Directory.Delete(old, recursive: true);
                    }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                    {
                    }
                }
            }

            Directory.CreateDirectory(folder);
            var path = Path.Combine(folder, fileName);
            if (File.Exists(path) && await HashAsync(path, cancellation) == expected)
            {
                progress?.Report(1);
                return (new VerifiedSetup(update.Version, path, expected), null);
            }

            // Downloaded under another name, so a half-finished file is never taken for a setup.
            var partial = path + ".partial";
            using (var response = await http.GetAsync(installer, HttpCompletionOption.ResponseHeadersRead, cancellation))
            {
                response.EnsureSuccessStatusCode();
                var total = response.Content.Headers.ContentLength ?? 0;
                await using var source = await response.Content.ReadAsStreamAsync(cancellation);
                await using var target = File.Create(partial);
                var buffer = new byte[81920];
                long read = 0;
                int count;
                while ((count = await source.ReadAsync(buffer, cancellation)) > 0)
                {
                    await target.WriteAsync(buffer.AsMemory(0, count), cancellation);
                    read += count;
                    if (total > 0)
                    {
                        progress?.Report((double)read / total);
                    }
                }
            }

            if (await HashAsync(partial, cancellation) != expected)
            {
                File.Delete(partial);
                return (null, Localization.L("The update could not be verified, so it was not installed."));
            }

            File.Move(partial, path, overwrite: true);
            return (new VerifiedSetup(update.Version, path, expected), null);
        }
        catch (Exception e) when (e is HttpRequestException or IOException or UnauthorizedAccessException or TaskCanceledException)
        {
            return (null, Localization.L("The update could not be installed: {0}", e.Message));
        }
    }

    /// <summary>
    /// Starts a verified setup: silent, no reboot, and /LAUNCH asks it to start NetFluss again
    /// once it has replaced it. Null when it is running; the caller then quits, which the setup
    /// waits for. The file is hashed once more first, since it may have sat on disk a while.
    /// </summary>
    internal static string? Launch(VerifiedSetup setup)
    {
        try
        {
            string actual;
            using (var stream = File.OpenRead(setup.Path))
            {
                actual = Convert.ToHexStringLower(SHA256.HashData(stream));
            }

            if (actual != setup.Hash)
            {
                return Localization.L("The update could not be verified, so it was not installed.");
            }

            Process.Start(new ProcessStartInfo
            {
                FileName = setup.Path,
                Arguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LAUNCH",
                UseShellExecute = false,
            })?.Dispose();
            return null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            return Localization.L("The update could not be installed: {0}", e.Message);
        }
    }

    private static async Task<string> HashAsync(string path, CancellationToken cancellation)
    {
        await using var stream = File.OpenRead(path);
        return Convert.ToHexStringLower(await SHA256.HashDataAsync(stream, cancellation));
    }
}
