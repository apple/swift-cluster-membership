//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import struct Dispatch.DispatchTime
import Logging
import NIO
import SWIM

/// The SWIM shell is responsible for driving all interactions of the `SWIM.Instance` with the outside world.
///
/// - Warning: Take care to only interact with the shell through `receive...` prefixed functions, as they ensure that
/// all operations performed on the shell are properly synchronized by hopping to the right event loop.
///
/// - SeeAlso: `SWIM.Instance` for detailed documentation about the SWIM protocol implementation.
public final class SWIMNIOShell {
    var swim: SWIM.Instance<SWIM.NIOPeer, SWIM.NIOPeer, SWIM.NIOPeer>!

    let settings: SWIMNIO.Settings
    var log: Logger {
        self.settings.logger
    }

    let eventLoop: EventLoop
    let channel: Channel

    let myself: SWIM.NIOPeer
    public var peer: SWIM.NIOPeer {
        self.myself
    }

    let onMemberStatusChange: (SWIM.MemberStatusChangedEvent<SWIM.NIOPeer>) -> Void

    public var node: Node {
        self.myself.node
    }

    /// Cancellable of the periodicPingTimer (if it was kicked off)
    private var nextPeriodicTickCancellable: SWIMCancellable?

    internal init(
        node: Node,
        settings: SWIMNIO.Settings,
        channel: Channel,
        onMemberStatusChange: @escaping (SWIM.MemberStatusChangedEvent<SWIM.NIOPeer>) -> Void
    ) {
        self.settings = settings

        self.channel = channel
        self.eventLoop = channel.eventLoop

        let myself = SWIM.NIOPeer(node: node, channel: channel)
        self.myself = myself
        self.swim = SWIM.Instance(settings: settings.swim, myself: myself)

        self.onMemberStatusChange = onMemberStatusChange
        self.onStart(startPeriodicPingTimer: settings._startPeriodicPingTimer)
    }

    /// Initialize timers and other after-initialized tasks
    private func onStart(startPeriodicPingTimer: Bool) {
        // Immediately announce that "we" are alive
        self.announceMembershipChange(.init(previousStatus: nil, member: self.swim.member))

        // Immediately attempt to connect to initial contact points
        self.settings.swim.initialContactPoints.forEach { node in
            self.receiveStartMonitoring(node: node)
        }

        if startPeriodicPingTimer {
            // Kick off timer for periodically pinging random cluster member (i.e. the periodic Gossip)
            self.handlePeriodicProtocolPeriodTick()
        }
    }

    /// Receive a shutdown signal and initiate the termination of the shell along with the swim protocol instance.
    ///
    /// Upon shutdown the myself member is marked as `.dead`, although it should not be expected to spread this
    /// information to other nodes. It technically could, but it is not expected not required to.
    public func receiveShutdown() {
        guard self.eventLoop.inEventLoop else {
            return self.eventLoop.execute {
                self.receiveShutdown()
            }
        }

        self.nextPeriodicTickCancellable?.cancel()
        switch self.swim.confirmDead(peer: self.peer) {
        case .applied(let change):
            self.tryAnnounceMemberReachability(change: change)
            self.log.info("\(Self.self) shutdown")
        case .ignored:
            () // ok
        }
    }

