//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import Logging
import NIO
import SWIM

extension SWIM {
//    enum Message: Codable {
//        case remote(RemoteMessage)
//        case local(LocalMessage) // TODO: remove?
//    }

    enum RemoteMessage: Codable {
        // case ping(replyTo: SWIM.NIOPeer<PingResponse>, payload: GossipPayload) // FIXME accept only PingResponse here
        case ping(replyTo: NIOPeer, payload: GossipPayload)

        /// "Ping Request" requests a SWIM probe.
        // case pingReq(target: SWIM.NIOPeer<Message>, replyTo: SWIM.NIOPeer<PingResponse>, payload: GossipPayload) // FIXME: typed peers
        case pingReq(target: NIOPeer, replyTo: NIOPeer, payload: GossipPayload)

        case response(PingResponse)
    }

//    /// Message sent in reply to a `SWIM.RemoteMessage.ping`.
//    ///
//    /// The ack may be delivered directly in a request-response fashion between the probing and pinged members,
//    /// or indirectly, as a result of a `pingReq` message.
//    enum PingResponse {
//        /// TODO: docs
//        /// - parameter target: always contains the peer of the member that was the target of the `ping`.
//        /// - parameter incarnation: TODO: docs
//        /// - parameter payload: TODO: docs
//        case ack(target: NIOPeer, incarnation: Incarnation, payload: GossipPayload)
//
//        /// TODO: docs
//        /// - parameter target: always contains the peer of the member that was the target of the `ping`.
//        /// - parameter incarnation: TODO: docs
//        /// - parameter payload: TODO: docs
//        case nack(target: NIOPeer)
//    }
}

/// The SWIM shell is responsible for driving all interactions of the `SWIM.Instance` with the outside world.
///
/// All access is assumed to be on the same `EventLoop` as the Channel used to initialize the shell.
///
/// - SeeAlso: `SWIM.Instance` for detailed documentation about the SWIM protocol implementation.
public final class NIOSWIMShell: SWIM.Context {
    internal var swim: SWIM.Instance!
    internal var settings: SWIM.Settings {
        self.swim.settings
    }

    public var log: Logger
    let eventLoop: EventLoop

    let myself: SWIM.NIOPeer
    public var peer: SWIMPeerProtocol {
        self.myself
    }

    public var node: Node {
        self.myself.node
    }

    internal var _peerConnections: [Node: SWIM.NIOPeer]

    internal init(settings: SWIM.Settings, node: Node, channel: Channel) {
        self.log = settings.logger
        self.eventLoop = channel.eventLoop
        self._peerConnections = [:]
        let myself = SWIM.NIOPeer(node: node, channel: channel)
        self.myself = myself
        self.swim = SWIM.Instance(settings, myself: myself)

        _ = self.startTimer(key: NIOSWIMShell.periodicPingKey, delay: self.settings.probeInterval) {
            self.periodicPingRandomMember()
        }
    }

    public func peer(on node: Node) -> SWIM.NIOPeer {
        if let peer = self._peerConnections[node] {
            return peer
        } else {
            fatalError("// FIXME: if not existing yet we need to make a connection") // FIXME:
        }
    }

    /// Start a *single* timer, to run the passed task after given delay.
    public func startTimer(key: String, delay: SWIMTimeAmount, _ task: @escaping () -> Void) -> Cancellable {
        fatalError("startTimer(key:delay:_:) has not been implemented")
    }

    // ==== ------------------------------------------------------------------------------------------------------------

//    internal func receiveTestingMessage(_ message: SWIM.TestingMessage) {
//        switch message {
//        case .getMembershipState(let replyTo):
//            self.log.trace("getMembershipState from \(replyTo), state: \(shell.swim._allMembersDict)")
//            replyTo.send(SWIM.MembershipState(membershipState: shell.swim._allMembersDict))
//            return .same
//        }
//    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receiving messages

