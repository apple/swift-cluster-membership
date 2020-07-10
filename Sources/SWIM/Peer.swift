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

public protocol SWIMPeerProtocol {
    /// Node that this peer is representing.
    var node: ClusterMembership.Node { get }

    /// "Ping" another SWIM peer.
    func ping(
        payload: SWIM.GossipPayload,
        from origin: SWIMPeerProtocol,
        timeout: TimeAmount,
        onComplete: @escaping (Result<SWIM.PingResponse, Error>) -> Void
    )

    /// "Ping Request" a SWIM peer.
    func pingReq(
        target: SWIMPeerProtocol,
        payload: SWIM.GossipPayload,
        from origin: SWIMPeerProtocol,
        timeout: TimeAmount,
        onComplete: @escaping (Result<SWIM.PingResponse, Error>) -> Void
    )

    /// "Ack"-nowledge a ping.
    func ack(target: SWIMPeerProtocol, incarnation: SWIM.Incarnation, payload: SWIM.GossipPayload)

    /// "NegativeAcknowledge" a ping.
    func nack(target: SWIMPeerProtocol)
}
