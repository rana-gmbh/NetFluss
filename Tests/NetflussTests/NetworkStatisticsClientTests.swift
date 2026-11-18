import Darwin
import Testing
@testable import Netfluss

@Suite
struct NetworkStatisticsClientTests {
    // Request contexts are the NSTAT wire request types, echoed by the kernel.
    private let subscribe: UInt64 = 1002
    private let query: UInt64 = 1004
    private let descriptor: UInt64 = 1005

    @Test func disappearingFlowDoesNotDisableHealthySubscription() {
        // Reproduced on macOS: GET_SRC_DESC returns ENOENT while counts
        // continue arriving. This must not switch the monitor to netstat diffs.
        #expect(!NetworkStatisticsClient.errorRequiresFallback(context: descriptor, error: ENOENT))
    }

    @Test func descriptorBufferPressureDoesNotDisableHealthySubscription() {
        for error in [ENOBUFS, EAGAIN] {
            #expect(!NetworkStatisticsClient.errorRequiresFallback(context: descriptor, error: error))
        }
    }

    @Test func unsupportedDescriptorDoesNotDisableSystemWideCounts() {
        #expect(!NetworkStatisticsClient.errorRequiresFallback(context: descriptor, error: EINVAL))
    }

    @Test func transientPollFailuresCanRetryWithoutFallback() {
        for error in [ENOBUFS, EAGAIN] {
            #expect(!NetworkStatisticsClient.errorRequiresFallback(context: query, error: error))
        }
    }

    @Test func rejectedSubscriptionStillRequiresFallback() {
        // Subscription requests are not retried by the polling timer.
        for error in [EINVAL, EACCES, ENOENT, ENOBUFS, EAGAIN] {
            #expect(NetworkStatisticsClient.errorRequiresFallback(context: subscribe, error: error))
        }
    }

    @Test func incompatibleCountsProtocolStillRequiresFallback() {
        #expect(NetworkStatisticsClient.errorRequiresFallback(context: query, error: EINVAL))
    }

    @Test func unknownPermanentErrorStillRequiresFallback() {
        #expect(NetworkStatisticsClient.errorRequiresFallback(context: 0, error: EINVAL))
    }

    // MARK: - Flow descriptors (layout read on macOS 27.2.1)

