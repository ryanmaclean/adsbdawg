# Tests

`nu --no-config-file tests/run.nu` runs, in order:

1. unit checks of the SBS-1 parser, metric producer, tag hygiene and active-aircraft window;
2. every case and sequence in `squawk-contract-fixtures.json` (parser squawk, JSON squawk,
   zero-padded tag, numeric gauge, repeated frames, no carry between frames);
3. a DogStatsD wire test: a fake dump1090 (`nc -l`) feeds `adsb.nu run`, a fake DogStatsD
   (`nc -u -l -k`) captures the datagrams, and the received metric lines must equal the
   in-process metrics line for line.

`--no-wire` skips step 3 (no `nc`, no sockets). The suite needs only Nushell 0.117 and
OpenBSD netcat; it does not talk to Datadog.
