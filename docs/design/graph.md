---
title: Audio graph design
description: How fire:graph compiles a node graph into a plan and runs it on many threads, sample-accurately and without allocating.
---

The audio graph (`fire:graph`) connects [nodes](/reference/core/#node) into a
directed acyclic graph and processes it once per audio block, on the audio
thread plus a pool of workers. This page records the design and why it is so.
The [graph guide](/guides/graph/) shows how to use it.

The design follows Tracktion Engine's `tracktion_graph` (read for reference,
not translated) where that proved sound, and departs from it where our node
model or its known weak spots call for something else. Those departures are
marked **Unlike Tracktion**.

## Model

- **Nodes and connections.** A graph owns a set of nodes (`graph_add_node`)
  and connections between them:
  - `graph_connect(g, src, src_channel, dst, dst_channel)` routes one audio
    channel;
  - `graph_connect_events(g, src, dst)` routes events (notes, MIDI,
    parameters).

  Fan-out is free. Fan-in sums: several connections into one input channel
  are added; several event connections are merged in time order. Cycles are
  rejected when connecting.

  *Unlike Tracktion*, where each node owns its inputs, our `core.Node` knows
  nothing about other nodes. Topology lives in the graph only.
- **Graph I/O.** `GRAPH_INPUT` and `GRAPH_OUTPUT` are built-in endpoints:
  device input and output audio, the event input (MIDI from `fire:midi`, say)
  and the event output.
- **Handles.** `Node_Id` is a generational handle: removing a node invalidates
  its ID, and a stale ID is rejected rather than reaching another node.

## Edits and the plan

The graph has two halves:

- **Control side** (`Graph`): the node table and connections, edited only on
  the control thread. Edits accumulate until `graph_commit`.
- **Audio side** (`Plan`): an immutable, compiled description of one version
  of the graph. It holds the processing order, each node's input wiring
  (buffer pointers), dependency counts, consumer lists, delay lines and event
  buffers. `graph_commit` compiles a new plan on the control thread and
  publishes it; the audio thread picks it up at the start of its next block.