    func receiveRemoteMessage(message: SWIM.RemoteMessage, from senderNode: Node) {
        self.tracelog(.receive, message: "\(message)")

        let sender = self.peer(on: senderNode)

        switch message {
        case .ping(let replyTo, let payload):
            self.handlePing(replyTo: replyTo, payload: payload)

        case .pingReq(let target, let replyTo, let payload):
            self.handlePingReq(target: target, replyTo: replyTo, payload: payload)

        case .response(let pingResponse):
            switch pingResponse {
            case .nack(let targetNode):
                let target = self.peer(on: targetNode)
                self.handlePingResponse(result: .success(pingResponse), pingedMember: target, pingReqOrigin: sender) // FIXME:
            case .ack(let targetNode, _, _):
                let target = self.peer(on: targetNode)
                self.handlePingResponse(result: .success(pingResponse), pingedMember: target, pingReqOrigin: sender) // FIXME:
            }
        }
    }

    private func handlePing(replyTo: SWIMPeerProtocol /* <SWIM.PingResponse> */, payload: SWIM.GossipPayload) {
        self.processGossipPayload(payload: payload)

        switch self.swim.onPing() {
        case .reply(let reply): // FIXME: shape is somewhat wrong
            self.tracelog(.reply(to: replyTo), message: "\(reply)")

            switch reply {
            case .ack(let target, let incarnation, let payload):
                replyTo.ack(target: self.peer(on: target), incarnation: incarnation, payload: payload) // FIXME: is the self.peer() needed?

            case .nack(let target):
                replyTo.nack(target: self.peer(on: target))
            }

            // TODO: push the process gossip into SWIM as well?
            // TODO: the payloadToProcess is the same as `payload` here... but showcasing
            self.processGossipPayload(payload: payload)
        }
    }

    private func handlePingReq(target: SWIM.NIOPeer /* <SWIM.Message> */, replyTo: SWIM.NIOPeer /* <SWIM.PingResponse> */, payload: SWIM.GossipPayload) {
        self.log.trace("Received request to ping [\(target)] from [\(replyTo)] with payload [\(payload)]")
        self.processGossipPayload(payload: payload)

        if !self.swim.isMember(target) {
            self.withEnsuredConnection(remoteNode: target.node) { result in
                // FIXME: how to make this proper here
                switch result {
                case .success:
                    // The case when member is a suspect is already handled in `processGossipPayload`, since
                    // payload will always contain suspicion about target member
                    self.swim.addMember(target, status: .alive(incarnation: 0)) // TODO: push into SWIM?
                    self.sendPing(to: target, pingReqOrigin: replyTo)
                case .failure(let error):
                    self.log.warning("Unable to obtain association for remote \(target.node)... Maybe it was tombstoned? Error: \(error)")
                }
            }
        } else {
            self.sendPing(to: target, pingReqOrigin: replyTo)
        }
    }

