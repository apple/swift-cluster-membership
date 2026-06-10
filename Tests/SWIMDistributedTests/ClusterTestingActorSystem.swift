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

/// A minimal `DistributedActorSystem` for testing SWIM integration.
///
/// All actors live in the same process, but remote calls are gated
/// by SWIM reachability: if the target node is not `.alive`, the call throws.
///
/// The system owns its `SWIMActor` — call `start(network:)` after creation
/// to bootstrap the cluster membership layer.
final class ClusterTestingActorSystem: DistributedActorSystem, @unchecked Sendable {
    typealias ActorID = ClusterActorID
    typealias SerializationRequirement = Swift.Codable
    typealias InvocationEncoder = ClusterInvocationEncoder
    typealias InvocationDecoder = ClusterInvocationDecoder
    typealias ResultHandler = ClusterResultHandler

    struct ClusterInvocationEncoder: DistributedTargetInvocationEncoder {
        typealias SerializationRequirement = Swift.Codable
        var arguments: [Data] = []

        mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {}
        mutating func recordArgument<Value: Codable>(_ argument: RemoteCallArgument<Value>) throws {
            self.arguments.append(try JSONEncoder().encode(argument.value))
        }
        mutating func recordErrorType<E: Error>(_ type: E.Type) throws {}
        mutating func recordReturnType<R: Codable>(_ type: R.Type) throws {}
        mutating func doneRecording() throws {}

        func makeDecoder(actorSystem: ClusterTestingActorSystem) -> ClusterInvocationDecoder {
            ClusterInvocationDecoder(arguments: self.arguments, actorSystem: actorSystem)
        }
    }

    final class ClusterInvocationDecoder: DistributedTargetInvocationDecoder, @unchecked Sendable {
        typealias SerializationRequirement = Swift.Codable
        var arguments: [Data]
        var argIndex = 0
        let actorSystem: ClusterTestingActorSystem

        init(arguments: [Data], actorSystem: ClusterTestingActorSystem) {
            self.arguments = arguments
            self.argIndex = 0
            self.actorSystem = actorSystem
        }

        func decodeGenericSubstitutions() throws -> [Any.Type] { [] }
        func decodeNextArgument<Argument: Codable>() throws -> Argument {
            guard self.arguments.count > self.argIndex else {
                throw ClusterTestingError.missingArgument
            }
            let data = self.arguments[self.argIndex]
            self.argIndex += 1
            let decoder = JSONDecoder()
            decoder.userInfo[.actorSystemKey] = self.actorSystem
            let value = try decoder.decode(Argument.self, from: data)
            return value
        }
        func decodeErrorType() throws -> Any.Type? { nil }
        func decodeReturnType() throws -> Any.Type? { nil }
    }

    fileprivate final class ResultBox: Sendable {
        let result: Mutex<Result<Any, Error>?> = .init(.none)
    }

    struct ClusterResultHandler: DistributedTargetInvocationResultHandler, Sendable {
        typealias SerializationRequirement = Swift.Codable
        fileprivate let box: ResultBox

        fileprivate init(box: ResultBox) {
            self.box = box
        }

        func onReturn<Success>(value: Success) async throws where Success: Decodable, Success: Encodable, Success: Sendable {
            self.box.result.withLock { $0 = .success(value) }
        }

        func onReturnVoid() async throws {
            self.box.result.withLock { $0 = .success(()) }
        }

        func onThrow<Err: Error>(error: Err) async throws {
            self.box.result.withLock { $0 = .failure(error) }
        }
    }

    private let actors = Mutex<[ActorID: any DistributedActor]>([:])
    private var reserved: Set<ActorID> = []
    let node: Node
    private let reachability: Mutex<ReachabilitySet>
    private let network: ClusterTestingNetwork
    var swim: SWIMActor<ClusterTestingActorSystem>? {
        get async { await self.network.swimActor(for: self.node) }
    }

    init(node: Node, network: ClusterTestingNetwork, swimSettings: SWIM.Settings = SWIM.Settings()) async {
        self.node = node
        self.network = network
        self.reachability = Mutex(ReachabilitySet())
        let swim = await SWIMActor(
            settings: .init(
                swim: swimSettings,
                myself: self.node,
                resolvePeer: { node in await network.swimActor(for: node) },
                onMembershipChange: { event in
                    self.reachability.withLock {
                        if event.member.status.isAlive {
                            $0.insert(event.member.node)
                        } else {
                            $0.remove(event.member.node)
                        }
                    }
                }
            ),
            actorSystem: self
        )
        await network.register(system: self, swim: swim)
    }

    func assignID<Act>(_ actorType: Act.Type) -> ActorID where Act: DistributedActor {
        let id = ActorID(node: self.node, localID: UUID().uuidString)
        self.actors.withLock { _ = $0[id] }
        self.reserved.insert(id)
        return id
    }

    func actorReady<Act>(_ actor: Act) where Act: DistributedActor, Act.ID == ActorID {
        self.actors.withLock { $0[actor.id] = actor }
    }

    func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act? where Act: DistributedActor {
        if id.node == self.node {
            return self.actors.withLock { $0[id] } as? Act
        }
        // For remote IDs, return nil so runtime creates a proxy.
        return nil
    }

    func resignID(_ id: ActorID) {
        _ = self.actors.withLock { $0.removeValue(forKey: id) }
    }

    func makeInvocationEncoder() -> ClusterInvocationEncoder {
        ClusterInvocationEncoder()
    }

