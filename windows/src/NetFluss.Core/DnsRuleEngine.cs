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

    /// <summary>
    /// The rule wants an encrypted preset this PC cannot use — Windows 10, DoT before 24H2, a
    /// policy prohibiting DoH, or a helper too old to set it. Held rather than downgraded to
    /// plain DNS, which would quietly undo what the rule is for.
    /// </summary>
    EncryptedDnsUnavailable,

    /// <summary>
    /// The user picked a resolver by hand on this network; the rules stay out of it until
    /// another network is joined. An empty <see cref="DnsAutoSwitchState.Ssid"/> means wired.
    /// </summary>
    ManualOverride,
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

    public static DnsAutoSwitchState EncryptedDnsUnavailable(string presetId) => new(DnsAutoSwitchKind.EncryptedDnsUnavailable, PresetId: presetId);

    /// <summary>An empty <paramref name="ssid"/> means the pick was made on a wired or unassociated link.</summary>
    public static DnsAutoSwitchState ManualOverride(string ssid) => new(DnsAutoSwitchKind.ManualOverride, ssid);
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

    /// <summary>Servers of every known preset, by id — hidden ones included, since a rule may name one.</summary>
    public IReadOnlyDictionary<string, IReadOnlyList<string>> PresetServers { get; init; } = new Dictionary<string, IReadOnlyList<string>>();

    /// <summary>The encryption of every encrypted preset, by id; a preset not listed is plain.</summary>
    public IReadOnlyDictionary<string, DnsEncryption> PresetEncryption { get; init; } = new Dictionary<string, DnsEncryption>();

    /// <summary>The adapter's encryption as read back from Windows; null is plain DNS.</summary>
    public DnsEncryption? CurrentEncryption { get; init; }

    /// <summary>The adapter's servers are encrypted in a way no preset describes.</summary>
    public bool CurrentEncryptionMixed { get; init; }

    /// <summary>
    /// What the helper can set. <see cref="EncryptedDnsCapabilities.None"/> when it cannot set
    /// encrypted DNS at all, which is also the default for callers that never use it.
    /// </summary>
    public EncryptedDnsCapabilities Capabilities { get; init; } = EncryptedDnsCapabilities.None;

    public IReadOnlyList<DnsRule> Rules { get; init; } = [];

    public string? FallbackPresetId { get; init; }

    /// <summary>
    /// The network (SSID, empty for wired) on which the user last picked a resolver by hand,
    /// if any. Kept in memory only: a restart is a fair point for the rules to take over again.
    /// </summary>
    public string? ManualOverrideNetwork { get; init; }
}

/// <summary>Either "leave DNS alone, and here is why", "apply this preset" or "switch encryption off".</summary>
public sealed record DnsRuleDecision(DnsAutoSwitchState State, string? ApplyPresetId = null, bool PauseEncryption = false)
{
    public static DnsRuleDecision Hold(DnsAutoSwitchState state) => new(state);

    public static DnsRuleDecision Apply(string presetId, DnsAutoSwitchState state) => new(state, presetId);

    /// <summary>Write the adapter's servers again without encryption, and nothing else.</summary>
    public static DnsRuleDecision Pause(DnsAutoSwitchState state) => new(state, PauseEncryption: true);
}