    private func descriptor(provider: UInt32, length: Int, ifindex: (Int, UInt32), pid: (Int, UInt32), name: (Int, String)) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        func put(_ value: UInt32, _ offset: Int) { for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xff) } }
        put(10003, 8)
        put(provider, 32)
        put(ifindex.1, ifindex.0)
        put(pid.1, pid.0)
        for (i, byte) in name.1.utf8.enumerated() { bytes[name.0 + i] = byte }
        return bytes
    }

    @Test func tcpDescriptorYieldsOwnerAndInterface() throws {
        let bytes = descriptor(provider: 2, length: 400, ifindex: (112, 13), pid: (156, 85115), name: (236, "Python"))
        let parsed = try #require(NetworkStatisticsClient.parseDescriptor(bytes, length: bytes.count))
        #expect(parsed == .init(provider: 2, ifindex: 13, pid: 85115, processName: "Python"))
    }

    @Test func userlandTCPUsesTheTCPLayout() throws {
        let bytes = descriptor(provider: 3, length: 400, ifindex: (112, 4), pid: (156, 321), name: (236, "Safari"))
        #expect(NetworkStatisticsClient.parseDescriptor(bytes, length: bytes.count)?.pid == 321)
    }

    @Test func udpDescriptorHasItsOwnLayout() throws {
        let bytes = descriptor(provider: 4, length: 320, ifindex: (152, 13), pid: (168, 85142), name: (172, "Python"))
        let parsed = try #require(NetworkStatisticsClient.parseDescriptor(bytes, length: bytes.count))
        #expect(parsed == .init(provider: 4, ifindex: 13, pid: 85142, processName: "Python"))
    }

    @Test func descriptorsBeyondTheirBoundsAreRejected() {
        let short = descriptor(provider: 2, length: 200, ifindex: (112, 13), pid: (156, 1), name: (180, "x"))
        #expect(NetworkStatisticsClient.parseDescriptor(short, length: short.count) == nil)
        let unknown = descriptor(provider: 9, length: 400, ifindex: (112, 13), pid: (156, 1), name: (236, "x"))
        #expect(NetworkStatisticsClient.parseDescriptor(unknown, length: unknown.count) == nil)
        // The declared length must fit in the buffer.
        let bytes = descriptor(provider: 2, length: 400, ifindex: (112, 13), pid: (156, 1), name: (236, "x"))
        #expect(NetworkStatisticsClient.parseDescriptor(bytes, at: 10, length: 400) == nil)
    }

    @Test func processNameCheckToleratesTruncation() {
        #expect(NetworkStatisticsClient.processNamesAgree(descriptor: "Python", actual: "Python"))
        // p_comm keeps 16 bytes, p_name 32.
        #expect(NetworkStatisticsClient.processNamesAgree(descriptor: "com.apple.WebKi", actual: "com.apple.WebKit.Networking"))
        #expect(!NetworkStatisticsClient.processNamesAgree(descriptor: "cubic", actual: "Python"))
        #expect(!NetworkStatisticsClient.processNamesAgree(descriptor: "", actual: "Python"))
    }

    @Test func flowDeltas() {
        typealias C = NetworkStatisticsClient.FlowCounts
        #expect(NetworkStatisticsClient.flowDelta(current: C(rx: 500, tx: 70), previous: C(rx: 200, tx: 50)) == C(rx: 300, tx: 20))
        // A flow first seen after the baseline is new: all of it counts.
        #expect(NetworkStatisticsClient.flowDelta(current: C(rx: 500, tx: 70), previous: nil) == C(rx: 500, tx: 70))
        // A reused srcref starts again from zero.
        #expect(NetworkStatisticsClient.flowDelta(current: C(rx: 10, tx: 5), previous: C(rx: 900, tx: 900)) == C(rx: 10, tx: 5))
    }

    // MARK: - Endpoints

    private func sockaddr4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8, port: UInt16) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 28)
        bytes[0] = 16; bytes[1] = UInt8(AF_INET)
        bytes[2] = UInt8(port >> 8); bytes[3] = UInt8(port & 0xff)
        bytes[4] = a; bytes[5] = b; bytes[6] = c; bytes[7] = d
        return bytes
    }

    @Test func ipv4EndpointIsDecoded() {
        let endpoint = NetworkStatisticsClient.endpoint(sockaddr4(1, 1, 1, 1, port: 443), at: 0)
        #expect(endpoint == .init(host: "1.1.1.1", port: 443))
    }

    @Test func ipv6EndpointIsDecoded() {
        var bytes = [UInt8](repeating: 0, count: 28)
        bytes[0] = 28; bytes[1] = UInt8(AF_INET6)
        bytes[2] = 0xc0; bytes[3] = 0x01
        bytes[8] = 0xfe; bytes[9] = 0x80; bytes[23] = 1
        #expect(NetworkStatisticsClient.endpoint(bytes, at: 0) == .init(host: "fe80::1", port: 49153))
    }

    @Test func unboundAndUnknownEndpoints() {
        // A listening or unconnected socket: address all zero.
        #expect(NetworkStatisticsClient.endpoint(sockaddr4(0, 0, 0, 0, port: 5353), at: 0) == .init(host: nil, port: 5353))
        // A moved layout reads as no address, not a wrong one.
        var garbage = sockaddr4(1, 2, 3, 4, port: 80)
        garbage[1] = 99
        #expect(NetworkStatisticsClient.endpoint(garbage, at: 0) == nil)
        garbage = sockaddr4(1, 2, 3, 4, port: 80)
        garbage[0] = 200
        #expect(NetworkStatisticsClient.endpoint(garbage, at: 0) == nil)
        #expect(NetworkStatisticsClient.endpoint([1, 2, 3], at: 0) == nil)
    }

    @Test func descriptorsCarryTheirEndpoints() throws {
        var tcp = descriptor(provider: 2, length: 400, ifindex: (112, 13), pid: (156, 85115), name: (236, "Python"))
        tcp.replaceSubrange(164..<192, with: sockaddr4(192, 168, 1, 94, port: 63033))
        tcp.replaceSubrange(192..<220, with: sockaddr4(1, 1, 1, 1, port: 443))
        let parsedTCP = try #require(NetworkStatisticsClient.parseDescriptor(tcp, length: tcp.count))
        #expect(parsedTCP.local == .init(host: "192.168.1.94", port: 63033))
        #expect(parsedTCP.remote == .init(host: "1.1.1.1", port: 443))
        #expect(parsedTCP.protocolName == "TCP")
        #expect(NetworkStatisticsClient.flowID(parsedTCP) == "TCP|192.168.1.94.63033|1.1.1.1.443|85115")

        var udp = descriptor(provider: 4, length: 320, ifindex: (152, 13), pid: (168, 85142), name: (172, "Python"))
        udp.replaceSubrange(96..<124, with: sockaddr4(192, 168, 1, 94, port: 60907))
        udp.replaceSubrange(124..<152, with: sockaddr4(1, 1, 1, 1, port: 53))
        let parsedUDP = try #require(NetworkStatisticsClient.parseDescriptor(udp, length: udp.count))
        #expect(parsedUDP.remote == .init(host: "1.1.1.1", port: 53))
        #expect(parsedUDP.protocolName == "UDP")
    }

    @Test func loopbackNeedsBothEnds() {
        let loop = NetworkStatisticsClient.Endpoint(host: "127.0.0.1", port: 8080)
        #expect(NetworkStatisticsClient.isLoopback(loop))
        #expect(NetworkStatisticsClient.isLoopback(.init(host: "::1", port: 631)))
        let lan = NetworkStatisticsClient.Endpoint(host: "192.168.1.2", port: 80)
        #expect(NetworkStatisticsClient.isLoopback(lan) == false)
        #expect(!NetworkStatisticsClient.isLoopback(nil))
    }
}

