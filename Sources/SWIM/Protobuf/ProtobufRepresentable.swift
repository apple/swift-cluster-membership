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
import struct Foundation.Data
import NIO
import protocol Swift.Decoder // to prevent shadowing by the ones in SwiftProtobuf
import protocol Swift.Encoder // to prevent shadowing by the ones in SwiftProtobuf
import SwiftProtobuf

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Protobuf representations

/// This protocol is for internal protobuf-serializable messages only.
///
/// We need a protocol separate from `ProtobufRepresentable` because otherwise we would be forced to make internal types public.
internal protocol InternalProtobufRepresentable: AnyProtobufRepresentable {
    associatedtype ProtobufRepresentation: SwiftProtobuf.Message

    init(from decoder: Decoder) throws
    func encode(to encoder: Encoder) throws

    func toProto() throws -> ProtobufRepresentation
    init(fromProto proto: ProtobufRepresentation) throws
}
