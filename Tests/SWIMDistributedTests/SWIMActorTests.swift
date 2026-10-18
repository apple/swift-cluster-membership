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
@testable import SWIM
import Synchronization
import Testing

@testable import SWIMDistributed

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct SWIMActorTests {
    let nodeA = Node(protocol: "test", host: "127.0.0.1", port: 1111, uid: 1)
    let nodeB = Node(protocol: "test", host: "127.0.0.1", port: 2222, uid: 2)
    let nodeC = Node(protocol: "test", host: "127.0.0.1", port: 3333, uid: 3)

    // MARK: - Two-node membership

    @Test
    func test_twoNodes_monitoringEachOther_shouldSeeBothMembers() async throws {
        let system = LocalTestingDistributedActorSystem()
        let registry = SWIMRegistry<LocalTestingDistributedActorSystem>()
        let swimA = registry.makeSWIM(node: self.nodeA, actorSystem: system)
        let swimB = registry.makeSWIM(node: self.nodeB, actorSystem: system)

        try await withRunning([swimA, swimB]) {
            _ = await swimA.whenLocal { await $0.monitor(node: self.nodeB) }
            _ = await swimB.whenLocal { await $0.monitor(node: self.nodeA) }

            // Drive a few protocol ticks so both nodes exchange gossip.
            try await driveProtocolPeriods([swimA, swimB], count: 2)
        }

        let membersA = await swimA.whenLocal { $0.members } ?? []
        let membersB = await swimB.whenLocal { $0.members } ?? []

        #expect(membersA.count == 2, "Node A should see both members")
        #expect(membersB.count == 2, "Node B should see both members")
        #expect(membersA.contains(where: { $0.node == self.nodeA }))
        #expect(membersA.contains(where: { $0.node == self.nodeB }))
    }

    // MARK: - Membership changes

    @Test
    func test_membershipChanges_shouldYieldReachabilityChanges() async throws {
        let system = LocalTestingDistributedActorSystem()
        let registry = SWIMRegistry<LocalTestingDistributedActorSystem>()
        let swimA = registry.makeSWIM(node: self.nodeA, actorSystem: system)
        let swimB = registry.makeSWIM(node: self.nodeB, actorSystem: system)
        let changesA = await swimA.whenLocal { $0.membershipChanges }!

        try await withRunning([swimA, swimB]) {
            _ = await swimA.whenLocal { await $0.monitor(node: self.nodeB) }
            try await driveProtocolPeriods([swimA, swimB], count: 2)
        }

        let events = await changesA.collect()
        #expect(events.first?.member.node == self.nodeA, "First event should announce the actor itself")
        #expect(events.contains { $0.member.node == self.nodeB && $0.status.isAlive }, "Should announce B as alive")
    }

    @Test
    func test_membershipChanges_shouldFinishWhenRunIsCancelled() async throws {
        let system = LocalTestingDistributedActorSystem()
        let registry = SWIMRegistry<LocalTestingDistributedActorSystem>()
        let swimA = registry.makeSWIM(node: self.nodeA, actorSystem: system)
        let changesA = await swimA.whenLocal { $0.membershipChanges }!

        let run = Task { await swimA.whenLocal { await $0.run() } }
        run.cancel()
        await run.value

        // Would hang if the stream was not finished.
        let events = await changesA.collect()
        #expect(events.count == 1)
    }

    // MARK: - confirmDead

    @Test
    func test_confirmDead_shouldMarkNodeAsDead() async throws {
        let system = LocalTestingDistributedActorSystem()
        let registry = SWIMRegistry<LocalTestingDistributedActorSystem>()
        let swimA = registry.makeSWIM(node: self.nodeA, actorSystem: system)
        let swimB = registry.makeSWIM(node: self.nodeB, actorSystem: system)
        _ = swimB
        let changesA = await swimA.whenLocal { $0.membershipChanges }!

        try await withRunning([swimA]) {
            _ = await swimA.whenLocal { await $0.monitor(node: self.nodeB) }
            // Confirm B dead from A's perspective.
            _ = await swimA.whenLocal { $0.confirmDead(node: self.nodeB) }
        }

        let events = await changesA.collect()
        let eventsAboutB = events.filter { $0.member.node == self.nodeB }
        #expect(eventsAboutB.last?.status.isDead ?? false, "Last event about B should be .dead, got: \(eventsAboutB)")
    }

    // MARK: - Ping round-trip

    @Test
    func test_ping_shouldReturnAck() async throws {
        let system = LocalTestingDistributedActorSystem()
        let registry = SWIMRegistry<LocalTestingDistributedActorSystem>()
        _ = registry.makeSWIM(node: self.nodeA, actorSystem: system)
        let swimB = registry.makeSWIM(node: self.nodeB, actorSystem: system)

        let response = try await swimB.ping(
            origin: self.nodeA,
            payload: .none,
            sequenceNumber: 1
        )

        switch response {
        case .ack(let target, _, _, _):
            #expect(target == self.nodeB)
        default:
            Issue.record("Expected ack, got \(response)")
        }
    }

    // MARK: - Failed probes

    @Test
    func test_pingRequest_shouldRespondWithNack_whenTargetDoesNotRespond() async throws {
        let system = LocalTestingDistributedActorSystem()
        let registry = SWIMRegistry<LocalTestingDistributedActorSystem>()
        let swimC = registry.makeSWIM(node: self.nodeC, actorSystem: system)
        // B is a member, but there is no actor to respond for it.
        _ = await swimC.whenLocal {
            $0._configureSWIM { _ = $0.addMember(self.nodeB, status: .alive(incarnation: 0)) }
        }

        // A asks C to ping B on its behalf.
        let response = try await swimC.pingRequest(
            target: self.nodeB,
            pingRequestOrigin: self.nodeA,
            payload: .none,
            sequenceNumber: 13
        )

        guard case .nack(let target, let sequenceNumber) = response else {
            Issue.record("Expected nack, got \(response)")
            return
        }
        #expect(target == self.nodeB)
        #expect(sequenceNumber == 13)
    }

    @Test
    func test_shouldMarkSuspect_whenPingFails_andNoOtherNodesCanBeRequested() async throws {
        let system = LocalTestingDistributedActorSystem()
        let registry = SWIMRegistry<LocalTestingDistributedActorSystem>()
        let swimA = registry.makeSWIM(node: self.nodeA, actorSystem: system)
        _ = await swimA.whenLocal {
            $0._configureSWIM { _ = $0.addMember(self.nodeB, status: .alive(incarnation: 0)) }
        }

        _ = await swimA.whenLocal {
            await $0.sendPing(
                to: self.nodeB,
                payload: .none,
                pingRequestOrigin: nil,
                pingRequestSequenceNumber: nil,
                timeout: .milliseconds(100),
                sequenceNumber: 1
            )
        }

        let statusOfB = await swimA.whenLocal { $0.members.first { $0.node == self.nodeB }?.status } ?? nil
        #expect(statusOfB == .suspect(incarnation: 0, suspectedBy: [self.nodeA]))
    }

    @Test
    func test_shouldMarkSuspect_whenPingFails_andPingRequestsFail() async throws {
        let system = LocalTestingDistributedActorSystem()
        let registry = SWIMRegistry<LocalTestingDistributedActorSystem>()
        let swimA = registry.makeSWIM(node: self.nodeA, actorSystem: system)
        let swimC = registry.makeSWIM(node: self.nodeC, actorSystem: system)
        // B is a member of both, but there is no actor to respond for it.
        for swim in [swimA, swimC] {
            _ = await swim.whenLocal {
                $0._configureSWIM { _ = $0.addMember(self.nodeB, status: .alive(incarnation: 0)) }
            }
        }
        _ = await swimA.whenLocal {
            $0._configureSWIM { _ = $0.addMember(self.nodeC, status: .alive(incarnation: 0)) }
        }

        try await withRunning([swimA, swimC]) {
            // The failed ping makes A ask C to ping B, which fails as well.
            _ = await swimA.whenLocal {
                await $0.sendPing(
                    to: self.nodeB,
                    payload: .none,
                    pingRequestOrigin: nil,
                    pingRequestSequenceNumber: nil,
                    timeout: .milliseconds(100),
                    sequenceNumber: 1
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        let statusOfB = await swimA.whenLocal { $0.members.first { $0.node == self.nodeB }?.status } ?? nil
        #expect(statusOfB?.isSuspect == true, "Expected B to be suspect, was: \(String(describing: statusOfB))")
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
        let registry = SWIMRegistry<LocalTestingDistributedActorSystem>()
        let swimA = registry.makeSWIM(node: self.nodeA, actorSystem: system)
        let swimB = registry.makeSWIM(node: self.nodeB, actorSystem: system)
        let swimC = registry.makeSWIM(node: self.nodeC, actorSystem: system)
        let changesA = await swimA.whenLocal { $0.membershipChanges }!
        let changesB = await swimB.whenLocal { $0.membershipChanges }!
        let changesC = await swimC.whenLocal { $0.membershipChanges }!

        try await withRunning([swimA, swimB, swimC]) {
            // ASYMMETRIC join: A only knows B, B only knows C.
            // Nobody tells A about C directly.
            _ = await swimA.whenLocal { await $0.monitor(node: self.nodeB) }
            _ = await swimB.whenLocal { await $0.monitor(node: self.nodeC) }

            // Drive protocol ticks so gossip spreads through the chain A <-> B <-> C.
            try await driveProtocolPeriods([swimA, swimB, swimC], count: 4)
        }

        // Each node's view of the cluster, built from its membership changes.
        let knownNodesA = await changesA.aliveNodes()
        let knownNodesB = await changesB.aliveNodes()
        let knownNodesC = await changesC.aliveNodes()

        // All three nodes should now know about each other, even though
        // nobody ever told A about C directly.
        #expect(knownNodesA.contains(self.nodeB), "A should know B")
        #expect(knownNodesA.contains(self.nodeC), "A should have discovered C via gossip")
        #expect(knownNodesB.contains(self.nodeA), "B should know A")
        #expect(knownNodesB.contains(self.nodeC), "B should know C")
        #expect(knownNodesC.contains(self.nodeA), "C should have discovered A via gossip")
        #expect(knownNodesC.contains(self.nodeB), "C should know B")

        // The host system can query SWIM for the current membership at any time.
        let membersA = await swimA.whenLocal { $0.members } ?? []
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

        let clusterA = SWIMCluster(node: self.nodeA, actorSystem: system, registry: registry)
        let clusterB = SWIMCluster(node: self.nodeB, actorSystem: system, registry: registry)
        let clusterC = SWIMCluster(node: self.nodeC, actorSystem: system, registry: registry)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for cluster in [clusterA, clusterB, clusterC] {
                group.addTask { await cluster.run() }
            }
            defer { group.cancelAll() }

            // Join the cluster through a single seed node.
            // A knows B, B knows C — gossip will do the rest.
            await clusterA.join(self.nodeB)
            await clusterB.join(self.nodeC)

            // Let SWIM exchange a few protocol periods.
            try await driveProtocolPeriods([clusterA.swim, clusterB.swim, clusterC.swim], count: 4)

            // Every cluster should now see every other node.
            #expect(await clusterA.members().count == 3)
            #expect(await clusterB.members().count == 3)
            #expect(await clusterC.members().count == 3)
            #expect(await clusterA.reachableNodes() == [self.nodeA, self.nodeB, self.nodeC])
        }
    }

    /// Demonstrates that distributed actor calls are gated by SWIM reachability.
    ///
    /// Three nodes form a cluster through a single seed. Actors on each node
    /// can talk to one another while the target node is `.alive`. When a node
    /// is marked `.dead`, calls to actors on that node fail.
    @Test
    func test_reachability_gatesDistributedActorCalls() async throws {
        let network = ClusterTestingNetwork()

        let systemA = await ClusterTestingActorSystem(node: self.nodeA, network: network)
        let systemB = await ClusterTestingActorSystem(node: self.nodeB, network: network)
        let systemC = await ClusterTestingActorSystem(node: self.nodeC, network: network)

        // Host an actor on each node; B and C are resolved as proxies on systemA
        // so calls to them go through the distributed mechanism.
        let actorA = SampleActor(actorSystem: systemA)
        let hostedB = SampleActor(actorSystem: systemB)
        let hostedC = SampleActor(actorSystem: systemC)
        let actorB = try SampleActor.resolve(id: hostedB.id, using: systemA)
        let actorC = try SampleActor.resolve(id: hostedC.id, using: systemA)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for system in [systemA, systemB, systemC] {
                group.addTask { await system.run() }
            }
            defer { group.cancelAll() }

            // Join the cluster through a single seed (node A).
            _ = await systemA.swim?.whenLocal { await $0.monitor(node: self.nodeB) }
            _ = await systemA.swim?.whenLocal { await $0.monitor(node: self.nodeC) }

            // Drive protocol ticks so gossip propagates.
            let swims = await [systemA.swim, systemB.swim, systemC.swim].compactMap { $0 }
            try await driveProtocolPeriods(swims, count: 5)

            // All nodes should see each other as alive.
            #expect(systemA.isNodeReachable(self.nodeB))
            #expect(systemA.isNodeReachable(self.nodeC))

            // Calls from A to B and C succeed while the targets are reachable.
            let greetingB = try await actorA.callGreet(on: actorB, name: "Alice")
            #expect(greetingB.contains("Hello, Alice!"))

            let greetingC = try await actorA.callGreet(on: actorC, name: "Bob")
            #expect(greetingC.contains("Hello, Bob!"))

            // Mark node B as dead from A's perspective.
            _ = await systemA.swim?.whenLocal { $0.confirmDead(node: self.nodeB) }
            // Membership changes are consumed by `systemA.run()`; give it a moment.
            try await Task.sleep(for: .milliseconds(50))

            // Node B is now unreachable from A.
            #expect(!systemA.isNodeReachable(self.nodeB))
            #expect(systemA.isNodeReachable(self.nodeC))

            // Calls to node B should fail now that it's unreachable.
            await network.unregister(node: self.nodeB)
            await #expect(throws: ClusterTestingError.nodeUnreachable(self.nodeB)) {
                try await actorA.callGreet(on: actorB, name: "Dead")
            }

            // Calls from A to C still work.
            let greetingC2 = try await actorA.callGreet(on: actorC, name: "Charlie")
            #expect(greetingC2.contains("Hello, Charlie!"))
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

    /// Creates a `SWIMActor` for `node` which resolves its peers through this registry, and registers it.
    func makeSWIM(node: Node, actorSystem: System) -> SWIMActor<System> {
        let swim = SWIMActor(
            settings: .init(
                swim: SWIM.Settings(),
                myself: node,
                resolvePeer: { node in self.resolve(node: node) }
            ),
            actorSystem: actorSystem
        )
        self.register(node: node, actor: swim)
        return swim
    }
}

// MARK: - Running helpers

/// Runs `swims` for the duration of `body`, with protocol periods driven only by the test.
///
/// When this returns, every actor's `membershipChanges` has finished, so its events can be collected.
func withRunning<System: DistributedActorSystem>(
    _ swims: [SWIMActor<System>],
    _ body: () async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        for swim in swims {
            group.addTask {
                await swim.whenLocal { await $0.run(periodicTicks: false) }
            }
        }
        defer { group.cancelAll() }
        try await body()
    }
}

/// Handles `count` protocol periods on each of `swims`, giving the pings of each period time to complete.
func driveProtocolPeriods<System: DistributedActorSystem>(_ swims: [SWIMActor<System>], count: Int) async throws {
    for _ in 0..<count {
        for swim in swims {
            _ = await swim.whenLocal { $0.handlePeriodicProtocolPeriodTick() }
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

extension AsyncStream {
    func collect() async -> [Element] {
        var elements: [Element] = []
        for await element in self {
            elements.append(element)
        }
        return elements
    }
}

extension AsyncStream<SWIM.MemberStatusChangedEvent> {
    /// Nodes that are alive according to the (finished) stream of changes.
    func aliveNodes() async -> Set<Node> {
        var nodes: Set<Node> = []
        for await event in self {
            if event.status.isAlive {
                nodes.insert(event.member.node)
            } else {
                nodes.remove(event.member.node)
            }
        }
        return nodes
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
