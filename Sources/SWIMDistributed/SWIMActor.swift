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
import CoreMetrics
import Distributed
import Logging
internal import Metrics
import SWIM

/// A generic, reusable distributed actor shell for the SWIM failure detection protocol.
///
/// `SWIMActor` wraps `SWIM.Instance` and drives all interactions with the outside world
/// through distributed actor remote calls. It works with **any** `DistributedActorSystem` —
/// you only need to provide a `Node -> ActorID` mapping in `Settings.resolvePeer`.
///
/// ## Usage
///
/// ```swift
/// let swim = SWIMActor<MyActorSystem>(
///     settings: .init(
///         swim: swimSettings,
///         myself: myNode,
///         resolvePeer: { node in await mySystem.resolveSWIMPeer(for: node) }
///     )
/// )
///
/// for await event in swim.membershipChanges {
///     await mySystem.applyReachabilityChange(event)
/// }
/// ```
///
/// - SeeAlso: `Settings`
/// - SeeAlso: `SWIM.Instance` for the pure state machine.
public distributed actor SWIMActor<System: DistributedActorSystem> {
    public typealias ActorSystem = System
    public typealias SerializationRequirement = System.SerializationRequirement
    internal let settings: SWIMActor.Settings
    internal var instance: SWIM.Instance

    public var metrics: SWIM.Metrics {
        self.instance.metrics
    }

    private lazy var log: Logger = {
        var log = self.settings.swim.logger
        log[metadataKey: "swim/node"] = "\(self.settings.myself)"
        return log
    }()

    private var nextPeriodicTickTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Creates a new `SWIMActor` with the given settings.
    ///
    /// This initializer also starts the periodic protocol tick loop.
    public init(settings: SWIMActor.Settings, actorSystem: System) async {
        self.settings = settings
        self.actorSystem = actorSystem
        self.instance = SWIM.Instance(settings: settings.swim, myself: settings.myself)

        // Kick off the periodic protocol tick loop
        self.nextPeriodicTickTask = Task {
            while !Task.isCancelled {
                await self.handlePeriodicProtocolPeriodTick()
            }
        }

        // Announce ourselves as alive
        self.announce(.init(previousStatus: nil, member: self.instance.member))
    }

    // MARK: - Distributed Protocol Surface

    /// Handles an incoming direct ping probe.
    ///
    /// Called remotely by another `SWIMActor` that is health-checking this node.
    public distributed func ping(
        origin: Node,
        payload: SWIM.GossipPayload,
        sequenceNumber: SWIM.SequenceNumber
    ) async throws -> SWIM.PingResponse {
        self.metrics.shell.messageInboundCount.increment()

        self.log.trace(
            "Received ping@\(sequenceNumber)",
            metadata: [
                "swim/ping/origin": "\(origin)",
                "swim/ping/payload": "\(payload)",
            ]
        )

        for directive in self.instance.onPing(
            pingOrigin: origin,
            payload: payload,
            sequenceNumber: sequenceNumber
        ) {
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipProcessed(gossipDirective)

            case .sendAck(_, let pingedTarget, let incarnation, let ackPayload, let ackSequenceNumber):
                return .ack(
                    target: pingedTarget,
                    incarnation: incarnation,
                    payload: ackPayload,
                    sequenceNumber: ackSequenceNumber
                )
            }
        }

        assertionFailure("ping should always return ack")

        throw SWIMActorError.noResponse
    }

    /// Handles an incoming indirect ping request.
    ///
    /// Called remotely by another `SWIMActor` that wants this node to ping `target` on its behalf.
    public distributed func pingRequest(
        target: Node,
        pingRequestOrigin: Node,
        payload: SWIM.GossipPayload,
        sequenceNumber: SWIM.SequenceNumber
    ) async throws -> SWIM.PingResponse {
        self.metrics.shell.messageInboundCount.increment()

        self.log.trace(
            "Received pingRequest@\(sequenceNumber) [\(target)] from [\(pingRequestOrigin)]",
            metadata: [
                "swim/pingRequest/origin": "\(pingRequestOrigin)",
                "swim/pingRequest/payload": "\(payload)",
            ]
        )

        for directive in self.instance.onPingRequest(
            target: target,
            pingRequestOrigin: pingRequestOrigin,
            payload: payload,
            sequenceNumber: sequenceNumber
        ) {
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipProcessed(gossipDirective)

            case .sendPing(let pingTarget, let pingPayload, let pingOrigin, let pingRequestSeqNr, let timeout, let pingSeqNr):
                return await self.sendPing(
                    to: pingTarget,
                    payload: pingPayload,
                    pingRequestOrigin: pingOrigin,
                    pingRequestSequenceNumber: pingRequestSeqNr,
                    timeout: timeout,
                    sequenceNumber: pingSeqNr
                )
            }
        }

        assertionFailure("pingRequest should always return ack/nack from sendPing")

        throw SWIMActorError.noResponse
    }

    // MARK: - Local API

    /// Starts monitoring the given node.
    ///
    /// This is effectively joining the SWIM membership of the other member.
    public func monitor(node: Node) async {
        guard self.settings.myself.withoutUID != node.withoutUID else {
            return  // no need to monitor ourselves
        }

        self.log.debug("Starting to monitor node: \(node)")

        // Fake an ack from the target to bootstrap membership
        let fakeGossip = SWIM.GossipPayload.membership([
            SWIM.Member(node: node, status: .alive(incarnation: 0), protocolPeriod: 0)
        ])
        let directives = self.instance.onPingResponse(
            response: .ack(target: node, incarnation: 0, payload: fakeGossip, sequenceNumber: 0),
            pingRequestOrigin: nil,
            pingRequestSequenceNumber: nil
        )
        for directive in directives {
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipProcessed(gossipDirective)
            case .sendAck, .sendNack, .sendPingRequests:
                break  // not applicable for the fake bootstrap ack
            }
        }

        // Send an initial ping
        let sequenceNumber = self.instance.nextSequenceNumber()
        _ = await self.sendPing(
            to: node,
            payload: self.instance.makeGossipPayload(to: nil),
            pingRequestOrigin: nil,
            pingRequestSequenceNumber: nil,
            timeout: self.settings.swim.pingTimeout,
            sequenceNumber: sequenceNumber
        )
    }

    /// Confirms that the given node is dead.
    ///
    /// This should be called by the host system when it decides to permanently remove a node.
    public func confirmDead(node: Node) async {
        let directive = self.instance.confirmDead(node: node)
        switch directive {
        case .applied(let change):
            self.log.info("Confirmed node .dead: \(change)")
            if change.isReachabilityChange {
                await self.settings.onMembershipChange(change)
            }
        case .ignored:
            self.log.debug("confirmDead for \(node) was ignored")
        }
    }

    // MARK: - Protocol Ticks

    /// Handles a single periodic protocol tick.
    func handlePeriodicProtocolPeriodTick() async {
        let result = self.instance.onPeriodicPingTick()
        for directive in result.directives {
            switch directive {
            case .membershipChanged(let change):
                self.announce(change)

            case .sendPing(let target, let payload, let timeout, let sequenceNumber):
                Task {
                    await self.sendPing(
                        to: target,
                        payload: payload,
                        pingRequestOrigin: nil,
                        pingRequestSequenceNumber: nil,
                        timeout: timeout,
                        sequenceNumber: sequenceNumber
                    )
                }
            }
        }

        try? await Task.sleep(for: result.nextTickDelay)
    }

    // MARK: - Sending pings

    @discardableResult
    public func sendPing(
        to target: Node,
        payload: SWIM.GossipPayload,
        pingRequestOrigin: Node?,
        pingRequestSequenceNumber: SWIM.SequenceNumber?,
        timeout: Duration,
        sequenceNumber: SWIM.SequenceNumber
    ) async -> SWIM.PingResponse {
        guard let targetPeer = await self.settings.resolvePeer(target) else {
            self.log.warning("Unable to resolve peer for node: \(target)")
            return .timeout(
                target: target,
                pingRequestOrigin: pingRequestOrigin,
                timeout: timeout,
                sequenceNumber: sequenceNumber
            )
        }
        self.log.debug(
            "Sending ping to \(target)",
            metadata: [
                "swim/target": "\(target)",
                "swim/timeout": "\(timeout)",
            ]
        )

        self.metrics.shell.messageOutboundCount.increment()
        let pingSentAt = ContinuousClock.now

        do {
            let response = try await self.pingWithTimeout(
                peer: targetPeer,
                origin: self.settings.myself,
                payload: payload,
                timeout: timeout,
                sequenceNumber: sequenceNumber
            )
            self.metrics.shell.pingResponseTime.record(duration: .now - pingSentAt)
            return self.handlePingResponse(
                response: response,
                pingRequestOrigin: pingRequestOrigin,
                pingRequestSequenceNumber: pingRequestSequenceNumber
            )
        } catch {
            self.log.warning("Ping to \(target) failed: \(error)")
            return self.handlePingResponse(
                response: .timeout(
                    target: target,
                    pingRequestOrigin: pingRequestOrigin,
                    timeout: timeout,
                    sequenceNumber: sequenceNumber
                ),
                pingRequestOrigin: pingRequestOrigin,
                pingRequestSequenceNumber: pingRequestSequenceNumber
            )
        }
    }

    /// Performs a distributed ping with a local timeout.
    private func pingWithTimeout(
        peer: SWIMActor<System>,
        origin: Node,
        payload: SWIM.GossipPayload,
        timeout: Duration,
        sequenceNumber: SWIM.SequenceNumber
    ) async throws -> SWIM.PingResponse {
        try await withThrowingTaskGroup(of: SWIM.PingResponse.self) { group in
            group.addTask {
                try await peer.ping(
                    origin: origin,
                    payload: payload,
                    sequenceNumber: sequenceNumber
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SWIMActorError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    public func sendPingRequests(
        _ directive: SWIM.Instance.SendPingRequestDirective
    ) async {
        let pingTimeout = directive.timeout
        let peerToPing = directive.target

        self.metrics.shell.messageOutboundCount.increment()

        let firstSuccessful = await withTaskGroup(of: SWIM.PingResponse.self) { group in
            for pingRequest in directive.requestDetails {
                group.addTask {
                    guard let peer = await self.settings.resolvePeer(pingRequest.peerToPingRequestThrough) else {
                        return .timeout(
                            target: peerToPing,
                            pingRequestOrigin: self.settings.myself,
                            timeout: pingTimeout,
                            sequenceNumber: pingRequest.sequenceNumber
                        )
                    }

                    do {
                        return try await peer.pingRequest(
                            target: peerToPing,
                            pingRequestOrigin: self.settings.myself,
                            payload: pingRequest.payload,
                            sequenceNumber: pingRequest.sequenceNumber
                        )
                    } catch {
                        return .timeout(
                            target: peerToPing,
                            pingRequestOrigin: self.settings.myself,
                            timeout: pingTimeout,
                            sequenceNumber: pingRequest.sequenceNumber
                        )
                    }
                }
            }

            var firstAck: SWIM.PingResponse?
            for await response in group {
                self.handleEveryPingRequestResponse(response: response, pinged: peerToPing)

                if case .ack = response, firstAck == nil {
                    firstAck = response
                    group.cancelAll()
                }
            }
            return firstAck
        }

        if let pingRequestResponse = firstSuccessful {
            self.handlePingRequestResponse(response: pingRequestResponse, pinged: peerToPing)
        } else {
            self.handlePingRequestResponse(
                response: .timeout(
                    target: peerToPing,
                    pingRequestOrigin: self.settings.myself,
                    timeout: pingTimeout,
                    sequenceNumber: 0
                ),
                pinged: peerToPing
            )
        }
    }

    // MARK: - Response handlers

    public func handlePingResponse(
        response: SWIM.PingResponse,
        pingRequestOrigin: Node?,
        pingRequestSequenceNumber: SWIM.SequenceNumber?
    ) -> SWIM.PingResponse {
        var pingRequestOriginResponse: SWIM.PingResponse?

        let directives = self.instance.onPingResponse(
            response: response,
            pingRequestOrigin: pingRequestOrigin,
            pingRequestSequenceNumber: pingRequestSequenceNumber
        )
        for directive in directives {
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipProcessed(gossipDirective)

            case .sendAck(_, let acknowledging, let target, let incarnation, let payload):
                pingRequestOriginResponse = .ack(
                    target: target,
                    incarnation: incarnation,
                    payload: payload,
                    sequenceNumber: acknowledging
                )

            case .sendNack(_, let acknowledging, let target):
                pingRequestOriginResponse = .nack(
                    target: target,
                    sequenceNumber: acknowledging
                )

            case .sendPingRequests(let pingRequestDirective):
                Task {
                    await self.sendPingRequests(pingRequestDirective)
                }
            }
        }

        return pingRequestOriginResponse ?? response
    }

    public func handlePingRequestResponse(response: SWIM.PingResponse, pinged: Node) {
        let directives = self.instance.onPingRequestResponse(response, pinged: pinged)
        for directive in directives {
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipProcessed(gossipDirective)

            case .alive(let previousStatus):
                self.log.debug("Member [\(pinged)] is alive")
                if previousStatus.isUnreachable, let member = self.instance.member(for: pinged) {
                    let event = SWIM.MemberStatusChangedEvent(previousStatus: previousStatus, member: member)
                    self.announce(event)
                }

            case .newlySuspect:
                self.log.debug("Member [\(pinged)] marked as suspect")

            case .nackReceived:
                self.log.debug("Received `nack` from indirect probing of [\(pinged)]")

            default:
                ()
            }
        }
    }

    public func handleEveryPingRequestResponse(response: SWIM.PingResponse, pinged: Node) {
        let directives = self.instance.onEveryPingRequestResponse(response, pinged: pinged)
        if !directives.isEmpty {
            fatalError(
                """
                Ignored directive from: onEveryPingRequestResponse! \
                This directive used to be implemented as always returning no directives. \
                Check your shell implementations if you updated the SWIM library as it seems this has changed. \
                Directive was: \(directives)
                """
            )
        }
    }

    // MARK: - Gossip & Announcements

    private func handleGossipProcessed(_ directive: SWIM.Instance.GossipProcessedDirective) {
        switch directive {
        case .applied(let change):
            self.announce(change)
        }
    }

    private func announce(_ change: SWIM.MemberStatusChangedEvent?) {
        guard let change = change, change.isReachabilityChange else {
            return
        }
        Task {
            await self.settings.onMembershipChange(change)
        }
    }

    deinit {
        self.nextPeriodicTickTask?.cancel()
        self.nextPeriodicTickTask = nil
    }
}

// MARK: - CustomStringConvertible
extension SWIMActor: CustomStringConvertible {
    nonisolated public var description: String {
        "\(Self.self)(\(self.id))"
    }
}

// MARK: - Test hooks
extension SWIMActor {
    /// Returns the current membership state.
    ///
    /// For testing only.
    public func _getMembershipState() -> [SWIM.Member] {
        Array(self.instance.members)
    }

    /// Allows configuring the underlying SWIM instance in tests.
    ///
    /// For testing only.
    public func _configureSWIM(_ configure: (inout SWIM.Instance) throws -> Void) rethrows {
        try configure(&self.instance)
    }
}

// MARK: - Errors
enum SWIMActorError: Error {
    case timeout
    case noResponse
}
