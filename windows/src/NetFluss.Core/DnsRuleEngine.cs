// Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.

namespace NetFluss.Core;

public enum DnsAutoSwitchKind
{
    Off,

    /// <summary>
    /// No helper, so the only way to set DNS would be a UAC prompt on every network change.
    /// </summary>
    NeedsHelper,

    /// <summary>A VPN profile's DNS owns the resolver right now.</summary>
    SuspendedByVpn,

    /// <summary>
    /// On a network with a rule, but holding at DHCP until the captive portal is cleared —
    /// applying early is what breaks the login page.
    /// </summary>
    WaitingForPortal,

    /// <summary>
    /// On a network with a rule, but the link is down. Kept apart from <see cref="NoRule"/> so
    /// a matched rule never reads as "no rule applies".
    /// </summary>
    WaitingForNetwork,

    Applied,

    NoRule,
}

/// <summary>What the engine decided, for the UI to explain itself. Port of the macOS <c>DNSAutoSwitchState</c>.</summary>
public sealed record DnsAutoSwitchState(DnsAutoSwitchKind Kind, string? Ssid = null, string? PresetId = null)
{
    public static readonly DnsAutoSwitchState Off = new(DnsAutoSwitchKind.Off);

    public static readonly DnsAutoSwitchState NeedsHelper = new(DnsAutoSwitchKind.NeedsHelper);

    public static readonly DnsAutoSwitchState SuspendedByVpn = new(DnsAutoSwitchKind.SuspendedByVpn);

    public static readonly DnsAutoSwitchState NoRule = new(DnsAutoSwitchKind.NoRule);

    public static DnsAutoSwitchState WaitingForPortal(string ssid) => new(DnsAutoSwitchKind.WaitingForPortal, ssid);

    public static DnsAutoSwitchState WaitingForNetwork(string ssid) => new(DnsAutoSwitchKind.WaitingForNetwork, ssid);

    /// <summary>An empty <paramref name="ssid"/> means the catch-all applied on a wired or unassociated link.</summary>
    public static DnsAutoSwitchState Applied(string ssid, string presetId) => new(DnsAutoSwitchKind.Applied, ssid, presetId);
}

/// <summary>Everything the decision needs, so it can be exercised without touching system DNS.</summary>
public sealed record DnsRuleInput
{
    public bool Enabled { get; init; }

    public bool HelperEnabled { get; init; }

    public string? Ssid { get; init; }

    public string? Bssid { get; init; }

    public LinkHealth? LinkHealth { get; init; }

    /// <summary>
    /// Whether the portal check can be trusted. With the internet check off there is no portal
    /// signal, so the engine cannot wait for one.
    /// </summary>
    public bool PortalSignalAvailable { get; init; }

    public bool VpnDnsActive { get; init; }

    public string? ActivePresetId { get; init; }

    /// <summary>The adapter's static resolvers, or null until they have been read.</summary>
    public IReadOnlyList<string>? CurrentServers { get; init; }

    /// <summary>Servers of every known preset, by id.</summary>
    public IReadOnlyDictionary<string, IReadOnlyList<string>> PresetServers { get; init; } = new Dictionary<string, IReadOnlyList<string>>();

    public IReadOnlyList<DnsRule> Rules { get; init; } = [];

    public string? FallbackPresetId { get; init; }
}

/// <summary>Either "leave DNS alone, and here is why" or "apply this preset".</summary>
public sealed record DnsRuleDecision(DnsAutoSwitchState State, string? ApplyPresetId = null)
{
    public static DnsRuleDecision Hold(DnsAutoSwitchState state) => new(state);

    public static DnsRuleDecision Apply(string presetId, DnsAutoSwitchState state) => new(state, presetId);
}

/// <summary>
/// Decides which DNS preset the current network should be using. Port of the macOS 2.7
/// <c>DNSRuleEngine</c>: the decision table is pure, and <see cref="Evaluate"/> adds the
/// settle delay and the retry backoff on a clock the caller passes in.
/// </summary>
public sealed class DnsRuleEngine
{
    /// <summary>Let routes, DHCP and the portal check settle before writing DNS.</summary>
    public static readonly TimeSpan SettleDelay = TimeSpan.FromSeconds(2);

    /// <summary>
    /// A write that did not take is retried on a growing delay. Every attempt is a privileged
    /// call, and a resolver change flushes the DNS cache, so a failure must not repeat on
    /// every tick.
    /// </summary>
    public static readonly TimeSpan FirstRetryDelay = TimeSpan.FromSeconds(5);

    public static readonly TimeSpan MaxRetryDelay = TimeSpan.FromMinutes(5);

    private string? _lastNetworkKey;
    private DateTime? _pendingSince;
    private (string PresetId, DateTime At, int Count)? _lastAttempt;

    public DnsAutoSwitchState State { get; private set; } = DnsAutoSwitchState.Off;

    public event EventHandler? StateChanged;

    public void Reset()
    {
        _lastNetworkKey = null;
        _pendingSince = null;
        _lastAttempt = null;
        Publish(DnsAutoSwitchState.Off);
    }

