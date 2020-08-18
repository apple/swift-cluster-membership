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
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin
#else
import Glibc
#endif
import Logging

public protocol SWIMProtocol {
    /// Must be invoked periodically, in intervals of `self.swim.dynamicLHMProtocolInterval`.
    ///
    // TODO: more docs
    ///
    /// - Returns:
    mutating func onPeriodicPingTick() -> SWIM.Instance.PeriodicPingTickDirective

    /// Must be invoked whenever a `Ping` message is received.
    ///
    /// A specific shell implementation must the returned directives by acting on them.
    /// The order of interpreting the events should be as returned by the onPing invocation.
    ///
    // TODO: more docs
    ///
    /// - Parameter payload:
    /// - Returns:
    mutating func onPing(payload: SWIM.GossipPayload, sequenceNumber: SWIM.SequenceNumber) -> [SWIM.Instance.PingDirective]

    /// Must be invoked when a `pingRequest` is received.
    ///
    // TODO: more docs
    ///
    /// - Parameters:
    ///   - target:
    ///   - replyTo:
    ///   - payload:
    /// - Returns:
    mutating func onPingRequest(target: SWIMPeer, replyTo: SWIMPeer, payload: SWIM.GossipPayload) -> [SWIM.Instance.PingRequestDirective]

    /// Must be invoked when a ping response, timeout, or error for a specific ping is received.
    ///
    // TODO: more docs
    ///
    /// - Parameters:
    ///   - response:
    ///   - pingRequestOrigin:
    /// - Returns:
    mutating func onPingResponse(response: SWIM.PingResponse, pingRequestOrigin: PingOriginSWIMPeer?) -> [SWIM.Instance.PingResponseDirective]

    /// Must be invoked whenever a successful response to a `pingRequest` happens or all of `pingRequest`'s fail.
    ///
    // TODO: more docs
    ///
    /// - Parameters:
    ///   - response:
    ///   - member:
    /// - Returns:
    mutating func onPingRequestResponse(_ response: SWIM.PingResponse, pingedMember member: AddressableSWIMPeer) -> SWIM.Instance.PingRequestResponseDirective

    /// Must be invoked whenever a response to a `pingRequest` (an ack, nack or lack response i.e. a timeout) happens.
    ///
    // TODO: more docs
    ///
    /// - Parameters:
    ///   - response:
    ///   - member:
    /// - Returns:
    mutating func onEveryPingRequestResponse(_ response: SWIM.PingResponse, pingedMember member: AddressableSWIMPeer)
}

extension SWIM {
    /// # SWIM (Scalable Weakly-consistent Infection-style Process Group Membership Protocol)
    ///
    /// > As you swim lazily through the milieu,
    /// > The secrets of the world will infect you.
    ///
    /// Implementation of the SWIM protocol in abstract terms, see [SWIMShell] for the acting upon directives issued by this instance.
    ///
    /// ### Modifications
    /// - Random, stable order members to ping selection: Unlike the completely random selection in the original paper.
    ///
    /// See the reference documentation of this swim implementation in the reference documentation.
    ///
    /// ### Related Papers
    /// - SeeAlso: [SWIM: Scalable Weakly-consistent Infection-style Process Group Membership Protocol](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf)
    /// - SeeAlso: [Lifeguard: Local Health Awareness for More Accurate Failure Detection](https://arxiv.org/abs/1707.00788)
    public final class Instance: SWIMProtocol { // FIXME: make it a struct?
        public let settings: SWIM.Settings

        // We store the owning SWIMShell peer in order avoid adding it to the `membersToPing` list
        private let myself: SWIMPeer
        private var node: ClusterMembership.Node {
            self.myself.node
        }

