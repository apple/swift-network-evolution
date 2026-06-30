# Socket Transfer Benchmark

SwiftNetwork benchmark for measuring the performance of round-trip transfers over the kernel-socket protocols — `SocketDatagramProtocol` (UDP) and `SocketStreamProtocol` (TCP) — on loopback.

## Usage of the Benchmark

To use this benchmark for performance measurements, make sure that you build it in release:
```
# Navigate into the SwiftNetwork directory and build everything in release:
% swift build -c release

# Navigate into the ./build/release directory and run the executable
./SocketTransfer
```
NOTE: Never run and measure this benchmark as a debug build; the performance information will not be valid.

## Command line arguments

General:
```
-proto udp|tcp  : Transport to use. Default: udp.
-tcp / -udp     : Shortcuts for -proto tcp / -proto udp.
-iterations N   : Number of transfers to perform. Default: 100.
-size N         : Size of each payload in bytes. Default: 1000.
-oneway         : One-way send mode (no echo). Measures pure write throughput.
-ip STRING      : Remote IP (IPv4 or IPv6) to send to. When set, runs a client-only
                  send loop instead of the in-process echo setup.
-port N         : Remote port (required with -ip).
-localport N    : Local source port to bind to. Default: 0 (ephemeral for TCP).
```

TCP-specific (applied when `-tcp` / `-proto tcp` is active):
```
-no-delay                : Disable Nagle's algorithm (TCP_NODELAY).
-keepalive               : Enable SO_KEEPALIVE with kernel defaults.
-keepalive-idle N        : TCP_KEEPIDLE / TCP_KEEPALIVE — idle seconds before the
                           first probe. Implies -keepalive.
-keepalive-interval N    : TCP_KEEPINTVL — seconds between probes. Implies -keepalive.
-keepalive-count N       : TCP_KEEPCNT — unacked probes before drop. Implies -keepalive.
```

Only the TCP options that actually translate through to `SocketStreamProtocolOptions` are exposed here. Other `TCP()` builder knobs (`noPush`, `maximumSegmentSize`, fast-open, etc.) currently no-op on the kernel-socket path and are deliberately omitted from this tool.

## Examples

```
# 1000 UDP echo round-trips, 1400-byte payloads:
./SocketTransfer -iterations 1000 -size 1400

# TCP echo with Nagle disabled:
./SocketTransfer -tcp -no-delay -iterations 1000 -size 1400

# TCP one-way send with keepalive tuned:
./SocketTransfer -tcp -oneway -keepalive -keepalive-idle 30 -keepalive-interval 5 -keepalive-count 3

# Send TCP to a remote listener:
./SocketTransfer -tcp -ip 127.0.0.1 -port 5555 -iterations 500 -size 2048
```
