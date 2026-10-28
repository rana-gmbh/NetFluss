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
        // continue arriving. This must not switch the monitor to nettop.
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

    @Test func transientPollFailuresCanRetryWithoutNettop() {
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
}