        /// Cluster `Member` representing this instance.
        public var myselfMember: SWIM.Member {
            self.member(for: self.node)!
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

        public init(settings: SWIM.Settings, myself: SWIMPeer) {
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

        /// Adjust the Local Health-aware Multiplier based on the event causing it.
        ///
        /// - Parameter event: event which causes the LHM adjustment.
        public func adjustLHMultiplier(_ event: LHModifierEvent) {
            self.localHealthMultiplier =
                min(
                    max(0, self.localHealthMultiplier + event.lhmAdjustment),
                    self.settings.lifeguard.maxLocalHealthMultiplier
                )
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
        public func addMember(_ peer: AddressableSWIMPeer, status: SWIM.Status) -> AddMemberDirective {
            let maybeExistingMember = self.member(for: peer)

            if let existingMember = maybeExistingMember, existingMember.status.supersedes(status) {
                // we already have a newer state for this member
                return .newerMemberAlreadyPresent(existingMember)
            }

            // just in case we had a peer added manually, and thus we did not know its uuid, let us remove it
            _ = self.members.removeValue(forKey: self.node.withoutUID)

            let member = SWIM.Member(peer: peer, status: status, protocolPeriod: self.protocolPeriod)
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
        public func nextMemberToPing() -> AddressableSWIMPeer? {
            if self.membersToPing.isEmpty {
                return nil
            }

            defer {
                self.advanceMembersToPingIndex()
            }
            return self.membersToPing[self.membersToPingIndex].peer
        }

        /// Selects `settings.indirectProbeCount` members to send a `ping-req` to.
        func membersToPingRequest(target: AddressableSWIMPeer) -> ArraySlice<SWIM.Member> {
            func notTarget(_ peer: AddressableSWIMPeer) -> Bool {
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
        public func mark(_ peer: AddressableSWIMPeer, as status: SWIM.Status) -> MarkedDirective {
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

        internal func incrementProtocolPeriod() {
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

        public func makeGossipPayload(to target: AddressableSWIMPeer?) -> SWIM.GossipPayload {
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

    func notMyself(_ peer: AddressableSWIMPeer) -> Bool {
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

    func isMyself(_ peer: AddressableSWIMPeer) -> Bool {
        // we are exactly that node:
        self.node == peer.node ||
            // ...or, the incoming node has no UID; there was no handshake made,
            // and thus the other side does not know which specific node it is going to talk to; as such, "we" are that node
            // as such, "we" are that node; we should never add such peer to our members, but we will reply to that node with "us" and thus
            // inform it about our specific UID, and from then onwards it will know about specifically this node (by replacing its UID-less version with our UID-ful version).
            self.node.withoutUID == peer.node
    }

    // TODO: ensure we actually store "us" in members; do we need this special handling if then at all?
    public func status(of peer: AddressableSWIMPeer) -> SWIM.Status? {
        if self.notMyself(peer) {
            return self.members[peer.node]?.status
        } else {
            // we consider ourselves always as alive (enables refuting others suspecting us)
            return .alive(incarnation: self.incarnation)
        }
    }

    public func isMember(_ peer: AddressableSWIMPeer) -> Bool {
        // the peer could be either:
        // - "us" (i.e. the peer which hosts this SWIM instance, or
        // - a "known member"
        peer.node == self.node || self.members[peer.node] != nil
    }

    public func member(for peer: AddressableSWIMPeer) -> SWIM.Member? {
        self.member(for: peer.node)
    }

    public func member(for node: ClusterMembership.Node) -> SWIM.Member? {
        self.members[node]
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

    public func onPeriodicPingTick() -> PeriodicPingTickDirective {
        defer {
            self.incrementProtocolPeriod()
        }

        guard let toPing = self.nextMemberToPing() else {
            return .ignore
        }

        return .sendPing(target: toPing as! SWIMPeer, timeout: self.dynamicLHMPingTimeout, sequenceNumber: self.nextSequenceNumber())
    }

    public enum PeriodicPingTickDirective {
        case ignore
        case sendPing(target: SWIMPeer, timeout: SWIMTimeAmount, sequenceNumber: SWIM.SequenceNumber)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: On Ping Handler

    public func onPing(payload: SWIM.GossipPayload, sequenceNumber: SWIM.SequenceNumber) -> [PingDirective] {
        var directives: [PingDirective] = []

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
        let reply = PingDirective.reply(
            .ack(
                target: self.myself.node,
                incarnation: self._incarnation,
                payload: self.makeGossipPayload(to: nil),
                sequenceNumber: sequenceNumber
            )
        )
        directives.append(reply)

        return directives
    }

    public enum PingDirective {
        case gossipProcessed(GossipProcessedDirective)
        case reply(SWIM.PingResponse)
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: On Ping Response Handlers

    public func onPingResponse(response: SWIM.PingResponse, pingRequestOrigin: PingOriginSWIMPeer?) -> [PingResponseDirective] {
        switch response {
        case .ack(let target, let incarnation, let payload, let sequenceNumber):
            return self.onPingAckResponse(target: target, incarnation: incarnation, payload: payload, pingRequestOrigin: pingRequestOrigin, sequenceNumber: sequenceNumber)
        case .nack(let target, let sequenceNumber):
            return self.onPingNackResponse(target: target, pingRequestOrigin: pingRequestOrigin, sequenceNumber: sequenceNumber)
        case .timeout(let target, _, let timeout, let sequenceNumber):
            return self.onPingResponseTimeout(target: target, timeout: timeout, pingRequestOrigin: pingRequestOrigin, sequenceNumber: sequenceNumber)
        case .error:
            fatalError() // FIXME: what to do here
        }
    }

    func onPingAckResponse(
        target pingedNode: Node,
        incarnation: SWIM.Incarnation,
        payload: SWIM.GossipPayload,
        pingRequestOrigin: PingOriginSWIMPeer?,
        sequenceNumber: SWIM.SequenceNumber
    ) -> [PingResponseDirective] {
        var directives: [PingResponseDirective] = []
        // We're proxying an ack payload from ping target back to ping source.
        // If ping target was a suspect, there'll be a refutation in a payload
        // and we probably want to process it asap. And since the data is already here,
        // processing this payload will just make gossip convergence faster.
        let gossipDirectives = self.onGossipPayload(payload)
        directives.append(contentsOf: gossipDirectives.map {
            PingResponseDirective.gossipProcessed($0)
        })

        // self.log.debug("Received ack from [\(pingedNode)] with incarnation [\(incarnation)] and payload [\(payload)]", metadata: self.metadata)
        self.mark(pingedNode, as: .alive(incarnation: incarnation))
        // self.markMember(latest: SWIM.Member(peer: pingedNode, status: .alive(incarnation: incarnation), protocolPeriod: self.protocolPeriod)) // FIXME: adding should be done in the instance...

        if let pingRequestOrigin = pingRequestOrigin {
            // pingRequestOrigin.ack(acknowledging: sequenceNumber, target: pingedNode, incarnation: incarnation, payload: payload)
            directives.append(
                .sendAck(
                    peer: pingRequestOrigin,
                    acknowledging: sequenceNumber,
                    target: pingedNode,
                    incarnation: incarnation,
                    payload: payload
                )
            )
        } else {
            self.adjustLHMultiplier(.successfulProbe)
        }

        return directives
    }

    func onPingNackResponse(
        target pingedNode: Node,
        pingRequestOrigin: PingOriginSWIMPeer?,
        sequenceNumber: SWIM.SequenceNumber
    ) -> [PingResponseDirective] {
        let directives: [PingResponseDirective] = []
        () // TODO: nothing???
        return directives
    }

    func onPingResponseTimeout(
        target pingedNode: Node,
        timeout: SWIMTimeAmount,
        pingRequestOrigin: PingOriginSWIMPeer?,
        sequenceNumber pingResponseSequenceNumber: SWIM.SequenceNumber
    ) -> [PingResponseDirective] {
        assert(pingedNode != myself.node, "target pinged node MUST NOT equal myself, why would we ping our own node.")
        // self.log.debug("Did not receive ack from \(pingedNode) within configured timeout. Sending ping requests to other members.")

        var directives: [PingResponseDirective] = []
        if let pingRequestOrigin = pingRequestOrigin {
            // Meaning we were doing a ping on behalf of the pingReq origin, and we need to report back to it.
            directives.append(
                .sendNack(
                    peer: pingRequestOrigin,
                    acknowledging: pingResponseSequenceNumber,
                    target: pingedNode
                )
            )
        } else {
            // We sent a direct `.ping` and it timed out; we now suspect the target node and must issue additional ping requests.
            guard let pingedMember = self.member(for: pingedNode) else {
                return directives // seems we are not aware of this node, ignore it
            }
            guard let pingedMemberLastKnownIncarnation = pingedMember.status.incarnation else {
                return directives // so it is already dead, not need to suspect it
            }

            // The member should become suspect, it missed out ping/ack cycle:
            self.mark(pingedMember.peer, as: self.makeSuspicion(incarnation: pingedMemberLastKnownIncarnation))

            // adjust the LHM accordingly, we failed a probe (ping/ack) cycle
            self.adjustLHMultiplier(.failedProbe)

            // if we have other peers, we should ping request through them,
            // if not then there's no-one to ping request through and we just continue.
            if let pingRequestDirective = self.preparePingRequests(target: pingedNode) {
                directives.append(.sendPingRequests(pingRequestDirective))
            }
        }

        return directives
    }

    /// Prepare ping request directives such that the shell can easily fire those messages
    func preparePingRequests(target: Node) -> SendPingRequestDirective? {
        guard let lastKnownStatus = self.status(of: target) else {
            // context.log.info("Skipping ping requests after failed ping to [\(toPing)] because node has been removed from member list") // FIXME allow logging
            return nil
        }

        // select random members to send ping requests to
        let membersToPingRequest = self.membersToPingRequest(target: target)

        guard !membersToPingRequest.isEmpty else {
            // no nodes available to ping, so we have to assume the node suspect right away
            guard let lastKnownIncarnation = lastKnownStatus.incarnation else {
                // log.debug("Not marking .suspect, as [\(target)] is already dead.") // "You are already dead!" // TODO logging
                return nil
            }

            switch self.mark(target, as: self.makeSuspicion(incarnation: lastKnownIncarnation)) {
            case .applied(_, _):
                // log.debug("No members to ping-req through, marked [\(target)] immediately as [\(currentStatus)].") // TODO: logging
                return nil
            case .ignoredDueToOlderStatus(_):
                // log.debug("No members to ping-req through to [\(target)], was already [\(currentStatus)].") // TODO: logging
                return nil
            }
        }

        let details = membersToPingRequest.map { member in
            SendPingRequestDirective.PingRequestDetail(
                memberToPingRequestThrough: member,
                payload: self.makeGossipPayload(to: target),
                sequenceNumber: self.nextSequenceNumber()
            )
        }

        return SendPingRequestDirective(targetNode: target, requestDetails: details)

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

    public enum PingResponseDirective {
        case gossipProcessed(GossipProcessedDirective)

        /// Send an `ack` message to `peer`
        case sendAck(peer: PingOriginSWIMPeer, acknowledging: SWIM.SequenceNumber, target: Node, incarnation: UInt64, payload: SWIM.GossipPayload)

        /// Send a `nack` to `peer`
        case sendNack(peer: PingOriginSWIMPeer, acknowledging: SWIM.SequenceNumber, target: Node)

        /// Send a `pingRequest` as described by the `SendPingRequestDirective`.
        ///
        /// The target node did not reply with an successful `.ack` and as such was now marked as `.suspect`.
        /// By sending ping requests to other members of the cluster we attempt to revert this suspicion,
        /// perhaps some other node is able to receive an `.ack` from it after all?
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

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: On Ping Request

    public func onPingRequest(target: SWIMPeer, replyTo: SWIMPeer, payload: SWIM.GossipPayload) -> [PingRequestDirective] {
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
        // Indirect ping timeout should always be shorter than pingRequest timeout.
        // Setting it to a fraction of initial ping timeout as suggested in the original paper.
        // SeeAlso: [Lifeguard IV.A. Local Health Multiplier (LHM)](https://arxiv.org/pdf/1707.00788.pdf)
        let timeout: SWIMTimeAmount = self.settings.pingTimeout * self.settings.lifeguard.indirectPingTimeoutMultiplier
        directives.append(.sendPing(target: target, pingRequestOrigin: replyTo, timeout: timeout, sequenceNumber: pingSequenceNumber))

        return directives
    }

    public enum PingRequestDirective {
        case gossipProcessed(GossipProcessedDirective)
        case ignore
        case sendPing(target: SWIMPeer, pingRequestOrigin: SWIMPeer, timeout: SWIMTimeAmount, sequenceNumber: SWIM.SequenceNumber)
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: On Ping Request Response

    /// This should be called on first successful (non-nack) pingRequestResponse
    public func onPingRequestResponse(_ response: SWIM.PingResponse, pingedMember member: AddressableSWIMPeer) -> PingRequestResponseDirective {
        guard let previousStatus = self.status(of: member) else {
            return .unknownMember
        }

        switch response {
        case .ack(let target, let incarnation, let payload, _):
            guard target == member.node else {
                fatalError("The ack.from member [\(target)] MUST be equal to the pinged member \(member.node)]; The Ack message is being forwarded back to us from the pinged member.")
                // TODO: make assert
            }

            switch self.mark(member, as: .alive(incarnation: incarnation)) {
            case .applied:
                // TODO: we can be more interesting here, was it a move suspect -> alive or a reassurance?
                return .alive(previousStatus: previousStatus, payloadToProcess: payload)
            case .ignoredDueToOlderStatus(let currentStatus):
                return .ignoredDueToOlderStatus(currentStatus: currentStatus)
            }
        case .nack:
            // TODO: this should never happen. How do we express it?
            return .nackReceived

        case .timeout, .error:
            switch previousStatus {
            case .alive(let incarnation),
                 .suspect(let incarnation, _):
                switch self.mark(member, as: self.makeSuspicion(incarnation: incarnation)) {
                case .applied:
                    return .newlySuspect(previousStatus: previousStatus, suspect: self.member(for: member.node)!)
                case .ignoredDueToOlderStatus(let status):
                    return .ignoredDueToOlderStatus(currentStatus: status)
                }
            case .unreachable:
                return .alreadyUnreachable
            case .dead:
                return .alreadyDead
            }
        }
    }

    /// This callback is adjusting local health and should be executed for _every_ received response to a pingRequest
    public func onEveryPingRequestResponse(_ result: SWIM.PingResponse, pingedMember member: AddressableSWIMPeer) {
        switch result {
        case .error, .timeout:
            // Failed pingRequestResponse indicates a missed nack, we should adjust LHMultiplier
            self.adjustLHMultiplier(.probeWithMissedNack)
        default:
            // Successful pingRequestResponse should be handled only once
            ()
        }
    }

    public enum PingRequestResponseDirective {
        case alive(previousStatus: SWIM.Status, payloadToProcess: SWIM.GossipPayload)
        case nackReceived
        /// Indicates that the `target` of the ping response is not known to this peer anymore,
        /// it could be that we already marked it as dead and removed it.
        ///
        /// No additional action, except optionally some debug logging should be performed.
        case unknownMember
        case newlySuspect(previousStatus: SWIM.Status, suspect: SWIM.Member)
        case alreadySuspect
        case alreadyUnreachable
        case alreadyDead
        /// The incoming gossip is older than already known information about the target peer (by incarnation), and was (safely) ignored.
        /// The current status of the peer is as returned in `currentStatus`.
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
                return .applied(change: .init(previousStatus: previousStatus, member: myselfMember))
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
                        change: .init(previousStatus: previousStatus, member: member),
                        level: .debug,
                        message: "Member [\(member.peer.node, orElse: "<unknown-node>")] marked as suspect, via incoming gossip"
                    )
                } else {
                    return .applied(change: .init(previousStatus: previousStatus, member: member))
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
        case applied(change: SWIM.MemberStatusChangeEvent?, level: Logger.Level?, message: Logger.Message?)
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

        static func applied(change: SWIM.MemberStatusChangeEvent?) -> SWIM.Instance.GossipProcessedDirective {
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
// MARK: SWIM Lifeguard Local Health Modifier event

extension SWIM.Instance {
    /// Events which cause the modification of the Local health aware Multiplier to be adjusted.
    ///
    /// - SeeAlso: Lifeguard IV.A. Local Health Aware Probe, which describes the rationale behind the events.
    public enum LHModifierEvent: Equatable {
        case successfulProbe
        case failedProbe
        case refutingSuspectMessageAboutSelf
        case probeWithMissedNack

        /// Returns by how much the LHM should be adjusted in response to this event.
        /// The adjusted value MUST be clamped between `0 <= value <= maxLocalHealthMultiplier`
        var lhmAdjustment: Int {
            switch self {
            case .successfulProbe:
                return -1 // decrease the LHM
            case .failedProbe,
                 .refutingSuspectMessageAboutSelf,
                 .probeWithMissedNack:
                return 1 // increase the LHM
            }
        }
    }
}
