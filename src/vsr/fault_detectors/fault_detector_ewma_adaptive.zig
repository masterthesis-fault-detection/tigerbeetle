const std = @import("std");
const stdx = @import("stdx");
const assert = std.debug.assert;
const Instant = stdx.Instant;
const Duration = stdx.Duration;

const AF_MIN: u32 = 20; // 2.0
const AF_MAX: u32 = 30; // 3.0
const HEARTBEAT_INTERVAL: Duration = .ms(500);

fn alert_factor_x10_fn(ewma_interval: Duration, upper_bound: Duration, lower_bound: Duration) u32 {
    // Avoid float similar to yellow threshold calculation. The alert factor is scaled by 10 to avoid float.
    if (ewma_interval.ns >= upper_bound.ns) return AF_MIN;
    if (ewma_interval.ns <= lower_bound.ns) return AF_MAX;

    const range = upper_bound.ns - lower_bound.ns;
    const distance = ewma_interval.ns - lower_bound.ns;

    const delta = AF_MAX - AF_MIN;

    // Factor is represented ×10.
    return AF_MIN -
        @as(u32, @intCast(
            (@as(u64, @intCast(distance)) * delta) /
                @as(u64, @intCast(range))
        ));
}

interval_min: Duration,
interval_max: Duration,

signal_last: Instant,
interval_ewma: Duration,

const FaultDetector = @This();

pub fn init(options: struct {
    now: Instant,
    interval_min: Duration,
    interval_max: Duration,
}) FaultDetector {
    assert(options.interval_min.ns < options.interval_max.ns);
    // Sanity check and overflow protection for ewma.
    assert(options.interval_max.ns <= 10 * std.time.ns_per_hour);
    return .{
        .interval_min = options.interval_min,
        .interval_max = options.interval_max,

        .signal_last = options.now,
        .interval_ewma = options.interval_max,
    };
}
pub fn heartbeat(detector: *FaultDetector, now: Instant) void {
    detector.signal(now);
}

pub fn on_false_positive(detector: *FaultDetector, now: Instant) void {
    _ = detector;
    _ = now;
    // No-op. The adaptive fault detector does not need to do anything on false positive.
    return;
}

pub fn signal(detector: *FaultDetector, now: Instant) void {
    const past = detector.signal_last;
    assert(past.ns <= now.ns);
    const elapsed = past.elapsed(now)
        // Clamp first, then ewma_add, to avoid overflows.
        .clamp(detector.interval_min, detector.interval_max);

    detector.interval_ewma = ewma_add_duration(detector.interval_ewma, elapsed);
    detector.signal_last = now;
}

pub fn tardy(detector: *FaultDetector, now: Instant) enum { green, yellow, red } {
    const past = detector.signal_last;
    assert(past.ns <= now.ns);
    const elapsed = past.elapsed(now);

    if (elapsed.ns *| 2 <= detector.interval_ewma.ns * 3) { // interval <= 1.5 * interval_ewma
        return .green;
    }
    assert(elapsed.ns >= detector.interval_ewma.ns);
    const af = alert_factor_x10_fn(detector.interval_ewma, HEARTBEAT_INTERVAL, detector.interval_min);
    if (elapsed.ns *| 10 <= detector.interval_ewma.ns * af) {
        return .yellow;
    }
    assert(elapsed.ns > detector.interval_ewma.ns);
    return .red;
}

pub fn reset(detector: *FaultDetector, now: Instant) void {
    const past = detector.signal_last;
    assert(past.ns <= now.ns);
    detector.* = FaultDetector.init(.{
        .now = now,
        .interval_min = detector.interval_min,
        .interval_max = detector.interval_max,
    });
}

fn ewma_add_duration(old: Duration, new: Duration) Duration {
    return .{
        .ns = @divFloor((old.ns * 4) + new.ns, 5),
    };
}


test "alert factor: clamps to minimum above upper bound" {
    const upper = Duration.ms(500);
    const lower = Duration.ms(100);

    try std.testing.expectEqual(
        AF_MIN,
        alert_factor_x10_fn(upper, upper, lower),
    );

    try std.testing.expectEqual(
        AF_MIN,
        alert_factor_x10_fn(Duration.ms(600), upper, lower),
    );
}

test "alert factor: clamps to maximum below lower bound" {
    const upper = Duration.ms(500);
    const lower = Duration.ms(100);

    try std.testing.expectEqual(
        AF_MAX,
        alert_factor_x10_fn(lower, upper, lower),
    );

    try std.testing.expectEqual(
        AF_MAX,
        alert_factor_x10_fn(Duration.ms(50), upper, lower),
    );
}

test "alert factor: SHOULD FAIL" {
    const upper = Duration.ms(500);
    const lower = Duration.ms(100);

    try std.testing.expectEqual(
        AF_MIN,
        alert_factor_x10_fn(lower, upper, lower),
    );

    try std.testing.expectEqual(
        AF_MIN,
        alert_factor_x10_fn(Duration.ms(50), upper, lower),
    );
}

test "alert factor: interpolates linearly" {
    const upper = Duration.ms(500);
    const lower = Duration.ms(100);

    // 100ms -> 3.0
    try std.testing.expectEqual(
        30,
        alert_factor_x10_fn(Duration.ms(100), upper, lower),
    );

    // 200ms -> 2.65, represented as 26 due to truncation
    try std.testing.expectEqual(
        26,
        alert_factor_x10_fn(Duration.ms(200), upper, lower),
    );

    // 300ms -> 2.3
    try std.testing.expectEqual(
        23,
        alert_factor_x10_fn(Duration.ms(300), upper, lower),
    );

    // 400ms -> 1.95, represented as 19 due to truncation
    try std.testing.expectEqual(
        19,
        alert_factor_x10_fn(Duration.ms(400), upper, lower),
    );

    // 500ms -> 1.6
    try std.testing.expectEqual(
        16,
        alert_factor_x10_fn(Duration.ms(500), upper, lower),
    );
}