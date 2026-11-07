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

## Links: polled memory queue vs. real signalling

`--link memory` (default) is an in-memory packet queue. It has no signalling: the sync
stack's driver loop polls it every turn, and the async stack's pumps hand packets to
each other directly. It isolates the cost of the layering itself.

`--link socket` connects the endpoints with a non-blocking `AF_UNIX`/`SOCK_DGRAM`
socketpair (a datagram socket that preserves boundaries and order and, unlike UDP
loopback, never drops: a full buffer makes `send` fail with `EAGAIN`, which is
real backpressure). Readiness is signalled by dispatch sources on a serial queue
(`FDWatcher`, shared by both stacks):

* **Sync:** a read source per endpoint runs one `turn` of that endpoint (drain the
  socket, deliver `readable`/`writable` events up, flush what the app wrote). A packet
  that hits `EAGAIN` stays in the transmit buffer and arms the endpoint's write source,
  whose handler retries and runs another turn. Nothing polls.
* **Async:** `receive()` tries `recv` and otherwise suspends on a continuation that the
  read source resumes; `allocate()` suspends while the last packet is stuck in a full
  socket, until the write source resumes it. Tasks run on the same serial dispatch
  queue as the sources, via the same run loop, drained after each source handler.
* `async-actor` supports the memory link only.

The `blocked(k)` column counts sends that found the socket full.

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

Options: `--link memory|socket` (see below), `--scenario NAME` (repeatable), `--stack sync|async|async-actor|sync-async|all`,
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

### Over datagram sockets (`--link socket`)

Same machine, 5 iterations, median, load average ~6. Each packet now costs a `send`,
a `recv` and a dispatch source wakeup in both stacks, so absolute times are 5-30x
higher and the stacks converge. Percentages are relative to sync.

```
              Metric (unit)             sync               async
bulk          Wall time (ms)           235.5         252.0 (+7%)
              Time/message (ns)     11,774.8      12,598.2 (+7%)
              Throughput (MB/s)        1,391         1,301 (-6%)
              Packets sent (k)         276.6         278.1 (+1%)
              Wakeups (k)                7.2        21.7 (+201%)

small-msgs    Wall time (ms)            59.0         85.5 (+45%)
              Time/message (ns)         59.0         85.5 (+45%)
              Throughput (MB/s)        1,085          748 (-31%)
              Packets sent (k)          59.1          59.1 (+0%)
              Wakeups (k)                1.5         4.6 (+207%)

streams-16    Wall time (ms)           101.8        147.6 (+45%)
              Time/message (ns)        127.3        184.4 (+45%)
              Throughput (MB/s)        1,006          694 (-31%)
              Packets sent (k)          91.0          91.0 (+0%)
              Wakeups (k)               37.6          40.0 (+6%)

streams-1000  Wall time (ms)            64.2         97.4 (+52%)
              Time/message (ns)        128.5        194.9 (+52%)
              Throughput (MB/s)          778          513 (-34%)
              Packets sent (k)          45.0          45.0 (+0%)
              Wakeups (k)              136.2         137.4 (+1%)

pingpong-1    Wall time (ms)           300.3        392.7 (+31%)
              Time/message (ns)      1,501.7      1,963.4 (+31%)
              Throughput (MB/s)           55           42 (-24%)
              Packets sent (k)         200.0         200.0 (+0%)
              Wakeups (k)              200.0       600.0 (+200%)

pingpong-100  Wall time (ms)            43.1       106.0 (+146%)
              Time/message (ns)        107.8       265.0 (+146%)
              Throughput (MB/s)          761          309 (-59%)
              Packets sent (k)          34.0          34.0 (+0%)
              Wakeups (k)              400.0         408.2 (+2%)

pipelined-8   Wall time (ms)            74.1        100.5 (+36%)
              Time/message (ns)        185.2        251.2 (+36%)
              Throughput (MB/s)        1,134          836 (-26%)
              Packets sent (k)          77.5          77.5 (+0%)
              Wakeups (k)               50.0         62.5 (+25%)

mixed         Wall time (ms)           149.9         163.4 (+9%)
              Time/message (ns)      1,171.0       1,276.9 (+9%)
              Throughput (MB/s)        1,119         1,026 (-8%)
              Packets sent (k)         142.9         142.9 (+0%)
              Wakeups (k)               21.5         25.3 (+18%)

bidi-32       Wall time (ms)           301.2        355.6 (+18%)
              Time/message (ns)        941.3      1,111.2 (+18%)
              Throughput (MB/s)        1,064          901 (-15%)
              Packets sent (k)         273.4         273.4 (+0%)
              Wakeups (k)              223.8         231.0 (+3%)

slow-reader   Wall time (ms)           129.9        154.1 (+19%)
              Time/message (ns)        811.7        962.9 (+19%)
              Throughput (MB/s)        1,232        1,039 (-16%)
              Packets sent (k)         138.3         138.8 (+0%)
              Wakeups (k)               28.7         44.0 (+53%)

tiny-window   Wall time (ms)           174.6        210.3 (+20%)
              Time/message (ns)      1,454.9      1,752.5 (+20%)
              Throughput (MB/s)        1,031          856 (-17%)
              Packets sent (k)         180.0         180.0 (+0%)
              Wakeups (k)              120.0        180.0 (+50%)
```

