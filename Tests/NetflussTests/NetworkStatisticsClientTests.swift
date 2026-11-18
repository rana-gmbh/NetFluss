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
}
