// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

using System.Net.Http;
using System.Windows;
using NetFluss.Core;
using Windows.Networking.Connectivity;

namespace NetFluss.App;

/// <summary>
/// Keeps <see cref="LinkStatus"/> current for the link indicator and the automatic DNS rules.
/// Port of the macOS <c>LinkHealthTracker</c>'s plumbing; the decision table is in Core.
///
/// <para><b>Where "is the internet there?" comes from.</b> macOS has to ask: it polls Apple's
/// captive-portal page on change and on a backoff. Windows already runs that check itself —
/// the Network Connectivity Status Indicator — and publishes the verdict, including a
/// distinct "constrained" state for a captive portal. So by default NetFluss reads Windows'
/// answer and makes no request of its own: the same check the Mac performs, at none of the
/// cost, and event-driven through <c>NetworkStatusChanged</c> rather than on a clock.</para>
///
/// <para>A user-chosen check address replaces that with a probe on the Mac's own schedule,
/// for networks where Windows' test is blocked or misleads.</para>
/// </summary>
internal sealed class LinkHealthService : IDisposable
{
    /// <summary>
    /// Re-read Windows' verdict at least this often even without an event. The read is a local
    /// query, not a request; this only bounds how long a missed event could leave it stale.
    /// </summary>
    private static readonly TimeSpan OsRefreshInterval = TimeSpan.FromSeconds(30);

    private static readonly HttpClient Http = CreateHttp();

    private readonly NetworkMonitorService _monitor;
    private readonly SettingsStore _store;
    private readonly LinkProbe _probe = new();

    private LinkProbeOutcome? _osVerdict;
    private volatile bool _osDirty = true;
    private DateTime _osCheckedAt = DateTime.MinValue;
    private bool _osQueryInFlight;
    private bool _disposed;

    internal LinkHealthService(NetworkMonitorService monitor, SettingsStore store)
    {
        _monitor = monitor;
        _store = store;

        try
        {
            NetworkInformation.NetworkStatusChanged += OnNetworkStatusChanged;
        }
        catch (Exception e) when (e is InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            // Without the event the periodic re-read still keeps the verdict honest.
        }

        _monitor.Ticked += (_, _) => Evaluate();
    }

    internal LinkStatus Status { get; private set; } = LinkStatus.Offline;

    /// <summary>Raised on the UI thread when <see cref="Status"/> changes.</summary>
    internal event EventHandler? Changed;

    /// <summary>
    /// Whether anything consumes the status. The DNS rules need it as much as the indicator
    /// does, so neither depends on the other being switched on (macOS 2.7.2, #69).
    /// </summary>
    internal Func<bool> IsWanted { get; set; } = () => true;

    private void OnNetworkStatusChanged(object? sender) => _osDirty = true;

    /// <summary>Runs on every monitor tick, on the UI thread.</summary>
    internal void Evaluate()
    {
        if (_disposed || !IsWanted())
        {
            return;
        }

        var settings = _store.Settings;
        var addresses = _monitor.Addresses;
        var carrier = LinkHealthEvaluator.Carrier(addresses.PrimaryAdapterId, _monitor.LastSample);

        LinkProbeOutcome? verdict = null;
        var addressed = carrier is { IsUp: true } && !LinkHealthEvaluator.IsUnusable(addresses.InternalIp, addresses.GatewayIp);

        // A locked session pauses the lookups behind the meter, and this is one of them.
        if (settings.LinkCheckInternet && addressed && !_monitor.Quiet)
        {
            if (string.IsNullOrEmpty(settings.LinkProbeUrl))
            {
                _probe.Reset();
                QueryWindowsIfDue();
                verdict = _osVerdict;
            }
            else
            {
                var fingerprint = LinkHealthEvaluator.Fingerprint(carrier!, addresses.InternalIp, addresses.GatewayIp);
                if (_probe.ShouldProbe(fingerprint, DateTime.UtcNow))
                {
                    StartProbe(settings.LinkProbeUrl);
                }

                verdict = _probe.Verdict;
            }
        }
        else if (!addressed)
        {
            // A new network says nothing about the last one's verdict.
            _probe.Reset();
        }

        Publish(LinkHealthEvaluator.Evaluate(carrier, addresses.InternalIp, addresses.GatewayIp, settings.LinkCheckInternet, verdict));
    }

    private void Publish(LinkStatus status)
    {
        if (status == Status)
        {
            return;
        }

        Status = status;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void QueryWindowsIfDue()
    {
        if (_osQueryInFlight || (!_osDirty && DateTime.UtcNow - _osCheckedAt < OsRefreshInterval))
        {
            return;
        }

        _osDirty = false;
        _osQueryInFlight = true;
        _osCheckedAt = DateTime.UtcNow;

        // Off the UI thread: the connectivity profile is a local query, but it is a COM call
        // into the network stack and can stall briefly while an adapter is coming up.
        _ = Task.Run(() =>
        {
            LinkProbeOutcome outcome;
            try
            {
                var level = NetworkInformation.GetInternetConnectionProfile()?.GetNetworkConnectivityLevel()
                            ?? NetworkConnectivityLevel.None;
                outcome = level switch
                {
                    NetworkConnectivityLevel.InternetAccess => LinkProbeOutcome.Online,
                    // Windows' name for a captive portal: something answers, not the internet.
                    NetworkConnectivityLevel.ConstrainedInternetAccess => LinkProbeOutcome.Portal,
                    _ => LinkProbeOutcome.Unreachable,
                };
            }
            catch (Exception)
            {
                // No verdict is better than a wrong one: unknown shows as online.
                outcome = LinkProbeOutcome.Online;
            }

            Dispatch(() =>
            {
                _osQueryInFlight = false;
                if (_osVerdict != outcome)
                {
                    _osVerdict = outcome;
                    Evaluate();
                }
            });
        });
    }

    private void StartProbe(string url)
    {
        _probe.Started(DateTime.UtcNow);
        _ = Task.Run(async () =>
        {
            int? status = null;
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, url);

                // A cached answer from before walking into the hotel would hide the portal
                // standing in front of us now.
                request.Headers.CacheControl = new System.Net.Http.Headers.CacheControlHeaderValue { NoCache = true, NoStore = true };
                using var response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false);
                status = (int)response.StatusCode;
            }
            catch (Exception e) when (e is HttpRequestException or TaskCanceledException or InvalidOperationException)
            {
                status = null;
            }

            var outcome = LinkProbe.Classify(status);
            Dispatch(() =>
            {
                if (_probe.Completed(outcome))
                {
                    Evaluate();
                }
            });
        });
    }

    private static void Dispatch(Action action)
    {
        if (Application.Current?.Dispatcher is { } dispatcher && !dispatcher.HasShutdownStarted)
        {
            dispatcher.BeginInvoke(action);
        }
    }

    /// <summary>
    /// Redirects are not followed: a portal answers by redirecting to its login page, and
    /// following it would land on a 200 and report the portal as the internet.
    /// </summary>
    private static HttpClient CreateHttp()
    {
        var http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false })
        {
            Timeout = TimeSpan.FromSeconds(4),
        };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("NetFluss/1.0");
        return http;
    }

    public void Dispose()
    {
        _disposed = true;
        try
        {
            NetworkInformation.NetworkStatusChanged -= OnNetworkStatusChanged;
        }
        catch (Exception e) when (e is InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
        }
    }
}
