# bun-epoll-timer-spin-repro

Reproduces a Bun 1.3.14 bug where a 1 ms self-rescheduling timer chain busy-spins a full CPU core
on Linux kernels without `epoll_pwait2` (older than 5.11), and shows how kafkajs 2.2.4 creates exactly
such a chain on every broker connection.

Only Docker is required. Everything runs inside `oven/bun` images.

## Quick start

```shell
./run.sh
```

This runs a matrix of Bun `1.3.13`, `1.3.14` and `1.4.0`, each with `epoll_pwait2` available and with
it blocked, across three timer chains, and prints one line per case:

```txt
bun       epoll_pwait2   mode        iter/s   user%    sys%
1.3.13    available      timer1         330     1.2     1.4
1.3.13    available      timer10         84     1.4     0.8
1.3.13    available      kafkajs        327     2.2     0.9
1.3.13    blocked        timer1         327     1.7     1.1
1.3.13    blocked        timer10         84     1.5     1.2
1.3.13    blocked        kafkajs        321     2.3     1.5
1.3.14    available      timer1         336     1.2     0.7
1.3.14    available      timer10         85       1     0.2
1.3.14    available      kafkajs        335     2.3     0.7
1.3.14    blocked        timer1         996      56    43.5
1.3.14    blocked        timer10         92       2     0.7
1.3.14    blocked        kafkajs        993    62.9    36.6
1.4.0     available      timer1         334     1.3     1.6
1.4.0     available      timer10         86     0.8     0.4
1.4.0     available      kafkajs        337       2     1.3
1.4.0     blocked        timer1         338       1     1.1
1.4.0     blocked        timer10         85     0.7     0.5
1.4.0     blocked        kafkajs        334     1.3     1.1
```

Only `1.3.14` with `epoll_pwait2` blocked burns a whole core (`user% + sys%` close to 100 on a
`--cpus=1` container). Every other combination stays at a few percent.

Environment overrides: `VERSIONS`, `MODES`, `SECONDS_PER_RUN` (see `run.sh`).

## Modes

`spin.ts` starts one of three timer chains, then measures timer frequency and CPU usage over a window:

| mode | what it runs |
| --- | --- |
| `timer1` | `setTimeout(fn, 1)` that re-arms itself inside its own callback |
| `timer10` | the same chain with a 10 ms delay (control) |
| `kafkajs` | the real `RequestQueue` from kafkajs 2.2.4, driven by one `checkPendingRequests()` call, no broker needed |

Run a single case by hand:

```shell
bun spin.ts timer1 5
docker run --rm --cpus=1 --security-opt seccomp=./seccomp-no-epoll_pwait2.json \
  -v "$PWD":/app -w /app oven/bun:1.3.14 bun spin.ts kafkajs 5
```

## What is going on

Two independent defects line up:

1. **kafkajs 2.2.4 re-arms a timer forever.** `RequestQueue.checkPendingRequests()` unconditionally
   calls `scheduleCheckPendingRequests()`, which schedules another `checkPendingRequests()` even when
   nothing is pending and the queue is not throttled. `throttledUntil` starts at `-1`, so the delay is
   a large negative number that runtimes clamp to 1 ms. The chain starts with the first response on a
   connection and only stops in `destroy()`, that is, when the connection closes. Upstream reports:
   [tulios/kafkajs#1556](https://github.com/tulios/kafkajs/issues/1556),
   [tulios/kafkajs#1704](https://github.com/tulios/kafkajs/issues/1704); unmerged fix
   [tulios/kafkajs#1572](https://github.com/tulios/kafkajs/pull/1572).
2. **Bun 1.3.14 truncates sub-millisecond epoll timeouts to 0.** Bun prefers `epoll_pwait2`, which
   takes a nanosecond `timespec`. On kernels older than 5.11 it falls back to `epoll_pwait`, converting
   the timeout with `tv_sec * 1000 + tv_nsec / 1000000`. After a 1 ms timer re-arms itself the remaining
   time is 0.9x ms, which becomes `epoll_pwait(..., 0)`, and the event loop spins until the deadline.
   Fixed by rounding up in [oven-sh/bun#34780](https://github.com/oven-sh/bun/pull/34780), shipped in
   Bun 1.4.0.

The fallback code already existed in 1.3.11 to 1.3.13, but those versions read timers off
`CLOCK_MONOTONIC_COARSE`, whose millisecond granularity never produced a sub-millisecond remainder.
[oven-sh/bun#29806](https://github.com/oven-sh/bun/pull/29806) (1.3.14) switched `timespec.now()` to a
nanosecond `rdtsc` based clock, which is why 1.3.14 is the only affected release.

The seccomp profile in this repo makes `epoll_pwait2` return `ENOSYS`, which sends Bun down the same
fallback path as a pre-5.11 kernel, so the bug reproduces on any modern host.

## Files

- `spin.ts`: the measurement script
- `run.sh`: the version x availability x mode matrix
- `seccomp-no-epoll_pwait2.json`: blocks `epoll_pwait2` with `ENOSYS`
- `package.json`: pins `kafkajs@2.2.4` for the `kafkajs` mode

## License

MIT