    /// <summary>
    /// The decision table. Order is the whole design: each guard explains why the engine
    /// must not write DNS in that situation.
    /// </summary>
    public static DnsRuleDecision Decide(DnsRuleInput input)
    {
        if (!input.Enabled)
        {
            return DnsRuleDecision.Hold(DnsAutoSwitchState.Off);
        }

        // Without the helper every write is a UAC prompt, on every network change. Refuse
        // rather than degrade into that.
        if (!input.HelperEnabled)
        {
            return DnsRuleDecision.Hold(DnsAutoSwitchState.NeedsHelper);
        }

        // A VPN profile's resolvers are in charge while it is up; a rule written underneath
        // would be a change the user cannot see take effect.
        if (input.VpnDnsActive)
        {
            return DnsRuleDecision.Hold(DnsAutoSwitchState.SuspendedByVpn);
        }

        if (string.IsNullOrEmpty(input.Ssid))
        {
            // Wired, or no association: only the catch-all can apply.
            if (input.FallbackPresetId is not { } fallback)
            {
                return DnsRuleDecision.Hold(DnsAutoSwitchState.NoRule);
            }

            var wired = DnsAutoSwitchState.Applied(string.Empty, fallback);
            return IsApplied(fallback, input) ? DnsRuleDecision.Hold(wired) : DnsRuleDecision.Apply(fallback, wired);
        }

        var ssid = input.Ssid;
        if ((Match(ssid, input.Bssid, input.Rules) ?? input.FallbackPresetId) is not { } target)
        {
            return DnsRuleDecision.Hold(DnsAutoSwitchState.NoRule);
        }

        // Captive portals answer DNS themselves; handing the machine a public resolver
        // before the login page is cleared is how you end up online with nothing working.
        if (input.PortalSignalAvailable && input.LinkHealth == Core.LinkHealth.Limited)
        {
            return DnsRuleDecision.Hold(DnsAutoSwitchState.WaitingForPortal(ssid));
        }

        if (input.LinkHealth == Core.LinkHealth.Offline)
        {
            return DnsRuleDecision.Hold(DnsAutoSwitchState.WaitingForNetwork(ssid));
        }

        // Already right: never spend a privileged call confirming it.
        var applied = DnsAutoSwitchState.Applied(ssid, target);
        return IsApplied(target, input) ? DnsRuleDecision.Hold(applied) : DnsRuleDecision.Apply(target, applied);
    }

    /// <summary>
    /// Whether the live resolver already is this preset. Compared by servers as well as by id:
    /// the active id is the first preset matching the live servers, so a custom preset with
    /// the same servers as a built-in would otherwise never count as applied and be rewritten
    /// for ever.
    /// </summary>
    private static bool IsApplied(string presetId, DnsRuleInput input)
    {
        if (presetId == input.ActivePresetId)
        {
            return true;
        }

        return input.CurrentServers is { } current
               && input.PresetServers.TryGetValue(presetId, out var servers)
               && current.Count == servers.Count
               && current.Order(StringComparer.OrdinalIgnoreCase).SequenceEqual(servers.Order(StringComparer.OrdinalIgnoreCase), StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>Most specific first: this access point, then this network name.</summary>
    public static string? Match(string ssid, string? bssid, IReadOnlyList<DnsRule> rules)
    {
        var active = rules.Where(rule => rule.Enabled && rule.Ssid == ssid).ToList();
        if (!string.IsNullOrEmpty(bssid)
            && active.FirstOrDefault(rule => string.Equals(rule.Bssid ?? string.Empty, bssid, StringComparison.OrdinalIgnoreCase)) is { } pinned)
        {
            return pinned.PresetId;
        }

        return active.FirstOrDefault(rule => string.IsNullOrEmpty(rule.Bssid))?.PresetId;
    }

    /// <summary>Runs the table and applies the debounce. Returns the preset to apply, if any.</summary>
    public string? Evaluate(DnsRuleInput input, DateTime now)
    {
        var decision = Decide(input);
        var key = $"{input.Ssid}|{input.Bssid}";
        if (key != _lastNetworkKey)
        {
            _lastNetworkKey = key;
            _pendingSince = now;
            _lastAttempt = null;
        }

        if (decision.ApplyPresetId is not { } presetId)
        {
            if (decision.State.Kind == DnsAutoSwitchKind.Applied)
            {
                _lastAttempt = null;
            }

            Publish(decision.State);
            return null;
        }

        // Networks arrive in pieces — association, address, route — and writing DNS into the
        // middle of that is how you get a write per tick. Wait for it to settle.
        if (_pendingSince is not { } since || now - since < SettleDelay)
        {
            return null;
        }

        var attempts = _lastAttempt is { } last && last.PresetId == presetId ? last.Count : 0;
        if (attempts > 0 && now - _lastAttempt!.Value.At < RetryDelay(attempts))
        {
            return null;
        }

        _lastAttempt = (presetId, now, attempts + 1);
        Publish(decision.State);
        return presetId;
    }

    /// <summary>5, 10, 20 … seconds, up to five minutes.</summary>
    public static TimeSpan RetryDelay(int attempts)
    {
        var seconds = FirstRetryDelay.TotalSeconds * Math.Pow(2, Math.Max(0, attempts - 1));
        return seconds >= MaxRetryDelay.TotalSeconds ? MaxRetryDelay : TimeSpan.FromSeconds(seconds);
    }

    private void Publish(DnsAutoSwitchState state)
    {
        if (state == State)
        {
            return;
        }

        State = state;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }
}
