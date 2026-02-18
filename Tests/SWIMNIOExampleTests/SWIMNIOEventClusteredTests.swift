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

    init() {
        self.settings.node = self.myselfNode
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        try! self.group.syncShutdownGracefully()
        self.group = nil
    }

    @Test
    func test_memberStatusChange_alive_emittedForMyself() async throws {
        try await withEmbeddedClusteredTestScope { cluster in
            let firstProbe = ProbeEventHandler(loop: group.next())

            let first = try await bindShell(probe: firstProbe, cluster: cluster) { [myselfNode] settings in
                settings.node = myselfNode
            }
            do {
                try await firstProbe.expectEvent(
                    SWIM.MemberStatusChangedEvent(previousStatus: nil, member: self.myselfMemberAliveInitial)
                )
                try await first.close().get()
            } catch {
                try await first.close().get()
                throw error
            }
        }
    }

    @Test
    func test_memberStatusChange_suspect_emittedForDyingNode() async throws {
        try await withEmbeddedClusteredTestScope { cluster in
            let firstProbe = ProbeEventHandler(loop: group.next())
            let secondProbe = ProbeEventHandler(loop: group.next())

            let secondNodePort = 7002
            let secondNode = Node(protocol: "udp", host: "127.0.0.1", port: secondNodePort, uid: 222_222)

            let second = try await bindShell(probe: secondProbe, cluster: cluster) { settings in
                settings.node = secondNode
            }

            let first = try await bindShell(probe: firstProbe, cluster: cluster) { [myselfNode] settings in
                settings.node = myselfNode
                settings.swim.initialContactPoints = [secondNode.withoutUID]
            }

            do {
                // wait for second probe to become alive:
                try await secondProbe.expectEvent(
                    SWIM.MemberStatusChangedEvent(
                        previousStatus: nil,
                        member: SWIM.Member(
                            peer: SWIM.NIOPeer(node: secondNode, channel: EmbeddedChannel()),
                            status: .alive(incarnation: 0),
                            protocolPeriod: 0
                        )
                    )
                )

                try await Task.sleep(for: .seconds(5))  // let them discover each other, since the nodes are slow at retrying and we didn't configure it yet a sleep is here meh
                try await second.close().get()

                try await firstProbe.expectEvent(
                    SWIM.MemberStatusChangedEvent(previousStatus: nil, member: self.myselfMemberAliveInitial)
                )

                let secondAliveEvent = try await firstProbe.expectEvent()
                #expect(secondAliveEvent.isReachabilityChange)
                #expect(secondAliveEvent.status.isAlive)
                #expect(secondAliveEvent.member.node.withoutUID == secondNode.withoutUID)

                let secondDeadEvent = try await firstProbe.expectEvent()
                #expect(secondDeadEvent.isReachabilityChange)
                #expect(secondDeadEvent.status.isDead)
                #expect(secondDeadEvent.member.node.withoutUID == secondNode.withoutUID)

                try await first.close().get()
            } catch {
                try await first.close().get()
                throw error
            }
        }
    }

    private func bindShell(
        probe probeHandler: ProbeEventHandler,
        cluster: EmbeddedCluster,
        configure: @Sendable (inout SWIMNIO.Settings) -> Void = { _ in () }
    ) async throws -> Channel {
        var settings = self.settings
        configure(&settings)
        await cluster.makeLogCapture(name: "swim-\(settings.node!.port)", settings: &settings)

        await cluster.appendNode(settings.node!)
        return try await DatagramBootstrap(group: self.group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { [settings] channel in
                let swimHandler = SWIMNIOHandler(settings: settings)
                return channel.pipeline.addHandler(swimHandler).flatMap { _ in
                    channel.pipeline.addHandler(probeHandler)
                }
            }
            .bind(host: settings.node!.host, port: settings.node!.port)
            .get()
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
    ) async throws -> SWIM.MemberStatusChangedEvent<SWIM.NIOPeer> {
        let got = try await self.expectEvent()

        if let expected = expected {
            #expect(got == expected, sourceLocation: sourceLocation)
        }

        return got
    }
}

final class ProbeEventHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = SWIM.MemberStatusChangedEvent<SWIM.NIOPeer>

    struct Storage: Sendable {
        var events: [SWIM.MemberStatusChangedEvent<SWIM.NIOPeer>] = []
        var waitingPromise: EventLoopPromise<SWIM.MemberStatusChangedEvent<SWIM.NIOPeer>>?
        var loop: EventLoop
    }

    let storage: Mutex<Storage>

    init(loop: EventLoop) {
        self.storage = Mutex(Storage(loop: loop))
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let change = self.unwrapInboundIn(data)
        self.storage.withLock { storage in
            storage.events.append(change)

            if let probePromise = storage.waitingPromise {
                let event = storage.events.removeFirst()
                probePromise.succeed(event)
                storage.waitingPromise = nil
            }
        }
    }

    func expectEvent(
        file: StaticString = #file,
        line: UInt = #line,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> SWIM.MemberStatusChangedEvent<SWIM.NIOPeer> {
        try await self.storage.withLock { storage in
            let p = storage.loop.makePromise(of: SWIM.MemberStatusChangedEvent<SWIM.NIOPeer>.self, file: file, line: line)
            storage.loop.execute {
                self.storage
                    .withLock { storage in
                        assert(storage.waitingPromise == nil, "Already waiting on an event")
                        if !storage.events.isEmpty {
                            let event = storage.events.removeFirst()
                            p.succeed(event)
                        } else {
                            storage.waitingPromise = p
                        }
                    }
            }
            return p
        }
        .futureResult
        .get()
    }
}
