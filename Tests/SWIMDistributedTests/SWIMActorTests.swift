//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import Distributed
import SWIM
import Synchronization
import Testing

@testable import SWIMDistributed

struct SWIMActorTests {
    // MARK: - Two-node membership

    @Test
    func test_twoNodes_monitoringEachOther_shouldSeeBothMembers() async throws {
        let system = LocalTestingDistributedActorSystem()
        let nodeA = Node(protocol: "test", host: "127.0.0.1", port: 1111, uid: 1)
        let nodeB = Node(protocol: "test", host: "127.0.0.1", port: 2222, uid: 2)

        let registry = SWIMRegistry<LocalTestingDistributedActorSystem>()

        let swimA = await SWIMActor(
            settings: .init(
                swim: SWIM.Settings(),
                myself: nodeA,
                resolvePeer: { node in registry.resolve(node: node) }
            ),
            actorSystem: system
        )
        registry.register(node: nodeA, actor: swimA)

        let swimB = await SWIMActor(
            settings: .init(
                swim: SWIM.Settings(),
                myself: nodeB,
                resolvePeer: { node in registry.resolve(node: node) }
            ),
            actorSystem: system
        )
        registry.register(node: nodeB, actor: swimB)

        _ = await swimA.whenLocal { await $0.monitor(node: nodeB) }
        _ = await swimB.whenLocal { await $0.monitor(node: nodeA) }

        // Drive a few protocol ticks so both nodes exchange gossip.
        _ = await swimA.whenLocal { await $0.handlePeriodicProtocolPeriodTick() }
        _ = await swimB.whenLocal { await $0.handlePeriodicProtocolPeriodTick() }

        try await Task.sleep(for: .milliseconds(100))

        let membersA = await swimA.whenLocal { $0._getMembershipState() } ?? []
        let membersB = await swimB.whenLocal { $0._getMembershipState() } ?? []

        #expect(membersA.count == 2, "Node A should see both members")
        #expect(membersB.count == 2, "Node B should see both members")
        #expect(membersA.contains(where: { $0.node == nodeA }))
        #expect(membersA.contains(where: { $0.node == nodeB }))
    }

    // MARK: - Reachability change callback

    @Test
    func test_onMembershipChange_shouldFireForReachabilityChanges() async throws {
        let system = LocalTestingDistributedActorSystem()
        let nodeA = Node(protocol: "test", host: "127.0.0.1", port: 1111, uid: 1)
        let nodeB = Node(protocol: "test", host: "127.0.0.1", port: 2222, uid: 2)

        let registry = SWIMRegistry<LocalTestingDistributedActorSystem>()
        let capturedEvents = Mutex<[SWIM.MemberStatusChangedEvent]>([])

        let swimA = await SWIMActor(
            settings: .init(
                swim: SWIM.Settings(),
                myself: nodeA,
                resolvePeer: { node in registry.resolve(node: node) },
                onMembershipChange: { event in
                    capturedEvents.withLock { $0.append(event) }
                }
            ),
            actorSystem: system
        )
        registry.register(node: nodeA, actor: swimA)

        let swimB = await SWIMActor(
            settings: .init(
                swim: SWIM.Settings(),
                myself: nodeB,
                resolvePeer: { node in registry.resolve(node: node) }
            ),
            actorSystem: system
        )
        registry.register(node: nodeB, actor: swimB)

        _ = await swimA.whenLocal { await $0.monitor(node: nodeB) }

        // A few ticks to let gossip propagate.
        _ = await swimA.whenLocal { await $0.handlePeriodicProtocolPeriodTick() }
        _ = await swimB.whenLocal { await $0.handlePeriodicProtocolPeriodTick() }
        _ = await swimA.whenLocal { await $0.handlePeriodicProtocolPeriodTick() }
        _ = await swimB.whenLocal { await $0.handlePeriodicProtocolPeriodTick() }

        try await Task.sleep(for: .milliseconds(100))

        let events = capturedEvents.withLock { $0 }

        // We expect at least one reachability change after both nodes exchange gossip.
        #expect(events.count >= 1, "Should have received at least one membership change event")
    }

    // MARK: - confirmDead

    @Test
    func test_confirmDead_shouldMarkNodeAsDead() async throws {
        let system = LocalTestingDistributedActorSystem()
        let nodeA = Node(protocol: "test", host: "127.0.0.1", port: 1111, uid: 1)
        let nodeB = Node(protocol: "test", host: "127.0.0.1", port: 2222, uid: 2)

        let registry = SWIMRegistry<LocalTestingDistributedActorSystem>()
        let capturedEvents = Mutex<[SWIM.MemberStatusChangedEvent]>([])

        let swimA = await SWIMActor(
            settings: .init(
                swim: SWIM.Settings(),
                myself: nodeA,
                resolvePeer: { node in registry.resolve(node: node) },
                onMembershipChange: { event in
                    capturedEvents.withLock { $0.append(event) }
                }
            ),
            actorSystem: system
        )
        registry.register(node: nodeA, actor: swimA)

        let swimB = await SWIMActor(
            settings: .init(
                swim: SWIM.Settings(),
                myself: nodeB,
                resolvePeer: { node in registry.resolve(node: node) }
            ),
            actorSystem: system
        )
        registry.register(node: nodeB, actor: swimB)

        _ = await swimA.whenLocal { await $0.monitor(node: nodeB) }

        // Confirm B dead from A's perspective.
        _ = await swimA.whenLocal { await $0.confirmDead(node: nodeB) }

        let events = capturedEvents.withLock { $0 }
        let deadEvent = events.first(where: { $0.member.node == nodeB && $0.member.status.isDead })
        #expect(deadEvent != nil, "Should have received a membership change event for nodeB with .dead status")
        #expect(deadEvent?.member.status.isDead ?? false, "Node B should be marked dead after confirmDead")
    }

    // MARK: - Ping round-trip

    @Test
    func test_ping_shouldReturnAck() async throws {
        let system = LocalTestingDistributedActorSystem()
        let nodeA = Node(protocol: "test", host: "127.0.0.1", port: 1111, uid: 1)
        let nodeB = Node(protocol: "test", host: "127.0.0.1", port: 2222, uid: 2)

        let registry = SWIMRegistry<LocalTestingDistributedActorSystem>()

        let swimA = await SWIMActor(
            settings: .init(
                swim: SWIM.Settings(),
                myself: nodeA,
                resolvePeer: { node in registry.resolve(node: node) }
            ),
            actorSystem: system
        )
        registry.register(node: nodeA, actor: swimA)

        let swimB = await SWIMActor(
            settings: .init(
                swim: SWIM.Settings(),
                myself: nodeB,
                resolvePeer: { node in registry.resolve(node: node) }
            ),
            actorSystem: system
        )
        registry.register(node: nodeB, actor: swimB)

        let response = try await swimB.ping(
            origin: nodeA,
            payload: .none,
            sequenceNumber: 1
        )

        switch response {
        case .ack(let target, _, _, _):
            #expect(target == nodeB)
        default:
            Issue.record("Expected ack, got \(response)")
        }
    }
}

// MARK: - Test helpers

/// Thread-safe registry for mapping `Node` to `SWIMActor` in tests.
final class SWIMRegistry<System: DistributedActorSystem>: Sendable {
    private let actors: Mutex<[Node: SWIMActor<System>]>

    init() {
        self.actors = Mutex([:])
    }

    func register(node: Node, actor: SWIMActor<System>) {
        self.actors.withLock { $0[node] = actor }
    }

    func resolve(node: Node) -> SWIMActor<System>? {
        self.actors.withLock { $0[node] }
    }
}
