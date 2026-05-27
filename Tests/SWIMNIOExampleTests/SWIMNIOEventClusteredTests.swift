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
import NIOCore
import SWIM
import SWIMTestKit
import Synchronization
import Testing

@testable import SWIMNIOExample

// TODO: those tests could be done on embedded event loops probably
@Suite(.serialized)
final class SWIMNIOEventClusteredTests {
    var settings: SWIMNIO.Settings = SWIMNIO.Settings(swim: .init())
    var myselfNode: Node!
    var myselfPeer: Node!
    var myselfMemberAliveInitial: SWIM.Member!

    var group: MultiThreadedEventLoopGroup!

    init() async {
        let port = await TestPortAllocator.shared.nextPort()
        self.myselfNode = Node(protocol: "udp", host: "127.0.0.1", port: port, uid: 1111)
        self.myselfPeer = myselfNode
        self.myselfMemberAliveInitial = SWIM.Member(node: myselfNode, status: .alive(incarnation: 0), protocolPeriod: 0)
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
            let firstProbe = ProbeEventHandler()

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
            let firstProbe = ProbeEventHandler()
            let secondProbe = ProbeEventHandler()

            let secondNodePort = await TestPortAllocator.shared.nextPort()
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
                            node: secondNode,
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
        let asyncChannel = try await DatagramBootstrap(group: self.group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: settings.node!.host, port: settings.node!.port) { channel in
                do {
                    let asyncChannel = try NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>(
                        wrappingChannelSynchronously: channel
                    )
                    return channel.eventLoop.makeSucceededFuture(asyncChannel)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        let service = SWIMNIOService(
            node: settings.node!,
            settings: settings,
            channel: asyncChannel,
            onMemberStatusChange: { event in
                probeHandler.handleEvent(event)
            }
        )

        Task {
            try? await service.run()
        }

        return asyncChannel.channel
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Test Utils

extension ProbeEventHandler {
    @discardableResult
    func expectEvent(
        _ expected: SWIM.MemberStatusChangedEvent? = nil,
        file: StaticString = (#file),
        line: UInt = #line,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> SWIM.MemberStatusChangedEvent {
        let got = try await self.expectEvent()

        if let expected = expected {
            #expect(got == expected, sourceLocation: sourceLocation)
        }

        return got
    }
}

final class ProbeEventHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = SWIM.MemberStatusChangedEvent

    struct Storage: Sendable {
        var events: [SWIM.MemberStatusChangedEvent] = []
        var continuation: CheckedContinuation<SWIM.MemberStatusChangedEvent, any Error>?
    }

    let storage: Mutex<Storage>

    init() {
        self.storage = Mutex(Storage())
    }

    func handleEvent(_ change: SWIM.MemberStatusChangedEvent) {
        self.storage.withLock { storage in
            if let continuation = storage.continuation {
                continuation.resume(returning: change)
                storage.continuation = nil
            } else {
                storage.events.append(change)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let change = self.unwrapInboundIn(data)
        self.handleEvent(change)
    }

    func expectEvent(
        file: StaticString = #file,
        line: UInt = #line,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> SWIM.MemberStatusChangedEvent {
        try await withCheckedThrowingContinuation { continuation in
            self.storage.withLock { storage in
                assert(storage.continuation == nil, "Already waiting on an event")
                if let event = storage.events.first {
                    storage.events.removeFirst()
                    continuation.resume(returning: event)
                } else {
                    storage.continuation = continuation
                }
            }
        }
    }
}