    func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout ClusterInvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res
    where
        Act: DistributedActor,
        Act.ID == ActorID,
        Err: Error,
        Res: Decodable,
        Res: Encodable
    {

        let targetSystem: ClusterTestingActorSystem
        if actor.id.node == self.node {
            targetSystem = self
        } else {
            // Check reachability before attempting a remote call.
            guard self.reachability.withLock({ $0.contains(actor.id.node) }) else {
                throw ClusterTestingError.nodeUnreachable(actor.id.node)
            }
            guard let system = await self.network.system(for: actor.id.node) else {
                throw ClusterTestingError.systemNotFound(actor.id.node)
            }
            targetSystem = system
        }

        guard let localActor = targetSystem.actors.withLock({ $0[actor.id] }) as? Act else {
            throw ClusterTestingError.actorNotFound(actor.id)
        }

        let box = ResultBox()
        let handler = ClusterResultHandler(box: box)
        var decoder = invocation.makeDecoder(actorSystem: self)
        try await executeDistributedTarget(
            on: localActor,
            target: target,
            invocationDecoder: &decoder,
            handler: handler
        )

        return try box.result.withLock {
            switch $0 {
            case .success(let value):
                return value as! Res
            case .failure(let error):
                throw error
            case .none:
                fatalError("Result never set")
            }
        }
    }

    func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout ClusterInvocationEncoder,
        throwing: Err.Type
    ) async throws
    where
        Act: DistributedActor,
        Act.ID == ActorID,
        Err: Error
    {
        _ = try await self.remoteCall(
            on: actor,
            target: target,
            invocation: &invocation,
            throwing: Err.self,
            returning: _Done.self
        )
    }

    func invokeHandlerOnReturn(
        handler: ClusterResultHandler,
        resultBuffer: UnsafeRawPointer,
        metatype: any Any.Type
    ) async throws {
        // Since _openExistential does not work with protocol compositions like Codable,
        // we handle the return types used in our tests directly.
        // In a real system the compiler synthesizes this method.
        switch metatype {
        case is String.Type:
            let value = resultBuffer.load(as: String.self)
            try await handler.onReturn(value: value)
        case is _Done.Type:
            let value = resultBuffer.load(as: _Done.self)
            try await handler.onReturn(value: value)
        default:
            fatalError("Unsupported return type for test system: \(metatype)")
        }
    }

    /// Whether SWIM currently believes `node` is alive.
    func isNodeReachable(_ node: Node) -> Bool {
        self.reachability.withLock { $0.contains(node) }
    }
}

struct ClusterActorID: Sendable, Hashable, Codable {
    let node: Node
    let localID: String
}

enum ClusterTestingError: Error, Equatable {
    case missingArgument
    case typeMismatch(expected: String, actual: String)
    case systemNotFound(Node)
    case actorNotFound(ClusterActorID)
    case nodeUnreachable(Node)
}

struct _Done: Codable {}

// MARK: - Reachability-gated distributed actor system

/// Coordinates in-process communication between test nodes.
///
/// A single `ClusterTestingNetwork` instance manages all systems and their
/// SWIM actors, replacing global static state with an explicit test harness.
actor ClusterTestingNetwork {
    private var systems: [Node: ClusterTestingActorSystem] = [:]
    private var swimActors: [Node: SWIMActor<ClusterTestingActorSystem>] = [:]

    func register(system: ClusterTestingActorSystem, swim: SWIMActor<ClusterTestingActorSystem>) {
        self.systems[system.node] = system
        self.swimActors[system.node] = swim
    }

    func system(for node: Node) -> ClusterTestingActorSystem? {
        self.systems[node]
    }

    func swimActor(for node: Node) -> SWIMActor<ClusterTestingActorSystem>? {
        self.swimActors[node]
    }

    func unregister(node: Node) {
        self.systems.removeValue(forKey: node)
        self.swimActors.removeValue(forKey: node)
    }
}

/// Tracks which nodes are currently reachable, updated by SWIM callbacks.
final class ReachabilitySet: @unchecked Sendable {
    private let nodes: Mutex<Set<Node>>

    init() {
        self.nodes = Mutex([])
    }

    func insert(_ node: Node) {
        _ = self.nodes.withLock { $0.insert(node) }
    }

    func remove(_ node: Node) {
        _ = self.nodes.withLock { $0.remove(node) }
    }

    func contains(_ node: Node) -> Bool {
        self.nodes.withLock { $0.contains(node) }
    }
}

/// A minimal wrapper showing how a host system integrates `SWIMActor`.
///
/// In a real system this would be part of your `DistributedActorSystem`
/// implementation (like `ClusterSystem` in swift-distributed-actors).
/// Here it just demonstrates the wiring.
actor SWIMCluster<System: DistributedActorSystem> {
    let node: Node
    let actorSystem: System
    let swim: SWIMActor<System>

    init(
        node: Node,
        actorSystem: System,
        registry: SWIMRegistry<System>
    ) async {
        self.node = node
        self.actorSystem = actorSystem

        self.swim = await SWIMActor(
            settings: .init(
                swim: SWIM.Settings(),
                myself: node,
                resolvePeer: { node in registry.resolve(node: node) },
                onMembershipChange: { _ in
                    // In a real system, update routing tables here.
                }
            ),
            actorSystem: actorSystem
        )
        registry.register(node: node, actor: self.swim)
    }

    /// Start monitoring `otherNode`. This is how a node "joins" the cluster.
    func join(_ otherNode: Node) async {
        await self.swim.whenLocal { await $0.monitor(node: otherNode) }
    }

    /// Manually drive one protocol tick (for testing).
    func tick() async {
        _ = await self.swim.whenLocal { await $0.handlePeriodicProtocolPeriodTick() }
    }

    /// Current membership view from SWIM.
    func members() async -> [SWIM.Member] {
        await self.swim.whenLocal { $0._getMembershipState() } ?? []
    }
}
