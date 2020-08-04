//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import Foundation // for natural logarithm // FIXME: remove https://github.pie.apple.com/sakkana/swift-cluster-membership/issues/6
import Logging

extension SWIM {
    /// # SWIM (Scalable Weakly-consistent Infection-style Process Group Membership Protocol).
    ///
    /// Implementation of the SWIM protocol in abstract terms, see [SWIMShell] for the acting upon directives issued by this instance.
    ///
    /// > As you swim lazily through the milieu,
    /// > The secrets of the world will infect you.
    ///
    /// ### Modifications
    /// - Random, stable order members to ping selection: Unlike the completely random selection in the original paper.
    ///
    /// See the reference documentation of this swim implementation in the reference documentation.
    ///
    /// ### Related Papers
    /// - SeeAlso: [SWIM: Scalable Weakly-consistent Infection-style Process Group Membership Protocol](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf)
    /// - SeeAlso: [Lifeguard: Local Health Awareness for More Accurate Failure Detection](https://arxiv.org/abs/1707.00788)
    public final class Instance { // FIXME: make it a struct?
        public let settings: SWIM.Settings

        // We store the owning SWIMShell peer in order avoid adding it to the `membersToPing` list
        private let myself: SWIMPeerProtocol
        private var node: ClusterMembership.Node {
            self.myself.node
        }

        /// Main members storage, map to values to obtain current members.
        internal var members: [ClusterMembership.Node: SWIM.Member]

        /// List of members maintained in random yet stable order, see `addMember` for details.
        internal var membersToPing: [SWIM.Member]
        /// Constantly mutated by `nextMemberToPing` in an effort to keep the order in which we ping nodes evenly distributed.
        private var _membersToPingIndex: Int = 0
        private var membersToPingIndex: Int {
            self._membersToPingIndex
        }

        private var _sequenceNumber: SWIM.SequenceNumber = 0
        /// Sequence numbers are used to identify messages and pair them up into request/replies.
        /// - SeeAlso: `SWIM.SequenceNumber`
        public func nextSequenceNumber() -> SWIM.SequenceNumber { // TODO: make internal?
            self._sequenceNumber += 1
            return self._sequenceNumber
        }

        /// Lifeguard IV.A. Local Health Multiplier (LHM)
        /// > These different sources of feedback are combined in a Local Health Multiplier (LHM).
        /// > LHM is a saturating counter, with a max value S and min value zero, meaning it will not
        /// > increase above S or decrease below zero.
        ///
        /// Local health multiplier is designed to relax the probeInterval and pingTimeout.
        /// The multiplier will be increased in a following cases:
        /// - When local node needs to refute a suspicion about itself
        /// - When ping-req is missing nack
        /// - When probe is failed
        ///  Each of the above may indicate that local instance is not processing incoming messages in timely order.
        /// The multiplier will be decreased when:
        /// - Ping succeeded with an ack.
        /// Events which cause the specified changes to the LHM counter are defined as `SWIM.LHModifierEvent`
        public var localHealthMultiplier = 0

        // TODO: docs; could be internal?
        public var dynamicLHMProtocolInterval: SWIMTimeAmount {
            SWIMTimeAmount.nanoseconds(self.settings.probeInterval.nanoseconds * Int64(1 + self.localHealthMultiplier))
        }

        // TODO: docs; could be internal?
        public var dynamicLHMPingTimeout: SWIMTimeAmount {
            SWIMTimeAmount.nanoseconds(self.settings.pingTimeout.nanoseconds * Int64(1 + self.localHealthMultiplier))
        }

        /// The incarnation number is used to get a sense of ordering of events, so if an `.alive` or `.suspect`
        /// state with a lower incarnation than the one currently known by a node is received, it can be dropped
        /// as outdated and we don't accidentally override state with older events. The incarnation can only
        /// be incremented by the respective node itself and will happen if that node receives a `.suspect` for
        /// itself, to which it will respond with an `.alive` with the incremented incarnation.
        public var incarnation: SWIM.Incarnation {
            self._incarnation
        }

        private var _incarnation: SWIM.Incarnation = 0

        public init(settings: SWIM.Settings, myself: SWIMPeerProtocol) {
            self.settings = settings
            self.myself = myself
            self.members = [:]
            self.membersToPing = []
            self.addMember(myself, status: .alive(incarnation: 0))
        }

        func makeSuspicion(incarnation: SWIM.Incarnation) -> SWIM.Status {
            .suspect(incarnation: incarnation, suspectedBy: [self.node])
        }

        func mergeSuspicions(suspectedBy: Set<ClusterMembership.Node>, previouslySuspectedBy: Set<ClusterMembership.Node>) -> Set<ClusterMembership.Node> {
            var newSuspectedBy = previouslySuspectedBy
            for suspectedBy in suspectedBy.sorted() where newSuspectedBy.count < self.settings.lifeguard.maxIndependentSuspicions {
                newSuspectedBy.update(with: suspectedBy)
            }
            return newSuspectedBy
        }

        // FIXME: docs
        public func adjustLHMultiplier(_ event: LHModifierEvent) {
            switch event {
            case .successfulProbe:
                if self.localHealthMultiplier > 0 {
                    self.localHealthMultiplier -= 1
                }
            case .failedProbe,
                 .refutingSuspectMessageAboutSelf,
                 .probeWithMissedNack:
                if self.localHealthMultiplier < self.settings.lifeguard.maxLocalHealthMultiplier {
                    self.localHealthMultiplier += 1
                }
            }
        }

