import Foundation

/// Why a VPN config was turned away before root touched it.
enum VPNConfigRefusal: Error, Equatable {
    case directive(String)
    case fileOutsideProfile(directive: String, path: String)
    case notPlainFile(String)
    case malformed(String)

    func message(kind: String) -> String {
        switch self {
        case .directive(let name):
            return "This \(kind) config was refused because it contains a '\(name)' directive, "
                + "which NetFluss will not run as root. Remove it and re-import."
        case .fileOutsideProfile(let directive, let path):
            return "This \(kind) config was refused because its '\(directive)' file (\(path)) "
                + "is outside the profile. Import that file together with the config."
        case .notPlainFile(let name):
            return "This \(kind) config was refused because '\(name)' is not a plain file "
                + "inside the profile, or is too large. Import it together with the config."
        case .malformed(let detail):
            return "This \(kind) config was refused because \(detail). Fix it and re-import."
        }
    }
}

/// Decides whether an OpenVPN config may be run as root.
///
/// This has to read the file exactly as openvpn does, or a line can mean one
/// thing here and another there. So it works on bytes, not `String`: Swift
/// treats CRLF as a single `Character`, which made an earlier line-based filter
/// see a Windows-format config as one long line, and a byte that isn't valid
/// UTF-8 made it give up and call the file clean. The rules below mirror
/// `read_config_file`, `parse_line`, `read_inline_file` and the `setenv opt`
/// prefix in openvpn 2.6's options.c.
///
/// It is an allowlist because a config has far more ways to reach root than
/// `plugin`: `pkcs11-providers`, `providers` and `engine` also load code,
/// `setenv opt plugin …` hides the word, and `log`, `status`, `writepid` and
/// friends write files as root.
enum OpenVPNConfigPolicy {
    /// `fgets` hands openvpn at most this many bytes per read, so anything longer
    /// comes apart in the middle: the tail of a comment would then be parsed as
    /// an option, and a close tag could appear at a read boundary this parser
    /// can't see. Real configs never get near it.
    static let maxLineBytes = 255

    /// Options that are safe to run as root. Up/down script hooks are here on
    /// purpose: `--script-security 1`, placed after `--config` in argv, stops them
    /// running, and many provider configs carry them for DNS.
    private static let allowedDirectives: Set<String> = [
        "allow-compression", "allow-pull-fqdn", "allow-recursive-routing", "askpass", "auth",
        "auth-nocache", "auth-retry", "auth-token", "auth-token-user", "auth-user-pass",
        "bcast-buffers", "bind", "bind-dev", "block-ipv6", "block-outside-dns", "ca", "cert",
        "cipher", "client", "comp-lzo", "comp-noadapt", "compat-mode", "compress",
        "connect-retry", "connect-retry-max", "connect-timeout", "crl-verify", "cryptoapicert",
        "data-ciphers", "data-ciphers-fallback", "dev", "dev-type", "dh", "dhcp-option",
        "dhcp-pre-release", "dhcp-release", "dhcp-renew", "disable-dco", "disable-occ", "dns",
        "down", "down-pre", "ecdh-curve", "echo", "explicit-exit-notify", "extra-certs",
        "fast-io", "float", "force-tls-key-material-export", "fragment", "group", "hand-window",
        "http-proxy", "http-proxy-option", "http-proxy-retry", "http-proxy-timeout",
        "http-proxy-user-pass", "ifconfig", "ifconfig-ipv6", "ifconfig-noexec",
        "ifconfig-nowarn", "ignore-unknown-option", "inactive", "ip-remote-hint", "ip-win32",
        "ipchange", "keepalive", "key", "key-derivation", "key-direction", "key-method",
        "keysize", "link-mtu", "local", "lport", "machine-readable-output", "mark", "max-routes",
        "mlock", "mssfix", "mtu-disc", "mtu-test", "mute", "mute-replay-warnings", "ncp-ciphers",
        "ncp-disable", "nice", "no-iv", "no-replay", "nobind", "ns-cert-type", "passtos",
        "peer-fingerprint", "peer-id", "persist-key", "persist-local-ip", "persist-remote-ip",
        "persist-tun", "ping", "ping-exit", "ping-restart", "ping-timer-rem", "pkcs12", "port",
        "preresolve", "prng", "proto", "proto-force", "protocol-flags", "pull", "pull-filter",
        "push-peer-info", "rcvbuf", "rdns-internal", "redirect-gateway", "redirect-private",
        "register-dns", "remap-usr1", "remote", "remote-cert-eku", "remote-cert-ku",
        "remote-cert-tls", "remote-random", "remote-random-hostname", "reneg-bytes",
        "reneg-pkts", "reneg-sec", "replay-window", "resolv-retry", "route", "route-delay",
        "route-gateway", "route-ipv6", "route-ipv6-gateway", "route-metric", "route-method",
        "route-noexec", "route-nopull", "route-pre-down", "route-up", "rport", "scramble",
        "script-security", "secret", "server-poll-timeout", "session-timeout", "setenv",
        "setenv-safe", "shaper", "sndbuf", "socket-flags", "socks-proxy", "socks-proxy-retry",
        "stale-routes-check", "static-challenge", "suppress-timestamps", "tap-sleep",
        "tcp-nodelay", "tcp-queue-limit", "tls-auth", "tls-cert-profile", "tls-cipher",
        "tls-ciphersuites", "tls-client", "tls-crypt", "tls-crypt-v2", "tls-exit", "tls-groups",
        "tls-remote", "tls-timeout", "tls-verify", "tls-version-max", "tls-version-min",
        "topology", "tran-window", "tun-ipv6", "tun-mtu", "tun-mtu-extra", "tun-mtu-max",
        "txqueuelen", "udp-mtu", "up", "up-delay", "up-restart", "use-prediction-resistance",
        "user", "verb", "verify-hash", "verify-x509-name", "win-sys", "windows-driver",
        "x509-track", "x509-username-field"
    ]

