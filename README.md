# Swift Cluster Membership

Swift Cluster Membership provides implementations of distributed membership protocols, which are an important building block for building distributed systems with Swift.

The core algorithm implementations _do not_ depend on any specific transport layer, although Proof-of-Concept implementations of using them with [swift-nio](https://github.com/apple/swift-nio) providing the networking and "interpreting" the algorithm state machines are provide in the repository.

## Membership Protocols

A membership protocol provides each process (“member”) of the group with a locally-maintained list of other **non-faulty** processes in the group. 
Part of a membership protocol's responsilibities lies with determining faulty and non-faulty members in a reliable and predictable manner. 

Members may join the membership at will, usually by contacting _any_ of the existing members, and become known to all other members in the cluster.
Members may leave the membership gracefully or crash and be determined as dead and thus removed from the non-falutly membership list using distributed failure detection mechanisms.

## Modules

### SWIM: Scalable Weakly-consistent Infection-style Process Group Membership Protocol

Implementation of the following papers:

- [SWIM: Scalable Weakly-consistent Infection-style Process Group Membership Protocol](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf)
- [Lifeguard: Local Health Awareness for More Accurate Failure Detection](https://arxiv.org/abs/1707.00788)

### Others in the future

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
