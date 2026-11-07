# Sync event-driven vs. async/await protocol stacks

A harness for comparing the performance and ergonomics of two ways of structuring a
layered network stack in Swift, on identical wire protocols, applications and
(simulated) network. Nothing here depends on SwiftNetwork; it is a standalone package.

```
swift build -c release --disable-sandbox
.build/release/stack-bench                       # every scenario on every stack
.build/release/stack-bench --list
swift test --disable-sandbox                     # correctness of all stacks, all scenarios
```

## What is being compared

Both stacks are three protocol layers over a datagram link:

```
 application   (workload script; same messages, sizes and checks in both)
 TLV           type:u16 | length:u32 | value        one per stream
 mux           QUIC-like streams + credit flow control, 1200 byte packets
 network       in-memory link: bounded packet pools, one per direction
```

* **`SyncStack`** - layers are noncopyable structs. Calls go *down* synchronously and
  either succeed or report would-block; the mux appends `readable(stream)` /
  `writable(stream)` events to an inline queue when a would-block clears, and the
  endpoint's loop drains that queue and hands events to the application. Nothing
  below ever calls up, so no layer can be re-entered. Upper layers read eagerly,
  and when they run out of data tell the mux how many bytes they need before the
  next event (`waitForRead(atLeast:)`).
* **`AsyncStack`** - each layer `await`s the one below. A stream's application task
  does `await tlv.receive()` / `await tlv.send(...)`, which `await` the mux, which
  waits on a continuation resumed by a receive pump task (packets arriving, credit
  arriving) or a send pump task (send buffer drained). The mux is a class because it
  is shared between those tasks.
* **`AsyncActorStack`** - the same code written the idiomatic way, with the shared
  types isolated to a global actor whose executor is the run loop. Kept because it
  is a *negative result* (see below); it is much slower than `AsyncStack`.

Everything not specific to the control-flow model is shared in `StackCommon` so that
the stacks differ only in how they wait and wake: the wire codec, `LinearBuffer`
(stream buffers), `RingQueue`, the packet pool, `StreamCore` (all of one stream's
framing and flow-control arithmetic), and the workload.

## Wire protocol

Packets are at most 1200 bytes and have no header. The link is reliable and ordered, so
there are no packet numbers, offsets or retransmission; what is left of QUIC is the
multiplexing and flow control, which is what we want to stress.

```
packet          := frame*
STREAM          := 0x01 | stream:u32 | len:u16 | data[len]
STREAM_FIN      := 0x02 | stream:u32 | len:u16 | data[len]     (last data of the stream)
MAX_STREAM_DATA := 0x10 | stream:u32 | limit:u64               (absolute credit, bytes)
message (TLV)   := type:u16 | length:u32 | value[length]       (inside a stream's byte stream)
```

All integers are big endian. A packet carries frames for several streams; when more
than one stream is ready each contributes at most `Wire.streamQuantum` (400) bytes per
visit, round robin, so busy streams interleave inside a packet. Each stream has an
initial credit equal to the scenario's `window`; a receiver extends it
(MAX_STREAM_DATA) once the application has consumed half a window, so a slow reader
backs the sender up. The sender buffers up to `sendBuffer` bytes per stream; writes of
a whole message either fit or wait. The link has `linkPackets` buffers per direction;
when they are all in flight the sender waits for the receiver to release one.

## Fairness decisions

The goal is to compare control-flow models, not implementations, so:

* **Same algorithms, same data layout.** Both muxes use `StreamCore`, the same ready
  list, the same packet-fill loop, the same buffers. Packet counts and frames per
  packet match to within a fraction of a percent (see the table: `pkts`).
* **Zero-copy in both.** TLV messages are parsed in place out of the receive buffer
  and encoded in place into the send buffer. (An idiomatic async API would more likely
  hand back owned `Data`/`[UInt8]`; a possible extension.)
* **No hidden hops or locks.** Everything runs on one thread. The sync stack runs in a
  plain loop; the async stack runs on a custom single-threaded run loop with no lock,
  hand-rolled `UnsafeContinuation` waiters (not `AsyncStream`), and caller-owned
  buffers. Dynamic exclusivity checks are off for both (`-enforce-exclusivity=unchecked`),
  otherwise the class-based async stack pays access checks on every property.
* **Same batching.** Sync flushes packets at the end of each loop turn; async has a send
  pump task that runs after the writers have yielded. Both coalesce what has been
  written by then.
* **Same semantic for "send completes":** the message has been accepted into the
  stream's send buffer (it suspends if there is no room). Neither waits for the packet
  to reach the network.
* **Same verification**, applied to every message (`--verify none|headers|full`).
  `headers` checks type, length, sequence and stream; `full` also checks every byte.
  Verification is common cost and dilutes ratios; use `--verify none` to see the stack
  alone.

## Scenarios

`stack-bench --list`: `bulk` (16 KB messages, 1 stream), `small-msgs` (64 B, 1 stream),
`streams-16`, `streams-1000`, `pingpong-1` / `pingpong-100` (request/response, one
outstanding per stream), `pipelined-8` (8 outstanding), `mixed` (64 B with occasional
20 KB), `bidi-32` (both directions), `slow-reader` (receiver handles 4 messages per
turn, 16 KB windows), `tiny-window` (4 KB windows, constant credit stalls).

