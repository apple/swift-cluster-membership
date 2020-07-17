# Swift Cluster Membership

Swift Cluster Membership provides implementations of distributed membership protocols, which are an important building block for building distributed systems with Swift.

The core algorithm implementations _do not_ depend on any specific transport layer, although Proof-of-Concept implementations of using them with [swift-nio](https://github.com/apple/swift-nio) providing the networking and "interpreting" the algorithm state machines are provide in the repository.

## Membership Protocols

A membership protocol provides each process (“member”) of the group with a locally-maintained list of other **non-faulty** processes in the group. 
Part of a membership protocol's responsibilities lies with determining faulty and non-faulty members in a reliable and predictable manner. 

Members may join the membership at will, usually by contacting _any_ of the existing members, and become known to all other members in the cluster.
Members may leave the membership gracefully or crash and be determined as dead and thus removed from the non-faulty membership list using distributed failure detection mechanisms.

### 🏊‍♀ 🏊‍♂  🏊‍♂️ SWIM: Scalable Weakly-consistent Infection-style Process Group Membership Protocol

Implementation of the following papers:

- [SWIM: Scalable Weakly-consistent Infection-style Process Group Membership Protocol](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf)
- [Lifeguard: Local Health Awareness for More Accurate Failure Detection](https://arxiv.org/abs/1707.00788)

### SWIM: Usage

As the `SWIM.Instance` is *completely agnostic to any IO or specific runtime*, using it requires implementing a form of "interpreter" (which we'll call "Shell" from here on) for it's directives, and hooking it up into some messaging system as well implementing a specific `SWIMPeerProtocol`.

The repository contains an example implementation over UDP messages using [swift-nio](https://github.com/apple/swift-nio). It has _not_ been tested in production, but serves as a good example how one might use the SWIM implementation provided by this package.

Firstly, one needs to construct a SWIM.Instance:

```swift
var swim = SWIM.Instance(settings: ...)
```

The instance is a value type, and and we need to drive it by calling mutating functions on it whenever we receive messages or timer events. For example, in our `SWIMNIOShell` we implement a function called `receiveMessage(message: SWIM.Message, from: SWIM.Node)` which we have to implement by applying the apropriate function on the SWIM instance:

```swift
// final class SWIMNIOShell { 
// FIXME pseudo code, not today's impl !!!!!! FIXME: this should be as simple as this example 

func receiveMessage(message: SWIM.Message) {
    switch message {
    case .ping(let replyTo, let payload):
        let directive = swim.onPing(from: senderNode, gossip: payload)
        
        switch directive { // TODO should it just speak in terms of nodes and members and we look up the peer for it?
        case .ack(let target, let incarnation, let payload):
            replyTo.ack(target: self.peer, incarnation: incarnation, payload: payload) 

        case .nack(let target):
            replyTo.nack(target: self.peer(on: target))
        }
    // case ...: // handle other messages here
    }
}
// }
```

The instance never actively sends messages, but only informs us in the form of "directives" what we (the `*Shell`) should be doing in order to handle it.

You might have noticed that the messaging is still somewhat abstracted away, we were simply able to send a message to the originator of the ping by writing `replyTo.ack(...)`, but where is the messaging actually implemented?

Since the SWIM instance does not know anything about runtimes, we also have to provide a specific implementation of `SWIMPeerProtocol` which the above code snippet was utilizing. 
The protocol outlines all basic capabilities a peer in the SWIM world has, such as being identifiable with an unique `Node` as well as being able to send messages to it:

```swift
public protocol SWIMPeerProtocol {
    /// Node that this peer is representing.
    var node: ClusterMembership.Node { get }

    /// "Ping" another SWIM peer.
    func ping(
        payload: SWIM.GossipPayload,
        from origin: SWIMPeerProtocol,
        timeout: SWIMTimeAmount,
        onComplete: @escaping (Result<SWIM.PingResponse, Error>) -> Void
    )

    /// "Ping Request" a SWIM peer.
    func pingReq(
        target: SWIMPeerProtocol,
        payload: SWIM.GossipPayload,
        from origin: SWIMPeerProtocol,
        timeout: SWIMTimeAmount,
        onComplete: @escaping (Result<SWIM.PingResponse, Error>) -> Void
    )

    /// Acknowledge a ping.
    func ack(target: SWIMPeerProtocol, incarnation: SWIM.Incarnation, payload: SWIM.GossipPayload)

    /// "NegativeAcknowledge" a ping.
    func nack(target: SWIMPeerProtocol)

    /// Type erase this member into an `AnySWIMMember`
    var asAnyMember: AnySWIMPeer { get }
}
```

## Other Algorithms

We are open to accepting additional membership implementations.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for a detailed guide on contributing.

See also, [STYLE_GUIDE.md](STYLE_GUIDE.md) for some additional style hints.

## Documentation

### API Documentation

API documentation is generated using Jazzy:

```
./scripts/docs/generate_api.sh
open .build/docs/api/...-dev/index.html
```

## Supported Versions

Swift: 

- Swift 5.2+ (including 5.3-dev)

Operating Systems:

- Linux systems (Ubuntu and friends)
- macOS
