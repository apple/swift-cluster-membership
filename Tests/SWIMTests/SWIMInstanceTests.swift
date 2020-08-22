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
@testable import SWIM
import XCTest

final class SWIMInstanceTests: XCTestCase {
    let myselfNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7001, uid: 1111)
    let secondNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7002, uid: 2222)
    let thirdNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7003, uid: 3333)
    let fourthNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7004, uid: 4444)
    let fifthNode = ClusterMembership.Node(protocol: "test", host: "127.0.0.1", port: 7005, uid: 5555)

    var myself: SWIMPeer!
    var second: SWIMPeer!
    var third: SWIMPeer!
    var fourth: SWIMPeer!
    var fifth: SWIMPeer!

    override func setUp() {
        super.setUp()
        self.myself = TestPeer(node: self.myselfNode)
        self.second = TestPeer(node: self.secondNode)
        self.third = TestPeer(node: self.thirdNode)
        self.fourth = TestPeer(node: self.fourthNode)
        self.fifth = TestPeer(node: self.fifthNode)
    }

    override func tearDown() {
        super.tearDown()
        self.myself = nil
        self.second = nil
        self.third = nil
        self.fourth = nil
        self.fifth = nil
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Detecting myself

    func test_notMyself_shouldDetectRemoteVersionOfSelf() {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        XCTAssertFalse(swim.notMyself(self.myself))
    }

    func test_notMyself_shouldDetectRandomNotMyselfActor() {
        let someone = self.second!

        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        XCTAssertTrue(swim.notMyself(someone))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Marking members as various statuses

    func test_mark_shouldNotApplyEqualStatus() throws {
        let otherPeer = self.second!
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        swim.addMember(otherPeer, status: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]))
        swim.incrementProtocolPeriod()

        try self.validateMark(swim: swim, peer: otherPeer, status: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]), shouldSucceed: false)

        XCTAssertEqual(swim.member(for: otherPeer)!.protocolPeriod, 0)
    }

    func test_mark_shouldApplyNewerStatus() throws {
        let otherPeer = self.second!
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        swim.addMember(otherPeer, status: .alive(incarnation: 0))

        for i: SWIM.Incarnation in 0 ... 5 {
            swim.incrementProtocolPeriod()
            try self.validateMark(swim: swim, peer: otherPeer, status: .suspect(incarnation: SWIM.Incarnation(i), suspectedBy: [self.thirdNode]), shouldSucceed: true)
            try self.validateMark(swim: swim, peer: otherPeer, status: .alive(incarnation: SWIM.Incarnation(i + 1)), shouldSucceed: true)
        }

        XCTAssertEqual(swim.member(for: otherPeer)!.protocolPeriod, 6)
    }

    func test_mark_shouldNotApplyOlderStatus_suspect() throws {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        // ==== Suspect member -----------------------------------------------------------------------------------------
        let suspectMember = self.second!
        swim.addMember(suspectMember, status: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]))
        swim.incrementProtocolPeriod()

        try self.validateMark(swim: swim, peer: suspectMember, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), shouldSucceed: false)
        try self.validateMark(swim: swim, peer: suspectMember, status: .alive(incarnation: 1), shouldSucceed: false)

        XCTAssertEqual(swim.member(for: suspectMember)!.protocolPeriod, 0)
    }

    func test_mark_shouldNotApplyOlderStatus_unreachable() throws {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        let unreachableMember = TestPeer(node: self.secondNode)
        swim.addMember(unreachableMember, status: .unreachable(incarnation: 1))
        swim.incrementProtocolPeriod()

        try self.validateMark(swim: swim, peer: unreachableMember, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), shouldSucceed: false)
        try self.validateMark(swim: swim, peer: unreachableMember, status: .alive(incarnation: 1), shouldSucceed: false)

        XCTAssertEqual(swim.member(for: unreachableMember)!.protocolPeriod, 0)
    }

    func test_mark_shouldApplyDead() throws {
        let otherPeer = self.second!

        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        swim.addMember(otherPeer, status: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]))
        swim.incrementProtocolPeriod()

        try self.validateMark(swim: swim, peer: otherPeer, status: .dead, shouldSucceed: true)

        XCTAssertEqual(swim.member(for: otherPeer)!.protocolPeriod, 1)
    }

    func test_mark_shouldNotApplyAnyStatusIfAlreadyDead() throws {
        let otherPeer = self.second!

        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        swim.addMember(otherPeer, status: .dead)
        swim.incrementProtocolPeriod()

        try self.validateMark(swim: swim, peer: otherPeer, status: .alive(incarnation: 99), shouldSucceed: false)
        try self.validateMark(swim: swim, peer: otherPeer, status: .suspect(incarnation: 99, suspectedBy: [self.thirdNode]), shouldSucceed: false)
        try self.validateMark(swim: swim, peer: otherPeer, status: .dead, shouldSucceed: false)

        XCTAssertEqual(swim.member(for: otherPeer)!.protocolPeriod, 0)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: handling ping-req responses

    func test_onPingRequestResponse_allowsSuspectNodeToRefuteSuspicion() {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        let secondPeer = self.second!
        let thirdPeer = self.third!

        // thirdPeer is suspect already...
        swim.addMember(secondPeer, status: .alive(incarnation: 0))
        swim.addMember(thirdPeer, status: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]))

        // Imagine: we asked secondPeer to ping thirdPeer
        // thirdPeer pings secondPeer, gets an ack back -- and there secondPeer had to bump its incarnation number // TODO test for that, using Swim.instance?

        // and now we get an `ack` back, secondPeer claims that thirdPeer is indeed alive!
        _ = swim.onPingRequestResponse(.ack(target: thirdPeer, incarnation: 2, payload: .none, sequenceNumber: 1), pingedMember: thirdPeer)
        // may print the result for debugging purposes if one wanted to

        // thirdPeer should be alive; after all, secondPeer told us so!
        XCTAssertTrue(swim.member(for: thirdPeer)!.isAlive)
    }

    func test_onPingRequestResponse_ignoresTooOldRefutations() {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        let secondPeer = self.second!
        let thirdPeer = self.third!

        // thirdPeer is suspect already...
        swim.addMember(secondPeer, status: .alive(incarnation: 0))
        swim.addMember(thirdPeer, status: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]))

        // Imagine: we asked secondPeer to ping thirdPeer
        // thirdPeer pings secondPeer, yet secondPeer somehow didn't bump its incarnation... so we should NOT accept its refutation

        // and now we get an `ack` back, secondPeer claims that thirdPeer is indeed alive!
        _ = swim.onPingRequestResponse(.ack(target: thirdPeer, incarnation: 1, payload: .none, sequenceNumber: 1), pingedMember: thirdPeer)
        // may print the result for debugging purposes if one wanted to

        // thirdPeer should be alive; after all, secondPeer told us so!
        XCTAssertTrue(swim.member(for: thirdPeer)!.isSuspect)
    }

    func test_onPingRequestResponse_storeIndividualSuspicions() throws {
        var settings: SWIM.Settings = .init()
        settings.lifeguard.maxIndependentSuspicions = 10
        let swim = SWIM.Instance(settings: settings, myself: self.myself)

        swim.addMember(self.second, status: .suspect(incarnation: 1, suspectedBy: [self.secondNode]))

        _ = swim.onPingRequestResponse(.timeout(target: self.second, pingRequestOrigin: nil, timeout: .milliseconds(800), sequenceNumber: 1), pingedMember: self.second)
        let resultStatus = swim.member(for: self.second)!.status
        if case .suspect(_, let confirmations) = resultStatus {
            XCTAssertEqual(confirmations, [secondNode, myselfNode])
        } else {
            XCTFail("Expected `.suspected(_, Set(0,1))`, got \(resultStatus)")
            return
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: receive a ping and reply to it

    func test_onPing_shouldOfferAckMessageWithMyselfReference() throws {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        swim.addMember(self.second, status: .alive(incarnation: 0))

        let directive = swim.onPing(pingOrigin: self.second, payload: .none, sequenceNumber: 0).first!
        switch directive {
        case .sendAck(let pinged, _, _, _):
            XCTAssertEqual(pinged.node, self.myselfNode) // which was added as myself to this swim instance
        case let other:
            XCTFail("Expected .sendAck, but got \(other)")
        }
    }

    func test_onPing_withAlive_shouldReplyWithAlive_withIncrementedIncarnation() throws {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        // from our perspective, all nodes are alive...
        swim.addMember(self.second, status: .alive(incarnation: 0))

        // Imagine: thirdPeer pings us, it suspects us (!)
        // we (p1) receive the ping and want to refute the suspicion, we are Still Alive:
        // (thirdPeer has heard from someone that we are suspect in incarnation 10 (for some silly reason))
        let res = swim.onPing(pingOrigin: self.third, payload: .none, sequenceNumber: 0).first!

        switch res {
        case .sendAck(_, let incarnation, _, _):
            // did not have to increment its incarnation number:
            XCTAssertEqual(incarnation, 0)
        case let reply:
            XCTFail("Expected .sendAck ping response, but got \(reply)")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Detecting when a change is "effective"

    func test_MarkedDirective_isEffectiveChange() {
        let p = self.myself!

        XCTAssertTrue(
            SWIM.MemberStatusChangedEvent(previousStatus: nil, member: SWIM.Member(peer: p, status: .alive(incarnation: 1), protocolPeriod: 1))
                .isReachabilityChange)
        XCTAssertTrue(
            SWIM.MemberStatusChangedEvent(previousStatus: nil, member: SWIM.Member(peer: p, status: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]), protocolPeriod: 1))
                .isReachabilityChange)
        XCTAssertTrue(
            SWIM.MemberStatusChangedEvent(previousStatus: nil, member: SWIM.Member(peer: p, status: .unreachable(incarnation: 1), protocolPeriod: 1))
                .isReachabilityChange)
        XCTAssertTrue(
            SWIM.MemberStatusChangedEvent(previousStatus: nil, member: SWIM.Member(peer: p, status: .dead, protocolPeriod: 1))
                .isReachabilityChange)

        XCTAssertFalse(
            SWIM.MemberStatusChangedEvent(previousStatus: .alive(incarnation: 1), member: SWIM.Member(peer: p, status: .alive(incarnation: 2), protocolPeriod: 1))
                .isReachabilityChange)
        XCTAssertFalse(
            SWIM.MemberStatusChangedEvent(previousStatus: .alive(incarnation: 1), member: SWIM.Member(peer: p, status: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]), protocolPeriod: 1))
                .isReachabilityChange)
        XCTAssertTrue(
            SWIM.MemberStatusChangedEvent(previousStatus: .alive(incarnation: 1), member: SWIM.Member(peer: p, status: .unreachable(incarnation: 1), protocolPeriod: 1))
                .isReachabilityChange)
        XCTAssertTrue(
            SWIM.MemberStatusChangedEvent(previousStatus: .alive(incarnation: 1), member: SWIM.Member(peer: p, status: .dead, protocolPeriod: 1))
                .isReachabilityChange)

        XCTAssertFalse(
            SWIM.MemberStatusChangedEvent(previousStatus: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]), member: SWIM.Member(peer: p, status: .alive(incarnation: 2), protocolPeriod: 1))
                .isReachabilityChange)
        XCTAssertFalse(
            SWIM.MemberStatusChangedEvent(previousStatus: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]), member: SWIM.Member(peer: p, status: .suspect(incarnation: 2, suspectedBy: [self.thirdNode]), protocolPeriod: 1))
                .isReachabilityChange)
        XCTAssertTrue(
            SWIM.MemberStatusChangedEvent(previousStatus: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]), member: SWIM.Member(peer: p, status: .unreachable(incarnation: 2), protocolPeriod: 1))
                .isReachabilityChange)
        XCTAssertTrue(
            SWIM.MemberStatusChangedEvent(previousStatus: .suspect(incarnation: 1, suspectedBy: [self.thirdNode]), member: SWIM.Member(peer: p, status: .dead, protocolPeriod: 1))
                .isReachabilityChange)

        XCTAssertTrue(
            SWIM.MemberStatusChangedEvent(previousStatus: .unreachable(incarnation: 1), member: SWIM.Member(peer: p, status: .alive(incarnation: 2), protocolPeriod: 1))
                .isReachabilityChange)
        XCTAssertTrue(
            SWIM.MemberStatusChangedEvent(previousStatus: .unreachable(incarnation: 1), member: SWIM.Member(peer: p, status: .suspect(incarnation: 2, suspectedBy: [self.thirdNode]), protocolPeriod: 1))
                .isReachabilityChange)
        XCTAssertFalse(
            SWIM.MemberStatusChangedEvent(previousStatus: .unreachable(incarnation: 1), member: SWIM.Member(peer: p, status: .unreachable(incarnation: 2), protocolPeriod: 1))
                .isReachabilityChange)
        XCTAssertFalse(
            SWIM.MemberStatusChangedEvent(previousStatus: .unreachable(incarnation: 1), member: SWIM.Member(peer: p, status: .dead, protocolPeriod: 1))
                .isReachabilityChange)

        // those are illegal, but even IF they happened at least we'd never bubble them up to high level
        // moving from .dead to any other state is illegal and should assert // TODO: sanity check
        XCTAssertFalse(
            SWIM.MemberStatusChangedEvent(previousStatus: .dead, member: SWIM.Member(peer: p, status: .dead, protocolPeriod: 1))
                .isReachabilityChange)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: handling gossip about the receiving node

    func test_onGossipPayload_myself_withAlive() throws {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)
        let currentIncarnation = swim.incarnation

        let myselfMember = swim.myselfMember

        let res = swim.onGossipPayload(about: myselfMember)

        XCTAssertEqual(swim.incarnation, currentIncarnation)

        switch res {
        case .applied(_, _, let warning) where warning == nil:
            ()
        default:
            XCTFail("Expected `.applied(warning: nil)`, got \(res)")
        }
    }

    func test_onGossipPayload_myself_withSuspectAndSameIncarnation_shouldIncrementIncarnation() throws {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)
        let currentIncarnation = swim.incarnation

        var myselfMember = swim.myselfMember
        myselfMember.status = .suspect(incarnation: currentIncarnation, suspectedBy: [self.thirdNode])

        let res = swim.onGossipPayload(about: myselfMember)

        XCTAssertEqual(swim.incarnation, currentIncarnation + 1)

        switch res {
        case .applied(_, _, let warning) where warning == nil:
            ()
        default:
            XCTFail("Expected `.applied(warning: nil)`, got \(res)")
        }
    }

    func test_onGossipPayload_myself_withSuspectAndLowerIncarnation_shouldNotIncrementIncarnation() throws {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)
        var currentIncarnation = swim.incarnation

        var myselfMember = swim.myselfMember

        // necessary to increment incarnation
        myselfMember.status = .suspect(incarnation: currentIncarnation, suspectedBy: [self.thirdNode])
        _ = swim.onGossipPayload(about: myselfMember)

        currentIncarnation = swim.incarnation

        myselfMember.status = .suspect(incarnation: currentIncarnation - 1, suspectedBy: [self.thirdNode]) // purposefully "previous"
        let res = swim.onGossipPayload(about: myselfMember)

        XCTAssertEqual(swim.incarnation, currentIncarnation)

        switch res {
        case .ignored(nil, nil):
            ()
        default:
            XCTFail("Expected [ignored(level: nil, message: nil)], got [\(res)]")
        }
    }

    func test_onGossipPayload_myself_withSuspectAndHigherIncarnation_shouldNotIncrementIncarnation() throws {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)
        let currentIncarnation = swim.incarnation

        var myselfMember = swim.myselfMember

        myselfMember.status = .suspect(incarnation: currentIncarnation + 6, suspectedBy: [self.thirdNode])
        let res = swim.onGossipPayload(about: myselfMember)

        XCTAssertEqual(swim.incarnation, currentIncarnation)

        switch res {
        case .applied(nil, _, let warning) where warning != nil:
            ()
        default:
            XCTFail("Expected `.none(message)`, got \(res)")
        }
    }

    func test_onGossipPayload_myself_withDead() throws {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        var myselfMember = swim.myselfMember
        myselfMember.status = .dead
        let res = swim.onGossipPayload(about: myselfMember)

        let myMember = swim.myselfMember
        XCTAssertEqual(myMember.status, .dead)

        switch res {
        case .applied(.some(let change), _, _) where change.status.isDead:
            XCTAssertEqual(change.member, myselfMember)
        default:
            XCTFail("Expected `.applied(.some(change to dead)`, got: \(res)")
        }
    }

    func test_onGossipPayload_other_withDead() throws {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)
        let other = self.second!

        swim.addMember(other, status: .alive(incarnation: 0))

        var otherMember = swim.member(for: other)!
        otherMember.status = .dead
        let res = swim.onGossipPayload(about: otherMember)

        switch res {
        case .applied(.some(let change), _, _) where change.status.isDead:
            XCTAssertEqual(change.member, otherMember)
        default:
            XCTFail("Expected `.applied(.some(change to dead))`, got \(res)")
        }
    }

    func test_onGossipPayload_myself_withUnreachable_unreachabilityEnabled() throws {
        var settings = SWIM.Settings()
        settings.extensionUnreachability = .enabled
        let swim = SWIM.Instance(settings: settings, myself: self.myself)

        var myselfMember = swim.myselfMember
        myselfMember.status = .unreachable(incarnation: 1)
        let directive = swim.onGossipPayload(about: myselfMember)

        let myMember = swim.myselfMember
        // we never accept other telling us about "our future" this is highly suspect!
        // only we can be the origin of incarnation numbers after all.
        XCTAssertEqual(myMember.status, .alive(incarnation: 0))

        switch directive {
        case .applied(nil, let logLevel, _):
            // an incoming unreachable event with a future incarnation number
            // that we have not reached yet is highly suspect thus the warning about it
            XCTAssertEqual(logLevel, .warning)
        default:
            XCTFail("Expected `.applied(_, .warning, ...)`, got: \(directive)")
        }
    }

    func test_onGossipPayload_other_withUnreachable_unreachabilityEnabled() throws {
        var settings = SWIM.Settings()
        settings.extensionUnreachability = .enabled
        let swim = SWIM.Instance(settings: settings, myself: self.myself)
        let other = self.second!

        swim.addMember(other, status: .alive(incarnation: 0))

        var otherMember = swim.member(for: other)!
        otherMember.status = .unreachable(incarnation: 1)
        let directive = swim.onGossipPayload(about: otherMember)

        switch directive {
        case .applied(.some(let change), _, _) where change.status.isUnreachable:
            XCTAssertEqual(change.member, otherMember)
        default:
            XCTFail("Expected `.applied(.some(change to unreachable))`, got: \(directive)")
        }
    }

    func test_onGossipPayload_myself_withOldUnreachable_unreachabilityEnabled() throws {
        var settings = SWIM.Settings()
        settings.extensionUnreachability = .enabled
        let swim = SWIM.Instance(settings: settings, myself: self.myself)
        swim.incrementProtocolPeriod()

        var myselfMember = swim.myselfMember
        myselfMember.status = .unreachable(incarnation: 0)
        let directive = swim.onGossipPayload(about: myselfMember)

        let myMember = swim.myselfMember
        XCTAssertEqual(myMember.status, .alive(incarnation: 0))

        switch directive {
        case .ignored:
            () // good
        default:
            XCTFail("Expected `.ignored`, since the unreachable information is too old to matter anymore, got: \(directive)")
        }
    }

    func test_onGossipPayload_other_withOldUnreachable_unreachabilityEnabled() throws {
        var settings = SWIM.Settings()
        settings.extensionUnreachability = .enabled
        let swim = SWIM.Instance(settings: settings, myself: self.myself)
        let other = self.second!

        swim.addMember(other, status: .alive(incarnation: 10))

        var otherMember = swim.member(for: other)!
        otherMember.status = .unreachable(incarnation: 1) // too old, we're already alive in 10
        let directive = swim.onGossipPayload(about: otherMember)

        switch directive {
        case .ignored:
            () // good
        default:
            XCTFail("Expected `.ignored`, since the unreachable information is too old to matter anymore, got: \(directive)")
        }
    }

    func test_onGossipPayload_myself_withUnreachable_unreachabilityDisabled() throws {
        var settings = SWIM.Settings()
        settings.extensionUnreachability = .disabled
        let swim = SWIM.Instance(settings: settings, myself: self.myself)

        var myselfMember = swim.myselfMember
        myselfMember.status = .unreachable(incarnation: 1)

        let directive = swim.onGossipPayload(about: myselfMember)

        // we never accept other peers causing us to become some other status,
        // we always view ourselfes as reachable (alive) until dead.
        let myMember = swim.myselfMember
        XCTAssertEqual(myMember.status, .alive(incarnation: 0))

        switch directive {
        case .ignored:
            () // ok, unreachability was disabled after all, so we completely ignore it
        default:
            XCTFail("Expected `.applied(_, .warning, ...)`, got: \(directive)")
        }
    }

    func test_onGossipPayload_other_withUnreachable_unreachabilityDisabled() throws {
        var settings = SWIM.Settings()
        settings.extensionUnreachability = .disabled
        let swim = SWIM.Instance(settings: settings, myself: self.myself)
        let other = self.second!

        swim.addMember(other, status: .alive(incarnation: 0))

        var otherMember = swim.member(for: other)!
        otherMember.status = .unreachable(incarnation: 1)
        // we receive an unreachability event, but we do not use this state, it should be automatically promoted to dead,
        // other nodes may use unreachability e.g. when we're rolling out a reconfiguration, but they can't force
        // us to keep those statuses of members, thus we always promote it to dead.
        let directive = swim.onGossipPayload(about: otherMember)

        switch directive {
        case .applied(.some(let change), _, _) where change.status.isDead:
            otherMember.status = .dead // with unreachability disabled, we automatically promoted it to .dead
            XCTAssertEqual(change.member, otherMember)
        default:
            XCTFail("Expected `.applied(.some(change to dead))`, got: \(directive)")
        }
    }

    func test_onGossipPayload_other_withNewSuspicion_shouldStoreIndividualSuspicions() throws {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)
        let other = self.second!

        swim.addMember(other, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]))
        var otherMember = swim.member(for: other)!
        otherMember.status = .suspect(incarnation: 0, suspectedBy: [self.secondNode])
        let res = swim.onGossipPayload(about: otherMember)
        if case .applied(.some(let change), _, _) = res,
           case .suspect(_, let confirmations) = change.status {
            XCTAssertEqual(confirmations.count, 2)
            XCTAssertTrue(confirmations.contains(secondNode), "expected \(confirmations) to contain \(secondNode)")
            XCTAssertTrue(confirmations.contains(thirdNode), "expected \(confirmations) to contain \(thirdNode)")
        } else {
            XCTFail("Expected `.applied(.some(suspect with multiple suspectedBy))`, got \(res)")
        }
    }

    func test_onGossipPayload_other_shouldNotApplyGossip_whenHaveEnoughSuspectedBy() throws {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)
        let other = self.second!

        let saturatedSuspectedByList = (1 ... swim.settings.lifeguard.maxIndependentSuspicions).map {
            Node(protocol: "test", host: "test", port: 12345, uid: UInt64($0))
        }

        swim.addMember(other, status: .suspect(incarnation: 0, suspectedBy: Set(saturatedSuspectedByList)))

        var otherMember = swim.member(for: other)!
        otherMember.status = .suspect(incarnation: 0, suspectedBy: [self.thirdNode])
        let res = swim.onGossipPayload(about: otherMember)
        guard case .ignored = res else {
            XCTFail("Expected `.ignored(_, _)`, got \(res)")
            return
        }
    }

    func test_onGossipPayload_other_shouldNotExceedMaximumSuspectedBy() throws {
        var settings: SWIM.Settings = .init()
        settings.lifeguard.maxIndependentSuspicions = 3

        let swim = SWIM.Instance(settings: settings, myself: self.myself)
        let other = self.second!

        swim.addMember(other, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode, self.secondNode]))

        var otherMember = swim.member(for: other)!
        otherMember.status = .suspect(incarnation: 0, suspectedBy: [self.thirdNode, self.fourthNode])
        let res = swim.onGossipPayload(about: otherMember)
        if case .applied(.some(let change), _, _) = res,
           case .suspect(_, let confirmation) = change.status {
            XCTAssertEqual(confirmation.count, swim.settings.lifeguard.maxIndependentSuspicions)
        } else {
            XCTFail("Expected `.applied(.some(suspectedBy)) where suspectedBy.count = maxIndependentSuspicions`, got \(res)")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: increment-ing counters

    func test_incrementProtocolPeriod_shouldIncrementTheProtocolPeriodNumberByOne() {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        for i in 0 ..< 10 {
            XCTAssertEqual(swim.protocolPeriod, i)
            swim.incrementProtocolPeriod()
        }
    }

    func test_members_shouldContainAllAddedMembers() {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        let secondPeer = self.second!
        let thirdPeer = self.third!

        swim.addMember(self.myself, status: .alive(incarnation: 0))
        swim.addMember(secondPeer, status: .alive(incarnation: 0))
        swim.addMember(thirdPeer, status: .alive(incarnation: 0))

        XCTAssertTrue(swim.isMember(self.myself))
        XCTAssertTrue(swim.isMember(secondPeer))
        XCTAssertTrue(swim.isMember(thirdPeer))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Modifying LHA-probe multiplier

    func test_onPingRequestResponse_incrementLHAMultiplier_whenMissedNack() {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        let secondPeer = self.second!

        swim.addMember(secondPeer, status: .alive(incarnation: 0))

        swim.onEveryPingRequestResponse(.timeout(target: secondPeer, pingRequestOrigin: nil, timeout: .milliseconds(300), sequenceNumber: 1), pingedMember: secondPeer)
        XCTAssertEqual(swim.localHealthMultiplier, 1)
    }

    func test_onPingRequestResponse_decrementLHAMultiplier_whenGotAck() {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        let secondPeer = self.second!

        swim.addMember(secondPeer, status: .alive(incarnation: 0))
        swim.localHealthMultiplier = 1
        _ = swim.onPingAckResponse(
            target: secondPeer,
            incarnation: 0,
            payload: .none,
            pingRequestOrigin: nil,
            sequenceNumber: 0
        )
        XCTAssertEqual(swim.localHealthMultiplier, 0)
    }

    func test_onPingRequestResponse_notIncrementLHAMultiplier_whenSeeOldSuspicion_onGossip() {
        let p1 = self.myself!
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)
        // first suspicion is for current incarnation, should increase LHA counter
        _ = swim.onGossipPayload(about: SWIM.Member(peer: p1, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0))
        XCTAssertEqual(swim.localHealthMultiplier, 1)
        // second suspicion is for a stale incarnation, should ignore
        _ = swim.onGossipPayload(about: SWIM.Member(peer: p1, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0))
        XCTAssertEqual(swim.localHealthMultiplier, 1)
    }

    func test_onPingRequestResponse_incrementLHAMultiplier_whenRefuteSuspicion_onGossip() {
        let p1 = self.myself!
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        _ = swim.onGossipPayload(about: SWIM.Member(peer: p1, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0))
        XCTAssertEqual(swim.localHealthMultiplier, 1)
    }

    func test_onPingRequestResponse_dontChangeLHAMultiplier_whenGotNack() {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        let secondPeer = self.second!

        swim.addMember(secondPeer, status: .alive(incarnation: 0))
        swim.localHealthMultiplier = 1

        _ = swim.onPingRequestResponse(.nack(target: secondPeer, sequenceNumber: 1), pingedMember: secondPeer)
        XCTAssertEqual(swim.localHealthMultiplier, 1)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Selecting members to ping

    func test_nextMemberToPing_shouldReturnEachMemberOnceBeforeRepeatingAndKeepOrder() throws {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        let memberCount = 10
        var members: Set<TestPeer> = []
        for i in 1 ... memberCount {
            var node = self.myselfNode
            node.port = 8000 + i
            let peer = TestPeer(node: node)
            members.insert(peer)
            swim.addMember(peer, status: .alive(incarnation: 0))
        }

        var seenNodes: [Node] = []
        for _ in 1 ... memberCount {
            guard let member = swim.nextMemberToPing() else {
                XCTFail("Could not fetch member to ping")
                return
            }

            seenNodes.append(member.node)
            members = members.filter {
                $0.node != member.node
            }
        }

        XCTAssertTrue(members.isEmpty, "all members should have been selected at least once")

        // should loop around and we should encounter all the same members now
        for _ in 1 ... memberCount {
            guard let member = swim.nextMemberToPing() else {
                XCTFail("Could not fetch member to ping")
                return
            }

            XCTAssertEqual(seenNodes.removeFirst(), member.node)
        }
    }

    func test_addMember_shouldAddAMemberWithTheSpecifiedStatusAndCurrentProtocolPeriod() {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)
        let status: SWIM.Status = .alive(incarnation: 1)

        swim.incrementProtocolPeriod()
        swim.incrementProtocolPeriod()
        swim.incrementProtocolPeriod()

        XCTAssertFalse(swim.isMember(self.second))
        _ = swim.addMember(self.second, status: status)

        XCTAssertTrue(swim.isMember(self.second))
        let member = swim.member(for: self.second)!
        XCTAssertEqual(member.protocolPeriod, swim.protocolPeriod)
        XCTAssertEqual(member.status, status)
    }

    func test_addMember_shouldNotAddLocalNodeForPinging() {
        let otherPeer = self.second!
        let swim = SWIM.Instance(settings: .init(), myself: otherPeer)

        XCTAssertTrue(swim.isMember(otherPeer))
        XCTAssertNil(swim.nextMemberToPing())
    }

    func test_nextMemberToPingRequest() {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        let res1 = swim.addMember(self.second, status: .alive(incarnation: 0))
        guard case .added(let firstMember) = res1 else {
            return XCTFail("Expected to successfully add peer, was: \(res1)")
        }
        let res2 = swim.addMember(self.third!, status: .alive(incarnation: 0))
        guard case .added(let secondMember) = res2 else {
            return XCTFail("Expected to successfully add peer, was: \(res2)")
        }
        let res3 = swim.addMember(self.fourth!, status: .alive(incarnation: 0))
        guard case .added(let thirdMember) = res3 else {
            return XCTFail("Expected to successfully add peer, was: \(res3)")
        }

        let membersToPing = swim.membersToPingRequest(target: self.fifth!)
        XCTAssertEqual(membersToPing.count, 3)

        let refsToPing = membersToPing.map {
            $0
        }
        XCTAssertTrue(refsToPing.contains(firstMember))
        XCTAssertTrue(refsToPing.contains(secondMember))
        XCTAssertTrue(refsToPing.contains(thirdMember))
    }

    func test_member_shouldReturnTheLastAssignedStatus() {
        let otherPeer = self.second!

        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        swim.addMember(otherPeer, status: .alive(incarnation: 0))
        XCTAssertEqual(swim.member(for: otherPeer)!.status, .alive(incarnation: 0))

        _ = swim.mark(otherPeer, as: .suspect(incarnation: 99, suspectedBy: [self.thirdNode]))
        XCTAssertEqual(swim.member(for: otherPeer)!.status, .suspect(incarnation: 99, suspectedBy: [self.thirdNode]))
    }

    func test_member_shouldWorkForMyself() {
        let swim = SWIM.Instance(settings: .init(), myself: self.myself)

        swim.addMember(self.second, status: .alive(incarnation: 10))

        let member = swim.myselfMember
        XCTAssertEqual(member.node, self.myself.node)
        XCTAssertTrue(member.isAlive)
        XCTAssertEqual(member.status, .alive(incarnation: 0))
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: (Round up the usual...) Suspects

    func test_suspects_shouldContainOnlySuspectedNodes() {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        let aliveAtZero = SWIM.Status.alive(incarnation: 0)
        swim.addMember(self.second, status: aliveAtZero)
        swim.addMember(self.third, status: aliveAtZero)
        swim.addMember(self.fourth, status: aliveAtZero)
        XCTAssertEqual(swim.notDeadMemberCount, 4) // three new nodes + myself

        self.validateSuspects(swim, expected: [])

        XCTAssertEqual(
            swim.mark(self.second, as: .suspect(incarnation: 0, suspectedBy: [self.third.node])),
            .applied(previousStatus: aliveAtZero, currentStatus: .suspect(incarnation: 0, suspectedBy: [self.third.node]))
        )
        self.validateSuspects(swim, expected: [self.second.node])

        _ = swim.mark(self.third, as: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]))
        self.validateSuspects(swim, expected: [self.second.node, self.third.node])

        _ = swim.mark(self.second, as: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]))
        _ = swim.mark(self.myself, as: .alive(incarnation: 1))
        self.validateSuspects(swim, expected: [self.second.node, self.third.node])
    }

    func test_suspects_shouldMark_whenBiggerSuspicionList() {
        var settings: SWIM.Settings = .init()
        settings.lifeguard.maxIndependentSuspicions = 10

        let swim = SWIM.Instance(settings: settings, myself: self.myself)

        let aliveAtZero = SWIM.Status.alive(incarnation: 0)
        swim.addMember(self.second, status: aliveAtZero)
        XCTAssertEqual(swim.notDeadMemberCount, 2)

        self.validateSuspects(swim, expected: [])
        let oldStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: [self.thirdNode])
        XCTAssertEqual(swim.mark(self.second, as: oldStatus), .applied(previousStatus: aliveAtZero, currentStatus: oldStatus))
        self.validateSuspects(swim, expected: [self.second.node])
        let newStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: [self.thirdNode, self.secondNode])
        XCTAssertEqual(swim.mark(self.second, as: newStatus), .applied(previousStatus: oldStatus, currentStatus: newStatus))
        self.validateSuspects(swim, expected: [self.second.node])
    }

    func test_suspects_shouldNotMark_whenSmallerSuspicionList() {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        let aliveAtZero = SWIM.Status.alive(incarnation: 0)
        swim.addMember(self.second, status: aliveAtZero)
        XCTAssertEqual(swim.notDeadMemberCount, 2)

        self.validateSuspects(swim, expected: [])
        let oldStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: [self.thirdNode, self.secondNode])
        XCTAssertEqual(swim.mark(self.second, as: oldStatus), .applied(previousStatus: aliveAtZero, currentStatus: oldStatus))
        self.validateSuspects(swim, expected: [self.second.node])
        let newStatus: SWIM.Status = .suspect(incarnation: 0, suspectedBy: [self.thirdNode])
        XCTAssertEqual(swim.mark(self.second, as: newStatus), .ignoredDueToOlderStatus(currentStatus: oldStatus))
        self.validateSuspects(swim, expected: [self.second.node])
    }

    func test_memberCount_shouldNotCountDeadMembers() {
        let settings = SWIM.Settings()
        let swim = SWIM.Instance(settings: settings, myself: self.myself)

        let aliveAtZero = SWIM.Status.alive(incarnation: 0)
        swim.addMember(self.second, status: aliveAtZero)
        swim.addMember(self.third, status: aliveAtZero)
        swim.addMember(self.fourth, status: aliveAtZero)
        XCTAssertEqual(swim.notDeadMemberCount, 4)

        swim.mark(self.second, as: .dead)
        XCTAssertEqual(swim.notDeadMemberCount, 3)

        swim.mark(self.fourth, as: .dead)
        XCTAssertEqual(swim.notDeadMemberCount, 2) // dead is not part of membership
    }

    func test_memberCount_shouldCountUnreachableMembers() {
        var settings = SWIM.Settings()
        settings.extensionUnreachability = .enabled
        let swim = SWIM.Instance(settings: settings, myself: self.myself)

        let aliveAtZero = SWIM.Status.alive(incarnation: 0)
        swim.addMember(self.second, status: aliveAtZero)
        swim.addMember(self.third, status: aliveAtZero)
        swim.addMember(self.fourth, status: aliveAtZero)
        XCTAssertEqual(swim.notDeadMemberCount, 4)

        swim.mark(self.second, as: .dead)
        XCTAssertEqual(swim.notDeadMemberCount, 3)

        swim.mark(self.third, as: .unreachable(incarnation: 19))
        XCTAssertEqual(swim.notDeadMemberCount, 3) // unreachable is still "part of the membership" as far as we are concerned

        swim.mark(self.fourth, as: .dead)
        XCTAssertEqual(swim.notDeadMemberCount, 2) // dead is not part of membership
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: makeGossipPayload

    func test_makeGossipPayload_shouldGossipAboutSelf_whenNoMembers() throws {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)

        try self.validateGossip(swim: swim, expected: [.init(peer: self.myself, status: .alive(incarnation: 0), protocolPeriod: 0)])
    }

    func test_makeGossipPayload_shouldEventuallyStopGossips() throws {
        let swim = SWIM.Instance(settings: SWIM.Settings(), myself: self.myself)
        swim.addMember(self.second, status: .alive(incarnation: 0))
        swim.addMember(self.third, status: .alive(incarnation: 0))

        var count = 0
        var gossip = swim.makeGossipPayload(to: nil)
        while case .membership(let members) = gossip, members.count > 1 {
            gossip = swim.makeGossipPayload(to: nil)
            count += 1
        }
        
        XCTAssertEqual(count, 7) // based on the default values of the
    }

    func test_makeGossipPayload_shouldReset_whenNewMemberChangedStatus() throws {
        let settings: SWIM.Settings = .init()
        let swim = SWIM.Instance(settings: settings, myself: self.myself)

        swim.addMember(self.second, status: .alive(incarnation: 0))
        swim.addMember(self.third, status: .alive(incarnation: 0))
        let myselfMember = SWIM.Member(peer: self.myself, status: .alive(incarnation: 0), protocolPeriod: 0)
        let thirdMember = SWIM.Member(peer: self.third, status: .alive(incarnation: 0), protocolPeriod: 0)

        try self.validateGossip(swim: swim, expected: [.init(peer: self.second, status: .alive(incarnation: 0), protocolPeriod: 0), myselfMember, thirdMember])

        _ = swim.mark(self.second, as: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]))
        try self.validateGossip(swim: swim, expected: [
            .init(peer: self.second, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0),
            myselfMember,
            thirdMember,
        ])
        try self.validateGossip(swim: swim, expected: [
            .init(peer: self.second, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0),
            myselfMember,
            thirdMember,
        ])

        // turns out it is alive after all, and it bumped its incarnation (it had to, to refute the suspicion)
        swim.mark(self.second, as: .alive(incarnation: 1))

        try self.validateGossip(swim: swim, expected: [
            .init(peer: self.second, status: .alive(incarnation: 1), protocolPeriod: 0),
            .init(peer: self.third, status: .alive(incarnation: 0), protocolPeriod: 0),
            myselfMember,
        ])
    }

    func test_makeGossipPayload_shouldReset_whenNewMembersJoin() throws {
        let settings: SWIM.Settings = .init()
        let swim = SWIM.Instance(settings: settings, myself: self.myself)

        swim.addMember(self.second, status: .alive(incarnation: 0))
        let myselfMember = SWIM.Member(peer: self.myself, status: .alive(incarnation: 0), protocolPeriod: 0)

        try self.validateGossip(swim: swim, expected: [.init(peer: self.second, status: .alive(incarnation: 0), protocolPeriod: 0), myselfMember])

        _ = swim.mark(self.second, as: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]))
        try self.validateGossip(swim: swim, expected: [.init(peer: self.second, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0), myselfMember])
        try self.validateGossip(swim: swim, expected: [.init(peer: self.second, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0), myselfMember])
        try self.validateGossip(swim: swim, expected: [.init(peer: self.second, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0), myselfMember])
        try self.validateGossip(swim: swim, expected: [.init(peer: self.second, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0), myselfMember])

        // a new member joins, and we must ensure it'd get some of the gossip
        swim.addMember(self.third, status: .alive(incarnation: 0))

        try self.validateGossip(swim: swim, expected: [
            .init(peer: self.second, status: .suspect(incarnation: 0, suspectedBy: [self.thirdNode]), protocolPeriod: 0),
            .init(peer: self.third, status: .alive(incarnation: 0), protocolPeriod: 0),
            myselfMember,
        ])
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Confirming dead

    func test_confirmDead_anUnknownNode_shouldDoNothing() throws {
        var settings = SWIM.Settings()
        settings.extensionUnreachability = .enabled
        let swim = SWIM.Instance(settings: settings, myself: self.myself)

        let directive = swim.confirmDead(peer: self.second)
        switch directive {
        case .ignored:
            () // ok
        default:
            XCTFail("Expected marking an unknown node to be ignored, got: \(directive)")
        }
    }

    func test_confirmDead_aKnownOtherNode_shouldApply() throws {
        var settings = SWIM.Settings()
        settings.extensionUnreachability = .enabled
        let swim = SWIM.Instance(settings: settings, myself: self.myself)

        swim.addMember(self.second, status: .alive(incarnation: 10))

        let directive = swim.confirmDead(peer: self.second)
        switch directive {
        case .applied(let change):
            let previousStatus = change.previousStatus
            let member = change.member
            XCTAssertEqual(previousStatus, SWIM.Status.alive(incarnation: 10))
            XCTAssertEqual("\(reflecting: member.peer)", "\(reflecting: self.second!)")
        default:
            XCTFail("Expected confirmingDead a node to be `.applied`, got: \(directive)")
        }
    }

    func test_confirmDead_myself_shouldApply() throws {
        var settings = SWIM.Settings()
        settings.extensionUnreachability = .enabled
        let swim = SWIM.Instance(settings: settings, myself: self.myself)

        swim.addMember(self.second, status: .alive(incarnation: 10))

        let directive = swim.confirmDead(peer: self.myself)
        switch directive {
        case .applied(let change):
            let previousStatus = change.previousStatus
            let member = change.member
            XCTAssertEqual(previousStatus, SWIM.Status.alive(incarnation: 0))
            XCTAssertEqual("\(reflecting: member.peer)", "\(reflecting: self.myself!)")
        default:
            XCTFail("Expected confirmingDead a node to be `.applied`, got: \(directive)")
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Sanity checks

    /// This test is weird and should "never" fail, but it did, on some toolchains.
    /// This test is to remain here as a sanity check if timeouts or something else would suddenly return unexpected values.
    func test_log_becauseWeSawItReturnWronglyOnSomeToolchains() {
        XCTAssertEqual(log2(4.0), 2)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: utility functions

    func validateMark(
        swim: SWIM.Instance, member: SWIM.Member, status: SWIM.Status, shouldSucceed: Bool,
        file: StaticString = (#file), line: UInt = #line
    ) throws {
        try self.validateMark(swim: swim, peer: member.peer, status: status, shouldSucceed: shouldSucceed, file: file, line: line)
    }

    func validateMark(
        swim: SWIM.Instance, peer: SWIMAddressablePeer, status: SWIM.Status, shouldSucceed: Bool,
        file: StaticString = (#file), line: UInt = #line
    ) throws {
        let markResult = swim.mark(peer, as: status)

        if shouldSucceed {
            guard case .applied = markResult else {
                XCTFail("Expected `.applied`, got `\(markResult)`", file: file, line: line)
                return
            }
        } else {
            guard case .ignoredDueToOlderStatus = markResult else {
                XCTFail("Expected `.ignoredDueToOlderStatus`, got `\(markResult)`", file: file, line: line)
                return
            }
        }
    }

    func validateSuspects(
        _ swim: SWIM.Instance, expected: Set<Node>,
        file: StaticString = (#file), line: UInt = #line
    ) {
        XCTAssertEqual(Set(swim.suspects.map {
            $0.node
        }), expected, file: file, line: line)
    }

    func validateGossip(swim: SWIM.Instance, expected: Set<SWIM.Member>, file: StaticString = (#file), line: UInt = #line) throws {
        let payload = swim.makeGossipPayload(to: nil)
        if expected.isEmpty {
            guard case SWIM.GossipPayload.none = payload else {
                XCTFail("Expected `.none`, but got `\(payload)`", file: file, line: line)
                return
            }
        } else {
            guard case SWIM.GossipPayload.membership(let members) = payload else {
                XCTFail("Expected `.membership`, but got `\(payload)`", file: file, line: line)
                return
            }

            XCTAssertEqual(Set(members), expected, file: file, line: line)
        }
    }
}
