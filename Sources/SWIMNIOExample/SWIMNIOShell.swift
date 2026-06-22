//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import Logging
import Metrics
import NIO
import NIOCore
import SWIM

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The SWIM shell is responsible for driving all interactions of the `SWIM.Instance` with the outside world.
///
/// - SeeAlso: `SWIM.Instance` for detailed documentation about SWIM implementation.
public actor SWIMNIOShell {

    private var hasStarted = false
    internal var swim: SWIM.Instance
    private var pendingPings: [SWIM.SequenceNumber: CheckedContinuation<SWIM.PingResponse, any Error>] = [:]
    private var monitoringTasks: [Node: Task<Void, Never>] = [:]
    private var nextPeriodicTickTask: Task<Void, Never>?

    let settings: SWIMNIO.Settings
    nonisolated var log: Logger {
        self.settings.logger
    }

    nonisolated let node: Node
    nonisolated let metrics: SWIM.Metrics.ShellMetrics

    private let outboundContinuation: AsyncStream<(SWIM.Message, Node)>.Continuation
    public let outboundStream: AsyncStream<(SWIM.Message, Node)>

    let onMemberStatusChange: @Sendable (SWIM.MemberStatusChangedEvent) -> Void

    public init(
        node: Node,
        settings: SWIMNIO.Settings,
        onMemberStatusChange: @escaping @Sendable (SWIM.MemberStatusChangedEvent) -> Void
    ) {
        let (stream, continuation) = AsyncStream<(SWIM.Message, Node)>.makeStream()
        self.outboundStream = stream
        self.outboundContinuation = continuation
        self.settings = settings
        self.node = node
        self.swim = SWIM.Instance(settings: settings.swim, myself: node)
        self.metrics = self.swim.metrics.shell
        self.onMemberStatusChange = onMemberStatusChange
    }

    public func start() {
        guard !self.hasStarted else { return }
        self.hasStarted = true

        // Immediately announce that "we" are alive
        self.onMemberStatusChange(.init(previousStatus: nil, member: self.swim.member))

        // Immediately attempt to connect to initial contact points
        for node in self.settings.swim.initialContactPoints {
            self.receiveStartMonitoring(node: node)
        }

        if self.settings._startPeriodicPingTimer {
            // Kick off timer for periodically pinging random cluster member (i.e. the periodic Gossip)
            self.nextPeriodicTickTask = Task {
                while !Task.isCancelled {
                    await self.handlePeriodicProtocolPeriodTick()
                }
            }
        }
    }

    public func run(
        channel: NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>
    ) async throws {
        self.start()
        try await self.runIO(channel: channel)
    }

    private func runIO(
        channel: NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>
    ) async throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let shellMetrics = self.swim.metrics.shell

        try await channel.executeThenClose { inbound, outbound in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        for try await envelope in inbound {
                            let bytes = envelope.data.getBytes(at: 0, length: envelope.data.readableBytes)!
                            let message = try decoder.decode(SWIM.Message.self, from: Data(bytes))
                            shellMetrics.messageInboundCount.increment()
                            shellMetrics.messageInboundBytes.record(bytes.count)
                            self.log.trace(
                                "Read successful: \(message.messageCaseDescription)",
                                metadata: [
                                    "remoteAddress": "\(envelope.remoteAddress)",
                                    "swim/message/type": "\(message.messageCaseDescription)",
                                    "swim/message": "\(message)",
                                ]
                            )
                            await self.receiveMessage(message, from: self.node(from: envelope.remoteAddress))
                        }
                    } catch {
                        self.log.error("Inbound error: \(error)")
                    }
                }

                group.addTask {
                    do {
                        for await (message, node) in self.outboundStream {
                            let data = try encoder.encode(message)
                            var buffer = ByteBuffer()
                            buffer.writeBytes(data)
                            let address = try SocketAddress(ipAddress: node.host, port: node.port)
                            let envelope = AddressedEnvelope<ByteBuffer>(remoteAddress: address, data: buffer)
                            shellMetrics.messageOutboundCount.increment()
                            shellMetrics.messageOutboundBytes.record(data.count)
                            try await outbound.write(envelope)
                        }
                    } catch {
                        self.log.error("Outbound error: \(error)")
                    }
                }
            }
        }
    }

    private func node(from address: SocketAddress) -> Node {
        switch address {
        case .v4(let addr):
            return Node(protocol: "udp", host: addr.host, port: address.port ?? 0, uid: nil)
        case .v6(let addr):
            return Node(protocol: "udp", host: addr.host, port: address.port ?? 0, uid: nil)
        default:
            fatalError("Unsupported address type: \(address)")
        }
    }

    /// Receive a shutdown signal and initiate the termination of the shell along with the swim protocol instance.
    public func receiveShutdown() {
        self.nextPeriodicTickTask?.cancel()
        self.nextPeriodicTickTask = nil

        for (_, task) in self.monitoringTasks {
            task.cancel()
        }
        self.monitoringTasks.removeAll()

        for (_, continuation) in self.pendingPings {
            continuation.resume(throwing: CancellationError())
        }
        self.pendingPings.removeAll()
        self.outboundContinuation.finish()

        let changeToAnnounce: SWIM.MemberStatusChangedEvent? = {
            switch self.swim.confirmDead(node: self.node) {
            case .applied(let change):
                self.log.info("\(Self.self) shutdown")
                return change
            case .ignored:
                return nil
            }
        }()
        self.announceIfReachabilityChange(changeToAnnounce)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receiving messages

    public func receiveMessage(_ message: SWIM.Message, from: Node) {
        self.tracelog(.receiveGeneral, message: "\(message)")

        switch message {
        case .ping(let replyTo, let payload, let sequenceNumber):
            self.receivePing(pingOrigin: replyTo, payload: payload, sequenceNumber: sequenceNumber)

        case .pingRequest(let target, let pingRequestOrigin, let payload, let sequenceNumber):
            self.receivePingRequest(
                target: target,
                pingRequestOrigin: pingRequestOrigin,
                payload: payload,
                sequenceNumber: sequenceNumber
            )

        case .response(let pingResponse):
            self.receivePingResponse(response: pingResponse, pingRequestOriginPeer: nil, pingRequestSequenceNumber: nil)
        }
    }

    /// Allows for typical local interactions with the shell
    public func receiveLocalMessage(message: SWIM.LocalMessage) {
        self.tracelog(.receiveGeneral, message: "\(message)")

        switch message {
        case .monitor(let node):
            self.receiveStartMonitoring(node: node)

        case .confirmDead(let node):
            self.receiveConfirmDead(deadNode: node)
        }
    }

    private func receivePing(
        pingOrigin: Node,
        payload: SWIM.GossipPayload,
        sequenceNumber: SWIM.SequenceNumber
    ) {
        var reachabilityChangesToAnnounce: [SWIM.MemberStatusChangedEvent?] = []

        self.log.trace(
            "Received ping@\(sequenceNumber)",
            metadata: self.swim.metadata([
                "swim/ping/pingOrigin": "\(pingOrigin)",
                "swim/ping/payload": "\(payload)",
                "swim/ping/seqNr": "\(sequenceNumber)",
            ])
        )

        let directives: [SWIM.Instance.PingDirective] = self.swim.onPing(
            pingOrigin: pingOrigin,
            payload: payload,
            sequenceNumber: sequenceNumber
        )
        for directive in directives {
            switch directive {
            case .gossipProcessed(.applied(let change)):
                reachabilityChangesToAnnounce.append(change)

            case .sendAck(let pingOrigin, let pingedTarget, let incarnation, let payload, let sequenceNumber):
                self.tracelog(.reply(to: pingOrigin), message: "\(directive)")
                let message = SWIM.Message.response(
                    .ack(target: pingedTarget, incarnation: incarnation, payload: payload, sequenceNumber: sequenceNumber)
                )
                self.outboundContinuation.yield((message, pingOrigin))
            }
        }

        for change in reachabilityChangesToAnnounce {
            self.announceIfReachabilityChange(change)
        }
    }

    private func receivePingRequest(
        target: Node,
        pingRequestOrigin: Node,
        payload: SWIM.GossipPayload,
        sequenceNumber: SWIM.SequenceNumber
    ) {
        self.log.trace(
            "Received pingRequest",
            metadata: [
                "swim/pingRequest/origin": "\(pingRequestOrigin)",
                "swim/pingRequest/sequenceNumber": "\(sequenceNumber)",
                "swim/target": "\(target)",
                "swim/gossip/payload": "\(payload)",
            ]
        )

        var reachabilityChangesToAnnounce: [SWIM.MemberStatusChangedEvent?] = []
        let directives = self.swim.onPingRequest(
            target: target,
            pingRequestOrigin: pingRequestOrigin,
            payload: payload,
            sequenceNumber: sequenceNumber
        )
        for directive in directives {
            switch directive {
            case .gossipProcessed(.applied(let change)):
                reachabilityChangesToAnnounce.append(change)

            case .sendPing(
                let target,
                let payload,
                let pingRequestOriginPeer,
                let pingRequestSequenceNumber,
                let timeout,
                let sequenceNumber
            ):
                Task {
                    try? await self.sendPing(
                        to: target,
                        payload: payload,
                        pingRequestOrigin: pingRequestOriginPeer,
                        pingRequestSequenceNumber: pingRequestSequenceNumber,
                        timeout: timeout,
                        sequenceNumber: sequenceNumber
                    )
                }
            }
        }

        for change in reachabilityChangesToAnnounce {
            self.announceIfReachabilityChange(change)
        }
    }

    ///   - pingRequestOrigin: is set only when the ping that this is a reply to was originated as a `pingRequest`.
    func receivePingResponse(
        response: SWIM.PingResponse,
        pingRequestOriginPeer: Node?,
        pingRequestSequenceNumber: SWIM.SequenceNumber?
    ) {
        var reachabilityChangesToAnnounce: [SWIM.MemberStatusChangedEvent?] = []

        self.log.trace(
            "Receive ping response: \(response)",
            metadata: self.swim.metadata([
                "swim/pingRequest/origin": .string("\(pingRequestOriginPeer, orElse: "nil")"),
                "swim/pingRequest/sequenceNumber": .string("\(pingRequestSequenceNumber, orElse: "nil")"),
                "swim/response": "\(response)",
                "swim/response/sequenceNumber": "\(response.sequenceNumber)",
            ])
        )

        // First, check if this is a response to a pending ping we sent
        if let continuation = self.pendingPings.removeValue(forKey: response.sequenceNumber) {
            continuation.resume(returning: response)
            return
        }

        let directives = self.swim.onPingResponse(
            response: response,
            pingRequestOrigin: pingRequestOriginPeer,
            pingRequestSequenceNumber: pingRequestSequenceNumber
        )
        for directive in directives {
            switch directive {
            case .gossipProcessed(.applied(let change)):
                reachabilityChangesToAnnounce.append(change)

            case .sendAck(let pingRequestOrigin, let acknowledging, let target, let incarnation, let payload):
                let message = SWIM.Message.response(
                    .ack(target: target, incarnation: incarnation, payload: payload, sequenceNumber: acknowledging)
                )
                self.outboundContinuation.yield((message, pingRequestOrigin))

            case .sendNack(let pingRequestOrigin, let acknowledging, let target):
                let message = SWIM.Message.response(
                    .nack(target: target, sequenceNumber: acknowledging)
                )
                self.outboundContinuation.yield((message, pingRequestOrigin))

            case .sendPingRequests(let pingRequestDirective):
                Task {
                    await self.sendPingRequests(pingRequestDirective)
                }
            }
        }

        for change in reachabilityChangesToAnnounce {
            self.announceIfReachabilityChange(change)
        }
    }

    func receiveEveryPingRequestResponse(
        result: SWIM.PingResponse,
        pingedPeer: Node
    ) {
        self.tracelog(.receive(pinged: pingedPeer), message: "\(result)")
        let directives = self.swim.onEveryPingRequestResponse(result, pinged: pingedPeer)
        if !directives.isEmpty {
            fatalError(
                """
                Ignored directive from: onEveryPingRequestResponse! \
                This directive used to be implemented as always returning no directives. \
                Check your shell implementations if you updated the SWIM library as it seems this has changed. \
                Directive was: \(directives), swim was: \(self.swim.metadata)
                """
            )
        }
    }

    func receivePingRequestResponse(
        result: SWIM.PingResponse,
        pingedPeer: Node
    ) {
        self.tracelog(.receive(pinged: pingedPeer), message: "\(result)")
        var reachabilityChangesToAnnounce: [SWIM.MemberStatusChangedEvent?] = []
        var directChangesToAnnounce: [SWIM.MemberStatusChangedEvent] = []

        let directives: [SWIM.Instance.PingRequestResponseDirective] = self.swim.onPingRequestResponse(
            result,
            pinged: pingedPeer
        )
        for directive in directives {
            switch directive {
            case .gossipProcessed(.applied(let change)):
                reachabilityChangesToAnnounce.append(change)

            case .alive(let previousStatus):
                self.log.debug("Member [\(pingedPeer)] marked as alive")
                if previousStatus.isUnreachable, let member = self.swim.member(for: pingedPeer) {
                    let event = SWIM.MemberStatusChangedEvent(previousStatus: previousStatus, member: member)
                    directChangesToAnnounce.append(event)
                }

            case .newlySuspect(let previousStatus, let suspect):
                self.log.debug("Member [\(suspect)] marked as suspect")
                let event = SWIM.MemberStatusChangedEvent(previousStatus: previousStatus, member: suspect)
                directChangesToAnnounce.append(event)

            case .nackReceived:
                self.log.debug("Received `nack` from indirect probing of [\(pingedPeer)]")
            case let other:
                self.log.trace("Handled ping request response, resulting directive: \(other), was ignored.")
            }
        }

        for change in reachabilityChangesToAnnounce {
            self.announceIfReachabilityChange(change)
        }
        for change in directChangesToAnnounce {
            self.onMemberStatusChange(change)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Sending ping, ping-req and friends

    /// Send a `ping` message to the `target` peer.
    func sendPing(
        to target: Node,
        payload: SWIM.GossipPayload,
        pingRequestOrigin: Node?,
        pingRequestSequenceNumber: SWIM.SequenceNumber?,
        timeout: Duration,
        sequenceNumber: SWIM.SequenceNumber
    ) async throws {
        self.log.trace(
            "Sending ping",
            metadata: self.swim.metadata([
                "swim/target": "\(target)",
                "swim/gossip/payload": "\(payload)",
                "swim/timeout": "\(timeout)",
            ])
        )

        self.tracelog(
            .send(to: target),
            message: "ping(replyTo: \(self.node), payload: \(payload), sequenceNr: \(sequenceNumber))"
        )

        let message = SWIM.Message.ping(replyTo: self.node, payload: payload, sequenceNumber: sequenceNumber)
        let pingSentAt: ContinuousClock.Instant = .now
        self.outboundContinuation.yield((message, target))

        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            if let continuation = self.pendingPings.removeValue(forKey: sequenceNumber) {
                continuation.resume(returning: .timeout(target: target, pingRequestOrigin: pingRequestOrigin, timeout: timeout, sequenceNumber: sequenceNumber))
            }
        }
        defer { timeoutTask.cancel() }

        let response = try await withCheckedThrowingContinuation { continuation in
            self.pendingPings[sequenceNumber] = continuation
        }

        self.swim.metrics.shell.pingResponseTime.record(
            duration: pingSentAt.duration(to: .now)
        )

        self.receivePingResponse(
            response: response,
            pingRequestOriginPeer: pingRequestOrigin,
            pingRequestSequenceNumber: pingRequestSequenceNumber
        )
    }

    private func sendSinglePingRequest(
        peerToPingRequestThrough: Node,
        payload: SWIM.GossipPayload,
        sequenceNumber: SWIM.SequenceNumber,
        pingTimeout: Duration,
        target: Node
    ) async throws -> Result<SWIM.PingResponse, any Error> {
        self.log.trace(
            "Sending ping request for [\(target)] to [\(peerToPingRequestThrough)] with payload: \(payload)"
        )
        self.tracelog(
            .send(to: peerToPingRequestThrough),
            message:
                "pingRequest(target: \(target), replyTo: \(self.node), payload: \(payload), sequenceNumber: \(sequenceNumber))"
        )

        let message = SWIM.Message.pingRequest(
            target: target,
            replyTo: self.node,
            payload: payload,
            sequenceNumber: sequenceNumber
        )
        self.outboundContinuation.yield((message, peerToPingRequestThrough))

        let pingRequestSentAt: ContinuousClock.Instant = .now

        let timeoutTask = Task {
            try? await Task.sleep(for: pingTimeout)
            if let continuation = self.pendingPings.removeValue(forKey: sequenceNumber) {
                continuation.resume(returning: .timeout(target: target, pingRequestOrigin: self.node, timeout: pingTimeout, sequenceNumber: sequenceNumber))
            }
        }
        defer { timeoutTask.cancel() }

        let response = try await withCheckedThrowingContinuation { continuation in
            self.pendingPings[sequenceNumber] = continuation
        }

        self.receiveEveryPingRequestResponse(result: response, pingedPeer: target)

        self.swim.metrics.shell.pingRequestResponseTimeAll.record(
            duration: pingRequestSentAt.duration(to: .now)
        )

        if case .ack = response {
            return .success(response)
        }
        return .failure(SWIMNIOTimeoutError(timeout: pingTimeout, message: "Ping request timeout"))
    }

    func sendPingRequests(
        _ directive: SWIM.Instance.SendPingRequestDirective
    ) async {
        let pingTimeout = directive.timeout
        let target = directive.target
        let startedSendingPingRequestsSentAt: ContinuousClock.Instant = .now

        let firstSuccess = await withTaskGroup(of: Result<SWIM.PingResponse, any Error>.self) { group in
            for pingRequest in directive.requestDetails {
                group.addTask {
                    do {
                        return try await self.sendSinglePingRequest(
                            peerToPingRequestThrough: pingRequest.peerToPingRequestThrough,
                            payload: pingRequest.payload,
                            sequenceNumber: pingRequest.sequenceNumber,
                            pingTimeout: pingTimeout,
                            target: target
                        )
                    } catch {
                        return .failure(error)
                    }
                }
            }

            var firstAck: SWIM.PingResponse?
            while let result = await group.next() {
                if case .success(let response) = result, case .ack = response {
                    firstAck = response
                    group.cancelAll()
                    break
                }
            }
            return firstAck
        }

        if let success = firstSuccess {
            self.swim.metrics.shell.pingRequestResponseTimeFirst.record(
                duration: startedSendingPingRequestsSentAt.duration(to: .now)
            )
            self.receivePingRequestResponse(result: success, pingedPeer: target)
        } else {
            self.log.debug(
                "Failed to pingRequest via \(directive.requestDetails.count) peers",
                metadata: ["pingRequest/target": "\(target)"]
            )
            self.receivePingRequestResponse(
                result: .timeout(target: target, pingRequestOrigin: nil, timeout: pingTimeout, sequenceNumber: 0),
                pingedPeer: target
            )
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handling local messages

    /// Periodic (scheduled) function to ping ("probe") a random member.
    ///
    /// This is the heart of the periodic gossip performed by SWIM.
    func handlePeriodicProtocolPeriodTick() async {
        var reachabilityChangesToAnnounce: [SWIM.MemberStatusChangedEvent?] = []
        let directives = self.swim.onPeriodicPingTick()
        var nextDelay: Duration = .seconds(1)

        for directive in directives {
            switch directive {
            case .membershipChanged(let change):
                reachabilityChangesToAnnounce.append(change)

            case .sendPing(let target, let payload, let timeout, let sequenceNumber):
                self.log.trace(
                    "Periodic ping random member, among: \(self.swim.otherMemberCount)",
                    metadata: self.swim.metadata
                )
                Task {
                    try? await self.sendPing(
                        to: target,
                        payload: payload,
                        pingRequestOrigin: nil,
                        pingRequestSequenceNumber: nil,
                        timeout: timeout,
                        sequenceNumber: sequenceNumber
                    )
                }

            case .scheduleNextTick(let delay):
                nextDelay = delay
            }
        }

        for change in reachabilityChangesToAnnounce {
            self.announceIfReachabilityChange(change)
        }

        try? await Task.sleep(for: nextDelay)
    }

    /// Extra functionality, allowing external callers to ask this swim shell to start monitoring a specific node.
    private func receiveStartMonitoring(node: Node) {
        guard self.node.withoutUID != node.withoutUID else {
            return  // no need to monitor ourselves
        }

        guard !self.swim.isMember(node, ignoreUID: true) else {
            return  // we're done, the peer has become a member!
        }

        // Cancel any existing monitoring task for this node to avoid duplication
        self.monitoringTasks[node]?.cancel()

        let task = Task {
            defer { self.monitoringTasks.removeValue(forKey: node) }

            let sequenceNumber = self.swim.nextSequenceNumber()
            self.tracelog(
                .send(to: node),
                message: "ping(replyTo: \(self.node), payload: .none, sequenceNr: \(sequenceNumber))"
            )
            let payload = self.swim.makeGossipPayload(to: nil)

            do {
                try await self.sendPing(
                    to: node,
                    payload: payload,
                    pingRequestOrigin: nil,
                    pingRequestSequenceNumber: nil,
                    timeout: .seconds(1),
                    sequenceNumber: sequenceNumber
                )
                // sendPing calls receivePingResponse internally, so no need to handle here
            } catch {
                self.log.debug(
                    "Failed to initial ping, will try again",
                    metadata: ["ping/target": "\(node)", "error": "\(error)"]
                )
            }
            // Retry after delay if not yet a member
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if !self.swim.isMember(node, ignoreUID: true) {
                self.log.info("(Re)-Attempt ping to initial contact point: \(node)")
                self.receiveStartMonitoring(node: node)
            }
        }

        self.monitoringTasks[node] = task
    }

    private func receiveConfirmDead(deadNode node: Node) {
        guard case .enabled = self.settings.swim.unreachability else {
            self.log.warning(
                "Received confirm .dead for [\(node)], however shell is not configured to use unreachable state, thus this results in no action."
            )
            return
        }

        var changeToAnnounce: SWIM.MemberStatusChangedEvent? = nil
        guard let member = self.swim.member(for: node) else {
            self.log.warning(
                "Attempted to confirm .dead [\(node)], yet no such member known",
                metadata: self.swim.metadata
            )
            return
        }

        let directive = self.swim.confirmDead(node: member.node)
        switch directive {
        case .ignored:
            self.log.warning(
                "Attempted to confirmDead node \(node) was ignored, was already dead?",
                metadata: [
                    "swim/member": .string("\(optional: self.swim.member(for: node))")
                ]
            )

        case .applied(let change):
            self.log.trace(
                "Confirmed node as .dead",
                metadata: self.swim.metadata([
                    "swim/member": .string("\(optional: self.swim.member(for: node))")
                ])
            )
            changeToAnnounce = change
        }

        if let change = changeToAnnounce {
            self.announceIfReachabilityChange(change)
        }
    }

    func handleGossipPayloadProcessedDirective(
        _ directive: SWIM.Instance.GossipProcessedDirective
    ) {
        switch directive {
        case .applied(let change):
            self.announceIfReachabilityChange(change)
        }
    }

    /// Announce a reachability change only if the event represents one.
    private func announceIfReachabilityChange(_ change: SWIM.MemberStatusChangedEvent?) {
        guard let change = change, change.isReachabilityChange else {
            return
        }
        self.onMemberStatusChange(change)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Tracelog helpers

extension SWIMNIOShell {
    enum TraceLogDirection: CustomStringConvertible {
        case receiveGeneral
        case receive(pinged: Node)
        case send(to: Node)
        case reply(to: Node)

        var description: String {
            switch self {
            case .receiveGeneral:
                return "<<<"
            case .receive(let pinged):
                return "<<<(\(pinged))"
            case .send(let to):
                return ">>>(\(to))"
            case .reply(let to):
                return ">>>(\(to))"
            }
        }
    }

    func tracelog(_ direction: TraceLogDirection, message: @autoclosure () -> String) {
        self.log.trace("\(direction) \(message())")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Reachability

/// Reachability indicates a failure detectors assessment of the member node's reachability,
/// i.e. whether or not the node is responding to health check messages.
///
/// Unlike `MemberStatus` (which may only move "forward"), reachability may flip back and forth between `.reachable`
/// and `.unreachable` states multiple times during the lifetime of a member.
///
/// - SeeAlso: `SWIM` for a distributed failure detector implementation which may issue unreachable events.
public enum MemberReachability: String, Equatable {
    /// The member is reachable and responding to failure detector probing properly.
    case reachable
    /// Failure detector has determined this node as not reachable.
    /// It may be a candidate to be downed.
    case unreachable
}
