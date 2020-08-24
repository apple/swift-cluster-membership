## Sample applications

Use `swift run` to run the samples.

### SWIMNIOSampleCluster

This sample app runs a _single node_ per process, however it is prepared to be easily clustered up. 
This mode of operation is useful to manually suspend or kill processes and see those issues be picked up by the SWIM implementation.

Recommended way to run:

```bash
# cd swift-cluster-membership
> swift run --package-path Samples SWIMNIOSampleCluster --help
```

which uses [swift argument parser](https://github.com/apple/swift-argument-parser) list all the options the sample app has available.

An example invocation would be:

```bash
swift run --package-path Samples SWIMNIOSampleCluster --port 7001
```

which spawns a node on `127.0.0.1:7001`, to spawn another node to join it and form a two node cluster you can:

```bash
swift run --package-path Samples SWIMNIOSampleCluster --port 7002 --initial-contact-points 127.0.0.1:7001,127.0.0.1:8888

# you can list multiple peers as contact points like this:
swift run --package-path Samples SWIMNIOSampleCluster --port 7003 --initial-contact-points 127.0.0.1:7001,127.0.0.1:7002
``` 

Once the cluster is formed, you'll see messages logged by the `SWIMNIOSampleHandler` showing when nodes become alive or dead.

You can enable debug or trace level logging to inspect more of the details of what is going on internally in the nodes.

To see the failure detection in action, you can kill processes, or "suspend" them for a little while by doing 

```bash
# swift run --package-path Samples SWIMNIOSampleCluster --port 7001
<ctrl +z>
^Z
[1]  + 35002 suspended  swift run --package-path Samples SWIMNIOSampleCluster --port 7001 
$ fg %1 
```

to resume the node; This can be useful to poke around and manually get a feel about how the failure detection works.
You can also hook the systems up to a metrics dashboard to see the information propagate in real time (once it is instrumented using swift-metrics).