    func receiveLocalMessage(context: SWIM.Context, message: SWIM.LocalMessage) {
        switch message {
        case .pingRandomMember:
            self.handleNewProtocolPeriod()

        case .monitor(let node):
            self.handleMonitor(node: node)

        case .confirmDead(let node):
            self.handleConfirmDead(deadNode: node)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Sending ping, ping-req and friends

    /// - parameter pingReqOrigin: is set only when the ping that this is a reply to was originated as a `pingReq`.
    func sendPing(
        to target: SWIMPeerProtocol, // SWIM.NIOPeer, // <SWIM.Message>
        pingReqOrigin: SWIM.NIOPeer? // <SWIM.PingResponse>
    ) {
        let payload = self.swim.makeGossipPayload(to: target)

        self.log.trace("Sending ping to [\(target)] with payload [\(payload)]")

        // let startPing = metrics.uptimeNanoseconds() // FIXME: metrics
        let replyPromise = self.eventLoop.makePromise(of: SWIM.PingResponse.self)
        let timeout: SWIMTimeAmount = self.swim.dynamicLHMProtocolInterval // FIXME: WE MUST HANDLE THE TIMEOUT ON THE FUTURE INSTEAD HERE SINCE WE HAVE NO REQUEST/REPLY FACILITY
        self.eventLoop.scheduleTask(deadline: .now() + timeout.toNIO) {
            replyPromise.fail(TimeoutError(task: "\(#function)", timeout: timeout))
        }

        target.ping(payload: payload, from: self.peer, timeout: timeout) { (result: Result<SWIM.PingResponse, Error>) in
            replyPromise.completeWith(result)
        }

        // we're guaranteed on "our" EL
        replyPromise.futureResult.whenComplete {
            self.handlePingResponse(result: $0, pingedMember: target, pingReqOrigin: pingReqOrigin)
        }
    }

    struct TimeoutError: Error {
        let task: String
        let timeout: SWIMTimeAmount
    }

    func sendPingRequests(toPing: SWIMPeerProtocol /* <SWIM.Message> */ ) {
        guard let lastKnownStatus = self.swim.status(of: toPing) else {
            self.log.info("Skipping ping requests after failed ping to [\(toPing)] because node has been removed from member list")
            return
        }

        // TODO: also push much of this down into SWIM.Instance

        // select random members to send ping requests to
        let membersToPingRequest = self.swim.membersToPingRequest(target: toPing)

        guard !membersToPingRequest.isEmpty else {
            // no nodes available to ping, so we have to assume the node suspect right away
            if let lastIncarnation = lastKnownStatus.incarnation {
                switch self.swim.mark(toPing, as: self.swim.makeSuspicion(incarnation: lastIncarnation)) {
                case .applied(_, let currentStatus):
                    self.log.info("No members to ping-req through, marked [\(toPing)] immediately as [\(currentStatus)].")
                    return
                case .ignoredDueToOlderStatus(let currentStatus):
                    self.log.info("No members to ping-req through to [\(toPing)], was already [\(currentStatus)].")
                    return
                }
            } else {
                self.log.trace("Not marking .suspect, as [\(toPing)] is already dead.") // "You are already dead!"
                return
            }
        }

        // We are only interested in successful pings, as a single success tells us the node is
        // still alive. Therefore we propagate only the first success, but no failures.
        // The failure case is handled through the timeout of the whole operation.
        let firstSuccessPromise = self.eventLoop.makePromise(of: SWIM.PingResponse.self)
        let pingTimeout = self.swim.dynamicLHMPingTimeout
        for member: SWIM.Member in membersToPingRequest {
            let payload = self.swim.makeGossipPayload(to: toPing)

            self.log.trace("Sending ping request for [\(toPing)] to [\(member)] with payload: \(payload)")

            // let startPingReq = metrics.uptimeNanoseconds() // FIXME: metrics
            // self.tracelog(.send(to: member.peer), message: ".pingReq(target: \(toPing), payload: \(payload), from: \(self.peer))")
            member.peer.pingReq(target: toPing, payload: payload, from: self.peer, timeout: pingTimeout) { result in
                // metrics.recordSWIMPingPingResponseTime(since: startPingReq) // FIXME: metrics

                // We choose to cascade only successes;
                // While this has a slight timing implication on time timeout of the pings -- the node that is last
                // in the list that we ping, has slightly less time to fulfil the "total ping timeout"; as we set a total timeout on the entire `firstSuccess`.
                // In practice those timeouts will be relatively large (seconds) and the few millis here should not have a large impact on correctness.
                switch result {
                case .success(let response):
                    firstSuccessPromise.succeed(response)
                case .failure(let error):
                    // these are generally harmless thus we do not want to log them on higher levels
                    self.log.trace("pingReq failed", metadata: [
                        "swim/target": "\(toPing)",
                        "swim/payload": "\(payload)",
                        "swim/pingTimeout": "\(pingTimeout)",
                        "error": "\(error)",
                    ])
                }
            }
        }

        // guaranteed to be on "our" EL
        firstSuccessPromise.futureResult.whenComplete { result in
            self.handlePingRequestResult(result: result, pingedMember: toPing)
        }
    }

    /// - parameter pingReqOrigin: is set only when the ping that this is a reply to was originated as a `pingReq`.
    func handlePingResponse(
        result: Result<SWIM.PingResponse, Error>,
        pingedMember: SWIMPeerProtocol, // SWIM.NIOPeer, // <SWIM.Message>
        pingReqOrigin: SWIM.NIOPeer? // <SWIM.PingResponse>
    ) {
        self.tracelog(.receive(pinged: pingedMember), message: "\(result)")

        switch result {
        case .failure(let err):
            if let timeoutError = err as? TimeoutError {
                self.log.debug(
                    """
                    Did not receive ack from \(pingedMember.node) within [\(timeoutError.timeout.prettyDescription)]. \
                    Sending ping requests to other members.
                    """,
                    metadata: [
                        "swim/target": "\(self.swim.member(for: pingedMember), orElse: "nil")",
                    ]
                )
            } else {
                self.log.debug(
                    """
                    Did not receive ack from \(pingedMember.node) within configured timeout. \
                    Sending ping requests to other members. Error: \(err)
                    """)
            }
            if let pingReqOrigin = pingReqOrigin {
                self.swim.adjustLHMultiplier(.probeWithMissedNack)
                pingReqOrigin.nack(target: pingedMember)
            } else {
                self.swim.adjustLHMultiplier(.failedProbe)
                self.sendPingRequests(toPing: pingedMember)
            }

        case .success(.ack(let pingedNode, let incarnation, let payload)):
            // We're proxying an ack payload from ping target back to ping source.
            // If ping target was a suspect, there'll be a refutation in a payload
            // and we probably want to process it asap. And since the data is already here,
            // processing this payload will just make gossip convergence faster.
            self.processGossipPayload(payload: payload)
            self.log.debug("Received ack from [\(pingedNode)] with incarnation [\(incarnation)] and payload [\(payload)]", metadata: self.swim.metadata)
            let pinged = self.peer(on: pingedNode)
            self.markMember(latest: SWIM.Member(peer: pinged, status: .alive(incarnation: incarnation), protocolPeriod: self.swim.protocolPeriod))
            if let pingReqOrigin = pingReqOrigin {
                pingReqOrigin.ack(target: pinged, incarnation: incarnation, payload: payload)
            } else {
                // LHA-probe multiplier for pingReq responses is handled separately `handlePingRequestResult`
                self.swim.adjustLHMultiplier(.successfulProbe)
            }
        case .success(.nack):
            break
        }
    }

    func handlePingRequestResult(result: Result<SWIM.PingResponse, Error>, pingedMember: SWIMPeerProtocol /* <SWIM.Message> */ ) {
        self.tracelog(.receive(pinged: pingedMember.node), message: "\(result)")
        // TODO: do we know here WHO replied to us actually? We know who they told us about (with the ping-req), could be useful to know

        switch self.swim.onPingRequestResponse(result, pingedMember: pingedMember) {
        case .alive(_, let payloadToProcess):
            self.processGossipPayload(payload: payloadToProcess)
        case .newlySuspect:
            self.log.debug("Member [\(pingedMember)] marked as suspect")
        case .nackReceived:
            self.log.debug("Received `nack` from indirect probing of [\(pingedMember)]")
        default:
            () // TODO: revisit logging more details here
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handling local messages

    /// Scheduling a new protocol period and performing the actions for the current protocol period
    func handleNewProtocolPeriod() {
        self.periodicPingRandomMember()

        self.startTimer(key: NIOSWIMShell.periodicPingKey, delay: self.swim.dynamicLHMProtocolInterval) {
            self.periodicPingRandomMember()
        }
    }

    /// Periodic (scheduled) function to ping ("probe") a random member.
    ///
    /// This is the heart of the periodic gossip performed by SWIM.
    func periodicPingRandomMember() {
        self.log.trace("Periodic ping random member, among: \(self.swim.allMembers.count)", metadata: self.swim.metadata)

        // needs to be done first, so we can gossip out the most up to date state
        self.checkSuspicionTimeouts()

        if let toPing = swim.nextMemberToPing() { // TODO: Push into SWIM
            self.sendPing(to: toPing, pingReqOrigin: nil)
        }
        self.swim.incrementProtocolPeriod()
    }

    func handleMonitor(node: Node) {
        guard self.node != node else { // FIXME: compare while ignoring the UUID
            return // no need to monitor ourselves, nor a replacement of us (if node is our replacement, we should have been dead already)
        }

        self.sendFirstRemotePing(on: node)
    }

    // TODO: test in isolation
    func handleConfirmDead(deadNode node: Node) {
        guard let member = self.swim.member(for: node) else {
            // TODO: would want to see if this happens when we fail these tests
            self.log.warning("Attempted to .confirmDead(\(node)), yet no such member known to \(self)!")
            return
        }

        // It is important to not infinitely loop cluster.down + confirmDead messages;
        // See: `.confirmDead` for more rationale
        if member.isDead {
            return // member is already dead, nothing else to do here.
        }

        self.log.trace("Confirming .dead member \(member.node)")

        // We are diverging from the SWIM paper here in that we store the `.dead` state, instead
        // of removing the node from the member list. We do that in order to prevent dead nodes
        // from being re-added to the cluster.
        // TODO: add time of death to the status
        // TODO: GC tombstones after a day

        switch self.swim.mark(member.peer, as: .dead) {
        case .applied(let .some(previousState), _):
            if previousState.isSuspect || previousState.isUnreachable {
                self.log.warning(
                    "Marked [\(member)] as [.dead]. Was marked \(previousState) in protocol period [\(member.protocolPeriod)]",
                    metadata: [
                        "swim/protocolPeriod": "\(self.swim.protocolPeriod)",
                        "swim/member": "\(member)", // TODO: make sure it is the latest status of it in here
                    ]
                )
            } else {
                self.log.warning(
                    "Marked [\(member)] as [.dead]. Node was previously [.alive], and now forced [.dead].",
                    metadata: [
                        "swim/protocolPeriod": "\(self.swim.protocolPeriod)",
                        "swim/member": "\(member)", // TODO: make sure it is the latest status of it in here
                    ]
                )
            }
        case .applied(nil, _):
            // TODO: marking is more about "marking a node as dead" should we rather log addresses and not peer paths?
            self.log.warning("Marked [\(member)] as [.dead]. Node was not previously known to SWIM.")
            // TODO: should we not issue a escalateUnreachable here? depends how we learnt about that node...

        case .ignoredDueToOlderStatus:
            // TODO: make sure a fatal error in SWIM.Shell causes a system shutdown?
            fatalError("Marking [\(member)] as [.dead] failed! This should never happen, dead is the terminal status. SWIM instance: \(self.swim)")
        }
    }

    func checkSuspicionTimeouts() {
        self.log.trace(
            "Checking suspicion timeouts...",
            metadata: [
                "swim/suspects": "\(self.swim.suspects)",
                "swim/all": "\(self.swim.allMembers)",
                "swim/protocolPeriod": "\(self.swim.protocolPeriod)",
            ]
        )

        for suspect in self.swim.suspects {
            if case .suspect(_, let suspectedBy) = suspect.status {
                let suspicionTimeout = self.swim.suspicionTimeout(suspectedByCount: suspectedBy.count)
                self.log.trace(
                    "Checking suspicion timeout for: \(suspect)...",
                    metadata: [
                        "swim/suspect": "\(suspect)",
                        "swim/suspectedBy": "\(suspectedBy.count)",
                        "swim/suspicionTimeout": "\(suspicionTimeout)",
                    ]
                )

                // proceed with suspicion escalation to .unreachable if the timeout period has been exceeded
                // We don't use Deadline because tests can override TimeSource
                guard let startTime = suspect.suspicionStartedAt,
                    self.swim.isExpired(deadline: startTime + suspicionTimeout.nanoseconds) else {
                    continue // skip, this suspect is not timed-out yet
                }

                guard let incarnation = suspect.status.incarnation else {
                    // suspect had no incarnation number? that means it is .dead already and should be recycled soon
                    return
                }

                var unreachableSuspect = suspect
                unreachableSuspect.status = .unreachable(incarnation: incarnation)
                self.markMember(latest: unreachableSuspect)
            }
        }

        // metrics.recordSWIM.Members(self.swim.allMembers) // FIXME metrics
    }

    private func markMember(latest: SWIM.Member) {
        switch self.swim.mark(latest.peer, as: latest.status) {
        case .applied(let previousStatus, _):
            self.log.trace(
                "Marked \(latest.node) as \(latest.status), announcing reachability change",
                metadata: [
                    "swim/member": "\(latest)",
                    "swim/previousStatus": "\(previousStatus, orElse: "nil")",
                ]
            )
            let statusChange = SWIM.MemberStatusChange(fromStatus: previousStatus, member: latest)
            self.tryAnnounceMemberReachability(change: statusChange)
        case .ignoredDueToOlderStatus:
            () // self.log.trace("No change \(latest), currentStatus remains [\(currentStatus)]. No reachability change to announce")
        }
    }

    // TODO: since this is applying payload to SWIM... can we do this in SWIM itself rather?
    func processGossipPayload(payload: SWIM.GossipPayload) {
        switch payload {
        case .membership(let members):
            self.processGossipedMembership(members: members)

        case .none:
            return // ok
        }
    }

    func processGossipedMembership(members: SWIM.Members) {
        for member in members {
            switch self.swim.onGossipPayload(about: member) {
            case .connect(let node, let continueAddingMember):
                // ensuring a connection is asynchronous, but executes callback in context
                self.withEnsuredConnection(remoteNode: node) { uniqueAddressResult in
                    switch uniqueAddressResult {
                    case .success(let uniqueAddress):
                        continueAddingMember(.success(uniqueAddress))
                    case .failure(let error):
                        continueAddingMember(.failure(error))
                        self.log.warning("Unable ensure association with \(node), could it have been tombstoned? Error: \(error)")
                    }
                }

            case .ignored(let level, let message):
                if let level = level, let message = message {
                    self.log.log(level: level, message, metadata: self.swim.metadata)
                }

            case .applied(let change, _, _):
                self.tryAnnounceMemberReachability(change: change)
            }
        }
    }

    /// Announce to the a change in reachability of a member.
    private func tryAnnounceMemberReachability(change: SWIM.MemberStatusChange?) {
        guard let change = change else {
            // this means it likely was a change to the same status or it was about us, so we do not need to announce anything
            return
        }

        guard change.isReachabilityChange else {
            // the change is from a reachable to another reachable (or an unreachable to another unreachable-like (e.g. dead) state),
            // and thus we must not act on it, as the shell was already notified before about the change into the current status.
            return
        }

        // Log the transition
        switch change.toStatus {
        case .unreachable:
            self.log.info(
                """
                Node \(change.member.node) determined [.unreachable]! \
                The node is not yet marked [.down], a downing strategy or other Cluster.Event subscriber may act upon this information.
                """, metadata: [
                    "swim/member": "\(change.member)",
                ]
            )
        default:
            self.log.info(
                "Node \(change.member.node) determined [.\(change.toStatus)] (was [\(change.fromStatus, orElse: "nil")].",
                metadata: [
                    "swim/member": "\(change.member)",
                ]
            )
        }

        let reachability: SWIM.MemberReachability
        switch change.toStatus {
        case .alive, .suspect:
            reachability = .reachable
        case .unreachable, .dead:
            reachability = .unreachable
        }

        // FIXME: !!!!! Publish an failureDetectorReachabilityChanged
        // publish(.failureDetectorReachabilityChanged(change.member.node, reachability))
    }

    // TODO: remove or simplify; SWIM/Associations: Simplify/remove withEnsuredAssociation #601
    /// Use to ensure an association to given remote node exists.
    func withEnsuredConnection(remoteNode: Node?, continueWithAssociation: @escaping (Result<Node, Error>) -> Void) {
        // this is a local node, so we don't need to connect first
        guard let remoteNode = remoteNode else {
            continueWithAssociation(.success(self.node))
            return
        }

        // handle kicking off associations automatically when attempting to send to them; so we do nothing here (!!!)
        continueWithAssociation(.success(remoteNode))
    }

    struct EnsureAssociationError: Error {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }

    /// This is effectively joining the SWIM membership of the other member.
    func sendFirstRemotePing(on node: Node) {
        let remotePeer = self.peer(on: node)

        // We need to include the member immediately, rather than when we have ensured the association.
        // This is because if we're not able to establish the association, we still want to re-try soon (in the next ping round),
        // and perhaps then the other node would accept the association (perhaps some transient network issues occurred OR the node was
        // already dead when we first try to ping it). In those situations, we need to continue the protocol until we're certain it is
        // suspect and unreachable, as without signalling unreachable the high-level membership would not have a chance to notice and
        // call the node [Cluster.MemberStatus.down].
        self.swim.addMember(remotePeer, status: .alive(incarnation: 0))

        // TODO: we are sending the ping here to initiate cluster membership. Once available this should do a state sync instead
        self.sendPing(to: remotePeer, pingReqOrigin: nil)
    }
}

extension NIOSWIMShell {
    static let name: String = "swim"

    static let periodicPingKey = "\(NIOSWIMShell.name)/periodic-ping"
}

// FIXME: do we need to expose reachability in SWIM like this?
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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal "trace-logging" for debugging purposes

internal enum TraceLogType: CustomStringConvertible {
    case reply(to: SWIMPeerProtocol)
    case receive(pinged: SWIMPeerProtocol?)

    static var receive: TraceLogType {
        .receive(pinged: nil)
    }

    var description: String {
        switch self {
        case .receive(nil):
            return "RECV"
        case .receive(let .some(pinged)):
            return "RECV(pinged:\(pinged.node))"
        case .reply(let to):
            return "REPL(to:\(to.node))"
        }
    }
}
