// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Diagnostics;
using System.Windows;
using System.Windows.Threading;
using NetFluss.Core;

namespace NetFluss.App;

/// <summary>
/// Scheduled update checks and installs, the Windows counterpart of Sparkle 2 on macOS.
///
/// <para>Once a day (if allowed) NetFluss asks GitHub for a newer Windows release. An installed
/// copy then downloads and verifies the setup in the background (<see cref="UpdateInstaller"/>)
/// and either asks — the <see cref="UpdateWindow"/>, with Install Update, Remind Me Later and
/// Skip This Version, as Sparkle does — or, with "Automatically download and install updates",
/// installs it by itself the next time no NetFluss window is in use, and relaunches.</para>
/// </summary>
internal sealed class UpdateNotifier
{
    private static readonly TimeSpan CheckInterval = TimeSpan.FromHours(24);

    /// <summary>
    /// The first check waits for the network to settle after sign-in: a check fired the
    /// moment the app starts at login usually fails, and then waits a whole day to retry.
    /// </summary>
    private static readonly TimeSpan StartupDelay = TimeSpan.FromSeconds(45);

    /// <summary>How often an automatic install looks for a moment when NetFluss is not in use.</summary>
    private static readonly TimeSpan IdlePoll = TimeSpan.FromMinutes(1);

    private readonly SettingsStore _store;
    private readonly Func<bool> _isInUse;
    private readonly DispatcherTimer _timer;
    private readonly DispatcherTimer _idleTimer;
    private bool _checking;
    private Task<(UpdateInstaller.VerifiedSetup? Setup, string? Error)>? _download;
    private string? _downloadVersion;
    private UpdateInstaller.VerifiedSetup? _ready;

    /// <summary>Who sees download progress: whoever asked last, even for a download already running.</summary>
    private IProgress<double>? _progressTarget;

    /// <param name="isInUse">Whether installing now would get in the user's way (an open window, a VPN connection).</param>
    internal UpdateNotifier(SettingsStore store, Func<bool> isInUse)
    {
        _store = store;
        _isInUse = isInUse;
        _timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = StartupDelay };
        _timer.Tick += async (_, _) =>
        {
            _timer.Interval = TimeSpan.FromHours(1);
            await CheckIfDueAsync();
        };