@Suite
struct NetworkSliceFlowTests {
    private typealias Flow = NetworkStatisticsClient.FlowSample
    private typealias Endpoint = NetworkStatisticsClient.Endpoint

    @Test func flowsAggregateIntoHostsServicesAndApps() {
        let flows = [
            Flow(id: "a", appName: "Safari", protocolName: "TCP",
                 local: Endpoint(host: "192.168.1.94", port: 50000), remote: Endpoint(host: "17.253.1.1", port: 443),
                 rx: 1_000, tx: 100),
            Flow(id: "b", appName: "Safari", protocolName: "UDP",
                 local: Endpoint(host: "192.168.1.94", port: 50001), remote: Endpoint(host: "17.253.1.1", port: 443),
                 rx: 500, tx: 50),
            Flow(id: "c", appName: "Plex", protocolName: "TCP",
                 local: Endpoint(host: "192.168.1.94", port: 32400), remote: Endpoint(host: "192.168.1.20", port: 51000),
                 rx: 10, tx: 9_000),
            // Unconnected UDP (mDNS): no remote end.
            Flow(id: "d", appName: "mDNSResponder", protocolName: "UDP",
                 local: Endpoint(host: nil, port: 5353), remote: nil, rx: 40, tx: 40),
            Flow(id: "idle", appName: "Idle", protocolName: "TCP", local: nil, remote: nil, rx: 0, tx: 0),
        ]
        let result = NetworkSliceSampler.aggregate(flows: flows)
        #expect(result.programDeltas["Safari"]?.rx == 1_500)
        #expect(result.programDeltas["Plex"]?.tx == 9_000)
        #expect(result.programDeltas["Idle"] == nil)
        #expect(result.hostDeltas["17.253.1.1"]?.rx == 1_500)
        #expect(result.hostDeltas.count == 2)
        #expect(result.privateHosts == ["192.168.1.20"])
        #expect(result.serviceDeltas["https"]?.rx == 1_500)
        #expect(result.serviceDeltas["zeroconf"]?.rx == 40)
        #expect(result.connectionDeltas.count == 4)
        #expect(result.connectionDeltas.first { $0.id == "d" }?.host == "*")
        #expect(result.connectionDeltas.first { $0.id == "d" }?.localAddress == "*")
    }
}