### CPU cycles and instructions

`stack-bench --cpu` reports CPU cycles and retired instructions for the same window as the
wall time, read from the kernel's per-process counters (`proc_pid_rusage`, `ri_cycles` /
`ri_instructions`, no root needed). They cover all threads of the process, so the dispatch
threads of the socket link are included. Effective clock was ~3.96 GHz throughout, so cycle
ratios track the wall-time ratios. Median of 5. Percentages relative to sync; IPC is
instructions per cycle.

In-memory link:

```
              Metric (unit)             sync                 async
bulk          Cycles (M)               139.8          187.0 (+34%)
              Instructions (M)         402.9          751.4 (+86%)
              Cycles/message         6,987.8        9,351.3 (+34%)
              Instr/message         20,146.7       37,568.9 (+86%)
              IPC                       2.88           4.02 (+40%)

small-msgs    Cycles (M)                57.0         161.3 (+183%)
              Instructions (M)         282.0       1,004.8 (+256%)
              Cycles/message            57.0         161.3 (+183%)
              Instr/message            282.0       1,004.8 (+256%)
              IPC                       4.95           6.23 (+26%)

streams-16    Cycles (M)                90.8         214.4 (+136%)
              Instructions (M)         382.0       1,167.2 (+206%)
              Cycles/message           113.4         268.0 (+136%)
              Instr/message            477.5       1,459.0 (+206%)
              IPC                       4.21           5.44 (+29%)

streams-1000  Cycles (M)                88.7         255.8 (+188%)
              Instructions (M)         244.6       1,154.7 (+372%)
              Cycles/message           177.4         511.6 (+188%)
              Instr/message            489.2       2,309.4 (+372%)
              IPC                       2.76           4.51 (+63%)

pingpong-1    Cycles (M)                30.7        490.1 (+1496%)
              Instructions (M)         224.6      2,893.2 (+1188%)
              Cycles/message           153.7      2,450.3 (+1494%)
              Instr/message          1,123.1     14,465.9 (+1188%)
              IPC                       7.31           5.90 (-19%)

pingpong-100  Cycles (M)                61.3         396.0 (+546%)
              Instructions (M)         396.3       2,379.0 (+500%)
              Cycles/message           153.3         989.9 (+546%)
              Instr/message            990.8       5,947.6 (+500%)
              IPC                       6.46            6.01 (-7%)

pipelined-8   Cycles (M)                54.2         167.9 (+210%)
              Instructions (M)         278.2         968.5 (+248%)
              Cycles/message           135.5         419.7 (+210%)
              Instr/message            695.5       2,421.4 (+248%)
              IPC                       5.13           5.77 (+12%)

mixed         Cycles (M)               148.5          204.2 (+38%)
              Instructions (M)         384.6          701.4 (+82%)
              Cycles/message         1,160.2        1,595.3 (+38%)
              Instr/message          3,004.3        5,479.4 (+82%)
              IPC                       2.59           3.43 (+32%)

bidi-32       Cycles (M)               350.4          634.1 (+81%)
              Instructions (M)         787.6       2,288.0 (+191%)
              Cycles/message         1,095.0        1,981.6 (+81%)
              Instr/message          2,461.1       7,149.9 (+191%)
              IPC                       2.25           3.61 (+60%)

slow-reader   Cycles (M)               100.1          180.6 (+80%)
              Instructions (M)         380.2         935.6 (+146%)
              Cycles/message           625.8        1,128.5 (+80%)
              Instr/message          2,376.4       5,847.7 (+146%)
              IPC                       3.80           5.18 (+36%)

tiny-window   Cycles (M)                80.5         244.4 (+204%)
              Instructions (M)         456.4       1,387.0 (+204%)
              Cycles/message           670.5       2,036.4 (+204%)
              Instr/message          3,803.2      11,558.5 (+204%)
              IPC                       5.67            5.68 (+0%)
```

