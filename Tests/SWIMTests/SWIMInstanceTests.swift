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

@testable import ClusterMembership
@testable import SWIM
import Testing
import Foundation

final class SWIMInstanceTests {
    let myselfNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7001, uid: 1111)
    let secondNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7002, uid: 2222)
    let thirdNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7003, uid: 3333)
    let fourthNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7004, uid: 4444)
    let fifthNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7005, uid: 5555)

    var myself: TestPeer!
    var second: TestPeer!
    var third: TestPeer!
    var fourth: TestPeer!
    var fifth: TestPeer!

    init() {
        self.myself = TestPeer(node: self.myselfNode)
        self.second = TestPeer(node: self.secondNode)
        self.third = TestPeer(node: self.thirdNode)
        self.fourth = TestPeer(node: self.fourthNode)
        self.fifth = TestPeer(node: self.fifthNode)
    }

    deinit {
        self.myself = nil
        self.second = nil
        self.third = nil
        self.fourth = nil
        self.fifth = nil
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Detecting myself
    @Test
    func test_notMyself_shouldDetectRemoteVersionOfSelf() {
        let swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        #expect(!swim.notMyself(self.myself))
    }

    @Test
    func test_notMyself_shouldDetectRandomNotMyselfActor() {
        let someone = self.second!

        let swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        #expect(swim.notMyself(someone))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Marking members as various statuses
    @Test
    func test_mark_shouldNotApplyEqualStatus() throws {
        let otherPeer = self.second!
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        _ = swim.addMember(otherPeer, status: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]))
        swim.incrementProtocolPeriod()

        try self.validateMark(swim: &swim, peer: otherPeer, status: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]), shouldSucceed: false)

        #expect(swim.member(for: otherPeer)!.protocolPeriod == 0)
    }

    @Test
    func test_mark_shouldApplyNewerStatus() throws {
        let otherPeer = self.second!
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        _ = swim.addMember(otherPeer, status: .alive(incarnation: 0))

        for i: SWIM.Incarnation in 0 ... 5 {
            swim.incrementProtocolPeriod()
            try self.validateMark(swim: &swim, peer: otherPeer, status: .suspect(incarnation: SWIM.Incarnation(i), suspectedBy: [self.thirdNode]), shouldSucceed: true)
            try self.validateMark(swim: &swim, peer: otherPeer, status: .alive(incarnation: SWIM.Incarnation(i + 1)), shouldSucceed: true)
        }

        #expect(swim.member(for: otherPeer)!.protocolPeriod == 6)
    }

    @Test
    func test_mark_shouldNotApplyOlderStatus_suspect() throws {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        // ==== Suspect member -----------------------------------------------------------------------------------------
        let suspectMember = self.second!
        _ = swim.addMember(suspectMember, status: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]))
        swim.incrementProtocolPeriod()

        try self.validateMark(swim: &swim, peer: suspectMember, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), shouldSucceed: false)
        try self.validateMark(swim: &swim, peer: suspectMember, status: .alive(incarnation: 1), shouldSucceed: false)

        #expect(swim.member(for: suspectMember)!.protocolPeriod == 0)
    }

    @Test
    func test_mark_shouldNotApplyOlderStatus_unreachable() throws {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        let unreachableMember = TestPeer(node: self.secondNode)
        _ = swim.addMember(unreachableMember, status: .unreachable(incarnation: 1))
        swim.incrementProtocolPeriod()

        try self.validateMark(swim: &swim, peer: unreachableMember, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), shouldSucceed: false)
        try self.validateMark(swim: &swim, peer: unreachableMember, status: .alive(incarnation: 1), shouldSucceed: false)

        #expect(swim.member(for: unreachableMember)!.protocolPeriod == 0)
    }

    @Test
    func test_mark_shouldApplyDead() throws {
        let otherPeer = self.second!

        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        _ = swim.addMember(otherPeer, status: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]))
        swim.incrementProtocolPeriod()

        try self.validateMark(swim: &swim, peer: otherPeer, status: .dead, shouldSucceed: true)

        #expect(swim.isMember(otherPeer) == false)
    }

    @Test
    func test_mark_shouldNotApplyAnyStatusIfAlreadyDead() throws {
        let otherPeer = self.second!

        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        _ = swim.addMember(otherPeer, status: .dead)
        swim.incrementProtocolPeriod()

        try self.validateMark(swim: &swim, peer: otherPeer, status: .alive(incarnation: 99), shouldSucceed: false)
        try self.validateMark(swim: &swim, peer: otherPeer, status: .suspect(incarnation: 99, suspectedBy: [self.thirdNode]), shouldSucceed: false)
        try self.validateMark(swim: &swim, peer: otherPeer, status: .dead, shouldSucceed: false)

        #expect(swim.member(for: otherPeer)!.protocolPeriod == 0)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: handling ping-req responses
    @Test
    func test_onPingRequestResponse_allowsSuspectNodeToRefuteSuspicion() {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        let secondPeer = self.second!
        let thirdPeer = self.third!

        // thirdPeer is suspect already...
        _ = swim.addMember(secondPeer, status: .alive(incarnation: 0))
        _ = swim.addMember(thirdPeer, status: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]))

        // Imagine: we asked secondPeer to ping thirdPeer
        // thirdPeer pings secondPeer, gets an ack back -- and there secondPeer had to bump its incarnation number // TODO test for that, using Swim.instance?

        // and now we get an `ack` back, secondPeer claims that thirdPeer is indeed alive!
        _ = swim.onPingRequestResponse(.ack(target: thirdPeer, incarnation: 2, payload: .none, sequenceNumber: 1), pinged: thirdPeer)
        // may print the result for debugging purposes if one wanted to

        // thirdPeer should be alive; after all, secondPeer told us so!
        #expect(swim.member(for: thirdPeer)!.isAlive)
    }

    @Test
    func test_onPingRequestResponse_ignoresTooOldRefutations() {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        let secondPeer = self.second!
        let thirdPeer = self.third!

        // thirdPeer is suspect already...
        _ = swim.addMember(secondPeer, status: .alive(incarnation: 0))
        _ = swim.addMember(thirdPeer, status: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]))

        // Imagine: we asked secondPeer to ping thirdPeer
        // thirdPeer pings secondPeer, yet secondPeer somehow didn't bump its incarnation... so we should NOT accept its refutation

        // and now we get an `ack` back, secondPeer claims that thirdPeer is indeed alive!
        _ = swim.onPingRequestResponse(.ack(target: thirdPeer, incarnation: 1, payload: .none, sequenceNumber: 1), pinged: thirdPeer)
        // may print the result for debugging purposes if one wanted to

        // thirdPeer should be alive; after all, secondPeer told us so!
        #expect(swim.member(for: thirdPeer)!.isSuspect)
    }

    @Test
    func test_onPingRequestResponse_storeIndividualSuspicions() throws {
        var settings: SWIM.Settings = .init()
        settings.lifeguard.maxIndependentSuspicions = 10
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)

        _ = swim.addMember(self.second, status: .suspect(incarnation: 1, suspectedBy: [self.secondNode]))

        _ = swim.onPingRequestResponse(.timeout(target: self.second, pingRequestOrigin: nil, timeout: .milliseconds(800), sequenceNumber: 1), pinged: self.second)
        let resultStatus = swim.member(for: self.second)!.status
        if case .suspect(_, let confirmations) = resultStatus {
            #expect(confirmations == [secondNode, myselfNode])
        } else {
            Issue.record("Expected `.suspected(_, Set(0,1))`, got \(resultStatus)")
            return
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: receive a ping and reply to it
    @Test
    func test_onPing_shouldOfferAckMessageWithMyselfReference() throws {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        _ = swim.addMember(self.second, status: .alive(incarnation: 0))

        let directive = swim.onPing(pingOrigin: self.second, payload: .none, sequenceNumber: 0).first!
        switch directive {
        case .sendAck(_, let pinged, _, _, _):
            #expect(pinged.node == self.myselfNode) // which was added as myself to this swim instance
        case let other:
            Issue.record("Expected .sendAck, but got \(other)")
        }
    }

    @Test
    func test_onPing_withAlive_shouldReplyWithAlive_withIncrementedIncarnation() throws {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        // from our perspective, all nodes are alive...
        _ = swim.addMember(self.second, status: .alive(incarnation: 0))

        // Imagine: thirdPeer pings us, it suspects us (!)
        // we (p1) receive the ping and want to refute the suspicion, we are Still Alive:
        // (thirdPeer has heard from someone that we are suspect in incarnation 10 (for some silly reason))
        let res = swim.onPing(pingOrigin: self.third, payload: .none, sequenceNumber: 0).first!

        switch res {
        case .sendAck(_, _, let incarnation, _, _):
            // did not have to increment its incarnation number:
            #expect(incarnation == 0)
        case let reply:
            Issue.record("Expected .sendAck ping response, but got \(reply)")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Detecting when a change is "effective"
    @Test
    func test_MarkedDirective_isEffectiveChange() {
        let p = self.myself!

        #expect(
            SWIM.MemberStatusChangedEvent(previousStatus: nil, member: SWIM.Member(peer: p, status: .alive(incarnation: 1), protocolPeriod: 1))
                .isReachabilityChange)
        #expect(
            SWIM.MemberStatusChangedEvent(previousStatus: nil, member: SWIM.Member(peer: p, status: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]), protocolPeriod: 1))
                .isReachabilityChange)
        #expect(
            SWIM.MemberStatusChangedEvent(previousStatus: nil, member: SWIM.Member(peer: p, status: .unreachable(incarnation: 1), protocolPeriod: 1))
                .isReachabilityChange)
        #expect(
            SWIM.MemberStatusChangedEvent(previousStatus: nil, member: SWIM.Member(peer: p, status: .dead, protocolPeriod: 1))
                .isReachabilityChange)

        #expect(!SWIM.MemberStatusChangedEvent(previousStatus: .alive(incarnation: 1), member: SWIM.Member(peer: p, status: .alive(incarnation: 2), protocolPeriod: 1))
                .isReachabilityChange)
        #expect(!SWIM.MemberStatusChangedEvent(previousStatus: .alive(incarnation: 1), member: SWIM.Member(peer: p, status: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]), protocolPeriod: 1))
                .isReachabilityChange)
        #expect(
            SWIM.MemberStatusChangedEvent(previousStatus: .alive(incarnation: 1), member: SWIM.Member(peer: p, status: .unreachable(incarnation: 1), protocolPeriod: 1))
                .isReachabilityChange)
        #expect(
            SWIM.MemberStatusChangedEvent(previousStatus: .alive(incarnation: 1), member: SWIM.Member(peer: p, status: .dead, protocolPeriod: 1))
                .isReachabilityChange)

        #expect(!SWIM.MemberStatusChangedEvent(previousStatus: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]), member: SWIM.Member(peer: p, status: .alive(incarnation: 2), protocolPeriod: 1))
                .isReachabilityChange)
        #expect(!SWIM.MemberStatusChangedEvent(previousStatus: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]), member: SWIM.Member(peer: p, status: .suspect(incarnation: 2, suspectedBy: [self.thirdNode]), protocolPeriod: 1))
                .isReachabilityChange)
        #expect(
            SWIM.MemberStatusChangedEvent(previousStatus: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]), member: SWIM.Member(peer: p, status: .unreachable(incarnation: 2), protocolPeriod: 1))
                .isReachabilityChange)
        #expect(
            SWIM.MemberStatusChangedEvent(previousStatus: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]), member: SWIM.Member(peer: p, status: .dead, protocolPeriod: 1))
                .isReachabilityChange)

        #expect(
            SWIM.MemberStatusChangedEvent(previousStatus: .unreachable(incarnation: 1), member: SWIM.Member(peer: p, status: .alive(incarnation: 2), protocolPeriod: 1))
                .isReachabilityChange)
        #expect(
            SWIM.MemberStatusChangedEvent(previousStatus: .unreachable(incarnation: 1), member: SWIM.Member(peer: p, status: .suspect(incarnation: 2, suspectedBy: [self.thirdNode]), protocolPeriod: 1))
                .isReachabilityChange)
        #expect(!SWIM.MemberStatusChangedEvent(previousStatus: .unreachable(incarnation: 1), member: SWIM.Member(peer: p, status: .unreachable(incarnation: 2), protocolPeriod: 1))
                .isReachabilityChange)
        #expect(!SWIM.MemberStatusChangedEvent(previousStatus: .unreachable(incarnation: 1), member: SWIM.Member(peer: p, status: .dead, protocolPeriod: 1))
                .isReachabilityChange)

        // those are illegal, but even IF they happened at least we'd never bubble them up to high level
        // moving from .dead to any other state is illegal and should assert // TODO: sanity check
        #expect(!SWIM.MemberStatusChangedEvent(previousStatus: .dead, member: SWIM.Member(peer: p, status: .dead, protocolPeriod: 1))
                .isReachabilityChange)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: handling gossip about the receiving node
    @Test
    func test_onGossipPayload_myself_withAlive() throws {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)
        let currentIncarnation = swim.incarnation

        let myselfMember = swim.member

        let directives = swim.onGossipPayload(about: myselfMember)

        #expect(swim.incarnation == currentIncarnation)

        switch directives.first {
        case .applied:
            () // ok
        default:
            Issue.record("Expected `.applied()`, \(optional: directives)")
        }
    }

    @Test
    func test_onGossipPayload_myself_withSuspectAndSameIncarnation_shouldIncrementIncarnation() throws {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)
        let currentIncarnation = swim.incarnation

        var myselfMember = swim.member
        myselfMember.status = .suspect(incarnation: currentIncarnation, suspectedBy: [self.thirdNode])

        let directives = swim.onGossipPayload(about: myselfMember)

        #expect(swim.incarnation == currentIncarnation + 1)

        switch directives.first {
        case .applied:
            ()
        default:
            Issue.record("Expected `.applied(warning: nil)`, \(optional: directives)")
        }
    }

    @Test
    func test_onGossipPayload_myself_withSuspectAndLowerIncarnation_shouldNotIncrementIncarnation() throws {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)
        var currentIncarnation = swim.incarnation

        var myselfMember = swim.member

        // necessary to increment incarnation
        myselfMember.status = .suspect(incarnation: currentIncarnation, suspectedBy: [self.thirdNode])
        _ = swim.onGossipPayload(about: myselfMember)

        currentIncarnation = swim.incarnation

        myselfMember.status = .suspect(incarnation: currentIncarnation - 1, suspectedBy: [self.thirdNode]) // purposefully "previous"
        let directives = swim.onGossipPayload(about: myselfMember)

        #expect(swim.incarnation == currentIncarnation)

        switch directives.first {
        case .applied(nil):
            ()
        default:
            Issue.record("Expected [ignored(level: nil, message: nil)], got \(directives)")
        }
    }

    @Test
    func test_onGossipPayload_myself_withSuspectAndHigherIncarnation_shouldNotIncrementIncarnation() throws {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)
        let currentIncarnation = swim.incarnation

        var myselfMember = swim.member

        myselfMember.status = .suspect(incarnation: currentIncarnation + 6, suspectedBy: [self.thirdNode])
        let directives = swim.onGossipPayload(about: myselfMember)

        #expect(swim.incarnation == currentIncarnation)

        switch directives.first {
        case .applied(nil):
            ()
        default:
            Issue.record("Expected `.none(message)`, got \(directives)")
        }
    }

    @Test
    func test_onGossipPayload_other_withDead() throws {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)
        let other = self.second!

        _ = swim.addMember(other, status: .alive(incarnation: 0))

        var otherMember = swim.member(for: other)!
        otherMember.status = .dead
        let directives = swim.onGossipPayload(about: otherMember)

        switch directives.first {
        case .applied(.some(let change)) where change.status.isDead:
            #expect(change.member == otherMember)
        default:
            Issue.record("Expected `.applied(.some(change to dead))`, got \(directives)")
        }
    }

    @Test
    func test_onGossipPayload_myself_withUnreachable_unreachabilityEnabled() throws {
        var settings = SWIM.Settings()
        settings.unreachability = .enabled
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)

        var myselfMember = swim.member
        myselfMember.status = .unreachable(incarnation: 1)
        let directives = swim.onGossipPayload(about: myselfMember)

        let myMember = swim.member
        // we never accept other telling us about "our future" this is highly suspect!
        // only we can be the origin of incarnation numbers after all.
        #expect(myMember.status == .alive(incarnation: 0))

        switch directives.first {
        case .applied(nil):
            ()
        default:
            Issue.record("Expected `.applied(_)`, got: \(String(reflecting: directives))")
        }
    }

    @Test
    func test_onGossipPayload_other_withUnreachable_unreachabilityEnabled() throws {
        var settings = SWIM.Settings()
        settings.unreachability = .enabled
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)
        let other = self.second!

        _ = swim.addMember(other, status: .alive(incarnation: 0))

        var otherMember = swim.member(for: other)!
        otherMember.status = .unreachable(incarnation: 1)
        let directives = swim.onGossipPayload(about: otherMember)

        switch directives.first {
        case .applied(.some(let change)) where change.status.isUnreachable:
            #expect(change.member == otherMember)
        default:
            Issue.record("Expected `.applied(.some(change to unreachable))`, got: \(String(reflecting: directives))")
        }
    }

    @Test
    func test_onGossipPayload_myself_withOldUnreachable_unreachabilityEnabled() throws {
        var settings = SWIM.Settings()
        settings.unreachability = .enabled
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)
        swim.incrementProtocolPeriod() // @1

        var myselfMember = swim.member
        myselfMember.status = .unreachable(incarnation: 0)
        let directives = swim.onGossipPayload(about: myselfMember)

        #expect(swim.member.status == .alive(incarnation: 1)) // equal to the incremented @1

        switch directives.first {
        case .applied(nil):
            () // good
        default:
            Issue.record("Expected `.ignored`, since the unreachable information is too old to matter anymore, got: \(optional: directives)")
        }
    }

    @Test
    func test_onGossipPayload_other_withOldUnreachable_unreachabilityEnabled() throws {
        var settings = SWIM.Settings()
        settings.unreachability = .enabled
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)
        let other = self.second!

        _ = swim.addMember(other, status: .alive(incarnation: 10))

        var otherMember = swim.member(for: other)!
        otherMember.status = .unreachable(incarnation: 1) // too old, we're already alive in 10
        let directives = swim.onGossipPayload(about: otherMember)

        if directives.isEmpty {
            () // good
        } else {
            Issue.record("Expected `[]]`, since the unreachable information is too old to matter anymore, got: \(optional: directives)")
        }
    }

    @Test
    func test_onGossipPayload_myself_withUnreachable_unreachabilityDisabled() throws {
        var settings = SWIM.Settings()
        settings.unreachability = .disabled
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)

        var myselfMember = swim.member
        myselfMember.status = .unreachable(incarnation: 1)

        let directives = swim.onGossipPayload(about: myselfMember)

        // we never accept other peers causing us to become some other status,
        // we always view ourselves as reachable (alive) until dead.
        let myMember = swim.member
        #expect(myMember.status == .alive(incarnation: 0))

        switch directives.first {
        case .applied(nil):
            () // ok, unreachability was disabled after all, so we completely ignore it
        default:
            Issue.record("Expected `.applied(_, .warning, ...)`, got: \(directives)")
        }
    }

    @Test
    func test_onGossipPayload_other_withUnreachable_unreachabilityDisabled() throws {
        var settings = SWIM.Settings()
        settings.unreachability = .disabled
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)
        let other = self.second!

        _ = swim.addMember(other, status: .alive(incarnation: 0))

        var otherMember = swim.member(for: other)!
        otherMember.status = .unreachable(incarnation: 1)
        // we receive an unreachability event, but we do not use this state, it should be automatically promoted to dead,
        // other nodes may use unreachability e.g. when we're rolling out a reconfiguration, but they can't force
        // us to keep those statuses of members, thus we always promote it to dead.
        let directives = swim.onGossipPayload(about: otherMember)

        switch directives.first {
        case .applied(.some(let change)) where change.status.isDead:
            otherMember.status = .dead // with unreachability disabled, we automatically promoted it to .dead
            #expect(change.member == otherMember)
        default:
            Issue.record("Expected `.applied(.some(change to dead))`, got: \(directives)")
        }
    }

    @Test
    func test_onGossipPayload_other_withNewSuspicion_shouldStoreIndividualSuspicions() throws {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)
        let other = self.second!

        _ = swim.addMember(other, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]))
        var otherMember = swim.member(for: other)!
        otherMember.status = .suspect(incarnation: 0, suspectedBy: [self.secondNode])
        let directives = swim.onGossipPayload(about: otherMember)
        if case .applied(.some(let change)) = directives.first,
            case .suspect(_, let confirmations) = change.status {
            #expect(confirmations.count == 2)
            #expect(confirmations.contains(secondNode), "expected \(confirmations) to contain \(secondNode)")
            #expect(confirmations.contains(thirdNode), "expected \(confirmations) to contain \(thirdNode)")
        } else {
            Issue.record("Expected `.applied(.some(suspect with multiple suspectedBy))`, got \(directives)")
        }
    }

    @Test
    func test_onGossipPayload_other_shouldNotApplyGossip_whenHaveEnoughSuspectedBy() throws {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)
        let other = self.second!

        let saturatedSuspectedByList = (1 ... swim.settings.lifeguard.maxIndependentSuspicions).map {
            Node(protocol: "test", host: "test", port: 12345, uid: UInt64($0))
        }

        _ = swim.addMember(other, status: .suspect(incarnation: 0, suspectedBy: Set(saturatedSuspectedByList)))

        var otherMember = swim.member(for: other)!
        otherMember.status = .suspect(incarnation: 0, suspectedBy: [self.thirdNode])
        let directives = swim.onGossipPayload(about: otherMember)
        guard case [] = directives else {
            Issue.record("Expected `[]]`, got \(String(reflecting: directives))")
            return
        }
    }

    @Test
    func test_onGossipPayload_other_shouldNotExceedMaximumSuspectedBy() throws {
        var settings: SWIM.Settings = .init()
        settings.lifeguard.maxIndependentSuspicions = 3

        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)
        let other = self.second!

        _ = swim.addMember(other, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode, self.secondNode]))

        var otherMember = swim.member(for: other)!
        otherMember.status = .suspect(incarnation: 0, suspectedBy: [self.thirdNode, self.fourthNode])
        let directives = swim.onGossipPayload(about: otherMember)
        if case .applied(.some(let change)) = directives.first,
            case .suspect(_, let confirmation) = change.status {
            #expect(confirmation.count == swim.settings.lifeguard.maxIndependentSuspicions)
        } else {
            Issue.record("Expected `.applied(.some(suspectedBy)) where suspectedBy.count = maxIndependentSuspicions`, got \(directives)")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: increment-ing counters
    @Test
    func test_incrementProtocolPeriod_shouldIncrementTheProtocolPeriodNumberByOne() {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        for i in 0 ..< 10 {
            #expect(swim.protocolPeriod == UInt64(i))
            swim.incrementProtocolPeriod()
        }
    }

    @Test
    func test_members_shouldContainAllAddedMembers() {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        let secondPeer = self.second!
        let thirdPeer = self.third!

        _ = swim.addMember(self.myself, status: .alive(incarnation: 0))
        _ = swim.addMember(secondPeer, status: .alive(incarnation: 0))
        _ = swim.addMember(thirdPeer, status: .alive(incarnation: 0))

        #expect(swim.isMember(self.myself))
        #expect(swim.isMember(secondPeer))
        #expect(swim.isMember(thirdPeer))

        #expect(swim.allMemberCount == 3)
        #expect(swim.notDeadMemberCount == 3)
        #expect(swim.otherMemberCount == 2)
    }

    @Test
    func test_isMember_shouldAllowCheckingWhenNotKnowingSpecificUID() {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        _ = swim.addMember(self.myself, status: .alive(incarnation: 0))
        _ = swim.addMember(self.second, status: .alive(incarnation: 0))

        #expect(swim.isMember(self.myself))
        #expect(swim.isMember(self.myself, ignoreUID: true))

        #expect(swim.isMember(TestPeer(node: self.secondNode.withoutUID), ignoreUID: true))
        #expect(!swim.isMember(TestPeer(node: self.secondNode.withoutUID)))

        #expect(!swim.isMember(TestPeer(node: self.thirdNode.withoutUID), ignoreUID: true))
        #expect(!swim.isMember(TestPeer(node: self.thirdNode.withoutUID)))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Modifying LHA-probe multiplier
    @Test
    func test_onPingRequestResponse_incrementLHAMultiplier_whenMissedNack() {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        let secondPeer = self.second!

        _ = swim.addMember(secondPeer, status: .alive(incarnation: 0))

        #expect(swim.localHealthMultiplier == 0)
        _ = swim.onEveryPingRequestResponse(.timeout(target: secondPeer, pingRequestOrigin: nil, timeout: .milliseconds(300), sequenceNumber: 1), pinged: secondPeer)
        #expect(swim.localHealthMultiplier == 1)
    }

    @Test
    func test_onPingRequestResponse_handlesNacksCorrectly() {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        _ = swim.addMember(self.second, status: .alive(incarnation: 0))
        _ = swim.addMember(self.third, status: .alive(incarnation: 0))
        _ = swim.addMember(self.fourth, status: .suspect(incarnation: 0, suspectedBy: [self.third.node]))

        #expect(swim.localHealthMultiplier == 0)
        // pretend first sends:
        //   - second.pingRequest(fourth)
        //   - third.pingRequest(fourth)

        // expect 2 nacks:

        // get nack from second 1/2
        _ = swim.onPingRequestResponse(
            .timeout(target: self.fourth, pingRequestOrigin: nil, timeout: .nanoseconds(1), sequenceNumber: 2),
            pinged: self.fourth
        )
        #expect(swim.localHealthMultiplier == 0)
        // get nack from third 2/2
        _ = swim.onPingRequestResponse(
            .timeout(target: self.fourth, pingRequestOrigin: nil, timeout: .nanoseconds(1), sequenceNumber: 3),
            pinged: self.fourth
        )
        #expect(swim.localHealthMultiplier == 0)
    }

    @Test
    func test_onPingRequestResponse_handlesMissingNacksCorrectly() {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        _ = swim.addMember(self.second, status: .alive(incarnation: 0))
        _ = swim.addMember(self.third, status: .alive(incarnation: 0))
        _ = swim.addMember(self.fourth, status: .suspect(incarnation: 0, suspectedBy: [self.third.node]))

        #expect(swim.localHealthMultiplier == 0)
        // pretend first sends:
        //   - second.pingRequest(fourth)
        //   - third.pingRequest(fourth)

        // timeout, no nack from third
        _ = swim.onEveryPingRequestResponse(
            .timeout(target: self.fourth, pingRequestOrigin: nil, timeout: .nanoseconds(1), sequenceNumber: 2),
            pinged: self.fourth
        )
        #expect(swim.localHealthMultiplier == 1)
        // timeout, no nack from third
        _ = swim.onEveryPingRequestResponse(
            .timeout(target: self.fourth, pingRequestOrigin: nil, timeout: .nanoseconds(1), sequenceNumber: 2),
            pinged: self.fourth
        )
        #expect(swim.localHealthMultiplier == 2)

        // all probes failed, thus the "main" one as well:
        _ = swim.onPingRequestResponse(
            .timeout(target: self.fourth, pingRequestOrigin: nil, timeout: .nanoseconds(1), sequenceNumber: 2),
            pinged: self.fourth
        )
        // this was already accounted for in the onEveryPingRequestResponse
        #expect(swim.localHealthMultiplier == 2)
    }

    // TODO: handle ack after nack scenarios; this needs modifications in SWIMNIO to handle these as well
    @Test
    func test_onPingRequestResponse_decrementLHAMultiplier_whenGotAck() {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        let secondPeer = self.second!

        _ = swim.addMember(secondPeer, status: .alive(incarnation: 0))
        swim.localHealthMultiplier = 1
        _ = swim.onPingAckResponse(
            target: secondPeer,
            incarnation: 0,
            payload: .none,
            pingRequestOrigin: nil,
            pingRequestSequenceNumber: nil,
            sequenceNumber: 0
        )
        #expect(swim.localHealthMultiplier == 0)
    }

    @Test
    func test_onPingAckResponse_forwardAckToOriginWithRightSequenceNumber_onAckFromTarget() {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        _ = swim.addMember(self.second, status: .alive(incarnation: 12))
        _ = swim.addMember(self.third, status: .alive(incarnation: 33))

        // let's pretend `third` asked us to ping `second`, and we get the ack back:
        let pingRequestOrigin = self.third!
        let pingRequestSequenceNumber: UInt32 = 1212

        let directives = swim.onPingAckResponse(
            target: self.second,
            incarnation: 12,
            payload: .none,
            pingRequestOrigin: pingRequestOrigin,
            pingRequestSequenceNumber: pingRequestSequenceNumber,
            sequenceNumber: 2 // the sequence number that we used to send the `ping` with
        )
        let contains = directives.contains {
            switch $0 {
            case .sendAck(let peer, let acknowledging, let target, let incarnation, _):
                #expect(peer.node == pingRequestOrigin.node)
                #expect(acknowledging == pingRequestSequenceNumber)
                #expect(self.second.node == target.node)
                #expect(incarnation == 12)
                return true
            default:
                return false
            }
        }
        #expect(contains, "directives should contain .sendAck")
    }

    @Test
    func test_onPingAckResponse_sendNackWithRightSequenceNumberToOrigin_onTimeout() {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        _ = swim.addMember(self.second, status: .alive(incarnation: 12))
        _ = swim.addMember(self.third, status: .alive(incarnation: 33))

        // let's pretend `third` asked us to ping `second`
        let pingRequestOrigin = self.third!
        let pingRequestSequenceNumber: UInt32 = 1212

        // and we get a timeout (so we should send a nack to the origin)
        let directives = swim.onPingResponseTimeout(
            target: self.second,
            timeout: .seconds(1),
            pingRequestOrigin: pingRequestOrigin,
            pingRequestSequenceNumber: pingRequestSequenceNumber
        )

        let contains = directives.contains {
            switch $0 {
            case .sendNack(let peer, let acknowledging, let target):
                #expect(peer.node == pingRequestOrigin.node)
                #expect(acknowledging == pingRequestSequenceNumber)
                #expect(self.second.node == target.node)
                return true
            default:
                return false
            }
        }
        #expect(contains, "directives should contain .sendAck")
    }

    @Test
    func test_onPingRequestResponse_notIncrementLHAMultiplier_whenSeeOldSuspicion_onGossip() {
        let p1 = self.myself!
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)
        // first suspicion is for current incarnation, should increase LHA counter
        _ = swim.onGossipPayload(about: SWIM.Member(peer: p1, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0))
        #expect(swim.localHealthMultiplier == 1)
        // second suspicion is for a stale incarnation, should ignore
        _ = swim.onGossipPayload(about: SWIM.Member(peer: p1, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0))
        #expect(swim.localHealthMultiplier == 1)
    }

    @Test
    func test_onPingRequestResponse_incrementLHAMultiplier_whenRefuteSuspicion_onGossip() {
        let p1 = self.myself!
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        _ = swim.onGossipPayload(about: SWIM.Member(peer: p1, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0))
        #expect(swim.localHealthMultiplier == 1)
    }

    @Test
    func test_onPingRequestResponse_dontChangeLHAMultiplier_whenGotNack() {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        let secondPeer = self.second!

        _ = swim.addMember(secondPeer, status: .alive(incarnation: 0))
        swim.localHealthMultiplier = 1

        _ = swim.onEveryPingRequestResponse(.nack(target: secondPeer, sequenceNumber: 1), pinged: secondPeer)
        #expect(swim.localHealthMultiplier == 1)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Selecting members to ping
    @Test
    func test_nextMemberToPing_shouldReturnEachMemberOnceBeforeRepeatingAndKeepOrder() throws {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        let memberCount = 10
        var members: Set<TestPeer> = []
        for i in 1 ... memberCount {
            var node = self.myselfNode
            node.port = 8000 + i
            let peer = TestPeer(node: node)
            members.insert(peer)
            _ = swim.addMember(peer, status: .alive(incarnation: 0))
        }

        var seenNodes: [Node] = []
        for _ in 1 ... memberCount {
            guard let member = swim.nextPeerToPing() else {
                Issue.record("Could not fetch member to ping")
                return
            }

            seenNodes.append(member.node)
            members = members.filter {
                $0.node != member.node
            }
        }

        #expect(members.isEmpty, "all members should have been selected at least once")

        // should loop around and we should encounter all the same members now
        for _ in 1 ... memberCount {
            guard let member = swim.nextPeerToPing() else {
                Issue.record("Could not fetch member to ping")
                return
            }

            #expect(seenNodes.removeFirst() == member.node)
        }
    }

    @Test
    func test_addMember_shouldAddAMemberWithTheSpecifiedStatusAndCurrentProtocolPeriod() {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)
        let status: SWIM.Status = .alive(incarnation: 1)

        swim.incrementProtocolPeriod()
        swim.incrementProtocolPeriod()
        swim.incrementProtocolPeriod()

        #expect(!swim.isMember(self.second))
        _ = swim.addMember(self.second, status: status)

        #expect(swim.isMember(self.second))
        let member = swim.member(for: self.second)!
        #expect(member.protocolPeriod == swim.protocolPeriod)
        #expect(member.status == status)
    }

    @Test
    func test_addMember_shouldNotAddLocalNodeForPinging() {
        let otherPeer = self.second!
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: .init(), myself: otherPeer)

        #expect(swim.isMember(otherPeer))
        #expect(swim.nextPeerToPing() == nil)
    }

    @Test
    func test_addMember_shouldNotAddPeerWithoutUID() {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: .init(), myself: self.myself)

        let other = TestPeer(node: .init(protocol: "test", host: "127.0.0.1", port: 111, uid: nil))
        let directives = swim.addMember(other, status: .alive(incarnation: 0))
        #expect(directives.count == 0)
        #expect(!swim.isMember(other))
        #expect(swim.nextPeerToPing() == nil)
    }

    @Test
    func test_addMember_shouldReplaceMemberIfDifferentUID() {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: .init(), myself: self.myself)
        _ = swim.addMember(self.second, status: .alive(incarnation: 0))
        #expect(swim.isMember(self.second))

        let restartedSecond = TestPeer(node: self.secondNode)
        restartedSecond.swimNode.uid = self.second.node.uid! * 2

        let directives = swim.addMember(restartedSecond, status: .alive(incarnation: 0))

        switch directives.first {
        case .previousHostPortMemberConfirmedDead(let event):
            #expect(event.previousStatus == SWIM.Status.alive(incarnation: 0))
            #expect(event.member.peer == self.second)
        default:
            Issue.record("Expected replacement directive, was: \(optional: directives.first), in: \(directives)")
        }
        switch directives.dropFirst().first {
        case .added(let addedMember):
            #expect(addedMember.node == restartedSecond.node)
            #expect(addedMember.status == SWIM.Status.alive(incarnation: 0))
        default:
            Issue.record("Expected .added as directive, was: \(optional: directives.dropFirst().first), in: \(directives)")
        }

        #expect(swim.isMember(restartedSecond))
        #expect(!swim.isMember(self.second))

        #expect(swim.isMember(self.myself))
    }

    @Test
    func test_nextMemberToPingRequest() {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        let ds1 = swim.addMember(self.second, status: .alive(incarnation: 0))
        #expect(ds1.count == 1)
        guard case .added(let firstMember) = ds1.first else {
            Issue.record("Expected to successfully add peer, was: \(ds1)")
            return
        }
        let ds2 = swim.addMember(self.third!, status: .alive(incarnation: 0))
        #expect(ds2.count == 1)
        guard case .added(let secondMember) = ds2.first else {
            Issue.record("Expected to successfully add peer, was: \(ds2)")
            return
        }
        let ds3 = swim.addMember(self.fourth!, status: .alive(incarnation: 0))
        #expect(ds3.count == 1)
        guard case .added(let thirdMember) = ds3.first else {
            Issue.record("Expected to successfully add peer, was: \(ds3)")
            return
        }

        let membersToPing = swim.membersToPingRequest(target: self.fifth!)
        #expect(membersToPing.count == 3)

        #expect(membersToPing.contains(firstMember))
        #expect(membersToPing.contains(secondMember))
        #expect(membersToPing.contains(thirdMember))
    }

    @Test
    func test_member_shouldReturnTheLastAssignedStatus() {
        let otherPeer = self.second!

        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        _ = swim.addMember(otherPeer, status: .alive(incarnation: 0))
        #expect(swim.member(for: otherPeer)!.status == .alive(incarnation: 0))

        _ = swim.mark(otherPeer, as: .suspect(incarnation: 99, suspectedBy: [self.thirdNode]))
        #expect(swim.member(for: otherPeer)!.status == .suspect(incarnation: 99, suspectedBy: [self.thirdNode]))
    }

    @Test
    func test_member_shouldWorkForMyself() {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: .init(), myself: self.myself)

        _ = swim.addMember(self.second, status: .alive(incarnation: 10))

        let member = swim.member
        #expect(member.node == self.myself.node)
        #expect(member.isAlive)
        #expect(member.status == .alive(incarnation: 0))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: (Round up the usual...) Suspects
    @Test
    func test_suspects_shouldContainOnlySuspectedNodes() {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        let aliveAtZero = SWIM.Status.alive(incarnation: 0)
        _ = swim.addMember(self.second, status: aliveAtZero)
        _ = swim.addMember(self.third, status: aliveAtZero)
        _ = swim.addMember(self.fourth, status: aliveAtZero)
        #expect(swim.notDeadMemberCount == 4) // three new nodes + myself

        self.validateSuspects(swim, expected: [])

        let directive: SWIM.Instance.MarkedDirective = swim.mark(self.second, as: .suspect(incarnation: 0, suspectedBy: [self.third.node]))
        switch directive {
        case .applied(let previousStatus, let member):
            #expect(previousStatus == aliveAtZero)
            #expect(member.status == .suspect(incarnation: 0, suspectedBy: [self.third.node]))
        default:
            Issue.record("Expected .applied, got: \(directive)")
        }
        self.validateSuspects(swim, expected: [self.second.node])

        _ = swim.mark(self.third, as: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]))
        self.validateSuspects(swim, expected: [self.second.node, self.third.node])

        _ = swim.mark(self.second, as: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]))
        _ = swim.mark(self.myself, as: .alive(incarnation: 1))
        self.validateSuspects(swim, expected: [self.second.node, self.third.node])
    }

    @Test
    func test_suspects_shouldMark_whenBiggerSuspicionList() {
        var settings: SWIM.Settings = .init()
        settings.lifeguard.maxIndependentSuspicions = 10

        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)

        let aliveAtZero = SWIM.Status.alive(incarnation: 0)
        _ = swim.addMember(self.second, status: aliveAtZero)
        #expect(swim.notDeadMemberCount == 2)

        self.validateSuspects(swim, expected: [])
        let oldStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: [self.thirdNode])
        let d1 = swim.mark(self.second, as: oldStatus)
        switch d1 {
        case .applied(let previousStatus, let member):
            #expect(previousStatus == aliveAtZero)
            #expect(member.status == oldStatus)
        default:
            Issue.record("Expected .applied, but got: \(d1)")
            return
        }
        self.validateSuspects(swim, expected: [self.second.node])
        let newStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: [self.thirdNode, self.secondNode])
        let d2 = swim.mark(self.second, as: newStatus)
        switch d2 {
        case .applied(let previousStatus, let member):
            #expect(previousStatus == oldStatus)
            #expect(member.status == newStatus)
        default:
            Issue.record("Expected .applied, but got: \(d1)")
            return
        }
        self.validateSuspects(swim, expected: [self.second.node])
    }

    @Test
    func test_suspects_shouldNotMark_whenSmallerSuspicionList() {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        let aliveAtZero = SWIM.Status.alive(incarnation: 0)
        _ = swim.addMember(self.second, status: aliveAtZero)
        #expect(swim.notDeadMemberCount == 2)

        self.validateSuspects(swim, expected: [])
        let oldStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: [self.thirdNode, self.secondNode])

        let d1 = swim.mark(self.second, as: oldStatus)
        switch d1 {
        case .applied(let previousStatus, let member):
            #expect(previousStatus == aliveAtZero)
            #expect(member.status == oldStatus)
        default:
            Issue.record("Expected .applied, but got: \(d1)")
            return
        }
        self.validateSuspects(swim, expected: [self.second.node])
        let newStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: [self.thirdNode])

        #expect(swim.mark(self.second, as: newStatus) == .ignoredDueToOlderStatus(currentStatus: oldStatus))
        let d2 = swim.mark(self.second, as: newStatus)
        switch d2 {
        case .ignoredDueToOlderStatus(currentStatus: oldStatus):
            () // ok
        default:
            Issue.record("Expected .ignoredDueToOlderStatus, but got: \(d2)")
            return
        }
        self.validateSuspects(swim, expected: [self.second.node])
    }

    @Test
    func test_memberCount_shouldNotCountDeadMembers() {
        let settings = SWIM.Settings()
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)

        let aliveAtZero = SWIM.Status.alive(incarnation: 0)
        _ = swim.addMember(self.second, status: aliveAtZero)
        _ = swim.addMember(self.third, status: aliveAtZero)
        _ = swim.addMember(self.fourth, status: aliveAtZero)
        #expect(swim.notDeadMemberCount == 4)

        _ = swim.mark(self.second, as: .dead)
        #expect(swim.notDeadMemberCount == 3)

        _ = swim.mark(self.fourth, as: .dead)
        #expect(swim.notDeadMemberCount == 2) // dead is not part of membership
    }

    @Test
    func test_memberCount_shouldCountUnreachableMembers() {
        var settings = SWIM.Settings()
        settings.unreachability = .enabled
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)

        let aliveAtZero = SWIM.Status.alive(incarnation: 0)
        _ = swim.addMember(self.second, status: aliveAtZero)
        _ = swim.addMember(self.third, status: aliveAtZero)
        _ = swim.addMember(self.fourth, status: aliveAtZero)
        #expect(swim.notDeadMemberCount == 4)

        _ = swim.mark(self.second, as: .dead)
        #expect(swim.notDeadMemberCount == 3)

        _ = swim.mark(self.third, as: .unreachable(incarnation: 19))
        #expect(swim.notDeadMemberCount == 3) // unreachable is still "part of the membership" as far as we are concerned

        _ = swim.mark(self.fourth, as: .dead)
        #expect(swim.notDeadMemberCount == 2) // dead is not part of membership
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: makeGossipPayload
    @Test
    func test_makeGossipPayload_shouldGossipAboutSelf_whenNoMembers() throws {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)

        try self.validateGossip(swim: &swim, expected: [.init(peer: self.myself, status: .alive(incarnation: 0), protocolPeriod: 0)])
    }

    @Test
    func test_makeGossipPayload_shouldEventuallyStopGossips() throws {
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: SWIM.Settings(), myself: self.myself)
        _ = swim.addMember(self.second, status: .alive(incarnation: 0))
        _ = swim.addMember(self.third, status: .alive(incarnation: 0))

        var count = 0
        var gossip = swim.makeGossipPayload(to: nil)
        while gossip.members.count > 1 {
            gossip = swim.makeGossipPayload(to: nil)
            count += 1
        }

        #expect(count == 7) // based on the default values of the
    }

    @Test
    func test_makeGossipPayload_shouldReset_whenNewMemberChangedStatus() throws {
        let settings: SWIM.Settings = .init()
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)

        _ = swim.addMember(self.second, status: .alive(incarnation: 0))
        _ = swim.addMember(self.third, status: .alive(incarnation: 0))
        let myselfMember = SWIM.Member(peer: self.myself, status: .alive(incarnation: 0), protocolPeriod: 0)
        let thirdMember = SWIM.Member(peer: self.third, status: .alive(incarnation: 0), protocolPeriod: 0)

        try self.validateGossip(swim: &swim, expected: [.init(peer: self.second, status: .alive(incarnation: 0), protocolPeriod: 0), myselfMember, thirdMember])

        _ = swim.mark(self.second, as: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]))
        try self.validateGossip(swim: &swim, expected: [
            .init(peer: self.second, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0),
            myselfMember,
            thirdMember,
        ])
        try self.validateGossip(swim: &swim, expected: [
            .init(peer: self.second, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0),
            myselfMember,
            thirdMember,
        ])

        // turns out it is alive after all, and it bumped its incarnation (it had to, to refute the suspicion)
        _ = swim.mark(self.second, as: .alive(incarnation: 1))

        try self.validateGossip(swim: &swim, expected: [
            .init(peer: self.second, status: .alive(incarnation: 1), protocolPeriod: 0),
            .init(peer: self.third, status: .alive(incarnation: 0), protocolPeriod: 0),
            myselfMember,
        ])
    }

    @Test
    func test_makeGossipPayload_shouldReset_whenNewMembersJoin() throws {
        let settings: SWIM.Settings = .init()
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)

        _ = swim.addMember(self.second, status: .alive(incarnation: 0))
        let myselfMember = SWIM.Member(peer: self.myself, status: .alive(incarnation: 0), protocolPeriod: 0)

        try self.validateGossip(swim: &swim, expected: [.init(peer: self.second, status: .alive(incarnation: 0), protocolPeriod: 0), myselfMember])

        _ = swim.mark(self.second, as: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]))
        try self.validateGossip(swim: &swim, expected: [.init(peer: self.second, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0), myselfMember])
        try self.validateGossip(swim: &swim, expected: [.init(peer: self.second, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0), myselfMember])
        try self.validateGossip(swim: &swim, expected: [.init(peer: self.second, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0), myselfMember])
        try self.validateGossip(swim: &swim, expected: [.init(peer: self.second, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0), myselfMember])

        // a new member joins, and we must ensure it'd get some of the gossip
        _ = swim.addMember(self.third, status: .alive(incarnation: 0))

        try self.validateGossip(swim: &swim, expected: [
            .init(peer: self.second, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0),
            .init(peer: self.third, status: .alive(incarnation: 0), protocolPeriod: 0),
            myselfMember,
        ])
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Confirming dead
    @Test
    func test_confirmDead_anUnknownNode_shouldDoNothing() throws {
        var settings = SWIM.Settings()
        settings.unreachability = .enabled
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)

        let directive = swim.confirmDead(peer: self.second)
        switch directive {
        case .ignored:
            () // ok
        default:
            Issue.record("Expected marking an unknown node to be ignored, got: \(directive)")
        }
    }

    @Test
    func test_confirmDead_aKnownOtherNode_shouldApply() throws {
        var settings = SWIM.Settings()
        settings.unreachability = .enabled
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)

        _ = swim.addMember(self.second, status: .alive(incarnation: 10))

        let directive = swim.confirmDead(peer: self.second)
        switch directive {
        case .applied(let change):
            let previousStatus = change.previousStatus
            let member = change.member
            #expect(previousStatus == SWIM.Status.alive(incarnation: 10))
            #expect("\(reflecting: member.peer)" == "\(reflecting: self.second!)")
        default:
            Issue.record("Expected confirmingDead a node to be `.applied`, got: \(directive)")
        }
    }

    @Test
    func test_confirmDead_myself_shouldApply() throws {
        var settings = SWIM.Settings()
        settings.unreachability = .enabled
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)

        _ = swim.addMember(self.second, status: .alive(incarnation: 10))

        let directive = swim.confirmDead(peer: self.myself)
        switch directive {
        case .applied(let change):
            let previousStatus = change.previousStatus
            let member = change.member
            #expect(previousStatus == SWIM.Status.alive(incarnation: 0))
            #expect("\(reflecting: member.peer)" == "\(reflecting: self.myself!)")
        default:
            Issue.record("Expected confirmingDead a node to be `.applied`, got: \(directive)")
        }
    }

    @Test
    func test_confirmDead_shouldRemovePeerFromMembersToPing() throws {
        var settings = SWIM.Settings()
        settings.unreachability = .enabled
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)

        _ = swim.addMember(self.second, status: .alive(incarnation: 10))
        _ = swim.addMember(self.third, status: .alive(incarnation: 10))

        let secondMember = swim.member(forNode: self.secondNode)!

        _ = swim.confirmDead(peer: self.second)
        #expect(!swim.membersToPing.contains(secondMember))

        #expect(swim.nextPeerToPing()?.node != self.second.node)
        #expect(swim.nextPeerToPing()?.node != self.second.node)
        #expect(swim.nextPeerToPing()?.node != self.second.node)
        #expect(swim.nextPeerToPing()?.node != self.second.node)
        #expect(swim.nextPeerToPing()?.node != self.second.node)
    }

    @Test
    func test_confirmDead_shouldStoreATombstone_disallowAddingAgain() throws {
        var settings = SWIM.Settings()
        settings.unreachability = .enabled
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)

        _ = swim.addMember(self.second, status: .alive(incarnation: 10))
        _ = swim.addMember(self.third, status: .alive(incarnation: 10))

        let secondMember = swim.member(forNode: self.secondNode)!

        _ = swim.confirmDead(peer: self.second)
        #expect(!swim.members.contains(secondMember))
        #expect(!swim.membersToPing.contains(secondMember))

        // "you are already dead"
        let directives = swim.addMember(self.second, status: .alive(incarnation: 100))

        // no mercy for zombies; don't add it again
        #expect(directives.count == 1)
        switch directives.first {
        case .memberAlreadyKnownDead(let dead):
            #expect(dead.status == SWIM.Status.dead)
            #expect(dead.node == self.secondNode)
        default:
            Issue.record("")
        }
        #expect(!swim.members.contains(secondMember))
        #expect(!swim.membersToPing.contains(secondMember))
    }

    @Test
    func test_confirmDead_tombstone_shouldExpireAfterConfiguredAmountOfTicks() throws {
        var settings = SWIM.Settings()
        settings.tombstoneCleanupIntervalInTicks = 3
        settings.tombstoneTimeToLiveInTicks = 2
        var swim = SWIM.Instance<TestPeer, TestPeer, TestPeer>(settings: settings, myself: self.myself)

        _ = swim.addMember(self.second, status: .alive(incarnation: 10))
        _ = swim.addMember(self.third, status: .alive(incarnation: 10))

        let secondMember = swim.member(forNode: self.secondNode)!

        _ = swim.confirmDead(peer: self.second)
        #expect(!swim.membersToPing.contains(secondMember))

        #expect(
            swim.removedDeadMemberTombstones
                .contains(.init(uid: self.secondNode.uid!, deadlineProtocolPeriod: 0 /* not part of equality*/ ))
        )

        _ = swim.onPeriodicPingTick()
        _ = swim.onPeriodicPingTick()

        #expect(
            swim.removedDeadMemberTombstones
                .contains(.init(uid: self.secondNode.uid!, deadlineProtocolPeriod: 0 /* not part of equality*/ ))
        )

        _ = swim.onPeriodicPingTick()
        _ = swim.onPeriodicPingTick()

        #expect(!swim.removedDeadMemberTombstones
                .contains(.init(uid: self.secondNode.uid!, deadlineProtocolPeriod: 0 /* not part of equality*/ ))
        )

        // past the deadline and tombstone expiration, we'd be able to smuggle in that node again...!
        _ = swim.addMember(self.second, status: .alive(incarnation: 135_342))
        let member = swim.member(for: self.second)
        #expect(member?.node == self.secondNode)
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Sanity checks
    @Test
    /// This test is weird and should "never" fail, but it did, on some toolchains.
    /// This test is to remain here as a sanity check if timeouts or something else would suddenly return unexpected values.
    func test_log_becauseWeSawItReturnWronglyOnSomeToolchains() {
        #expect(log2(4.0) == 2)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: utility functions
    func validateMark(
        swim: inout SWIM.Instance<TestPeer, TestPeer, TestPeer>, member: SWIM.Member<TestPeer>, status: SWIM.Status, shouldSucceed: Bool,
        file: StaticString = (#file), line: UInt = #line
    ) throws {
        try self.validateMark(swim: &swim, peer: member.peer, status: status, shouldSucceed: shouldSucceed, file: file, line: line)
    }

    func validateMark(
        swim: inout SWIM.Instance<TestPeer, TestPeer, TestPeer>, peer: TestPeer, status: SWIM.Status, shouldSucceed: Bool,
        file: StaticString = (#file), line: UInt = #line
    ) throws {
        let markResult = swim.mark(peer, as: status)

        if shouldSucceed {
            guard case .applied = markResult else {
                Issue.record("Expected `.applied`, got `\(markResult)`")
//                , file: file, line: line)
                return
            }
        } else {
            guard case .ignoredDueToOlderStatus = markResult else {
                Issue.record("Expected `.ignoredDueToOlderStatus`, got `\(markResult)`")
//                , file: file, line: line)
                return
            }
        }
    }

    func validateSuspects(
        _ swim: SWIM.Instance<TestPeer, TestPeer, TestPeer>, expected: Set<Node>,
        file: StaticString = (#file), line: UInt = #line
    ) {
        #expect(Set(swim.suspects.map {$0.node}) == expected)
//                file: file, line: line)
    }

    func validateGossip(swim: inout SWIM.Instance<TestPeer, TestPeer, TestPeer>, expected: Set<SWIM.Member<TestPeer>>, file: StaticString = (#file), line: UInt = #line) throws {
        let payload = swim.makeGossipPayload(to: nil)
        #expect(Set(payload.members) == expected)
//                , file: file, line: line)
    }
}
