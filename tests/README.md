# Squawk contract fixture source

These declarative cases have not been executed. They specify expectations for the actual SBS1Message parser and log_dawg producer; they are not a replacement implementation or a passing model test. No runner or new dependency is added.

A permitted remote validation environment must exercise the candidate parser/producer on every input, capture actual DogStatsD datagrams and check gauge/count types plus tags against these expectations. Retain numeric JSON/gauge compatibility, leading zeros in tags, invalid-field rejection, duplicate frame counts, no squawk carry between messages, and sparse frames without callsign. Check unrelated telemetry and the existing socket/service regressions separately.

For integrated acceptance, pass representative real receiver frames through the admitted collector, Agent and intake, then verify dashboard queries and per-object monitor validation against the correct host/device. Count aggregation and time-window behavior require native evidence. This does not authorize live telemetry, deployment or monitoring actions while the session mute and execution gates remain closed.
