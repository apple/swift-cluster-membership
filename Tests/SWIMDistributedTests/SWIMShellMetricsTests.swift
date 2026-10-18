//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
@preconcurrency import Distributed
import Metrics
import MetricsTestKit
import Testing

@testable import SWIM
@testable import SWIMDistributed

struct SWIMShellMetricsTests {
    let nodeA = Node(protocol: "test", host: "127.0.0.1", port: 1111, uid: 1)
    let nodeB = Node(protocol: "test", host: "127.0.0.1", port: 2222, uid: 2)
    let nodeC = Node(protocol: "test", host: "127.0.0.1", port: 3333, uid: 3)

    @Test
    func test_sendPing_shouldRecordShellMetrics() async throws {
        let system = LocalTestingDistributedActorSystem()
        let registry = SWIMRegistry<LocalTestingDistributedActorSystem>()
        let metrics = TestMetrics()
        let swimA = withMetricsFactory(metrics) {
            registry.makeSWIM(node: self.nodeA, actorSystem: system)
        }
        _ = registry.makeSWIM(node: self.nodeB, actorSystem: system)

        _ = await swimA.whenLocal {
            await $0.sendPing(
                to: self.nodeB,
                payload: .none,
                pingRequestOrigin: nil,
                pingRequestSequenceNumber: nil,
                timeout: .seconds(1),
                sequenceNumber: 1
            )
        }

        let shell = try #require(await swimA.whenLocal { $0.metrics.shell })
        let pingResponseTime = try metrics.expectTimer(shell.pingResponseTime)
        #expect(pingResponseTime.values.count == 1)
        let messageOutboundCount = try metrics.expectCounter(shell.messageOutboundCount)
        #expect(messageOutboundCount.totalValue == 1)
    }

    @Test
    func test_sendPingRequests_shouldRecordShellMetrics() async throws {
        let system = LocalTestingDistributedActorSystem()
        let registry = SWIMRegistry<LocalTestingDistributedActorSystem>()
        let metrics = TestMetrics()
        let swimA = withMetricsFactory(metrics) {
            registry.makeSWIM(node: self.nodeA, actorSystem: system)
        }
        _ = registry.makeSWIM(node: self.nodeB, actorSystem: system)
        _ = registry.makeSWIM(node: self.nodeC, actorSystem: system)

        // A asks C to ping B on its behalf.
        let directive = SWIM.Instance.SendPingRequestDirective(
            target: self.nodeB,
            timeout: .seconds(1),
            requestDetails: [
                .init(peerToPingRequestThrough: self.nodeC, payload: .none, sequenceNumber: 1)
            ]
        )
        _ = await swimA.whenLocal { await $0.sendPingRequests(directive) }

        let shell = try #require(await swimA.whenLocal { $0.metrics.shell })
        let first = try metrics.expectTimer(shell.pingRequestResponseTimeFirst)
        #expect(first.values.count == 1)
        let all = try metrics.expectTimer(shell.pingRequestResponseTimeAll)
        #expect(all.values.count == 1)
        let messageOutboundCount = try metrics.expectCounter(shell.messageOutboundCount)
        #expect(messageOutboundCount.totalValue == 1)
    }
}