        // The protocol period represents the number of times we have pinged a random member
        // of the cluster. At the end of every ping cycle, the number will be incremented.
        // Suspicion timeouts are based on the protocol period, i.e. if a probe did not
        // reply within any of the `suspicionTimeoutPeriodsMax` rounds, it would be marked as `.suspect`.
        private var _protocolPeriod: Int = 0

        /// In order to speed up the spreading of "fresh" rumors, we order gossips in their "number of times gossiped",
        /// and thus are able to easily pick the least spread rumor and pick it for the next gossip round.
        private var _messagesToGossip: Heap<SWIM.Gossip> = Heap(
            comparator: {
                $0.numberOfTimesGossiped < $1.numberOfTimesGossiped
            }
        )

        // FIXME: should not be public
        @discardableResult
        public func addMember(_ peer: SWIMAddressablePeer, status: SWIM.Status) -> AddMemberDirective {
            let maybeExistingMember = self.member(for: peer)

            if let existingMember = maybeExistingMember, existingMember.status.supersedes(status) {
                // we already have a newer state for this member
                return .newerMemberAlreadyPresent(existingMember)
            }

            // just in case we had a peer added manually, and thus we did not know its uuid, let us remove it
            _ = self.members.removeValue(forKey: self.node.withoutUID)

            let member = SWIM.Member(peer: peer, status: status, protocolPeriod: self.protocolPeriod, suspicionStartedAt: self.nowNanos()) // FIXME: why the suspicion?
            self.members[member.node] = member

            if maybeExistingMember == nil, self.notMyself(member) {
                // Newly added members are inserted at a random spot in the list of members
                // to ping, to have a better distribution of messages to this node from all
                // other nodes. If for example all nodes would add it to the end of the list,
                // it would take a longer time until it would be pinged for the first time
                // and also likely receive multiple pings within a very short time frame.
                let insertIndex = Int.random(in: self.membersToPing.startIndex ... self.membersToPing.endIndex)
                self.membersToPing.insert(member, at: insertIndex)
                if insertIndex <= self.membersToPingIndex {
                    // If we inserted the new member before the current `membersToPingIndex`,
                    // we need to advance the index to avoid pinging the same member multiple
                    // times in a row. This is especially critical when inserting a larger
                    // number of members, e.g. when the cluster is just being formed, or
                    // on a rolling restart.
                    self.advanceMembersToPingIndex()
                }
            }

            self.addToGossip(member: member)

            return .added(member)
        }

        public enum AddMemberDirective {
            case added(SWIM.Member)
            case newerMemberAlreadyPresent(SWIM.Member)
        }

        /// Shell API
        ///
        /// Must be invoked when a `pingRequest` is received.
        public func onPingRequest(target: SWIMPeerProtocol, replyTo: SWIMPeerProtocol, payload: SWIM.GossipPayload) -> [PingRequestDirective] {
            var directives: [PingRequestDirective] = []

            // 1) Process gossip
            switch payload {
            case .membership(let members):
                directives = members.map { member in
                    let directive = self.onGossipPayload(about: member)
                    return .gossipProcessed(directive)
                }
            case .none:
                () // ok, no gossip payload
            }

            // 2) Process the ping request itself
            guard self.notMyself(target) else {
                print("Received ping request about myself, ignoring; target: \(target), replyTo: \(replyTo)") // TODO: log?
                directives.append(.ignore)
                return directives
            }

            if !self.isMember(target) {
                // The case when member is a suspect is already handled in `processGossipPayload`, since
                // payload will always contain suspicion about target member
                self.addMember(target, status: .alive(incarnation: 0))
            }
            let pingSequenceNumber = self.nextSequenceNumber()
            directives.append(.sendPing(target: target, pingReqOrigin: replyTo, timeout: self.dynamicLHMPingTimeout, sequenceNumber: pingSequenceNumber))

            return directives
        }

        public enum PingRequestDirective {
            case gossipProcessed(GossipProcessedDirective)
            case ignore
            case sendPing(target: SWIMPeerProtocol, pingReqOrigin: SWIMPeerProtocol, timeout: SWIMTimeAmount, sequenceNumber: SWIM.SequenceNumber)
        }

        /// Implements the round-robin yet shuffled member to probe selection as proposed in the SWIM paper.
        ///
        /// This mechanism should reduce the time until state is spread across the whole cluster,
        /// by guaranteeing that each node will be gossiped to within N cycles (where N is the cluster size).
        ///
        /// - Note:
        ///   SWIM 4.3: [...] The failure detection protocol at member works by maintaining a list (intuitively, an array) of the known
        ///   elements of the current membership list, and select-ing ping targets not randomly from this list,
        ///   but in a round-robin fashion. Instead, a newly joining member is inserted in the membership list at
        ///   a position that is chosen uniformly at random. On completing a traversal of the entire list,
        ///   rearranges the membership list to a random reordering.
        public func nextMemberToPing() -> SWIMAddressablePeer? {
            if self.membersToPing.isEmpty {
                return nil
            }

            defer {
                self.advanceMembersToPingIndex()
            }
            return self.membersToPing[self.membersToPingIndex].peer
        }

        /// Selects `settings.indirectProbeCount` members to send a `ping-req` to.
        func membersToPingRequest(target: SWIMAddressablePeer) -> ArraySlice<SWIM.Member> {
            func notTarget(_ peer: SWIMAddressablePeer) -> Bool {
                peer.node != target.node
            }

            func isReachable(_ status: SWIM.Status) -> Bool {
                status.isAlive || status.isSuspect
            }

            let candidates = self.members
                .values
                .filter {
                    notTarget($0.peer) && notMyself($0.peer) && isReachable($0.status)
                }
                .shuffled()

            return candidates.prefix(self.settings.indirectProbeCount)
        }

