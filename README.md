# Swift Cluster Membership

A collection of Cluster Membership protocol implementations in Swift.

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
