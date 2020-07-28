//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Cluster Membership project authors
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
    public enum Message: Codable {
        case ping(replyTo: NIOPeer, payload: GossipPayload, sequenceNr: SequenceNr)

        /// "Ping Request" requests a SWIM probe.
        case pingReq(target: NIOPeer, replyTo: NIOPeer, payload: GossipPayload, sequenceNr: SequenceNr)

        case response(PingResponse, sequenceNr: SequenceNr)

        var sequenceNr: SequenceNr {
            switch self {
            case .ping(_, _, let sequenceNr):
                return sequenceNr
            case .pingReq(_, _, _, let sequenceNr):
                return sequenceNr
            case .response(_, let sequenceNr):
                return sequenceNr
            }
        }
    }
}

/// The SWIM shell is responsible for driving all interactions of the `SWIM.Instance` with the outside world.
///
/// WARNING: ALL external invocations MUST be executed on the Shell's `EventLoop`, failure to do so will c
///
/// - SeeAlso: `SWIM.Instance` for detailed documentation about the SWIM protocol implementation.
public final class SWIMNIOShell: SWIM.Context {
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

    /// Function to creat new outbound connections to discovered peers
    let makeClient: (Node) -> EventLoopFuture<Channel>

    internal init(
        settings: SWIM.Settings,
        node: Node,
        channel: Channel,
        startPeriodicPingTimer: Bool = true,
        makeClient: @escaping (Node) -> EventLoopFuture<Channel>
    ) {
        self.log = settings.logger
        self.eventLoop = channel.eventLoop
        self._peerConnections = [:]

        let myself = SWIM.NIOPeer(node: node, channel: channel)
        self.myself = myself
        self.swim = SWIM.Instance(settings: settings, myself: myself)

        self.makeClient = makeClient

        self.onStart(startPeriodicPingTimer: startPeriodicPingTimer)
    }

    /// Initialize timers and other after-initialized tasks
    private func onStart(startPeriodicPingTimer: Bool) {
        // Immediately attempt to connect to initial contact points
        self.settings.initialContactPoints.forEach { node in
            self.resolvePeer(on: node) { peer in
                self.swim.addMember(peer, status: .alive(incarnation: 0)) // assume the best case; we'll find out soon enough its real status
            }
        }

        if startPeriodicPingTimer {
            // Kick off timer for periodically pinging random cluster member (i.e. the periodic Gossip)
            self.schedule(key: SWIMNIOShell.periodicPingKey, delay: self.settings.probeInterval) {
                self.handleNewProtocolPeriod()
            }
        }
    }

    public func resolvePeer(_ addressable: AddressableSWIMPeer, _ whenResolved: @escaping (SWIM.NIOPeer) -> Void) {
        if let readyPeer = addressable as? SWIM.NIOPeer, readyPeer.channel != nil {
            whenResolved(readyPeer)
        } else {
            self.resolvePeer(on: addressable.node, whenResolved)
        }
    }

    /// Returns existing `NIOPeer` (associated with a Channel) or establishes a new outbound channel and returns once connected.
    ///
    /// - Parameters:
    ///   - node: node which the peer will be representing // TODO: UIDs...
    ///   - whenResolved: callback is ensure to run on `self.eventLoop`
    public func resolvePeer(on node: Node, _ whenResolved: @escaping (SWIM.NIOPeer) -> Void) {
        guard self.node != node else {
            fatalError("Attempted to resolve and send messages to myself [\(self.node)], this should never be necessary.")
        }

        if let peer = self._peerConnections[node], peer.channel != nil {
            whenResolved(peer)
        } else {
            self.log.trace("Resolving new SWIM.NIOPeer: \(node)", metadata: [
                "swim/node": "\(node)",
            ])

            self.makeClient(node).hop(to: self.eventLoop).map { channel in
                let peer = SWIM.NIOPeer(node: node, channel: channel)
                self.log.trace("Successfully resolved new SWIM.NIOPeer", metadata: [
                    "swim/node": "\(node)",
                    "swim/nio/channel": "\(channel)",
                ])
                self._peerConnections[node] = peer
                whenResolved(peer)
            }.whenFailure { error in
                self.log.error("Failed resolving peer for \(node)", metadata: [
                    "error": "\(error)",
                ])
            }
        }
    }

