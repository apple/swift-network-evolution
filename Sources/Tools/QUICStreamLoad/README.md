# QUIC Stream Load Benchmark

SwiftNetwork benchmark for measuring the performance of QUIC opening many streams on a connection.

## Usage of the Benchmark

To run this benchmark you will need SwiftTLS setup and installed.

To use this benchmark for performance measurements, make sure that you build it in release:
```
# Navigate into the SwiftNetwork directory and build everything in release:
% swift build -c release

# Navigate into the ./build/release directory and run the executable
./QUICStreamLoad
```

NOTE: Never run and measure this benchmark as a debug build the performance information will not be valid.

## Writing only while the stream has room

By default each stream writes its whole upload at once. With `-respect-room` it writes in chunks of
`-write-chunk-size` bytes (16 KB by default), asking the stream for its room before each chunk and
waiting to be told when it has none, as `EndpointFlow` does. Open many streams at once to leave the
connection's writers waiting for room together:

```
./QUICStreamLoad -respect-room -concurrent-streams 1000 -stream-count 2000 -upload-size 65536
```