        @discardableResult
        public func mark(_ peer: SWIMAddressablePeer, as status: SWIM.Status) -> MarkedDirective {
            let previousStatusOption = self.status(of: peer)

            var status = status
            var protocolPeriod = self.protocolPeriod
            var suspicionStartedAt: Int64?

            if case .suspect(let incomingIncarnation, let incomingSuspectedBy) = status,
                case .suspect(let previousIncarnation, let previousSuspectedBy)? = previousStatusOption,
                let member = self.member(for: peer),
                incomingIncarnation == previousIncarnation {
                let suspicions = self.mergeSuspicions(suspectedBy: incomingSuspectedBy, previouslySuspectedBy: previousSuspectedBy)
                status = .suspect(incarnation: incomingIncarnation, suspectedBy: suspicions)
                // we should keep old protocol period when member is already a suspect
                protocolPeriod = member.protocolPeriod
                suspicionStartedAt = member.suspicionStartedAt
            } else if case .suspect = status {
                suspicionStartedAt = self.nowNanos()
            }

            if let previousStatus = previousStatusOption, previousStatus.supersedes(status) {
                // we already have a newer status for this member
                return .ignoredDueToOlderStatus(currentStatus: previousStatus)
            }

            let member = SWIM.Member(peer: peer, status: status, protocolPeriod: protocolPeriod, suspicionStartedAt: suspicionStartedAt)
            self.members[peer.node] = member
            self.addToGossip(member: member)

            if status.isDead {
                self.removeFromMembersToPing(member)
            }

            return .applied(previousStatus: previousStatusOption, currentStatus: status)
        }

        public enum MarkedDirective: Equatable {
            case ignoredDueToOlderStatus(currentStatus: SWIM.Status)
            case applied(previousStatus: SWIM.Status?, currentStatus: SWIM.Status)
        }

        public func incrementProtocolPeriod() { // TODO: make internal
            self._protocolPeriod += 1
        }

        func advanceMembersToPingIndex() {
            self._membersToPingIndex = (self._membersToPingIndex + 1) % self.membersToPing.count
        }

        func removeFromMembersToPing(_ member: SWIM.Member) {
            if let index = self.membersToPing.firstIndex(where: { $0.peer.node == member.peer.node }) {
                self.membersToPing.remove(at: index)
                if index < self.membersToPingIndex {
                    self._membersToPingIndex -= 1
                }

                if self.membersToPingIndex >= self.membersToPing.count {
                    self._membersToPingIndex = self.membersToPing.startIndex
                }
            }
        }

        public var protocolPeriod: Int {
            self._protocolPeriod
        }

        /// Debug only. Actual suspicion timeout depends on number of suspicions and calculated in `suspicionTimeout`
        /// This will only show current estimate of how many intervals should pass before suspicion is reached. May change when more data is coming
        var timeoutSuspectsBeforePeriodMax: Int64 {
            self.settings.lifeguard.suspicionTimeoutMax.nanoseconds / self.dynamicLHMProtocolInterval.nanoseconds + 1
        }

        /// Debug only. Actual suspicion timeout depends on number of suspicions and calculated in `suspicionTimeout`
        /// This will only show current estimate of how many intervals should pass before suspicion is reached. May change when more data is coming
        var timeoutSuspectsBeforePeriodMin: Int64 {
            self.settings.lifeguard.suspicionTimeoutMin.nanoseconds / self.dynamicLHMProtocolInterval.nanoseconds + 1
        }

        /// The suspicion timeout is calculated as defined in Lifeguard Section IV.B https://arxiv.org/abs/1707.00788
        /// According to it, suspicion timeout is logarithmically decaying from `suspicionTimeoutPeriodsMax` to `suspicionTimeoutPeriodsMin`
        /// depending on a number of suspicion confirmations.
        ///
        /// Suspicion timeout adjusted according to number of known independent suspicions of given member.
        ///
        /// See: Lifeguard IV-B: Local Health Aware Suspicion
        ///
        /// The timeout for a given suspicion is calculated as follows:
        ///
        /// ```
        ///                                             log(C + 1) 􏰁
        /// SuspicionTimeout =􏰀 max(Min, Max − (Max−Min) ----------)
        ///                                             log(K + 1)
        /// ```
        ///
        /// where:
        /// - `Min` and `Max` are the minimum and maximum Suspicion timeout.
        ///   See Section `V-C` for discussion of their configuration.
        /// - `K` is the number of independent suspicions required to be received before setting the suspicion timeout to `Min`.
        ///   We default `K` to `3`.
        /// - `C` is the number of independent suspicions about that member received since the local suspicion was raised.
        public func suspicionTimeout(suspectedByCount: Int) -> SWIMTimeAmount {
            let minTimeout = self.settings.lifeguard.suspicionTimeoutMin
            let maxTimeout = self.settings.lifeguard.suspicionTimeoutMax
            return max(minTimeout, .nanoseconds(maxTimeout.nanoseconds - Int64(round(Double(maxTimeout.nanoseconds - minTimeout.nanoseconds) * (log2(Double(suspectedByCount + 1)) / log2(Double(self.settings.lifeguard.maxIndependentSuspicions + 1)))))))
        }

        /// Checks if a deadline is expired (relating to current time).
        public func isExpired(deadline: Int64) -> Bool {
            deadline < self.nowNanos()
        }

        private func nowNanos() -> Int64 {
            self.settings.timeSourceNanos()
        }