Options: `--scenario NAME` (repeatable), `--stack sync|async|async-actor|sync-async|all`,
`--iterations N`, `--scale F` (message count multiplier), `--verify`, and
`--repeat-seconds S` to loop one stack/scenario for profiling.

## Profiling

```
.build/release/stack-bench --stack async --scenario pingpong-1 --repeat-seconds 30 &
sample stack-bench 10 -file /tmp/async.txt                 # or Instruments / xctrace
xctrace record --template 'Time Profiler' --launch -- .build/release/stack-bench \
    --stack sync --scenario small-msgs --repeat-seconds 10
```

Counters reported per run: packets sent, and "wakeups" - events delivered upward in the
sync stack, task suspensions in the async stack (including link waits).

## Results

One run on an Apple silicon Mac, release build, 5 iterations, median, `--verify headers`.
The machine was not idle (load average ~7-11), so treat absolute numbers as noisy
and compare within a row. `ns/msg` is per application message.

| scenario     | sync ms | async ms | async-actor ms | async / sync | async-actor / sync |
|--------------|--------:|---------:|---------------:|-------------:|-------------------:|
| bulk         |    32.2 |     45.2 |          109.8 |        1.4x  |              3.4x  |
| small-msgs   |    14.1 |     38.9 |           71.6 |        2.8x  |              5.1x  |
| streams-16   |    21.2 |     47.8 |           72.7 |        2.3x  |              3.4x  |
| streams-1000 |    20.2 |     52.8 |          113.2 |        2.6x  |              5.6x  |
| pingpong-1   |     7.5 |     87.0 |         3882.6 |       11.6x  |            517x    |
| pingpong-100 |    15.3 |     78.5 |          285.6 |        5.1x  |             18.7x  |
| pipelined-8  |    13.4 |     38.5 |          158.7 |        2.9x  |             11.8x  |
| mixed        |    30.8 |     44.4 |           64.1 |        1.4x  |              2.1x  |
| bidi-32      |    76.4 |    131.9 |          185.1 |        1.7x  |              2.4x  |
| slow-reader  |    24.6 |     40.4 |          108.3 |        1.6x  |              4.4x  |
| tiny-window  |    20.2 |     51.0 |          583.2 |        2.5x  |             28.8x  |

## What the numbers say

**Where the time goes.** In the sync stack the cost of crossing a layer is a function
call, so a message costs tens of nanoseconds and the bulk case is memcpy-bound. In the
async stack every would-block becomes a suspension, a continuation resume and a job
enqueue/dequeue, measured at roughly 150-200 ns per wakeup in the best configuration.
`pingpong-1` has three wakeups per message and nothing to amortise them over, so it
shows the per-hop cost almost directly; `bulk` amortises each wakeup over many
messages and is only ~1.4x.

**The runtime, not the code, dominates the async profile.** Profiling `AsyncStack` shows
most time in `libswift_Concurrency` rather than in the stack: job enqueue/run, task
status record locking (the task-executor preference is a status record), and `os_signpost`
tracing checks (`concurrency::trace::*`, `os_signpost_enabled`, ~20-25% of samples in
`pingpong-1`). None of that is removable from user code.

**Isolation to a custom-executor actor is very expensive here (`async-actor`).** With the
shared types isolated to a global actor whose executor is our run loop, a continuation
resumed from within actor code is enqueued on the *global pool*, run there just long enough
to be switched back onto the actor, and re-enqueued - an off-thread wakeup per resume
(~19 us per message in `pingpong-1`). The fast `AsyncStack` therefore does *not* use actors: its types
are `@unchecked Sendable` classes, every task is spawned with
`Task(executorPreference: runLoop)`, and nothing is isolated. That removes the safety net
that actor isolation provides, and it is a real ergonomics cost of getting acceptable
performance. Giving the *actor-isolated* tasks a task-executor preference as well makes every
resume enqueue twice (~860 ns per hop), which is also worse. We did not find a
configuration that keeps actor isolation and avoids both costs.

**Ergonomics.** The async application is straight-line code per stream (`send`, `await`
responses, `finish`, `drain`); the sync application is a per-stream state machine
(`StreamProgress`) with explicit "blocked on write" / "owed a response" / deferred-turn
bookkeeping, and it must be re-entered correctly from three event kinds. The sync stack's
guarantees (no re-entrancy, no shared mutable state across tasks, no isolation
annotations) come for free from its structure; the async stack has to opt out of the
compiler's isolation checking to be fast. The async stack also needed a hand-rolled
executor and continuation waiters, and its zero-copy API (a message pointer valid only
until the caller next suspends) is a trap the sync API's "valid until the next receive"
rule does not have.

## Caveats and next steps

* Single threaded on both sides; no multi-core scaling, which is where async's
  work-stealing executors would otherwise matter.
* The "network" is an in-memory queue, so latency is zero and the link never loses or
  reorders. Real I/O (a socketpair or UDP loopback underneath the link) would add syscalls
  that are equal for both stacks and would shrink the ratios.
* Not yet measured: a third async variant using default executors/actors (what an app that
  doesn't customise executors gets), owned-buffer reads (`Data`) instead of zero-copy views,
  allocation counts per message, and instruction-level comparison with
  `xctrace` Counters.
* Timings above were taken on a loaded machine; rerun on a quiet one before drawing
  fine-grained conclusions.