    /// Start a *single* timer, to run the passed task after given delay.
    @discardableResult
    public func schedule(key: String, delay: SWIMTimeAmount, _ task: @escaping () -> Void) -> SWIMCancellable {
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
        case .ping(let replyTo, let payload, let sequenceNr):
            self.receivePing(replyTo: replyTo, payload: payload, sequenceNr: sequenceNr)

        case .pingReq(let target, let replyTo, let payload, let sequenceNr):
            self.receivePingReq(target: target, replyTo: replyTo, payload: payload, sequenceNr: sequenceNr)

        case .response(let pingResponse, let sequenceNr):
            self.receivePingResponse(result: pingResponse, pingReqOriginPeer: nil, sequenceNr: sequenceNr) // FIXME!!!!! we MUST be able to know if this was a response to a ping req CAUSED ping or not; we need request/reply basically
        }
    }

    public func receiveLocalMessage(context: SWIM.Context, message: SWIM.LocalMessage) {
        switch message {
        case .monitor(let node):
            self.handleMonitor(node: node)

        case .confirmDead(let node):
            self.handleConfirmDead(deadNode: node)
        }
    }

    private func receivePing(replyTo: SWIMPeerReplyProtocol /* <SWIM.PingResponse> */, payload: SWIM.GossipPayload, sequenceNr: SWIM.SequenceNr) {
        self.log.trace("Received ping", metadata: self.swim.metadata([
            "swim/replyTo": "\(replyTo.node)",
            "swim/gossip/payload": "\(payload)",
            "swim/sequenceNr": "\(sequenceNr)",
        ]))

        let directives: [SWIM.Instance.OnPingDirective] = self.swim.onPing(payload: payload)
        directives.forEach { directive in
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective)

            case .reply(let reply):
                self.tracelog(.reply(to: replyTo), message: "\(reply)")

                switch reply {
                case .ack(let targetNode, let incarnation, let payload):
                    assert(targetNode == self.node, "Since we are replying to a ping, the target has to be myself node")
                    self.resolvePeer(replyTo) { peer in
                        peer.ack(acknowledging: sequenceNr, target: self.myself, incarnation: incarnation, payload: payload)
                    }

                case .nack(let targetNode):
                    assert(targetNode == self.node, "Since we are replying to a ping, the target has to be myself node")
                    self.resolvePeer(replyTo) { peer in
                        peer.nack(acknowledging: sequenceNr, target: self.myself)
                    }

                case .timeout, .error:
                    fatalError("FIXME this should not happen")
                }
                //
                //            // TODO: push the process gossip into SWIM as well?
                //            // TODO: the payloadToProcess is the same as `payload` here... but showcasing
                //            self.processGossipPayload(payload: payload)
            }
        }
    }

    private func receivePingReq(target: SWIM.NIOPeer /* <SWIM.Message> */, replyTo: SWIM.NIOPeer /* <SWIM.PingResponse> */, payload: SWIM.GossipPayload, sequenceNr: SWIM.SequenceNr) {
        self.log.trace("Received pingRequest", metadata: [
            "swim/replyTo": "\(replyTo.node)",
            "swim/target": "\(target.node)",
            "swim/gossip/payload": "\(payload)",
        ])
        // self.processGossipPayload(payload: payload) // TODO: push into swim

        let directives: [SWIM.Instance.PingRequestDirective] = self.swim.onPingRequest(target: target, replyTo: replyTo, payload: payload)
        directives.forEach { directive in
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective)
            case .ignore:
                self.log.trace("Ignoring ping request", metadata: self.swim.metadata([
                    "swim/pingReq/seqNr": "\(sequenceNr)",
                    "swim/pingReq/target": "\(target)",
                    "swim/pingReq/replyTo": "\(replyTo)",
                ]))
            case .sendPing:
                self.sendPing(to: target, pingReqOriginPeer: replyTo)
            }
        }