    /// `<tag>` blocks allowed in a config. A block's body is an argument to the
    /// option of the same name, so only options that take key material qualify.
    private static let allowedInlineTags: Set<String> = [
        "auth-user-pass", "ca", "cert", "connection", "crl-verify", "dh", "extra-certs",
        "http-proxy-user-pass", "key", "peer-fingerprint", "pkcs12", "secret", "tls-auth",
        "tls-crypt", "tls-crypt-v2"
    ]

    /// Directives that name a file, with the position of that file's argument.
    /// openvpn reads these as root, so they must stay inside the staged profile:
    /// `auth-user-pass /etc/master.passwd` would hand that file to the server.
    private static let fileArgument: [String: Int] = [
        "askpass": 1, "auth-user-pass": 1, "ca": 1, "cert": 1, "crl-verify": 1, "dh": 1,
        "extra-certs": 1, "http-proxy": 3, "http-proxy-user-pass": 1, "key": 1, "pkcs12": 1,
        "secret": 1, "socks-proxy": 3, "tls-auth": 1, "tls-crypt": 1, "tls-crypt-v2": 1
    ]

    /// Values in a file position that are keywords, not files.
    private static let fileKeywords: Set<String> = [
        "[[INLINE]]", "[inline]", "auto", "auto-nct", "none", "stdin"
    ]

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let connectionClose = Array("</connection>".utf8)

    /// Checks a config and returns the side files it needs, relative to it.
    static func referencedFiles(in config: [UInt8]) throws -> [String] {
        // openvpn's C strings would stop at a NUL, so the two parsers would part
        // ways there.
        guard !config.contains(0) else { throw VPNConfigRefusal.malformed("it contains a NUL byte") }

        var files: [String] = []
        var openBlockClose: [UInt8]?
        var inConnection = false
        var lineNumber = 0
        var start = 0

        while start < config.count {
            // Split on LF only, keeping it, as fgets does. CR is just whitespace.
            let end = config[start...].firstIndex(of: 0x0A).map { $0 + 1 } ?? config.count
            var line = config[start..<end]
            start = end
            lineNumber += 1

            guard line.count <= maxLineBytes else {
                throw VPNConfigRefusal.malformed("line \(lineNumber) is too long")
            }
            if lineNumber == 1, line.starts(with: utf8BOM) { line = line.dropFirst(utf8BOM.count) }

            if let close = openBlockClose {
                if closes(line, tag: close) { openBlockClose = nil }
                continue
            }
            if inConnection, closes(line, tag: connectionClose) {
                inConnection = false
                continue
            }

            var parameters = try tokens(of: line, lineNumber: lineNumber)
            guard !parameters.isEmpty else { continue }
            if parameters[0].count >= 3, parameters[0].starts(with: [0x2D, 0x2D]) {
                parameters[0].removeFirst(2)
            }

            if parameters.count == 1, parameters[0].first == 0x3C, parameters[0].last == 0x3E {
                let tag = Array(parameters[0].dropFirst().dropLast())
                let name = printable(tag)
                guard allowedInlineTags.contains(name) else { throw VPNConfigRefusal.directive("<\(name)>") }
                // A `<connection>` body is options, not data, so it gets the same
                // line checks as the rest of the file. A block nested inside one
                // would end at the first `</connection>` for openvpn but not here.
                guard !inConnection else {
                    throw VPNConfigRefusal.malformed("line \(lineNumber) nests a block inside <connection>")
                }
                if name == "connection" {
                    inConnection = true
                } else {
                    openBlockClose = Array("</".utf8) + tag + [0x3E]
                }
                continue
            }

            try check(parameters, files: &files)
        }

        guard openBlockClose == nil, !inConnection else {
            throw VPNConfigRefusal.malformed("a <block> is never closed")
        }
        return files
    }