Datagram socket link:

```
              Metric (unit)             sync                 async
bulk          Cycles (M)               941.8         1,015.2 (+8%)
              Instructions (M)       4,373.1         4,687.0 (+7%)
              Cycles/message        47,091.4        50,761.8 (+8%)
              Instr/message        218,653.4       234,347.7 (+7%)
              IPC                       4.64            4.62 (-0%)

small-msgs    Cycles (M)               234.1          345.2 (+47%)
              Instructions (M)       1,133.6        1,852.3 (+63%)
              Cycles/message           234.1          345.2 (+47%)
              Instr/message          1,133.6        1,852.3 (+63%)
              IPC                       4.84           5.37 (+11%)

streams-16    Cycles (M)               407.8          525.0 (+29%)
              Instructions (M)       1,684.1        2,386.6 (+42%)
              Cycles/message           509.7          656.3 (+29%)
              Instr/message          2,105.2        2,983.2 (+42%)
              IPC                       4.13           4.55 (+10%)

streams-1000  Cycles (M)               237.1          372.8 (+57%)
              Instructions (M)         889.4        1,640.4 (+84%)
              Cycles/message           474.2          745.5 (+57%)
              Instr/message          1,778.9        3,280.9 (+84%)
              IPC                       3.75           4.40 (+17%)

pingpong-1    Cycles (M)             1,201.0        1,576.7 (+31%)
              Instructions (M)       5,669.5        7,672.7 (+35%)
              Cycles/message         6,005.0        7,883.5 (+31%)
              Instr/message         28,347.5       38,363.7 (+35%)
              IPC                       4.72            4.87 (+3%)

pingpong-100  Cycles (M)               171.7         427.7 (+149%)
              Instructions (M)         899.4       2,423.6 (+169%)
              Cycles/message           429.2       1,069.2 (+149%)
              Instr/message          2,248.6       6,059.1 (+169%)
              IPC                       5.24            5.67 (+8%)

pipelined-8   Cycles (M)               293.2          400.7 (+37%)
              Instructions (M)       1,384.8        2,003.6 (+45%)
              Cycles/message           733.0        1,001.8 (+37%)
              Instr/message          3,462.0        5,009.0 (+45%)
              IPC                       4.72            5.00 (+6%)

mixed         Cycles (M)               612.9           667.6 (+9%)
              Instructions (M)       2,436.0        2,708.2 (+11%)
              Cycles/message         4,788.2         5,215.8 (+9%)
              Instr/message         19,031.0       21,158.1 (+11%)
              IPC                       3.97            4.06 (+2%)

bidi-32       Cycles (M)             1,198.3        1,437.7 (+20%)
              Instructions (M)       4,629.5        5,764.3 (+25%)
              Cycles/message         3,744.7        4,492.7 (+20%)
              Instr/message         14,467.1       18,013.4 (+25%)
              IPC                       3.86            4.01 (+4%)

slow-reader   Cycles (M)               515.7          619.9 (+20%)
              Instructions (M)       2,369.6        2,869.5 (+21%)
              Cycles/message         3,223.4        3,874.7 (+20%)
              Instr/message         14,810.2       17,934.2 (+21%)
              IPC                       4.59            4.63 (+1%)

tiny-window   Cycles (M)               697.6          847.6 (+22%)
              Instructions (M)       3,243.9        3,969.2 (+22%)
              Cycles/message         5,813.2        7,063.7 (+22%)
              Instr/message         27,032.7       33,076.6 (+22%)
              IPC                       4.65            4.68 (+1%)
```

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
* The memory link has zero latency and never loses or reorders; the socket link adds real
  syscalls and readiness signalling but is still same-process, lossless and
  single-queue (no real network, no packet loss, no UDP). With sockets the per-packet
  syscall cost is common to both stacks and shrinks the ratios (see the socket table).
* The socket link uses one serial dispatch queue for everything; a kqueue-driven loop
  would avoid dispatch's per-event overhead for both stacks.
* Not yet measured: a third async variant using default executors/actors (what an app that
  doesn't customise executors gets), owned-buffer reads (`Data`) instead of zero-copy views,
  allocation counts per message, and instruction-level comparison with
  `xctrace` Counters.
* Timings above were taken on a loaded machine; rerun on a quiet one before drawing
  fine-grained conclusions.
