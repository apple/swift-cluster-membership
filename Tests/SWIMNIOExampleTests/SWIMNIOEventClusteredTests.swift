//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import NIO
import SWIM
import SWIMTestKit
import Synchronization
import Testing

@testable import SWIMNIOExample

// TODO: those tests could be done on embedded event loops probably
@Suite(.serialized)
final class SWIMNIOEventClusteredTests {
    var settings: SWIMNIO.Settings = SWIMNIO.Settings(swim: .init())
    lazy var myselfNode = Node(protocol: "udp", host: "127.0.0.1", port: 7001, uid: 1111)
    lazy var myselfPeer = SWIM.NIOPeer(node: myselfNode, channel: EmbeddedChannel())
    lazy var myselfMemberAliveInitial = SWIM.Member(peer: myselfPeer, status: .alive(incarnation: 0), protocolPeriod: 0)

    var group: MultiThreadedEventLoopGroup!
    let embeddedClustered = EmbeddedClustered()

    init() {
        self.settings.node = self.myselfNode
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        try! self.group.syncShutdownGracefully()
        self.group = nil
    }

    @Test
    func test_memberStatusChange_alive_emittedForMyself() throws {
        let firstProbe = ProbeEventHandler(loop: group.next())

        let first = try bindShell(probe: firstProbe) { settings in
            settings.node = self.myselfNode
        }
        defer { try! first.close().wait() }

        try firstProbe.expectEvent(
            SWIM.MemberStatusChangedEvent(previousStatus: nil, member: self.myselfMemberAliveInitial)
        )
    }

    @Test
    func test_memberStatusChange_suspect_emittedForDyingNode() throws {
        let firstProbe = ProbeEventHandler(loop: group.next())
        let secondProbe = ProbeEventHandler(loop: group.next())

        let secondNodePort = 7002
        let secondNode = Node(protocol: "udp", host: "127.0.0.1", port: secondNodePort, uid: 222_222)

        let second = try bindShell(probe: secondProbe) { settings in
            settings.node = secondNode
        }

        let first = try bindShell(probe: firstProbe) { settings in
            settings.node = self.myselfNode
            settings.swim.initialContactPoints = [secondNode.withoutUID]
        }
        defer { try! first.close().wait() }

        // wait for second probe to become alive:
        try secondProbe.expectEvent(
            SWIM.MemberStatusChangedEvent(
                previousStatus: nil,
                member: SWIM.Member(
                    peer: SWIM.NIOPeer(node: secondNode, channel: EmbeddedChannel()),
                    status: .alive(incarnation: 0),
                    protocolPeriod: 0
                )
            )
        )

        sleep(5)  // let them discover each other, since the nodes are slow at retrying and we didn't configure it yet a sleep is here meh
        try! second.close().wait()

        try firstProbe.expectEvent(
            SWIM.MemberStatusChangedEvent(previousStatus: nil, member: self.myselfMemberAliveInitial)
        )

        let secondAliveEvent = try firstProbe.expectEvent()
        #expect(secondAliveEvent.isReachabilityChange)
        #expect(secondAliveEvent.status.isAlive)
        #expect(secondAliveEvent.member.node.withoutUID == secondNode.withoutUID)

        let secondDeadEvent = try firstProbe.expectEvent()
        #expect(secondDeadEvent.isReachabilityChange)
        #expect(secondDeadEvent.status.isDead)
        #expect(secondDeadEvent.member.node.withoutUID == secondNode.withoutUID)
    }

    private func bindShell(
        probe probeHandler: ProbeEventHandler,
        configure: (inout SWIMNIO.Settings) -> Void = { _ in () }
    ) throws -> Channel {
        var settings = self.settings
        configure(&settings)
        self.embeddedClustered.session.makeLogCapture(name: "swim-\(settings.node!.port)", settings: &settings)

        self.embeddedClustered.session._storage.withLock { $0.nodes.append(settings.node!) }
        return try DatagramBootstrap(group: self.group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in

                let swimHandler = SWIMNIOHandler(settings: settings)
                return channel.pipeline.addHandler(swimHandler).flatMap { _ in
                    channel.pipeline.addHandler(probeHandler)
                }
            }.bind(host: settings.node!.host, port: settings.node!.port).wait()
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Test Utils

extension ProbeEventHandler {
    @discardableResult
    func expectEvent(
        _ expected: SWIM.MemberStatusChangedEvent<SWIM.NIOPeer>? = nil,
        file: StaticString = (#file),
        line: UInt = #line,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> SWIM.MemberStatusChangedEvent<SWIM.NIOPeer> {
        let got = try self.expectEvent()

        if let expected = expected {
            #expect(got == expected, sourceLocation: sourceLocation)
        }

        return got
    }
}

final class ProbeEventHandler: ChannelInboundHandler {
    typealias InboundIn = SWIM.MemberStatusChangedEvent<SWIM.NIOPeer>

    var events: [SWIM.MemberStatusChangedEvent<SWIM.NIOPeer>] = []
    var waitingPromise: EventLoopPromise<SWIM.MemberStatusChangedEvent<SWIM.NIOPeer>>?
    var loop: EventLoop

    init(loop: EventLoop) {
        self.loop = loop
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let change = self.unwrapInboundIn(data)
        self.events.append(change)

        if let probePromise = self.waitingPromise {
            let event = self.events.removeFirst()
            probePromise.succeed(event)
            self.waitingPromise = nil
        }
    }

    func expectEvent(
        file: StaticString = #file,
        line: UInt = #line,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> SWIM.MemberStatusChangedEvent<SWIM.NIOPeer> {
        let p = self.loop.makePromise(of: SWIM.MemberStatusChangedEvent<SWIM.NIOPeer>.self, file: file, line: line)
        self.loop.execute {
            assert(self.waitingPromise == nil, "Already waiting on an event")
            if !self.events.isEmpty {
                let event = self.events.removeFirst()
                p.succeed(event)
            } else {
                self.waitingPromise = p
            }
        }
        return try p.futureResult.wait()
    }
}
