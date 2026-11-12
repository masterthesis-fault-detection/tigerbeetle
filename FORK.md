# Thesis fork: adaptive failure detection

This fork of TigerBeetle is used in a master's thesis on failure detection. It changes how
replicas suspect the primary and adds the instrumentation needed to measure that detection in
VOPR and on AWS. Upstream TigerBeetle is documented in [README.md](README.md).

- **Base:** upstream commit `f0ddb6bcb`.
- **Main branch:** `feature/vopr-false-positive-stats`.
- **Isolation experiment:** `feedback-isolation-experiment`, see [Branches](#branches).

## Failure detector variants

The active variant is the file imported as `FaultDetector` in `src/vsr.zig`
(`@import("vsr/fault_detector.zig")` by default). To switch variants, point that import at another
file. All variants share the upstream EWMA of signal
inter-arrival times: green ≤ 1.5 × EWMA, yellow ≤ alert factor × EWMA, red (suspicion) beyond
that.

| File | Variant | Alert factor |
|------|---------|--------------|
| `src/vsr/fault_detector.zig` | **Feedback adaptive** (default) | Starts at `alert_factor_init`. It is raised by one step on each false suspicion and lowered by one step after `heartbeat_stable_duration` of stable heartbeats, staying within `[alert_factor_min, alert_factor_max]` |
| `src/vsr/fault_detectors/fault_detector_ewma_load_adaptive.zig` | **Load adaptive** | Interpolated linearly from the current EWMA: 3.0 at EWMA ≤ `interval_min` (high load) down to 2.0 at EWMA ≥ the 500 ms heartbeat interval (idle). No feedback |
| `src/vsr/fault_detectors/fault_detector_ewma.zig` | **Baseline**: upstream EWMA | Fixed at 3. The new hooks are no-ops |

Feedback-adaptive parameters (constants at the top of `fault_detector.zig`):

| Constant | Value | Meaning |
|----------|-------|---------|
| `alert_factor_step_denom` | 2 | Step size 1/2 |
| `alert_factor_min` / `alert_factor_max` / `alert_factor_init` | 2 / 3 / 3 | Bounds and start value |
| `heartbeat_stable_duration` | 5 s | Stable time before lowering the alert factor |
| `heartbeat_deviation_denom` | 10 | A heartbeat is stable if its gap is within 500 ms ± `interval_min` × alert factor / 10 |

The DST evaluation patches these constants and `interval_min`/`interval_max` in `replica.zig`
to build each configuration.

## Protocol change: `false_suspicion` message

The feedback loop needs to know when a suspicion was wrong. To tell it, a new command
`false_suspicion = 25` is added (`vsr.zig`, `message_header.zig`, `message_pool.zig`):

1. **Primary:** when a primary in `normal` status receives an `exit_view` from a backup, it
   replies once with `false_suspicion` (`replica.zig`, `send_false_suspicion`). It replies again
   only after that backup's exit-view vote has been cleared.
2. **Backup:** a backup in the same view accepts the reply only if it comes from the current
   primary. It then calls `FaultDetector.on_false_suspicion` (`on_false_suspicion`).

The message is advisory only. It doesn't count toward the exit-view quorum and doesn't change
view-change state.

Related `replica.zig` changes:
- Heartbeats call the new `FaultDetector.heartbeat()` instead of `signal()`, so the detector can
  judge heartbeat stability.
- `send_exit_view` logs its reason (`suspicion`, `exit_view_message_timeout` or
  `view_change_status_timeout`).

## VOPR metrics (`src/vopr.zig`)

Replicas emit `suspicion_raised` and `view_change_completed` events
(`ReplicaEvent` → `Cluster.callbacks.on_view_change_event`). VOPR classifies each suspicion:

- **True positive:** the suspected primary is unreachable from the suspecting replica. The
  failure time is the start of that unreachability episode.
- **False positive:** the suspected primary is still reachable.
- **Superseded:** a later view change started before this one completed.

At the end of each seed, VOPR prints a summary line that the DST evaluation parses, followed by
min/mean/median/p95/max statistics:

```
VOPR_METRICS seed=… total_vc=… tp=… fp=… superseded=… unresolved=… tp_ttr_mean_ticks=… tp_ttr_failure_mean_ticks=… fp_ttr_mean_ticks=…
```

The packet simulator delivers `false_suspicion` out-of-band, respecting only partition filters.
This way the extra message neither takes up link capacity nor uses PRNG draws, so a seed takes
the same trajectory with every detector variant.

## Client and timing changes (cloud E2E latency)

- `config.zig`: `rtt` lowered from 300 ms to 100 ms, so the first request timeout is 200 ms.
- `vsr/client.zig`: a new option `request_timeout_retry_interval_ticks` retries at a fixed interval
  (`Timeout.backoff_fixed`) instead of with exponential backoff.
- `tb_client/context.zig`: the C client, and with it the Python client, retries every tick
  (10 ms) after the first timeout. That way, end-to-end latency tracks how long the cluster is
  unavailable, not the backoff.

## Branches

| Branch | Purpose |
|--------|---------|
| `feature/vopr-false-positive-stats` | All changes above |
| `feedback-isolation-experiment` | Variant for the isolation experiment, branched before the client retry fix. It changes three things: `alert_factor_init = 2`, `heartbeat_stable_duration = 50 s`, and after a view change beyond view 1 `reset` restarts at `alert_factor_max` |

## Building

```bash
./zig/zig build vopr:build             # VOPR with the active detector -> zig-out/bin/vopr
./zig/zig build -Drelease               # tigerbeetle binary for the cloud benchmarks
./zig/zig build clients:python -Drelease
```
