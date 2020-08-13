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
import NIO
import SWIM
@testable import SWIMNIO
import XCTest

final class SWIMNIOEventTests: EmbeddedClusteredXCTestCase {
    override var alwaysPrintCaptureLogs: Bool {
        true
    }

    var settings: SWIM.Settings!
    lazy var myselfNode = Node(protocol: "udp", host: "127.0.0.1", port: 7001, uid: 1111)
    lazy var myselfPeer = SWIM.NIOPeer(node: myselfNode, channel: nil)
    lazy var myselfMemberAliveInitial = SWIM.Member(peer: myselfPeer, status: .alive(incarnation: 0), protocolPeriod: 0)

    let nonExistentNode = Node(protocol: "udp", host: "127.0.0.222", port: 7834, uid: 9324)
    lazy var nonExistentPeer = SWIM.NIOPeer(node: nonExistentNode, channel: nil)

    var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        super.setUp()

        self.settings = SWIM.Settings()
        self.settings.node = self.myselfNode

        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        try! self.group.syncShutdownGracefully()
        self.group = nil

        super.tearDown()
    }

    func test_memberStatusChange_alive_emittedForMyself() throws {
        let firstProbe = ProbeEventHandler(loop: group.next())

        let first = try bindShell(settings, probe: firstProbe)
        defer { try! first.close().wait() }

        try firstProbe.expectEvent(SWIM.MemberStatusChangeEvent(previousStatus: nil, member: self.myselfMemberAliveInitial))
    }

    func test_memberStatusChange_suspect_emittedForNonExistentNode() throws {
        let firstProbe = ProbeEventHandler(loop: group.next())

        self.settings.initialContactPoints = [
            self.nonExistentNode,
        ]
        let first = try bindShell(settings, probe: firstProbe)
        defer { try! first.close().wait() }

        try firstProbe.expectEvent(SWIM.MemberStatusChangeEvent(previousStatus: nil, member: self.myselfMemberAliveInitial))
        let event = try firstProbe.expectEvent()
        XCTAssertTrue(event.isReachabilityChange)
        XCTAssertTrue(event.status.isUnreachable)
        XCTAssertEqual(event.member.node, self.nonExistentNode)
    }

    private func bindShell(_ settings: SWIM.Settings, probe probeHandler: ProbeEventHandler) throws -> Channel {
        self._nodes.append(settings.node!)

        let channel = try DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                var settings = settings
                self.makeLogCapture(name: "swim-\(settings.node!.port)", settings: &settings)
                let swimHandler = SWIMProtocolHandler(settings: settings)
                return channel.pipeline.addHandler(swimHandler).flatMap { _ in
                    channel.pipeline.addHandler(probeHandler)
                }
            }.bind(host: settings.node!.host, port: settings.node!.port).wait()
        return channel
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Test Utils

extension ProbeEventHandler {
    @discardableResult
    func expectEvent(
        _ expected: SWIM.MemberStatusChangeEvent? = nil,
        file: StaticString = (#file), line: UInt = #line
    ) throws -> SWIM.MemberStatusChangeEvent {
        let got = try self.expectEvent()

        if let expected = expected {
            XCTAssertEqual(got, expected, file: file, line: line)
        }

        return got
    }
}

final class ProbeEventHandler: ChannelInboundHandler {
    typealias InboundIn = SWIM.MemberStatusChangeEvent

    var events: [SWIM.MemberStatusChangeEvent] = []
    var waitingPromise: EventLoopPromise<SWIM.MemberStatusChangeEvent>?
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

    func expectEvent(file: StaticString = #file, line: UInt = #line) throws -> SWIM.MemberStatusChangeEvent {
        let p = self.loop.makePromise(of: SWIM.MemberStatusChangeEvent.self, file: file, line: line)
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
