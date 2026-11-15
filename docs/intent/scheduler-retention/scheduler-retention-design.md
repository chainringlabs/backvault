---
parent: high-level-design
prefix: SCHED
---

# scheduler-retention

## Context and Design Philosophy

scheduler-retention is the container's process 1: the `main` of the `backvault` service binary. The runtime image is distroless, with no shell and no cron, so the supervisor is the program itself. It has four jobs: install logging once, run a backup cycle on a fixed interval, prune old backup files once a day, and exit promptly and cleanly when Docker asks it to stop.

The design leans two ways:

- **The service outlives any one failure.** A backup cycle that fails, or even panics, is logged and the schedule continues. A vault that is briefly unreachable at 03:00 should not take the backup service down until someone notices.
- **A failed cycle is retried soon.** The newest backup is only as fresh as the last cycle that succeeded, so a failure is followed by another attempt after a few minutes, not after the full backup interval. The common case is a container that starts before its reverse proxy can route to the vault: the first cycle fails within seconds and the vault is reachable a minute later.
- **Shutdown is prompt.** Docker gives a container ten seconds after SIGTERM. The supervisor never sleeps for longer than one second at a time, so a stop request is honoured almost immediately when idle.

## Logging

After the `--version` check, the supervisor installs the process-wide `log` backend before anything else runs. The backend is a small hand-written `log::Log` implementation: each record is one line, `YYYY-MM-DDTHH:MM:SSZ LEVEL message`, written to stdout. Where `LOG_FILE` is set, the same lines are also appended to that file, which is created if absent. If the file cannot be opened, the failure is logged to stdout and the service continues with stdout alone; a logging problem must never stop backups. Every other segment emits through the facade and configures nothing.

## Interval Loop

```mermaid
flowchart TD
    A[start] --> L[install logger, register SIGTERM/SIGINT flag]
    L --> B[validate BACKUP_INTERVAL_HOURS and RETRY_INTERVAL_MINUTES]
    B -->|invalid| X[log error, exit 1]
    B --> C[run_backup]
    C --> D[record today's UTC date as last cleanup day]
    D --> E{shutdown requested?}
    E -->|yes| Z[log Shutdown complete, exit 0]
    E -->|no| W{last cycle succeeded?}
    W -->|yes| F[sleep backup interval in 1 s slices]
    W -->|no| R[log the retry, sleep retry interval in 1 s slices]
    R --> G
    F --> G{shutdown requested?}
    G -->|yes| Z
    G -->|no| H[run_backup]
    H --> I{UTC date changed?}
    I -->|yes| J[run_cleanup, record date]
    I -->|no| E
    J --> E
```

`backvault --version` prints the name and version and exits 0 before anything else happens; the image smoke test in CI relies on it, since the service never exits on its own. `BACKUP_INTERVAL_HOURS` defaults to 12 and must be an integer from 1 to 8760; anything else is fatal before the first backup. One backup runs immediately on startup, then the loop sleeps and runs again.

How long the loop sleeps depends on the cycle it has just run. After a cycle that wrote a backup it sleeps the full backup interval. After a cycle that failed or panicked it sleeps the retry interval, and it keeps doing so, one attempt per retry interval with no limit and no back-off, until a cycle succeeds; the backup interval is then counted from that success. The rule is the same for the startup cycle and for every later one, and it does not look at why the cycle failed. `RETRY_INTERVAL_MINUTES` defaults to 5 and must be an integer from 1 to 1440; anything else is fatal before the first backup, like the backup interval. A retry interval longer than the backup interval is capped at the backup interval, so a failure never makes the next attempt later than it would otherwise have been. Each retry is announced at INFO with the wait in seconds, directly after the cycle's ERROR line.

`run_backup` calls backup-cycle's `cycle::run` inside `std::panic::catch_unwind`, absorbs its outcome, and reports whether a backup was written: `Ok(path)` logs success with the path; `Err(CycleError)` logs the error at ERROR; a panic logs the panic payload at ERROR. None of these stop the loop.

The day-rollover cleanup check follows every cycle the loop runs, retries included, whether or not the cycle succeeded.

The loop is a `Supervisor` struct generic over a `CycleRunner` (production: `cycle::run`), a `Clock` (UTC date and time; the one trait definition, which backup-cycle also consumes for its filename timestamp), and a `Sleeper` (one-second slices), sharing an `Arc<AtomicBool>` shutdown flag with the signal handler. Tests substitute all four.

## Retention Cleanup

Cleanup is triggered by the calendar, not by a timer: after each backup cycle, if the current UTC date differs from the date recorded at the last cleanup (or at startup), `run_cleanup` runs once and the date is updated. With a 12-hour interval, cleanup therefore happens within one interval after midnight UTC, not at midnight.

`RETAIN_DAYS` defaults to 7. A value that is not a non-negative integer, or is 0, disables cleanup with an info log. A value above 3650 disables cleanup with an error log. Neither is fatal.

Before deleting anything, `run_cleanup` confines `BACKUP_DIR` (default `/app/backups`) with the same canonicalise-and-require-`/app`-prefix check the backup cycle applies before writing; the check is backup-cycle's `cycle::confine_to_app`. A directory outside `/app` logs an error and skips cleanup. It then deletes every entry that is a regular file, not a symlink, has the suffix `.enc` or `.enc.part` (an abandoned partial write), and has a modification time older than `RETAIN_DAYS × 86400` seconds. Other entries are left alone. If the directory does not exist, cleanup logs a warning and returns. The number of files removed is logged.

## Signals and Shutdown

