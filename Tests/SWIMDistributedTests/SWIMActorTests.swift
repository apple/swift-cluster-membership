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
import SWIM
import Synchronization
import Testing

@testable import SWIMDistributed

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

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

    // MARK: - Practical integration: gossip-based discovery

    /// Demonstrates SWIM's core value proposition for distributed systems:
    /// you only need to know ONE node to discover the entire cluster.
    ///
    /// In this scenario:
    /// - Node A knows about Node B (monitors it)
    /// - Node B knows about Node C (monitors it)
    /// - Node A does NOT know about Node C initially
    ///
    /// Through SWIM's gossip piggybacked on ping/ack messages,
    /// Node A discovers Node C automatically.
    @Test
    func test_gossipDiscovery_asymmetricJoin_discoversAllNodes() async throws {
        let system = LocalTestingDistributedActorSystem()

        let nodeA = Node(protocol: "test", host: "127.0.0.1", port: 1111, uid: 1)
        let nodeB = Node(protocol: "test", host: "127.0.0.1", port: 2222, uid: 2)
        let nodeC = Node(protocol: "test", host: "127.0.0.1", port: 3333, uid: 3)

        let registry = SWIMRegistry<LocalTestingDistributedActorSystem>()

        // Each node maintains its own view of the cluster, updated by SWIM callbacks.
        let knownNodesA = Mutex<Set<Node>>([])
        let knownNodesB = Mutex<Set<Node>>([])
        let knownNodesC = Mutex<Set<Node>>([])

        let swimA = await SWIMActor(
            settings: .init(
                swim: SWIM.Settings(),
                myself: nodeA,
                resolvePeer: { node in registry.resolve(node: node) },
                onMembershipChange: { event in
                    if event.member.status.isAlive {
                        _ = knownNodesA.withLock { $0.insert(event.member.node) }
                    }
                }
            ),
            actorSystem: system
        )
        registry.register(node: nodeA, actor: swimA)

        let swimB = await SWIMActor(
            settings: .init(
                swim: SWIM.Settings(),
                myself: nodeB,
                resolvePeer: { node in registry.resolve(node: node) },
                onMembershipChange: { event in
                    if event.member.status.isAlive {
                        _ = knownNodesB.withLock { $0.insert(event.member.node) }
                    }
                }
            ),
            actorSystem: system
        )
        registry.register(node: nodeB, actor: swimB)

        let swimC = await SWIMActor(
            settings: .init(
                swim: SWIM.Settings(),
                myself: nodeC,
                resolvePeer: { node in registry.resolve(node: node) },
                onMembershipChange: { event in
                    if event.member.status.isAlive {
                        _ = knownNodesC.withLock { $0.insert(event.member.node) }
                    }
                }
            ),
            actorSystem: system
        )
        registry.register(node: nodeC, actor: swimC)

        // ASYMMETRIC join: A only knows B, B only knows C.
        // Nobody tells A about C directly.
        _ = await swimA.whenLocal { await $0.monitor(node: nodeB) }
        _ = await swimB.whenLocal { await $0.monitor(node: nodeC) }

        // Drive protocol ticks so gossip spreads through the chain A <-> B <-> C.
        for _ in 0..<4 {
            _ = await swimA.whenLocal { await $0.handlePeriodicProtocolPeriodTick() }
            _ = await swimB.whenLocal { await $0.handlePeriodicProtocolPeriodTick() }
            _ = await swimC.whenLocal { await $0.handlePeriodicProtocolPeriodTick() }
        }

        try await Task.sleep(for: .milliseconds(100))

        // All three nodes should now know about each other, even though
        // nobody ever told A about C directly.
        #expect(knownNodesA.withLock { $0.contains(nodeB) }, "A should know B")
        #expect(knownNodesA.withLock { $0.contains(nodeC) }, "A should have discovered C via gossip")
        #expect(knownNodesB.withLock { $0.contains(nodeA) }, "B should know A")
        #expect(knownNodesB.withLock { $0.contains(nodeC) }, "B should know C")
        #expect(knownNodesC.withLock { $0.contains(nodeA) }, "C should have discovered A via gossip")
        #expect(knownNodesC.withLock { $0.contains(nodeB) }, "C should know B")

        // The host system can query SWIM for the current membership at any time.
        let membersA = await swimA.whenLocal { $0._getMembershipState() } ?? []
        #expect(membersA.count >= 3, "A's SWIM state should include all discovered nodes")
    }

    // MARK: - Host-system integration pattern

    /// Demonstrates how a real distributed actor system could wrap SWIM.
    ///
    /// `SWIMCluster` owns a `DistributedActorSystem` and a `SWIMActor`.
    /// It exposes a simple API (`join`, `members`) while SWIM handles
    /// the messy work of failure detection and gossip behind the scenes.
    @Test
    func test_hostSystemWrapper_joinAndQueryMembership() async throws {
        let system = LocalTestingDistributedActorSystem()
        let registry = SWIMRegistry<LocalTestingDistributedActorSystem>()

        let nodeA = Node(protocol: "test", host: "127.0.0.1", port: 1111, uid: 1)
        let nodeB = Node(protocol: "test", host: "127.0.0.1", port: 2222, uid: 2)
        let nodeC = Node(protocol: "test", host: "127.0.0.1", port: 3333, uid: 3)

        let clusterA = await SWIMCluster(
            node: nodeA,
            actorSystem: system,
            registry: registry
        )
        let clusterB = await SWIMCluster(
            node: nodeB,
            actorSystem: system,
            registry: registry
        )
        let clusterC = await SWIMCluster(
            node: nodeC,
            actorSystem: system,
            registry: registry
        )

        // Join the cluster through a single seed node.
        // A knows B, B knows C — gossip will do the rest.
        await clusterA.join(nodeB)
        await clusterB.join(nodeC)

        // Let SWIM exchange a few protocol periods.
        for _ in 0..<4 {
            await clusterA.tick()
            await clusterB.tick()
            await clusterC.tick()
        }
        try await Task.sleep(for: .milliseconds(100))

        // Every cluster should now see every other node.
        #expect(await clusterA.members().count == 3)
        #expect(await clusterB.members().count == 3)
        #expect(await clusterC.members().count == 3)

        // The host system can also react to reachability changes
        // via the `onMembershipChange` closure (see SWIMCluster.init).
    }

    /// Demonstrates that distributed actor calls are gated by SWIM reachability.
    ///
    /// Three nodes form a cluster through a single seed. Actors on each node
    /// can talk to one another while the target node is `.alive`. When a node
    /// is marked `.dead`, calls to actors on that node fail.
    @Test
    func test_reachability_gatesDistributedActorCalls() async throws {
        let nodeA = Node(protocol: "test", host: "127.0.0.1", port: 1111, uid: 1)
        let nodeB = Node(protocol: "test", host: "127.0.0.1", port: 2222, uid: 2)
        let nodeC = Node(protocol: "test", host: "127.0.0.1", port: 3333, uid: 3)

        var fastSettings = SWIM.Settings()
        fastSettings.probeInterval = .milliseconds(50)

        let network = ClusterTestingNetwork()

        let systemA = await ClusterTestingActorSystem(node: nodeA, network: network, swimSettings: fastSettings)
        let systemB = await ClusterTestingActorSystem(node: nodeB, network: network, swimSettings: fastSettings)
        let systemC = await ClusterTestingActorSystem(node: nodeC, network: network, swimSettings: fastSettings)

        // Create actors on each node, but resolve them as proxies on systemA
        // so all calls go through the distributed mechanism.
        let actorA = try SampleActor.resolve(
            id: .init(
                node: systemA.node,
                localID: UUID().uuidString
            ),
            using: systemA
        )
        let actorB = try SampleActor.resolve(id: .init(node: systemB.node, localID: UUID().uuidString), using: systemA)
        let actorC = try SampleActor.resolve(id: .init(node: systemC.node, localID: UUID().uuidString), using: systemA)

        // Join the cluster through a single seed (node A).
        _ = await systemA.swim?.whenLocal { await $0.monitor(node: nodeB) }
        _ = await systemA.swim?.whenLocal { await $0.monitor(node: nodeC) }

        // Drive protocol ticks so gossip propagates.
        for _ in 0..<5 {
            _ = await systemA.swim?.whenLocal { await $0.handlePeriodicProtocolPeriodTick() }
            _ = await systemB.swim?.whenLocal { await $0.handlePeriodicProtocolPeriodTick() }
            _ = await systemC.swim?.whenLocal { await $0.handlePeriodicProtocolPeriodTick() }
        }
        try await Task.sleep(for: .milliseconds(100))

        // All nodes should see each other as alive.
        #expect(systemA.isNodeReachable(nodeB))
        #expect(systemA.isNodeReachable(nodeC))

        // Calls from A to B and C succeed while the targets are reachable.
        let greetingB = try await actorA.callGreet(on: actorB, name: "Alice")
        #expect(greetingB.contains("Hello, Alice!"))

        let greetingC = try await actorA.callGreet(on: actorC, name: "Bob")
        #expect(greetingC.contains("Hello, Bob!"))

        // Mark node B as dead from A's perspective.
        _ = await systemA.swim?.whenLocal { await $0.confirmDead(node: nodeB) }
        // `onMembershipChange` is delivered asynchronously; give it a moment.
        try await Task.sleep(for: .milliseconds(50))

        // Node B is now unreachable from A.
        #expect(!systemA.isNodeReachable(nodeB))
        #expect(systemA.isNodeReachable(nodeC))

        // Calls to node B should fail now that it's unreachable.
        await network.unregister(node: nodeB)
        await #expect(throws: ClusterTestingError.nodeUnreachable(nodeB)) {
            try await actorA.callGreet(on: actorB, name: "Dead")
        }

        // Calls from A to C still work.
        let greetingC2 = try await actorA.callGreet(on: actorC, name: "Charlie")
        #expect(greetingC2.contains("Hello, Charlie!"))
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

// MARK: - Sample distributed actor

distributed actor SampleActor {
    typealias ActorSystem = ClusterTestingActorSystem

    distributed func greet(name: String) -> String {
        "Hello, \(name)! from \(self.id.node)"
    }

    /// Forwards a `greet` call to `other`.
    ///
    /// This lets us test reachability gating: `other` is received as a
    /// remote proxy on our actor system, so `other.greet()` goes through
    /// the system's `remoteCall` where the reachability check lives.
    distributed func callGreet(on other: SampleActor, name: String) async throws -> String {
        try await other.greet(name: name)
    }
}