**Persistent nodes.** A node lives from `graph_add_node` (which prepares it
with the graph's sample rate and max block) to its removal. Its output buffers
and event buffer belong to the node's slot, not to a plan, so successive plans
share the same nodes, buffers and state. An edit never resets or reloads
anything. *Unlike Tracktion*, which rebuilds node objects and transfers state
by stable ID.

**Retiring plans.** When the audio thread switches plans it hands the old one
back through a queue. The control thread frees a retired plan once no worker
can still be reading it (each worker publishes the plan it is in). Only then
are nodes removed by that edit released and destroyed. Nothing is allocated or
freed on the audio thread.

## One block

`graph_process` (`[rt]`) runs one block of `frames ≤ max_block`:

1. Adopt a newly published plan, if any.
2. Deliver parameter changes (see below) and the graph's input audio and
   events.
3. Reset every node's dependency counter to its number of distinct upstream
   nodes. Queue the nodes with none.
4. Process nodes as they become ready (next section) until all are done.
5. Copy `GRAPH_OUTPUT`'s inputs to the caller's output buffers.

Processing a node:

- **Audio inputs.** An input channel with one source and no compensating
  delay reads the source's output buffer directly (no copy). Several sources
  are summed into the node's input scratch buffer, in connection order, so
  results do not depend on thread timing. No source means a silent buffer.
- **Event inputs.** The node's input events are its incoming event
  connections' outputs, plus parameter changes due this block, merged by
  offset. This is a stable merge in a fixed source order.
- **Process.** The node is called through `core.node_process`. Its output
  events go to its own fixed-capacity `Event_Writer`; overflow is counted, not
  allocated.

## Scheduling (multithreaded)

The scheduler is a dependency-counter scheme, the same idea as Tracktion's
lock-free player:

- Each plan node has an atomic counter of unfinished upstream nodes. When a
  node finishes, the thread decrements each consumer's counter (`acq_rel`).
  The thread that takes a counter to zero owns that consumer.
- It **keeps the first ready consumer for itself** (no queue round trip, so
  chains stay on one core) and pushes the rest onto a bounded lock-free MPMC
  queue.
- The audio thread is a worker too. The block ends when an atomic "nodes
  remaining" counter reaches zero. *Unlike Tracktion*, which waits for one
  root node: we also process nodes that do not reach the output, such as
  meters and sends to elsewhere.
- **Waking.** Idle workers spin briefly, then sleep on a semaphore.
  - *Unlike Tracktion*, which only signals at the start of a block, pushing
    ready work posts the semaphore when a worker is asleep. Mid-block
    parallelism therefore does not depend on spinning.
  - The audio thread never waits on an OS primitive; it only spins (and
    posts).
- **Threads.** The default is CPU cores − 1 workers, configurable from 0
  (single-threaded) up. Workers get realtime priority where the OS allows
  (`rt.set_realtime_priority`), set by each worker on itself. *Unlike
  Tracktion*, whose upgrade call targets the creating thread.
- **Memory ordering.** A node's writes to its buffers happen before its
  consumers' counter decrements (release), and the consumer's thread observes
  that decrement (acquire) before reading. The MPMC queue publishes with
  release and acquire.

Because summing and event merging run in a fixed order, a block's output is
**bit-identical for any thread count**. The tests check exactly that.

## Parameters

`graph_set_param(g, node, param, value, at)` is control thread only. It
queues `{node, param, value, at}` on a lock-free SPSC queue.

- At the start of each block the audio thread moves queued changes into each
  node's pending list, a fixed capacity per node, kept sorted by time.
- A change with `at` inside this block arrives as a `core.Param_Value` event
  at the exact offset.
- A change due later waits; `at = 0` or a time already past arrives at
  offset 0.

## Latency compensation

Nodes may report latency (`Node_VTable.latency`, in frames; nil means 0). When
compiling, the plan computes each node's *arrival latency*: the maximum over
its sources of the source's arrival latency plus the source's own latency.

- Every connection whose source arrives earlier than that maximum gets a delay
  line of the difference, for audio channels and events alike. So parallel
  paths that meet are aligned.
- `graph_latency(g)` reports the total latency at `GRAPH_OUTPUT`.
- Delay lines belong to the graph, keyed by connection, and are reused by the
  next plan when the delay is unchanged. Edits elsewhere in the graph
  therefore don't reset a delay line's contents (Tracktion keeps its delay
  lines across edits the same way).
- Compensation can be disabled per graph (`Graph_Settings`).

## Memory

| Owner | What |
|-------|------|
| Node slot (persistent) | output channels × max block; input scratch for summing; one `Event_Writer`; pending parameter list |
| Plan (per commit) | order, counters, consumer lists, input wiring, the MPMC ready queue, per-node merged-event buffers |
| Graph | delay lines, the parameter queue, the retired-plan queue, the thread pool |

Everything is allocated when nodes are added or a plan is compiled, on the
control thread. `graph_process` performs no allocation; the tests run it under
the trapping allocator.

## Testing

- **Topologies:** chains, fan-out, fan-in summing (known values), event
  routing, events delayed by compensation, cycles rejected, stale handles
  rejected.
- **Sample accuracy:** parameter changes land at exact offsets at any block
  split.
- **Latency:** a delayed path summed with an inverted direct path cancels
  exactly when compensation is on, and does not when it is off.
- **Threads:** random DAGs give bit-identical output at 0, 1, 3 and 7 workers.
- **Live edits:** one thread commits random graphs while another processes
  blocks: no crash, no allocation, every block complete.
- **The graph as a node:** `graph_node(g)` adapts a graph to `core.Node`, so
  `testkit.render` checks it like any node (finite output, no allocation,
  block-size invariance). It also lets graphs nest.