        public func makeGossipPayload(to target: SWIMAddressablePeer?) -> SWIM.GossipPayload {
            var members: [SWIM.Member] = []
            // buddy system will always send to a suspect its suspicion.
            // The reason for that to ensure the suspect will be notified it is being suspected,
            // even if the suspicion has already been disseminated more than `numberOfTimesGossiped` times.
            let targetIsSuspect: Bool
            if let target = target,
                let member = self.member(for: target),
                member.isSuspect {
                // the member is suspect, and we must inform it about this, thus including in gossip payload:
                members.append(member)
                targetIsSuspect = true
            } else {
                targetIsSuspect = false
            }

            // In order to avoid duplicates within a single gossip payload, we
            // first collect all messages we need to gossip out and only then
            // re-insert them into `messagesToGossip`. Otherwise, we may end up
            // selecting the same message multiple times, if e.g. the total number
            // of messages is smaller than the maximum gossip size, or for newer
            // messages that have a lower `numberOfTimesGossiped` counter than
            // the other messages.
            guard self._messagesToGossip.count > 0 else {
                if members.isEmpty {
                    return .none
                } else {
                    return .membership(members)
                }
            }

            var gossipRoundMessages: [SWIM.Gossip] = []
            gossipRoundMessages.reserveCapacity(min(self.settings.gossip.maxGossipCountPerMessage, self._messagesToGossip.count))
            while gossipRoundMessages.count < self.settings.gossip.maxNumberOfMessages,
                let gossip = self._messagesToGossip.removeRoot() {
                gossipRoundMessages.append(gossip)
            }

            members.reserveCapacity(gossipRoundMessages.count)

            for var gossip in gossipRoundMessages {
                // We do NOT add gossip to payload if it's a gossip about self and self is a suspect,
                // this case was handled earlier and doing it here will lead to duplicate messages
                if !(target?.node == gossip.member.peer.node && targetIsSuspect) {
                    members.append(gossip.member)
                }
                gossip.numberOfTimesGossiped += 1
                if gossip.numberOfTimesGossiped < self.settings.gossip.maxGossipCountPerMessage {
                    self._messagesToGossip.append(gossip)
                }
            }

            return .membership(members)
        }

