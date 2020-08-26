# Contributors Handbook

## Glossary

In an attempt to form a shared vocabulary in the project, words used in the APIs have been carefully selected and we'd like to keep using them to refer to the same things in various implementations.

- CoolAlgorithm **Instance** - we refer to a specific implementation of a membership algorithm as an "Instance". An instance is:
    - SHOULD be a value type; as it makes debugging the state of an instance simpler; i.e. we can record the last 10 states of the algorithm and see how things went wrong, even in running clustered systems if necessary.
    - is NOT performing any IO (except for logging which we after long debates, decided that it's better to allow implementations to log if configured to do so)
    - it most likely IS a finite state machine, although may not be one in the strict meaning of the pattern. If possible to express as an FSM, we recommend doing so, or carving out pieces of the protocol which can be represented as a state machine.
    - an instance SHOULD be easy to test in isolation, such that crazy edge cases in algorithms can be codified in easy to run and understand test cases when necessary
- CoolAlgorithm **Shell** - inspired by shells as we know them from terminals, a shell is what handles the interaction with the environment and the instance; it is the link between the I/O and the pure instance. One can also think of it as an "interpreter."
- **Directive** - directives are how an algorithm instance may choose to interact with a Shell. Upon performing some action on an algorithm's instance it SHOULD return a directive, which will instruct the Shell to "now do this thing, then that thing". It "directs the shell" to do the right thing, following the instances protocol.
- **Peer** - a peer is a known host that has the potential to be a cluster member; we can communicate with a peer by sending messages to it (and it may send messages to us), however a peer does not have an inherent cluster membership status, in order to have a status it must be (wrapped in a) *Member*
    - Peers SHOULD be Unique; meaning that if node dies and spawns again using the same host/port pair, we should consider it to be a _new peer_ rather than the same peer. This is usually solved by issuing some random UUID on node startup, and including this ID in any messaging the peer performs. 
- **Cluster Member** - a member of a cluster, meaning it is _known to be (or have been) part of the cluster_ and likely has some associated cluster state (e.g. alive or dead etc.)
    - It most likely is wrapping a Peer with additional information

## Tips

- When working with directives, never `return []`, always preallocate a directives array and `return directives`.
  - there are many situations where it is good to bail out early, but many operations have some form of "needs to always be done"
    in their directives. Using this pattern ensures you won't accidentally miss those directives. 
- When "should never happen", use `precondition`s with a lot of contextual information (including the entire instance state), 
  so users can provide you with a good crash report.

## Testing tips

Tests have `LogCapture` installed are able to capture all logs "per node" and later present them in a readable output if a test fails automatically.

If you need to investigate test logs without the test failing, you can enable them like so:

```swift
final class SWIMNIOClusteredTests: RealClusteredXCTestCase {

    override var alwaysPrintCaptureLogs: Bool {
        true
    }
    
    // ... 

}
```