        _idleTimer = new DispatcherTimer(DispatcherPriority.Background) { Interval = IdlePoll };
        _idleTimer.Tick += (_, _) => InstallIfIdle();
    }

    /// <summary>A scheduled check found a release the user should be asked about.</summary>
    internal event EventHandler<AvailableUpdate>? UpdateFound;

    internal AvailableUpdate? Available { get; private set; }

    internal static string CurrentVersion => HelperClient.AppVersion;

    /// <summary>
    /// The test channel: with NETFLUSS_UPDATE_PRERELEASES=1, pre-releases are offered too.
    /// They still need a valid signature, so this widens what is offered, never what is trusted.
    /// </summary>
    private static bool IncludePrereleases => Environment.GetEnvironmentVariable("NETFLUSS_UPDATE_PRERELEASES") == "1";

    internal void Start() => _timer.Start();

    /// <summary>
    /// The version this launch was updated to, once: set before a setup is started and read
    /// by the copy it relaunches. Null after a normal start or a setup that did not finish.
    /// </summary>
    internal string? TakeCompletedUpdate()
    {
        var installing = _store.Settings.InstallingUpdateVersion;
        if (installing.Length == 0)
        {
            return null;
        }

        _store.Batch(s => s.InstallingUpdateVersion = string.Empty);
        return installing == CurrentVersion ? installing : null;
    }

    /// <summary>The About window's button and the tray menu: checks now, regardless of the schedule.</summary>
    internal async Task<AvailableUpdate?> CheckNowAsync()
    {
        var update = await UpdateLookup.FetchAsync(CurrentVersion, IncludePrereleases);
        _store.Batch(settings => settings.LastUpdateCheck = DateTimeOffset.Now);
        Available = update;
        return update;
    }

    /// <summary>
    /// The verified setup for <paramref name="update"/>: the one fetched in the background if
    /// it is ready or still coming, otherwise a fresh download.
    /// </summary>
    internal Task<(UpdateInstaller.VerifiedSetup? Setup, string? Error)> PrepareAsync(AvailableUpdate update, IProgress<double>? progress)
    {
        if (_ready is { } ready && ready.Version == update.Version)
        {
            progress?.Report(1);
            return Task.FromResult<(UpdateInstaller.VerifiedSetup?, string?)>((ready, null));
        }

        _progressTarget = progress;
        if (_download is { IsCompleted: false } running && _downloadVersion == update.Version)
        {
            return running;
        }

        _downloadVersion = update.Version;
        _download = DownloadAsync(update);
        return _download;
    }

    /// <summary>
    /// Installs and relaunches: starts the setup and quits NetFluss, which the setup waits for.
    /// Null once that is under way; otherwise why it is not.
    /// </summary>
    internal async Task<string?> InstallAsync(AvailableUpdate update, IProgress<double>? progress)
    {
        var (setup, error) = await PrepareAsync(update, progress);
        return setup is null ? error : Install(setup);
    }

    /// <summary>"Skip This Version": the scheduled checks stop offering it.</summary>
    internal void Skip(AvailableUpdate update) => _store.Batch(s => s.SkippedUpdateVersion = update.Version);

    private async Task<(UpdateInstaller.VerifiedSetup? Setup, string? Error)> DownloadAsync(AvailableUpdate update)
    {
        // Created here, on the UI thread, so reports arrive there too.
        var relay = new Progress<double>(fraction => _progressTarget?.Report(fraction));
        var result = await UpdateInstaller.DownloadAsync(update, relay, CancellationToken.None);
        if (result.Setup is { } setup)
        {
            _ready = setup;
        }

        return result;
    }

    private string? Install(UpdateInstaller.VerifiedSetup setup)
    {
        _idleTimer.Stop();
        _store.Batch(s => s.InstallingUpdateVersion = setup.Version);
        var error = UpdateInstaller.Launch(setup);
        if (error is not null)
        {
            _store.Batch(s => s.InstallingUpdateVersion = string.Empty);
            return error;
        }

        // Quitting cleanly saves statistics and the timer before the setup replaces the files.
        Application.Current.Shutdown();
        return null;
    }

    private async Task CheckIfDueAsync()
    {
        var settings = _store.Settings;
        if (_checking || !settings.AutomaticUpdateChecks)
        {
            return;
        }

        if (settings.LastUpdateCheck is { } last && DateTimeOffset.Now - last < CheckInterval)
        {
            return;
        }

        _checking = true;
        try
        {
            var update = await CheckNowAsync();
            if (update is null || update.Version == _store.Settings.SkippedUpdateVersion)
            {
                return;
            }

            if (!UpdateInstaller.CanInstall(update))
            {
                // A portable copy or a release without a verifiable setup: ask, offering the download.
                UpdateFound?.Invoke(this, update);
                return;
            }

            if (_store.Settings.AutomaticallyInstallUpdates)
            {
                var (setup, _) = await PrepareAsync(update, progress: null);
                if (setup is not null)
                {
                    _idleTimer.Start();
                    return;
                }

                // Downloading or verifying failed: ask instead, where the error can be shown.
            }
            else
            {
                // Fetched while the user reads the notes, so Install Update is quick.
                _ = PrepareAsync(update, progress: null);
            }

            UpdateFound?.Invoke(this, update);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            // Offline, rate-limited or GitHub down: try again in an hour, say nothing.
        }
        finally
        {
            _checking = false;
        }
    }

    private void InstallIfIdle()
    {
        if (_ready is not { } setup || !_store.Settings.AutomaticallyInstallUpdates)
        {
            _idleTimer.Stop();
            return;
        }

        if (_isInUse())
        {
            return;
        }

        if (Install(setup) is not null && Available is { } update)
        {
            // The setup would not start: fall back to asking, which shows why.
            UpdateFound?.Invoke(this, update);
        }
    }

    internal static void Open(Uri url)
    {
        try
        {
            Process.Start(new ProcessStartInfo(url.ToString()) { UseShellExecute = true });
        }
        catch (System.ComponentModel.Win32Exception)
        {
        }
    }
}