        /// Adds `Member` to gossip messages.
        ///
        /// It will be gossiped at most `settings.gossip.maxGossipCountPerMessage` times. // TODO: confirm this
        private func addToGossip(member: SWIM.Member) {
            // we need to remove old state before we add the new gossip, so we don't gossip out stale state
            self._messagesToGossip.remove(where: { $0.member.peer.node == member.peer.node })
            self._messagesToGossip.append(.init(member: member, numberOfTimesGossiped: 0))
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Member helper functions

extension SWIM.Instance {
    func notMyself(_ member: SWIM.Member) -> Bool {
        self.isMyself(member) == nil
    }

    func notMyself(_ peer: SWIMAddressablePeer) -> Bool {
        !self.isMyself(peer)
    }

    func isMyself(_ member: SWIM.Member) -> SWIM.Member? {
        if self.isMyself(member.peer) {
            var m = member
            m.node = self.node // this ensures the UID is present, even if an incoming gossip was UIDless (because it's their first message, and there was no handshake to exchange the UIDs)
            return m
        } else {
            return nil
        }
    }

    func isMyself(_ peer: SWIMAddressablePeer) -> Bool {
        // we are exactly that node:
        self.node == peer.node ||
            // ...or, the incoming node has no UID; there was no handshake made,
            // and thus the other side does not know which specific node it is going to talk to; as such, "we" are that node
            // as such, "we" are that node; we should never add such peer to our members, but we will reply to that node with "us" and thus
            // inform it about our specific UID, and from then onwards it will know about specifically this node (by replacing its UID-less version with our UID-ful version).
            self.node.withoutUID == peer.node
    }

    // TODO: ensure we actually store "us" in members; do we need this special handling if then at all?
    public func status(of peer: SWIMAddressablePeer) -> SWIM.Status? {
        if self.notMyself(peer) {
            return self.members[peer.node]?.status
        } else {
            // we consider ourselves always as alive (enables refuting others suspecting us)
            return .alive(incarnation: self.incarnation)
        }
    }

    public func isMember(_ peer: SWIMAddressablePeer) -> Bool {
        // the peer could be either:
        // - "us" (i.e. the peer which hosts this SWIM instance, or
        // - a "known member"
        peer.node == self.node || self.members[peer.node] != nil
    }

    public func member(for peer: SWIMAddressablePeer) -> SWIM.Member? {
        let node = peer.node
        return self.members[node]
    }

    public func member(for node: ClusterMembership.Node) -> SWIM.Member? {
        self.member(for: self.myself)
    }

    /// Counts non-dead members.
    public var notDeadMemberCount: Int {
        self.members.lazy.filter {
            !$0.value.isDead
        }.count
    }

    public var otherMemberCount: Int {
        max(0, self.members.count - 1)
    }

    // for testing; used to implement the data for the testing message in the shell: .getMembershipState
    var _allMembersDict: [Node: SWIM.Status] {
        self.members.mapValues {
            $0.status
        }
    }

    /// Lists all suspect members.
    ///
    /// - SeeAlso: `SWIM.MemberStatus.suspect`
    public var suspects: SWIM.Members {
        self.members
            .lazy
            .map {
                $0.value
            }
            .filter {
                $0.isSuspect
            }
    }

    /// Lists all members known to SWIM right now
    public var allMembers: SWIM.MembersValues {
        self.members.values
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Handling SWIM protocol interactions

extension SWIM.Instance {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: On Periodic Ping Tick Handler

    /// Must be invoked periodically, in intervals of `self.swim.dynamicLHMProtocolInterval`.
    public func onPeriodicPingTick() -> PeriodicPingTickDirective {
        defer {
            self.incrementProtocolPeriod()
        }

        guard let toPing = self.nextMemberToPing() else {
            return .ignore
        }

        return .sendPing(target: toPing as! SWIMPeerProtocol, timeout: self.dynamicLHMPingTimeout, sequenceNumber: self.nextSequenceNumber())
    }

    public enum PeriodicPingTickDirective {
        case ignore
        case sendPing(target: SWIMPeerProtocol, timeout: SWIMTimeAmount, sequenceNumber: SWIM.SequenceNumber)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: On Ping Handler

    /// Shell API
    ///
    /// Must be invoked whenever a `Ping` message is received.
    ///
    /// A specific shell implementation must the returned directives by acting on them.
    /// The order of interpreting the events should be as returned by the onPing invocation.
    public func onPing(payload: SWIM.GossipPayload) -> [OnPingDirective] {
        var directives: [OnPingDirective] = []

        // 1) Process gossip
        switch payload {
        case .membership(let members):
            directives = members.map { member in
                let directive = self.onGossipPayload(about: member)
                return .gossipProcessed(directive)
            }
        case .none:
            () // ok, no gossip payload
        }

        // 2) Prepare reply
        let reply = OnPingDirective.reply(
            .ack(
                target: self.myself.node,
                incarnation: self._incarnation,
                payload: self.makeGossipPayload(to: nil),
                sequenceNumber: self.nextSequenceNumber()
            )
        )
        directives.append(reply)

        return directives
    }

    public enum OnPingDirective {
        case gossipProcessed(GossipProcessedDirective)
        case reply(SWIM.PingResponse)
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: On Ping Response Handlers

    /// API
    public func onPingResponse(response: SWIM.PingResponse, pingReqOrigin: SWIMPeerReplyProtocol?) -> [OnPingResponseDirective] {
        switch response {
        case .ack(let target, let incarnation, let payload, let sequenceNumber):
            return self.onPingAckResponse(target: target, incarnation: incarnation, payload: payload, pingReqOrigin: pingReqOrigin, sequenceNumber: sequenceNumber)
        case .nack(let target, let sequenceNumber):
            return self.onPingNackResponse(target: target, pingReqOrigin: pingReqOrigin, sequenceNumber: sequenceNumber)
        case .timeout(let target, let pingReqOriginNode, let timeout, let sequenceNumber):
            return self.onPingResponseTimeout(target: target, timeout: timeout, pingReqOrigin: pingReqOrigin, sequenceNumber: sequenceNumber)
        case .error(let error, let target, let sequenceNumber):
            fatalError() // FIXME: what to do here
        }
    }

    public func onPingAckResponse(
        // response: SWIM.PingResponse,
        target pingedNode: Node, // FIXME: names consistency!!!
        incarnation: SWIM.Incarnation,
        payload: SWIM.GossipPayload,
        pingReqOrigin: SWIMPeerReplyProtocol?,
        sequenceNumber: SWIM.SequenceNumber
    ) -> [OnPingResponseDirective] {
        var directives: [OnPingResponseDirective] = []
        // We're proxying an ack payload from ping target back to ping source.
        // If ping target was a suspect, there'll be a refutation in a payload
        // and we probably want to process it asap. And since the data is already here,
        // processing this payload will just make gossip convergence faster.
        let gossipDirectives = self.onGossipPayload(payload)
        directives.append(contentsOf: gossipDirectives.map {
            OnPingResponseDirective.gossipProcessed($0)
        })

        // self.log.debug("Received ack from [\(pingedNode)] with incarnation [\(incarnation)] and payload [\(payload)]", metadata: self.metadata)
        self.mark(pingedNode, as: .alive(incarnation: incarnation))
        // self.markMember(latest: SWIM.Member(peer: pingedNode, status: .alive(incarnation: incarnation), protocolPeriod: self.protocolPeriod)) // FIXME: adding should be done in the instance...

        if let pingReqOrigin = pingReqOrigin {
            // pingReqOrigin.ack(acknowledging: sequenceNumber, target: pingedNode, incarnation: incarnation, payload: payload)
            directives.append(
                .sendAck(
                    peer: pingReqOrigin,
                    acknowledging: sequenceNumber,
                    target: pingedNode,
                    incarnation: incarnation,
                    payload: payload
                )
            )
        } else {
            // LHA-probe multiplier for pingReq responses is handled separately `handlePingRequestResult`
            self.adjustLHMultiplier(.successfulProbe)
        }

        return directives
    }

    public func onPingNackResponse(
        // response: SWIM.PingResponse,
        target pingedNode: Node, // TODO: names consistency!
        pingReqOrigin: SWIMPeerReplyProtocol?,
        sequenceNumber: SWIM.SequenceNumber
    ) -> [OnPingResponseDirective] {
        var directives: [OnPingResponseDirective] = []
        () // TODO: nothing???
        return directives
    }

    public func onPingResponseTimeout(
        // response: SWIM.PingResponse,
        target pingedNode: Node,
        // pingReqOrigin: Node?,
        timeout: SWIMTimeAmount,
        pingReqOrigin: SWIMPeerReplyProtocol?,
        sequenceNumber pingResponseSequenceNumber: SWIM.SequenceNumber
    ) -> [OnPingResponseDirective] {
        var directives: [OnPingResponseDirective] = []

//            if let timeoutError = err as? TimeoutError {
//                self.log.debug(
//                    """
//                    Did not receive ack from \(pingedNode) within [\(timeoutError.timeout.prettyDescription)]. \
//                    Sending ping requests to other members.
//                    """,
//                    metadata: [
//                        "swim/target": "\(self.member(for: pingedNode), orElse: "nil")",
//                    ]
//                )
//            } else {
//                self.log.debug(
//                    """
//                    Did not receive ack from \(pingedNode) within configured timeout. \
//                    Sending ping requests to other members. Error: \(err)
//                    """)
//            }

        // TODO: timeout details here (!)
        // self.log.debug("Did not receive ack from \(pingedNode) within configured timeout. Sending ping requests to other members.")
        if let pingReqOrigin = pingReqOrigin {
            // Meaning we were doing a ping on behalf of the pingReq origin, and we need to report back to it.
            self.adjustLHMultiplier(.probeWithMissedNack)
            directives.append(
                .sendNack(
                    peer: pingReqOrigin,
                    acknowledging: pingResponseSequenceNumber,
                    target: pingedNode
                )
            )
        } else {
            self.adjustLHMultiplier(.failedProbe)
            if let pingRequestDirective = self.preparePingRequests(toPing: pingedNode) {
                directives.append(.sendPingRequests(pingRequestDirective))
            }
        }

        return directives
    }

    /// Prepare ping request directives such that the shell can easily fire those messages
    func preparePingRequests(toPing: Node) -> SendPingRequestDirective? {
        guard let lastKnownStatus = self.status(of: toPing) else {
            // context.log.info("Skipping ping requests after failed ping to [\(toPing)] because node has been removed from member list") // FIXME allow logging
            return nil
        }

        // select random members to send ping requests to
        let membersToPingRequest = self.membersToPingRequest(target: toPing)

        guard !membersToPingRequest.isEmpty else {
            // no nodes available to ping, so we have to assume the node suspect right away
            if let lastIncarnation = lastKnownStatus.incarnation {
                switch self.mark(toPing, as: self.makeSuspicion(incarnation: lastIncarnation)) {
                case .applied(_, let currentStatus):
                    print("No members to ping-req through, marked [\(toPing)] immediately as [\(currentStatus)].") // TODO: logging
                    return nil
                case .ignoredDueToOlderStatus(let currentStatus):
                    print("No members to ping-req through to [\(toPing)], was already [\(currentStatus)].") // TODO: logging
                    return nil
                }
            } else {
                print("Not marking .suspect, as [\(toPing)] is already dead.") // "You are already dead!" // TODO logging
                return nil
            }
        }

        let details = membersToPingRequest.map { member in
            SendPingRequestDirective.PingRequestDetail(
                memberToPingRequestThrough: member,
                payload: self.makeGossipPayload(to: toPing),
                sequenceNumber: self.nextSequenceNumber()
            )
        }

        return SendPingRequestDirective(targetNode: toPing, requestDetails: details)

//        // We are only interested in successful pings, as a single success tells us the node is
//        // still alive. Therefore we propagate only the first success, but no failures.
//        // The failure case is handled through the timeout of the whole operation.
//        let firstSuccess = context.system._eventLoopGroup.next().makePromise(of: SWIM.PingResponse.self)
//        let pingTimeout = self.dynamicLHMPingTimeout
//        for member in membersToPingRequest {
//            let payload = self.makeGossipPayload(to: toPing)
//
//            context.log.trace("Sending ping request for [\(toPing)] to [\(member)] with payload: \(payload)")
//
//            let startPingReq = context.system.metrics.uptimeNanoseconds()
//            let answer = member.ref.ask(for: SWIM.PingResponse.self, timeout: pingTimeout) {
//                let pingReq = SWIM.RemoteMessage.pingReq(target: toPing, replyTo: $0, payload: payload)
//                self.tracelog(context, .ask(member.ref), message: pingReq)
//                return SWIM.Message.remote(pingReq)
//            }
//
//            answer._onComplete { result in
//                context.system.metrics.recordSWIMPingPingResponseTime(since: startPingReq)
//
//                // We choose to cascade only successes;
//                // While this has a slight timing implication on time timeout of the pings -- the node that is last
//                // in the list that we ping, has slightly less time to fulfil the "total ping timeout"; as we set a total timeout on the entire `firstSuccess`.
//                // In practice those timeouts will be relatively large (seconds) and the few millis here should not have a large impact on correctness.
//                if case .success(let response) = result {
//                    firstSuccess.succeed(response)
//                }
//            }
//        }
//
//        context.onResultAsync(of: firstSuccess.futureResult, timeout: pingTimeout) { result in
//            self.handlePingRequestResult(context: context, result: result, pingedMember: toPing)
//            return .same
//        }
    }

    public enum OnPingResponseDirective {
        case gossipProcessed(GossipProcessedDirective)

        /// Send an `ack` message to `peer`
        case sendAck(peer: SWIMPeerReplyProtocol, acknowledging: SWIM.SequenceNumber, target: Node, incarnation: UInt64, payload: SWIM.GossipPayload)

        /// Send a `nack` to `peer`
        case sendNack(peer: SWIMPeerReplyProtocol, acknowledging: SWIM.SequenceNumber, target: Node)

        /// Send a `pingRequest`
        case sendPingRequests(SendPingRequestDirective)
    }

    public struct SendPingRequestDirective {
        public let targetNode: Node
        public let requestDetails: [PingRequestDetail]

        public struct PingRequestDetail {
            public let memberToPingRequestThrough: SWIM.Member
            public let payload: SWIM.GossipPayload
            public let sequenceNumber: SWIM.SequenceNumber
        }
    }

    /// Must be invoked whenever a response to a `pingRequest` (an ack, nack or lack response i.e. a timeout) happens.
    public func onPingRequestResponse(_ response: SWIM.PingResponse, pingedMember member: SWIMAddressablePeer) -> OnPingRequestResponseDirective {
        guard let lastKnownStatus = self.status(of: member) else {
            return .unknownMember
        }

        switch response {
        case .timeout, .error:
            // missed pingReq's nack may indicate a problem with local health
            self.adjustLHMultiplier(.probeWithMissedNack)

            switch lastKnownStatus {
            case .alive(let incarnation), .suspect(let incarnation, _):
                switch self.mark(member, as: self.makeSuspicion(incarnation: incarnation)) {
                case .applied:
                    return .newlySuspect
                case .ignoredDueToOlderStatus(let status):
                    return .ignoredDueToOlderStatus(currentStatus: status)
                }
            case .unreachable:
                return .alreadyUnreachable
            case .dead:
                return .alreadyDead
            }

        case .ack(let target, let incarnation, let payload, let sequenceNumber):
            assert(target == member.node, "The ack.from member [\(target)] MUST be equal to the pinged member \(member.node)]; The Ack message is being forwarded back to us from the pinged member.")
            self.adjustLHMultiplier(.successfulProbe)
            switch self.mark(member, as: .alive(incarnation: incarnation)) {
            case .applied:
                // TODO: we can be more interesting here, was it a move suspect -> alive or a reassurance?
                return .alive(previous: lastKnownStatus, payloadToProcess: payload)
            case .ignoredDueToOlderStatus(let currentStatus):
                return .ignoredDueToOlderStatus(currentStatus: currentStatus)
            }
        case .nack:
            return .nackReceived
        }
    }

    public enum OnPingRequestResponseDirective {
        case alive(previous: SWIM.Status, payloadToProcess: SWIM.GossipPayload)
        case nackReceived
        case unknownMember
        case newlySuspect
        case alreadySuspect
        case alreadyUnreachable
        case alreadyDead
        case ignoredDueToOlderStatus(currentStatus: SWIM.Status)
    }

    internal func onGossipPayload(_ payload: SWIM.GossipPayload) -> [GossipProcessedDirective] {
        switch payload {
        case .none:
            return []
        case .membership(let members):
            return members.map { member in
                self.onGossipPayload(about: member)
            }
        }
    }

    internal func onGossipPayload(about member: SWIM.Member) -> GossipProcessedDirective {
        if let myself = self.isMyself(member) {
            return onMyselfGossipPayload(myself: myself)
        } else {
            return onOtherMemberGossipPayload(member: member)
        }
    }

    private func onMyselfGossipPayload(myself incoming: SWIM.Member) -> SWIM.Instance.GossipProcessedDirective {
        assert(self.myself.node == incoming.peer.node, "Attempted to process gossip as-if about myself, but was not the same peer, was: \(incoming). Myself: \(self.myself, orElse: "nil")")

        // Note, we don't yield changes for myself node observations, thus the self node will never be reported as unreachable,
        // after all, we can always reach ourselves. We may reconsider this if we wanted to allow SWIM to inform us about
        // the fact that many other nodes think we're unreachable, and thus we could perform self-downing based upon this information // TODO: explore self-downing driven from SWIM

        switch incoming.status {
        case .alive:
            // as long as other nodes see us as alive, we're happy
            return .applied(change: nil)
        case .suspect(let suspectedInIncarnation, _):
            // someone suspected us, so we need to increment our incarnation number to spread our alive status with
            // the incremented incarnation
            if suspectedInIncarnation == self.incarnation {
                self.adjustLHMultiplier(.refutingSuspectMessageAboutSelf)
                self._incarnation += 1
                // refute the suspicion, we clearly are still alive
                self.addToGossip(member: SWIM.Member(peer: self.myself, status: .alive(incarnation: self._incarnation), protocolPeriod: self.protocolPeriod))
                return .applied(change: nil)
            } else if suspectedInIncarnation > self.incarnation {
                return .applied(
                    change: nil,
                    level: .warning,
                    message: """
                    Received gossip about self with incarnation number [\(suspectedInIncarnation)] > current incarnation [\(self._incarnation)], \
                    which should never happen and while harmless is highly suspicious, please raise an issue with logs. This MAY be an issue in the library.
                    """
                )
            } else {
                // incoming incarnation was < than current one, i.e. the incoming information is "old" thus we discard it
                return .ignored
            }

        case .unreachable(let unreachableInIncarnation):
            // someone suspected us, so we need to increment our incarnation number to spread our alive status with
            // the incremented incarnation
            // TODO: this could be the right spot to reply with a .nack, to prove that we're still alive
            if unreachableInIncarnation == self.incarnation {
                self._incarnation += 1
            } else if unreachableInIncarnation > self.incarnation {
                return .applied(
                    change: nil,
                    level: .warning,
                    message: """
                    Received gossip about self with incarnation number [\(unreachableInIncarnation)] > current incarnation [\(self._incarnation)], \
                    which should never happen and while harmless is highly suspicious, please raise an issue with logs. This MAY be an issue in the library.
                    """
                )
            }

            return .applied(change: nil)

        case .dead:
            guard var myselfMember = self.member(for: self.myself) else {
                return .applied(change: nil)
            }

            myselfMember.status = .dead
            switch self.mark(self.myself, as: .dead) {
            case .applied(.some(let previousStatus), _):
                return .applied(change: .init(fromStatus: previousStatus, member: myselfMember))
            default:
                return .ignored(level: .warning, message: "Self already marked .dead")
            }
        }
    }

    private func onOtherMemberGossipPayload(member: SWIM.Member) -> SWIM.Instance.GossipProcessedDirective {
        assert(self.node != member.node, "Attempted to process gossip as-if not-myself, but WAS same peer, was: \(member). Myself: \(self.myself, orElse: "nil")")

        if self.isMember(member.peer) {
            switch self.mark(member.peer, as: member.status) {
            case .applied(let previousStatus, let currentStatus):
                var member = member
                member.status = currentStatus
                if currentStatus.isSuspect, previousStatus?.isAlive ?? false {
                    return .applied(
                        change: .init(fromStatus: previousStatus, member: member),
                        level: .debug,
                        message: "Member [\(member.peer.node, orElse: "<unknown-node>")] marked as suspect, via incoming gossip"
                    )
                } else {
                    return .applied(change: .init(fromStatus: previousStatus, member: member))
                }

            case .ignoredDueToOlderStatus(let currentStatus):
                return .ignored(
                    level: .trace,
                    message: "Gossip about member \(reflecting: member.node), incoming: [\(member.status)] does not supersede current: [\(currentStatus)]"
                )
            }
        } else {
            self.addMember(member.peer, status: member.status) // we assume the best

            // ask the shell to eagerly prep a connection with it
            return .connect(node: member.node)
        }
    }

    public enum GossipProcessedDirective {
        case applied(change: SWIM.MemberStatusChange?, level: Logger.Level?, message: Logger.Message?)
        /// Ignoring a gossip update is perfectly fine: it may be "too old" or other reasons
        case ignored(level: Logger.Level?, message: Logger.Message?) // TODO: allow the instance to log
        /// Warning! Even though we have an `ClusterMembership.Node` here, we need to ensure that we are actually connected to the node,
        /// hosting this swim peer.
        ///
        /// It can happen that a gossip payload informs us about a node that we have not heard about before,
        /// and do not have a connection to it either (e.g. we joined only seed nodes, and more nodes joined them later
        /// we could get information through the seed nodes about the new members; but we still have never talked to them,
        /// thus we need to ensure we have a connection to them, before we consider adding them to the membership).
        case connect(node: ClusterMembership.Node) // FIXME: should be able to remove this

        static func applied(change: SWIM.MemberStatusChange?) -> SWIM.Instance.GossipProcessedDirective {
            .applied(change: change, level: nil, message: nil)
        }

        static var ignored: SWIM.Instance.GossipProcessedDirective {
            .ignored(level: nil, message: nil)
        }
    }
}

extension SWIM.Instance: CustomDebugStringConvertible {
    public var debugDescription: String {
        // multi-line on purpose
        """
        SWIMInstance(
            settings: \(settings),
            
            myself: \(String(reflecting: myself)),
                                
            _incarnation: \(_incarnation),
            _protocolPeriod: \(_protocolPeriod), 

            members: [
                \(members.map { "\($0.key)" }.joined(separator: "\n        "))
            ] 
            membersToPing: [ 
                \(membersToPing.map { "\($0)" }.joined(separator: "\n        "))
            ]
             
            _messagesToGossip: \(_messagesToGossip)
        )
        """
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: MemberStatus Change

extension SWIM {
    public struct MemberStatusChange {
        public let member: SWIM.Member
        public var toStatus: SWIM.Status {
            // Note if the member is marked .dead, SWIM shall continue to gossip about it for a while
            // such that other nodes gain this information directly, and do not have to wait until they detect
            // it as such independently.
            self.member.status
        }

        /// Previous status of the member, needed in order to decide if the change is "effective" or if applying the
        /// member did not move it in such way that we need to inform the cluster about unreachability.
        public let fromStatus: SWIM.Status?

        public init(fromStatus: SWIM.Status?, member: SWIM.Member) {
            if let from = fromStatus, from == .dead {
                precondition(member.status == .dead, "Change MUST NOT move status 'backwards' from [.dead] state to anything else, but did so, was: \(member)")
            }

            self.fromStatus = fromStatus
            self.member = member
        }

        /// Reachability changes are important events, in which a reachable node became unreachable, or vice-versa,
        /// as opposed to events which only move a member between `.alive` and `.suspect` status,
        /// during which the member should still be considered and no actions assuming it's death shall be performed (yet).
        ///
        /// If true, a system may want to issue a reachability change event and handle this situation by confirming the node `.dead`,
        /// and proceeding with its removal from the cluster.
        public var isReachabilityChange: Bool {
            guard let fromStatus = self.fromStatus else {
                // i.e. nil -> anything, is always an effective reachability affecting change
                return true
            }

            // explicitly list all changes which are affecting reachability, all others do not (i.e. flipping between
            // alive and suspect does NOT affect high-level reachability).
            switch (fromStatus, self.toStatus) {
            case (.alive, .unreachable),
                 (.alive, .dead):
                return true
            case (.suspect, .unreachable),
                 (.suspect, .dead):
                return true
            case (.unreachable, .alive),
                 (.unreachable, .suspect):
                return true
            case (.dead, .alive),
                 (.dead, .suspect),
                 (.dead, .unreachable):
                fatalError("Change MUST NOT move status 'backwards' from .dead state to anything else, but did so, was: \(self)")
            default:
                return false
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Lifeguard Local Health Modifier event

extension SWIM.Instance {
    public enum LHModifierEvent {
        case successfulProbe
        case failedProbe
        case refutingSuspectMessageAboutSelf
        case probeWithMissedNack
    }
}