    private static func check(_ parameters: [[UInt8]], files: inout [String]) throws {
        var parameters = parameters[...]
        // `setenv opt X …` is option X with errors downgraded to warnings.
        if parameters.count >= 2, printable(parameters[0]) == "setenv", printable(parameters[1]) == "opt" {
            guard parameters.count >= 3 else { throw VPNConfigRefusal.directive("setenv opt") }
            parameters = parameters.dropFirst(2)
        }

        let directive = printable(parameters[parameters.startIndex])
        guard allowedDirectives.contains(directive) else { throw VPNConfigRefusal.directive(directive) }

        guard let position = fileArgument[directive], position < parameters.count else { return }
        let argument = parameters[parameters.startIndex + position]
        guard let path = String(bytes: argument, encoding: .utf8) else {
            throw VPNConfigRefusal.fileOutsideProfile(directive: directive, path: printable(argument))
        }
        if fileKeywords.contains(path) { return }
        if directive == "crl-verify", parameters.count > 2 {
            throw VPNConfigRefusal.fileOutsideProfile(directive: directive, path: path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !components.contains("..") else {
            throw VPNConfigRefusal.fileOutsideProfile(directive: directive, path: path)
        }
        if !files.contains(path) { files.append(path) }
    }

    /// `read_inline_file`: a block ends at the first line that, after leading
    /// whitespace, *starts with* its close tag.
    private static func closes(_ line: ArraySlice<UInt8>, tag: [UInt8]) -> Bool {
        line.drop(while: isSpace).starts(with: tag)
    }

    /// `parse_line`, state for state, without its 256-byte parameter limit (which
    /// the line limit above already covers). Returns the line's parameters; a
    /// line openvpn would reject is refused here too.
    private static func tokens(of line: ArraySlice<UInt8>, lineNumber: Int) throws -> [[UInt8]] {
        enum State { case initial, unquoted, quoted, singleQuoted }

        var parameters: [[UInt8]] = []
        var current: [UInt8] = []
        var state = State.initial
        var backslash = false

        scan: for input in Array(line) + [0] {
            var output: UInt8 = 0

            if !backslash, input == 0x5C, state != .singleQuoted {
                backslash = true
                continue
            }

            var finished = false
            switch state {
            case .initial:
                if !isSpace(input) {
                    if input == 0x3B || input == 0x23 { break scan }
                    if !backslash, input == 0x22 {
                        state = .quoted
                    } else if !backslash, input == 0x27 {
                        state = .singleQuoted
                    } else {
                        output = input
                        state = .unquoted
                    }
                }
            case .unquoted:
                if !backslash, isSpace(input) { finished = true } else { output = input }
            case .quoted:
                if !backslash, input == 0x22 { finished = true } else { output = input }
            case .singleQuoted:
                if input == 0x27 { finished = true } else { output = input }
            }

            if finished {
                parameters.append(current)
                current = []
                state = .initial
            }
            if backslash, output != 0, !(output == 0x5C || output == 0x22 || isSpace(output)) {
                throw VPNConfigRefusal.malformed("line \(lineNumber) has a stray backslash")
            }
            backslash = false
            if output != 0 { current.append(output) }
        }

        guard state != .quoted, state != .singleQuoted else {
            throw VPNConfigRefusal.malformed("line \(lineNumber) has an unclosed quote")
        }
        return parameters
    }

    /// `space()` in options.c: NUL or C-locale `isspace`.
    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0 || byte == 0x20 || (0x09...0x0D).contains(byte)
    }
}

/// Decides whether a WireGuard config may be handed to `wg-quick` as root.
///
/// `wg-quick` evals `PreUp`, `PostUp`, `PreDown` and `PostDown`, so an imported
/// `.conf` is a root shell unless those lines are kept out. The key rules mirror
/// its `parse_options`: LF-separated, cut at the first `#`, key before the first
/// `=`, whitespace trimmed, case-insensitive. An allowlist, because bash drops
/// NUL bytes while reading, which a filter looking for those four words would
/// not see coming.
enum WireGuardConfigPolicy {
    private static let allowedKeys: Set<String> = [
        "address", "allowedips", "dns", "endpoint", "fwmark", "listenport", "mtu",
        "persistentkeepalive", "presharedkey", "privatekey", "publickey", "saveconfig", "table"
    ]
    private static let allowedSections: Set<String> = ["[interface]", "[peer]"]

    static func validate(_ config: [UInt8]) throws {
        guard !config.contains(0) else { throw VPNConfigRefusal.malformed("it contains a NUL byte") }

        for (index, rawLine) in config.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            let uncommented = rawLine.prefix { $0 != 0x23 }
            let line = trimmed(uncommented)
            guard !line.isEmpty else { continue }

            if line.first == 0x5B {
                let section = printable(line).lowercased()
                guard allowedSections.contains(section) else { throw VPNConfigRefusal.directive(section) }
                continue
            }
            guard let equals = line.firstIndex(of: 0x3D) else {
                throw VPNConfigRefusal.malformed("line \(index + 1) has no '=' in it")
            }
            let key = printable(trimmed(line[..<equals]))
            guard allowedKeys.contains(key.lowercased()) else { throw VPNConfigRefusal.directive(key) }
        }
    }

    private static func trimmed(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        let isSpace: (UInt8) -> Bool = { $0 == 0x20 || (0x09...0x0D).contains($0) }
        var result = bytes.drop(while: isSpace)
        while let last = result.last, isSpace(last) { result = result.dropLast() }
        return result
    }
}

/// A short, safe rendering of config bytes for comparisons and error messages.
private func printable<Bytes: Collection>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    String(String(decoding: bytes, as: UTF8.self).prefix(64))
}