/// <summary>The write <see cref="DnsRuleEngine.Next"/> wants made: a preset, or the encryption pause.</summary>
public sealed record DnsRuleAction(string? PresetId, bool PauseEncryption = false);

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

        // A hand pick in the popover is a decision about this network, as on macOS: undoing
        // it a few seconds later made the switcher look broken.
        var networkName = input.Ssid ?? string.Empty;
        if (input.ManualOverrideNetwork is { } manual && manual == networkName)
        {
            return DnsRuleDecision.Hold(DnsAutoSwitchState.ManualOverride(networkName));
        }

        if (string.IsNullOrEmpty(input.Ssid))
        {
            // Wired, or no association: only the catch-all can apply.
            return input.FallbackPresetId is { } fallback
                ? Write(fallback, string.Empty, input)
                : DnsRuleDecision.Hold(DnsAutoSwitchState.NoRule);
        }

        var ssid = input.Ssid;
        if ((Match(ssid, input.Bssid, input.Rules) ?? input.FallbackPresetId) is not { } target)
        {
            return DnsRuleDecision.Hold(DnsAutoSwitchState.NoRule);
        }

        // Captive portals answer DNS themselves; handing the machine a public resolver
        // before the login page is cleared is how you end up online with nothing working.
        // An encrypted resolver cannot reach the portal at all, so one left on from the last
        // network is switched off meanwhile: the same servers, written without encryption.
        if (input.PortalSignalAvailable && input.LinkHealth == Core.LinkHealth.Limited)
        {
            var waiting = DnsAutoSwitchState.WaitingForPortal(ssid);
            return input.CurrentEncryption is not null ? DnsRuleDecision.Pause(waiting) : DnsRuleDecision.Hold(waiting);
        }

        if (input.LinkHealth == Core.LinkHealth.Offline)
        {
            return DnsRuleDecision.Hold(DnsAutoSwitchState.WaitingForNetwork(ssid));
        }

        return Write(target, ssid, input);
    }

    /// <summary>
    /// The tail every matched rule shares: skip what is already in effect, then check that
    /// this kind of write is possible at all.
    /// </summary>
    private static DnsRuleDecision Write(string presetId, string ssid, DnsRuleInput input)
    {
        // Already right: never spend a privileged call confirming it.
        var applied = DnsAutoSwitchState.Applied(ssid, presetId);
        if (IsApplied(presetId, input))
        {
            return DnsRuleDecision.Hold(applied);
        }

        if (input.PresetEncryption.TryGetValue(presetId, out var encryption) && !input.Capabilities.Supports(encryption.Transport))
        {
            return DnsRuleDecision.Hold(DnsAutoSwitchState.EncryptedDnsUnavailable(presetId));
        }

        return DnsRuleDecision.Apply(presetId, applied);
    }

    /// <summary>
    /// Whether the live resolver already is this preset. Compared by servers and encryption as
    /// well as by id: the active id is the first preset matching the live resolver, so a custom
    /// preset with the same servers as a built-in would otherwise never count as applied and be
    /// rewritten for ever. The encryption counts too — plain Cloudflare is not applied while
    /// the adapter speaks DoH to the same addresses.
    /// </summary>
    private static bool IsApplied(string presetId, DnsRuleInput input)
    {
        if (presetId == input.ActivePresetId)
        {
            return true;
        }

        if (input.CurrentEncryptionMixed
            || input.CurrentServers is not { } current
            || !input.PresetServers.TryGetValue(presetId, out var servers)
            || current.Count != servers.Count
            || !current.Order(StringComparer.OrdinalIgnoreCase).SequenceEqual(servers.Order(StringComparer.OrdinalIgnoreCase), StringComparer.OrdinalIgnoreCase))
        {
            return false;
        }

        return DnsEncryption.SameAs(input.PresetEncryption.GetValueOrDefault(presetId), input.CurrentEncryption);
    }

    /// <summary>
    /// The stored hand pick, or null once the PC is on a different network. Only a network
    /// that is actually up counts as different: a Wi-Fi drop or a re-association reads as no
    /// SSID for a moment and must not clear it (macOS does the same).
    /// </summary>
    /// <param name="stored">The network the pick was made on, empty for wired, or null for none.</param>
    /// <param name="ssid">The current network name, null or empty for wired or none.</param>
    /// <param name="networkUp">Whether the adapter is up and the link not offline.</param>
    public static string? CurrentManualOverride(string? stored, string? ssid, bool networkUp)
        => stored is not null && (stored == (ssid ?? string.Empty) || !networkUp) ? stored : null;

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

    /// <summary>
    /// Runs the table and applies the debounce. Returns the preset to apply, if any; an
    /// encryption pause is not a preset and reads as null here, so callers that act on
    /// decisions use <see cref="Next"/>.
    /// </summary>
    public string? Evaluate(DnsRuleInput input, DateTime now) => Next(input, now)?.PresetId;

    /// <summary>Runs the table and applies the debounce. Returns the write to make, if any.</summary>
    public DnsRuleAction? Next(DnsRuleInput input, DateTime now)
    {
        var decision = Decide(input);
        var key = $"{input.Ssid}|{input.Bssid}";
        if (key != _lastNetworkKey)
        {
            _lastNetworkKey = key;
            _pendingSince = now;
            _lastAttempt = null;
        }

        if (decision.PauseEncryption)
        {
            return Debounced(PauseKey, decision.State, now) ? new DnsRuleAction(null, PauseEncryption: true) : null;
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

        return Debounced(presetId, decision.State, now) ? new DnsRuleAction(presetId) : null;
    }

    /// <summary>The pause's slot in the backoff; no preset id can start with a NUL.</summary>
    private const string PauseKey = "\0pause-encryption";

    /// <summary>
    /// Networks arrive in pieces — association, address, route — and writing DNS into the
    /// middle of that is how you get a write per tick. Wait for it to settle, then back off a
    /// write that does not take.
    /// </summary>
    private bool Debounced(string key, DnsAutoSwitchState state, DateTime now)
    {
        if (_pendingSince is not { } since || now - since < SettleDelay)
        {
            return false;
        }

        var attempts = _lastAttempt is { } last && last.PresetId == key ? last.Count : 0;
        if (attempts > 0 && now - _lastAttempt!.Value.At < RetryDelay(attempts))
        {
            return false;
        }

        _lastAttempt = (key, now, attempts + 1);
        Publish(state);
        return true;
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