//        if !self.swim.isMember(target) {
//            self.____withEnsuredConnection(remoteNode: target.node) { result in
//                // FIXME: how to make this proper here
//                switch result {
//                case .success:
//                    // The case when member is a suspect is already handled in `processGossipPayload`, since
//                    // payload will always contain suspicion about target member
//                    self.swim.addMember(target, status: .alive(incarnation: 0)) // TODO: push into SWIM?
//                    self.sendPing(to: target, pingReqOrigin: replyTo)
//                case .failure(let error):
//                    self.log.warning("Unable to obtain association for remote \(target.node)... Maybe it was tombstoned? Error: \(error)")
//                }
//            }
//        } else {
//            self.sendPing(to: target, pingReqOrigin: replyTo)
//        }
    }

    /// - parameter pingReqOrigin: is set only when the ping that this is a reply to was originated as a `pingReq`.
    func receivePingResponse(
        result: SWIM.PingResponse,
        pingReqOriginPeer: SWIM.NIOPeer?,
        sequenceNr: SWIM.SequenceNr
    ) {
        let directives = self.swim.onPingResponse(response: result, pingReqOrigin: pingReqOriginPeer, sequenceNr: sequenceNr)
        // optionally debug log all directives here
        directives.forEach { directive in
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective)

            case .sendAck(let pingReqOrigin, let acknowledging, let target, let incarnation, let payload):
                pingReqOrigin.ack(acknowledging: acknowledging, target: target, incarnation: incarnation, payload: payload)

            case .sendNack(let pingReqOrigin, let acknowledging, let target):
                pingReqOrigin.nack(acknowledging: acknowledging, target: target)

            case .sendPingRequests(let pingRequestDirective):
                self.sendPingRequests(pingRequestDirective)
            }
        }
    }

    func receivePingRequestResponse(result: SWIM.PingResponse, pingedMember: AddressableSWIMPeer /* <SWIM.Message> */ ) {
        self.tracelog(.receive(pinged: pingedMember.node), message: "\(result)")
        // TODO: do we know here WHO replied to us actually? We know who they told us about (with the ping-req), could be useful to know

        switch self.swim.onPingRequestResponse(result, pingedMember: pingedMember) {
        case .alive(_, let payloadToProcess):
            fatalError("self.processGossipPayload(payload: payloadToProcess)") // FIXME: !!!!!
        case .newlySuspect:
            self.log.debug("Member [\(pingedMember)] marked as suspect")
        case .nackReceived:
            self.log.debug("Received `nack` from indirect probing of [\(pingedMember)]")
        case let other:
            self.log.trace("Handled ping request response, resulting directive: \(other), was ignored.") // TODO explicitly list all cases
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Sending ping, ping-req and friends

    // FIXME: make sendPing and a sendPingReq separately perhaps?

    /// - parameter pingReqOrigin: is set only when the ping that this is a reply to was originated as a `pingReq`.
    func sendPing(
        to target: AddressableSWIMPeer, // SWIM.NIOPeer, // <SWIM.Message>
        pingReqOriginPeer: SWIM.NIOPeer? // <SWIM.PingResponse>
    ) {
        let payload = self.swim.makeGossipPayload(to: target)

        self.log.trace("Sending ping", metadata: self.swim.metadata([
            "swim/target": "\(target.node)",
            "swim/gossip/payload": "\(payload)",
        ]))

        self.resolvePeer(target) { targetPeer in
            // let startPing = metrics.uptimeNanoseconds() // FIXME: metrics

            let timeout: SWIMTimeAmount = self.swim.dynamicLHMProtocolInterval

            targetPeer.ping(payload: payload, from: self.peer, timeout: timeout) { (result: Result<SWIM.PingResponse, Error>) in
                self.eventLoop.execute {
                    switch result {
                    case .success(let response):
                        self.receivePingResponse(result: response, pingReqOriginPeer: pingReqOriginPeer, sequenceNr: 666_666) // FIXME!!!!!!!!!!!
                    case .failure(let error):
                        self.log.error("Failed reply promise: \(error)")
                    }
                }
            }
        }
    }

    func sendPingRequests(_ directive: SWIM.Instance.SendPingRequestDirective) {
        // We are only interested in successful pings, as a single success tells us the node is
        // still alive. Therefore we propagate only the first success, but no failures.
        // The failure case is handled through the timeout of the whole operation.
        let firstSuccessPromise = self.eventLoop.makePromise(of: SWIM.PingResponse.self)
        let pingTimeout = self.swim.dynamicLHMPingTimeout
        let toPing = directive.targetNode
        for detail in directive.requestDetails {
            let memberToPingRequestThrough = detail.memberToPingRequestThrough
            let payload = detail.payload

            self.log.trace("Sending ping request for [\(toPing)] to [\(memberToPingRequestThrough)] with payload: \(payload)")

            // let startPingReq = metrics.uptimeNanoseconds() // FIXME: metrics
            // self.tracelog(.send(to: member.peer), message: ".pingReq(target: \(toPing), payload: \(payload), from: \(self.peer))")
            self.resolvePeer(memberToPingRequestThrough.peer) { peerToPingRequestThrough in
                peerToPingRequestThrough.pingRequest(target: toPing, payload: payload, from: self.peer, timeout: pingTimeout) { result in
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
        }

        // guaranteed to be on "our" EL
        firstSuccessPromise.futureResult.whenComplete {
            switch $0 {
            case .success(let response):
                self.receivePingRequestResponse(result: response, pingedMember: toPing)
            case .failure(let error):
                self.receivePingRequestResponse(result: .error(error, target: toPing.node), pingedMember: toPing)
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handling local messages

    /// Scheduling a new protocol period and performing the actions for the current protocol period
    func handleNewProtocolPeriod() {
        self.periodicPingRandomMember()

        self.schedule(key: SWIMNIOShell.periodicPingKey, delay: self.swim.dynamicLHMProtocolInterval) {
            self.handleNewProtocolPeriod()
        }
    }

    /// Periodic (scheduled) function to ping ("probe") a random member.
    ///
    /// This is the heart of the periodic gossip performed by SWIM.
    func periodicPingRandomMember() {
        self.log.trace("Periodic ping random member, among: \(self.swim.otherMemberCount)", metadata: self.swim.metadata)

        // needs to be done first, so we can gossip out the most up to date state
        self.checkSuspicionTimeouts()

        if let toPing = self.swim.nextMemberToPing() { // TODO: Push into SWIM
            self.sendPing(to: toPing, pingReqOriginPeer: nil)
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
            fatalError("Marking [\(member)] as [.dead] failed! This should never happen, dead is the terminal status. SWIM instance: \(optional: self.swim)")
        }
    }

    func checkSuspicionTimeouts() {
        self.log.trace(
            "Checking suspicion timeouts...",
            metadata: [
                "swim/suspects": "\(self.swim.suspects)",
                "swim/all": Logger.MetadataValue.array(self.swim.allMembers.map { "\($0)" }),
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

    // FIXME: push into swim
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
//    func processGossipPayload(payload: SWIM.GossipPayload) {
//        switch payload {
//        case .membership(let members):
//            self.handleGossipPayloadProcessedDirective(members: members)
//
//        case .none:
//            return // ok
//        }
//    }

//    func processGossipedMembership(members: SWIM.Members) {
//        for member in members {
//            switch self.swim.onGossipPayload(about: member) {
//            case .connect(let node): // FIXME: remove this
//                self.resolvePeer(on: node) { _ in () } // "connect"
//
//            case .ignored(let level, let message):
//                if let level = level, let message = message {
//                    self.log.log(level: level, message, metadata: self.swim.metadata)
//                }
//
//            case .applied(let change, _, _):
//                self.tryAnnounceMemberReachability(change: change)
//            }
//        }
//    }

    func handleGossipPayloadProcessedDirective(_ directive: SWIM.Instance.GossipProcessedDirective) {
        switch directive {
        case .connect(let node): // FIXME: remove this?
            self.resolvePeer(on: node) { _ in () } // "connect"

        case .ignored(let level, let message): // TODO:
            if let level = level, let message = message {
                self.log.log(level: level, message, metadata: self.swim.metadata)
            }

        case .applied(let change, _, _):
            self.tryAnnounceMemberReachability(change: change)
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
    // FIXME: this should go away, we don't need it at all
//    func ____withEnsuredConnection(remoteNode: Node?, continueWithAssociation: @escaping (Result<Node, Error>) -> Void) {
//        // this is a local node, so we don't need to connect first
//        guard let remoteNode = remoteNode else {
//            continueWithAssociation(.success(self.node))
//            return
//        }
//
//        // handle kicking off associations automatically when attempting to send to them; so we do nothing here (!!!)
//        continueWithAssociation(.success(remoteNode))
//    }

    struct EnsureAssociationError: Error {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }

    /// This is effectively joining the SWIM membership of the other member.
    func sendFirstRemotePing(on node: Node) {
        self.resolvePeer(on: node) { peer in
            // We need to include the member immediately, rather than when we have ensured the association.
            // This is because if we're not able to establish the association, we still want to re-try soon (in the next ping round),
            // and perhaps then the other node would accept the association (perhaps some transient network issues occurred OR the node was
            // already dead when we first try to ping it). In those situations, we need to continue the protocol until we're certain it is
            // suspect and unreachable, as without signalling unreachable the high-level membership would not have a chance to notice and
            // call the node [Cluster.MemberStatus.down].
            self.swim.addMember(peer, status: .alive(incarnation: 0))

            // TODO: we are sending the ping here to initiate cluster membership. Once available this should do a state sync instead
            self.sendPing(to: peer, pingReqOriginPeer: nil)
        }
    }
}

extension SWIMNIOShell {
    static let periodicPingKey = "swim/periodic-ping"
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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors

struct TimeoutError: Error {
    let task: String
    let timeout: SWIMTimeAmount
}