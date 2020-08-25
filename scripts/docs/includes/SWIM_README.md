# SWIM Cluster Membership API Documentation

Welcome to the API documentation of Swift Cluster Membership's SWIM implementation!

### General overview

Please refer to [`SWIM`](SWIM/Enums/SWIM.html) documentation for a general discussion and overview of the algorithm.

### Custom transport implementations

When considering custom shell implementations, types of most interest are:

- [SWIMProtocol](Protocols/SWIMProtocol.html) which documents the callbacks which are needed to be invoked to drive the algorithm encapsulated in SWIM.Instance,
- and the peer protocols [SWIMPeer](Protocols/SWIMPeer.html), [SWIMPingOriginPeer](Protocols/SWIMPingOriginPeer.html), [SWIMPingRequestOriginPeer](Protocols/SWIMPingRequestOriginPeer.html) which represent the various roles a peer plays in the protocol. 

### Reusing existing implementations

For reusing existing implementations please refer to their documentation pages, listed below:

## Modules

Other modules
<!-- module links inserted here by generate_docs_api.sh -->