SIGTERM and SIGINT set the shared atomic flag through `signal-hook`'s flag registration, which is async-signal-safe and does nothing else in the handler. The sleeper sleeps in slices of at most one second and returns as soon as the flag is set. The main loop checks the flag after sleeping and before each new cycle. A signal that arrives during a backup cycle does not interrupt it; the cycle finishes, the day-rollover cleanup check still runs, and then the loop exits. Shutdown logs `Shutdown complete` and the process ends with status 0.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
|----------|--------|------------------------|-----------|
| Supervisor implementation | The service binary's own `main` loop as PID 1 | Shell `entrypoint.sh` + cron; an init system such as `tini` or `supercronic`; a separate supervisor binary | The runtime image is shell-free and holds one executable; the loop is forty lines and needs nothing an init system provides. |
| Log backend | Hand-written `log::Log` writing stdout and optionally `LOG_FILE` | `env_logger`; `simplelog`; `tracing-subscriber` | One fixed line format and two sinks do not justify a logging framework's tree (tenet: *Small tree beats convenient crate*). |
| Unopenable `LOG_FILE` | Log to stdout and continue | Exit 1 | The file is a convenience; the backups are the point. |
| Scheduling model | Fixed interval in hours | Cron expression; fixed time of day | `[inferred]` Simplest to validate and reason about; `CRON_EXPRESSION` still appears in `.env-example` as a remnant. |
| Cleanup trigger | After the first backup on a new UTC calendar day | Separate timer or thread; cron | `[inferred]` Avoids a second timer in a single-threaded loop. Cost: cleanup latency of up to one interval after midnight. |
| Calendar | UTC | Container local time | A static image carries no timezone database, so local time is UTC in practice; saying so makes the behaviour the same on every host. |
| Failed-cycle policy | Log, then try again after a fixed retry interval (default 5 minutes) until a cycle succeeds; no back-off, no failure limit; panics are caught | Wait the full backup interval after a failure; a fixed delay before the startup cycle; exit on failure and let Docker restart; exponential back-off; a capped number of retries; retry only failures classed as transient; let a panic abort | A transient vault outage should cost minutes of backup freshness, not a whole interval, and should not stop future backups. A startup delay only covers the start-up race and has to guess how long the vault takes to become reachable. Classifying failures is fragile: a reverse proxy that has not yet loaded the vault's route answers 404, which is indistinguishable from a wrong `BW_SERVER`. A cap or back-off adds state for no benefit at one cheap request every few minutes. A bug in one cycle is the same from the operator's view as a failed cycle. Cost: a permanently broken configuration logs a failure, and makes one token request, every retry interval without surfacing a health signal. |
| Retry interval longer than the backup interval | Cap it at the backup interval | Reject the combination at startup; honour it as written | A failure should never postpone the next attempt; rejecting a harmless combination would turn a tuning mistake into a service that will not start. |
| Signal handling | `signal-hook` flag registration | Raw `libc` handlers; `ctrlc`; `tokio::signal` | The flag API is async-signal-safe by construction and is the smallest correct option without an async runtime. |
| Sleep granularity | 1 s slices | A single long sleep; condvar wake from the handler | `[inferred]` Keeps SIGTERM response under one second with nothing shared but an atomic. |
| Deletion rules | Regular, non-symlink `*.enc` and `*.enc.part` by mtime only, inside a confined directory | Delete by filename timestamp; delete anything older than N days | `[inferred]` Never follows symlinks or touches non-backup files that may share the mounted volume; the containment check is the same one the writer uses, so the two can never disagree. |
| Validation severity | Backup-interval and retry-interval errors fatal; retention errors disable cleanup | All fatal; all soft | `[inferred]` Without valid intervals there is no schedule to run; without valid retention the backups themselves are unaffected. |
| Dependency injection | `CycleRunner`, `Clock`, `Sleeper` traits and a shared flag | Call the cycle, clock, and `thread::sleep` directly | Every loop, signal, and retention spec becomes testable in milliseconds, which the previous untested design lacked. |

## Open Questions & Future Decisions

### Resolved
1. ✅ **Cleanup is confined to `/app`** by the same function the backup cycle uses.
2. ✅ **The supervisor is the binary**; no import path, no shell, lint and tests cover it like any other module.
3. ✅ **Logging is installed once, here.** `LOG_FILE` is this segment's variable.

### Deferred
1. **"Midnight" wording.** The README describes cleanup as happening at midnight; it happens after the first cycle of a new UTC day. The README changes when the Rust service lands.
2. **Health signal.** No heartbeat file, exit-on-N-failures, or `HEALTHCHECK`. Decide whether a stuck or always-failing service should be observable from outside the logs.
3. **Signal during a cycle.** The cycle runs to completion before shutdown. With a slow vault this can exceed Docker's default 10 s stop grace and result in SIGKILL mid-export; the `.part`-then-rename write in backup-cycle means a killed cycle leaves at most an abandoned `.part` file, never a truncated `.enc`. Decide whether to document a longer `stop_grace_period` in the Compose reference.

## Cascade Notes

- **backup-cycle**: supplies `cycle::run` and `CycleError`; shares the `/app` containment function.
- **delivery**: the image's entrypoint is this binary and its smoke test is `--version`; the Compose reference may gain `stop_grace_period`. The README's environment table lists `RETRY_INTERVAL_MINUTES` beside `BACKUP_INTERVAL_HOURS`.

## References

- `signal-hook`: https://docs.rs/signal-hook
- `log` facade: https://docs.rs/log
- Sibling segments: backup-cycle (the work each tick performs), delivery (the distroless base that motivates a shell-free supervisor)
- Docker stop grace period: https://docs.docker.com/reference/cli/docker/container/stop/