    /// Start a *single* timer, to run the passed task after given delay.
    @discardableResult
    private func schedule(delay: Duration, _ task: @escaping () -> Void) -> SWIMCancellable {
        self.eventLoop.assertInEventLoop()

        let scheduled: Scheduled<Void> = self.eventLoop.scheduleTask(in: delay.toNIO) { () in task() }
        return SWIMCancellable { scheduled.cancel() }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receiving messages

    public func receiveMessage(message: SWIM.Message) {
        guard self.eventLoop.inEventLoop else {
            return self.eventLoop.execute {
                self.receiveMessage(message: message)
            }
        }

        self.tracelog(.receive, message: "\(message)")

        switch message {
        case .ping(let replyTo, let payload, let sequenceNumber):
            self.receivePing(pingOrigin: replyTo, payload: payload, sequenceNumber: sequenceNumber)

        case .pingRequest(let target, let pingRequestOrigin, let payload, let sequenceNumber):
            self.receivePingRequest(target: target, pingRequestOrigin: pingRequestOrigin, payload: payload, sequenceNumber: sequenceNumber)

        case .response(let pingResponse):
            self.receivePingResponse(response: pingResponse, pingRequestOriginPeer: nil, pingRequestSequenceNumber: nil)
        }
    }

    /// Allows for typical local interactions with the shell
    public func receiveLocalMessage(message: SWIM.LocalMessage) {
        guard self.eventLoop.inEventLoop else {
            return self.eventLoop.execute {
                self.receiveLocalMessage(message: message)
            }
        }

        self.tracelog(.receive, message: "\(message)")

        switch message {
        case .monitor(let node):
            self.receiveStartMonitoring(node: node)

        case .confirmDead(let node):
            self.receiveConfirmDead(deadNode: node)
        }
    }

    private func receivePing(pingOrigin: SWIM.NIOPeer, payload: SWIM.GossipPayload<SWIM.NIOPeer>, sequenceNumber: SWIM.SequenceNumber) {
        guard self.eventLoop.inEventLoop else {
            return self.eventLoop.execute {
                self.receivePing(pingOrigin: pingOrigin, payload: payload, sequenceNumber: sequenceNumber)
            }
        }

        self.log.trace("Received ping@\(sequenceNumber)", metadata: self.swim.metadata([
            "swim/ping/pingOrigin": "\(pingOrigin.swimNode)",
            "swim/ping/payload": "\(payload)",
            "swim/ping/seqNr": "\(sequenceNumber)",
        ]))

        let directives: [SWIM.Instance.PingDirective] = self.swim.onPing(pingOrigin: pingOrigin.peer(self.channel), payload: payload, sequenceNumber: sequenceNumber)
        directives.forEach { directive in
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective)

            case .sendAck(let pingOrigin, let pingedTarget, let incarnation, let payload, let sequenceNumber):
                self.tracelog(.reply(to: pingOrigin), message: "\(directive)")
                Task {
                    await pingOrigin.peer(self.channel).ack(acknowledging: sequenceNumber, target: pingedTarget, incarnation: incarnation, payload: payload)
                }
            }
        }
    }

    private func receivePingRequest(
        target: SWIM.NIOPeer,
        pingRequestOrigin: SWIM.NIOPeer,
        payload: SWIM.GossipPayload<SWIM.NIOPeer>,
        sequenceNumber: SWIM.SequenceNumber
    ) {
        guard self.eventLoop.inEventLoop else {
            return self.eventLoop.execute {
                self.receivePingRequest(target: target, pingRequestOrigin: pingRequestOrigin, payload: payload, sequenceNumber: sequenceNumber)
            }
        }

        self.log.trace("Received pingRequest", metadata: [
            "swim/pingRequest/origin": "\(pingRequestOrigin.node)",
            "swim/pingRequest/sequenceNumber": "\(sequenceNumber)",
            "swim/target": "\(target.node)",
            "swim/gossip/payload": "\(payload)",
        ])

        let directives = self.swim.onPingRequest(
            target: target,
            pingRequestOrigin: pingRequestOrigin,
            payload: payload,
            sequenceNumber: sequenceNumber
        )
        directives.forEach { directive in
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective)

            case .sendPing(let target, let payload, let pingRequestOriginPeer, let pingRequestSequenceNumber, let timeout, let sequenceNumber):
                Task {
                    await self.sendPing(
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
    }

    ///   - pingRequestOrigin: is set only when the ping that this is a reply to was originated as a `pingRequest`.
    func receivePingResponse(
        response: SWIM.PingResponse<SWIM.NIOPeer, SWIM.NIOPeer>,
        pingRequestOriginPeer: SWIM.NIOPeer?,
        pingRequestSequenceNumber: SWIM.SequenceNumber?
    ) {
        guard self.eventLoop.inEventLoop else {
            return self.eventLoop.execute {
                self.receivePingResponse(response: response, pingRequestOriginPeer: pingRequestOriginPeer, pingRequestSequenceNumber: pingRequestSequenceNumber)
            }
        }

        self.log.trace("Receive ping response: \(response)", metadata: self.swim.metadata([
            "swim/pingRequest/origin": "\(pingRequestOriginPeer, orElse: "nil")",
            "swim/pingRequest/sequenceNumber": "\(pingRequestSequenceNumber, orElse: "nil")",
            "swim/response": "\(response)",
            "swim/response/sequenceNumber": "\(response.sequenceNumber)",
        ]))

        let directives = self.swim.onPingResponse(response: response, pingRequestOrigin: pingRequestOriginPeer, pingRequestSequenceNumber: pingRequestSequenceNumber)
        // optionally debug log all directives here
        directives.forEach { directive in
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective)

            case .sendAck(let pingRequestOrigin, let acknowledging, let target, let incarnation, let payload):
                Task {
                    await pingRequestOrigin.ack(acknowledging: acknowledging, target: target, incarnation: incarnation, payload: payload)
                }

            case .sendNack(let pingRequestOrigin, let acknowledging, let target):
                Task {
                    await pingRequestOrigin.nack(acknowledging: acknowledging, target: target)
                }

            case .sendPingRequests(let pingRequestDirective):
                Task {
                    await self.sendPingRequests(pingRequestDirective)
                }
            }
        }
    }

    func receiveEveryPingRequestResponse(result: SWIM.PingResponse<SWIM.NIOPeer, SWIM.NIOPeer>, pingedPeer: SWIM.NIOPeer) {
        guard self.eventLoop.inEventLoop else {
            return self.eventLoop.execute {
                self.receiveEveryPingRequestResponse(result: result, pingedPeer: pingedPeer)
            }
        }
        self.tracelog(.receive(pinged: pingedPeer), message: "\(result)")
        let directives = self.swim.onEveryPingRequestResponse(result, pinged: pingedPeer)
        if !directives.isEmpty {
            fatalError("""
            Ignored directive from: onEveryPingRequestResponse! \
            This directive used to be implemented as always returning no directives. \
            Check your shell implementations if you updated the SWIM library as it seems this has changed. \
            Directive was: \(directives), swim was: \(self.swim.metadata)
            """)
        }
    }

    func receivePingRequestResponse(result: SWIM.PingResponse<SWIM.NIOPeer, SWIM.NIOPeer>, pingedPeer: SWIM.NIOPeer) {
        guard self.eventLoop.inEventLoop else {
            return self.eventLoop.execute {
                self.receivePingRequestResponse(result: result, pingedPeer: pingedPeer)
            }
        }

        self.tracelog(.receive(pinged: pingedPeer), message: "\(result)")
        // TODO: do we know here WHO replied to us actually? We know who they told us about (with the ping-req), could be useful to know

        // FIXME: change those directives
        let directives: [SWIM.Instance.PingRequestResponseDirective] = self.swim.onPingRequestResponse(result, pinged: pingedPeer)
        directives.forEach {
            switch $0 {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective)

            case .alive(let previousStatus):
                self.log.debug("Member [\(pingedPeer.swimNode)] marked as alive")

                if previousStatus.isUnreachable, let member = swim.member(for: pingedPeer) {
                    let event = SWIM.MemberStatusChangedEvent(previousStatus: previousStatus, member: member) // FIXME: make SWIM emit an option of the event
                    self.announceMembershipChange(event)
                }

            case .newlySuspect(let previousStatus, let suspect):
                self.log.debug("Member [\(suspect)] marked as suspect")
                let event = SWIM.MemberStatusChangedEvent(previousStatus: previousStatus, member: suspect) // FIXME: make SWIM emit an option of the event
                self.announceMembershipChange(event)

            case .nackReceived:
                self.log.debug("Received `nack` from indirect probing of [\(pingedPeer)]")
            case let other:
                self.log.trace("Handled ping request response, resulting directive: \(other), was ignored.") // TODO: explicitly list all cases
            }
        }
    }

    private func announceMembershipChange(_ change: SWIM.MemberStatusChangedEvent<SWIM.NIOPeer>) {
        self.onMemberStatusChange(change)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Sending ping, ping-req and friends

    /// Send a `ping` message to the `target` peer.
    ///
    /// - parameters:
    ///   - pingRequestOrigin: is set only when the ping that this is a reply to was originated as a `pingRequest`.
    ///   - payload: the gossip payload to be sent with the `ping` message
    ///   - sequenceNumber: sequence number to use for the `ping` message
    func sendPing(
        to target: SWIM.NIOPeer,
        payload: SWIM.GossipPayload<SWIM.NIOPeer>,
        pingRequestOrigin: SWIM.NIOPeer?,
        pingRequestSequenceNumber: SWIM.SequenceNumber?,
        timeout: Duration,
        sequenceNumber: SWIM.SequenceNumber
    ) async {
        self.log.trace("Sending ping", metadata: self.swim.metadata([
            "swim/target": "\(target)",
            "swim/gossip/payload": "\(payload)",
            "swim/timeout": "\(timeout)",
        ]))

        self.tracelog(.send(to: target), message: "ping(replyTo: \(self.peer), payload: \(payload), sequenceNr: \(sequenceNumber))")

        do {
            let response = try await target.ping(payload: payload, from: self.peer, timeout: timeout, sequenceNumber: sequenceNumber)
            self.receivePingResponse(
                response: response,
                pingRequestOriginPeer: pingRequestOrigin,
                pingRequestSequenceNumber: pingRequestSequenceNumber
            )
        } catch let error as SWIMNIOTimeoutError {
            self.receivePingResponse(
                response: .timeout(target: target, pingRequestOrigin: pingRequestOrigin, timeout: error.timeout, sequenceNumber: sequenceNumber),
                pingRequestOriginPeer: pingRequestOrigin,
                pingRequestSequenceNumber: pingRequestSequenceNumber
            )
        } catch {
            self.log.debug("Failed to ping", metadata: ["ping/target": "\(target)", "error": "\(error)"])
            self.receivePingResponse(
                response: .timeout(target: target, pingRequestOrigin: pingRequestOrigin, timeout: timeout, sequenceNumber: sequenceNumber),
                pingRequestOriginPeer: pingRequestOrigin,
                pingRequestSequenceNumber: pingRequestSequenceNumber
            )
        }
    }

    func sendPingRequests(_ directive: SWIM.Instance<SWIM.NIOPeer, SWIM.NIOPeer, SWIM.NIOPeer>.SendPingRequestDirective) async {
        // We are only interested in successful pings, as a single success tells us the node is
        // still alive. Therefore we propagate only the first success, but no failures.
        // The failure case is handled through the timeout of the whole operation.
        let firstSuccessPromise = self.eventLoop.makePromise(of: SWIM.PingResponse<SWIM.NIOPeer, SWIM.NIOPeer>.self)
        let pingTimeout = directive.timeout
        let target = directive.target
        let startedSendingPingRequestsSentAt: DispatchTime = .now()

        await withTaskGroup(of: Void.self) { group in
            for pingRequest in directive.requestDetails {
                group.addTask {
                    let peerToPingRequestThrough = pingRequest.peerToPingRequestThrough
                    let payload = pingRequest.payload
                    let sequenceNumber = pingRequest.sequenceNumber

                    self.log.trace("Sending ping request for [\(target)] to [\(peerToPingRequestThrough.swimNode)] with payload: \(payload)")
                    self.tracelog(.send(to: peerToPingRequestThrough), message: "pingRequest(target: \(target), replyTo: \(self.peer), payload: \(payload), sequenceNumber: \(sequenceNumber))")

                    let pingRequestSentAt: DispatchTime = .now()
                    do {
                        let response = try await peerToPingRequestThrough.pingRequest(
                            target: target,
                            payload: payload,
                            from: self.peer,
                            timeout: pingTimeout, sequenceNumber: sequenceNumber
                        )

                        // we only record successes
                        self.swim.metrics.shell.pingRequestResponseTimeAll.recordInterval(since: pingRequestSentAt)
                        self.receiveEveryPingRequestResponse(result: response, pingedPeer: target)

                        if case .ack = response {
                            // We only cascade successful ping responses (i.e. `ack`s);
                            //
                            // While this has a slight timing implication on time timeout of the pings -- the node that is last
                            // in the list that we ping, has slightly less time to fulfil the "total ping timeout"; as we set a total timeout on the entire `firstSuccess`.
                            // In practice those timeouts will be relatively large (seconds) and the few millis here should not have a large impact on correctness.
                            firstSuccessPromise.succeed(response)
                        }
                    } catch {
                        self.receiveEveryPingRequestResponse(result: .timeout(target: target, pingRequestOrigin: self.myself, timeout: pingTimeout, sequenceNumber: sequenceNumber), pingedPeer: target)
                        // these are generally harmless thus we do not want to log them on higher levels
                        self.log.trace("Failed pingRequest", metadata: [
                            "swim/target": "\(target)",
                            "swim/payload": "\(payload)",
                            "swim/pingTimeout": "\(pingTimeout)",
                            "error": "\(error)",
                        ])
                    }
                }
            }
        }

        // guaranteed to be on "our" EL
        firstSuccessPromise.futureResult.whenComplete { result in
            switch result {
            case .success(let response):
                self.swim.metrics.shell.pingRequestResponseTimeFirst.recordInterval(since: startedSendingPingRequestsSentAt)
                self.receivePingRequestResponse(result: response, pingedPeer: target)

            case .failure(let error):
                self.log.debug("Failed to pingRequest via \(directive.requestDetails.count) peers", metadata: ["pingRequest/target": "\(target)", "error": "\(error)"])
                self.receivePingRequestResponse(result: .timeout(target: target, pingRequestOrigin: nil, timeout: pingTimeout, sequenceNumber: 0), pingedPeer: target) // sequence number does not matter
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handling local messages

    /// Periodic (scheduled) function to ping ("probe") a random member.
    ///
    /// This is the heart of the periodic gossip performed by SWIM.
    func handlePeriodicProtocolPeriodTick() {
        self.eventLoop.assertInEventLoop()

        let directives = self.swim.onPeriodicPingTick()
        for directive in directives {
            switch directive {
            case .membershipChanged(let change):
                self.tryAnnounceMemberReachability(change: change)

            case .sendPing(let target, let payload, let timeout, let sequenceNumber):
                self.log.trace("Periodic ping random member, among: \(self.swim.otherMemberCount)", metadata: self.swim.metadata)
                Task {
                    await self.sendPing(to: target, payload: payload, pingRequestOrigin: nil, pingRequestSequenceNumber: nil, timeout: timeout, sequenceNumber: sequenceNumber)
                }

            case .scheduleNextTick(let delay):
                self.nextPeriodicTickCancellable = self.schedule(delay: delay) {
                    self.handlePeriodicProtocolPeriodTick()
                }
            }
        }
    }

    /// Extra functionality, allowing external callers to ask this swim shell to start monitoring a specific node.
    // TODO: Add some attempts:Int + maxAttempts: Int and handle them appropriately; https://github.com/apple/swift-cluster-membership/issues/32
    private func receiveStartMonitoring(node: Node) {
        guard self.eventLoop.inEventLoop else {
            return self.eventLoop.execute {
                self.receiveStartMonitoring(node: node)
            }
        }

        guard self.node.withoutUID != node.withoutUID else {
            return // no need to monitor ourselves, nor a replacement of us (if node is our replacement, we should have been dead already)
        }

        let targetPeer = node.peer(on: self.channel)

        guard !self.swim.isMember(targetPeer, ignoreUID: true) else {
            return // we're done, the peer has become a member!
        }

        let sequenceNumber = self.swim.nextSequenceNumber()
        self.tracelog(.send(to: targetPeer), message: "ping(replyTo: \(self.peer), payload: .none, sequenceNr: \(sequenceNumber))")
        Task {
            do {
                let response = try await targetPeer.ping(payload: self.swim.makeGossipPayload(to: nil), from: self.peer, timeout: .seconds(1), sequenceNumber: sequenceNumber)
                self.receivePingResponse(response: response, pingRequestOriginPeer: nil, pingRequestSequenceNumber: nil)
            } catch {
                self.log.debug("Failed to initial ping, will try again", metadata: ["ping/target": "\(node)", "error": "\(error)"])
                // TODO: implement via re-trying a few times and then giving up https://github.com/apple/swift-cluster-membership/issues/32
                self.eventLoop.scheduleTask(in: .seconds(5)) {
                    self.log.info("(Re)-Attempt ping to initial contact point: \(node)")
                    self.receiveStartMonitoring(node: node)
                }
            }
        }
    }

    // TODO: not presently used in the SWIMNIO + udp implementation, make use of it or remove? other impls do need this functionality.
    private func receiveConfirmDead(deadNode node: Node) {
        guard case .enabled = self.settings.swim.unreachability else {
            self.log.warning("Received confirm .dead for [\(node)], however shell is not configured to use unreachable state, thus this results in no action.")
            return
        }

        // We are diverging from the SWIM paper here in that we store the `.dead` state, instead
        // of removing the node from the member list. We do that in order to prevent dead nodes
        // from being re-added to the cluster.
        // TODO: add time of death to the status?

        guard let member = swim.member(forNode: node) else {
            self.log.warning("Attempted to confirm .dead [\(node)], yet no such member known", metadata: self.swim.metadata)
            return
        }

        // even if it's already dead, swim knows how to handle all the cases:
        let directive = self.swim.confirmDead(peer: member.peer)
        switch directive {
        case .ignored:
            self.log.warning("Attempted to confirmDead node \(node) was ignored, was already dead?", metadata: [
                "swim/member": "\(optional: swim.member(forNode: node))",
            ])

        case .applied(let change):
            self.log.trace("Confirmed node as .dead", metadata: self.swim.metadata([
                "swim/member": "\(optional: swim.member(forNode: node))",
            ]))
            self.tryAnnounceMemberReachability(change: change)
        }
    }

    func handleGossipPayloadProcessedDirective(_ directive: SWIM.Instance<SWIM.NIOPeer, SWIM.NIOPeer, SWIM.NIOPeer>.GossipProcessedDirective) {
        switch directive {
        case .applied(let change):
            self.tryAnnounceMemberReachability(change: change)
        }
    }

    /// Announce to the a change in reachability of a member.
    private func tryAnnounceMemberReachability(change: SWIM.MemberStatusChangedEvent<SWIM.NIOPeer>?) {
        guard let change = change else {
            // this means it likely was a change to the same status or it was about us, so we do not need to announce anything
            return
        }

        guard change.isReachabilityChange else {
            // the change is from a reachable to another reachable (or an unreachable to another unreachable-like (e.g. dead) state),
            // and thus we must not act on it, as the shell was already notified before about the change into the current status.
            return
        }

        // emit the SWIM.MemberStatusChange as user event
        self.announceMembershipChange(change)
    }
}

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

struct SWIMCancellable {
    let cancel: () -> Void

    init(_ cancel: @escaping () -> Void) {
        self.cancel = cancel
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Peer "resolve"

extension SWIMAddressablePeer {
    /// Since we're an implementation over UDP, all messages are sent to the same channel anyway,
    /// and simply wrapped in `NIO.AddressedEnvelope`, thus we can easily take any addressable and
    /// convert it into a real NIO peer by simply providing the channel we're running on.
    func peer(_ channel: Channel) -> SWIM.NIOPeer {
        self.swimNode.peer(on: channel)
    }
}

extension ClusterMembership.Node {
    /// Since we're an implementation over UDP, all messages are sent to the same channel anyway,
    /// and simply wrapped in `NIO.AddressedEnvelope`, thus we can easily take any addressable and
    /// convert it into a real NIO peer by simply providing the channel we're running on.
    func peer(on channel: Channel) -> SWIM.NIOPeer {
        .init(node: self, channel: channel)
    }
}
