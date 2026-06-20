# Mojo concurrency & CSP — options for multi-threaded apps

**Date:** 2026-06-20 · **Context:** millfolio's Mojo services (notably the `flare`
single-threaded reactor) and whether CSP is a viable pattern without compiler
support. Synthesized from a deep-research pass (17 sources, 47 claims → 8
verified high-confidence; primary sources favored). State as of **Mojo
~v1.0.0b2, mid-2026** — Mojo moves fast; re-verify version-dated claims.

---

## Recommendations

1. **Don't build CSP (Go-style channels + green threads).** Green threads are
   *explicitly rejected* by Modular and can't be implemented as a library
   without runtime/compiler support. A channel API over real OS threads is
   buildable but heavyweight and unsafe (see below) — not worth it.
2. **Scale the server shared-nothing, thread-per-core via `SO_REUSEPORT`.** This
   is the realistic, proven-today path — and **`flare` already supports it**
   (per-worker `SO_REUSEPORT` listeners by default for `num_workers >= 2`). Run N
   independent single-threaded reactors pinned per core; no shared mutable state,
   so you sidestep Mojo's missing concurrency primitives entirely.
3. **Offload blocking work to a small OS-thread pool via FFI** (`libc`
   `pthread_create`) with hand-rolled mutex/condvar-guarded queues — only where a
   reactor would otherwise block. Keep shared state minimal and guard it
   manually (there is no `Send`/`Sync` safety yet).
4. **Don't invest in an async/channel runtime.** Native, zero-cost Rust-style
   `async`/`await` + `Send`/`Sync` is Modular's chosen direction; anything you
   hand-roll now will be superseded. Use `parallelize` only for **compute**
   (data-parallel) work, never for I/O concurrency.

---

## What exists today (Mojo ~v1.0.0b2, mid-2026)

- **Data-parallelism only, not concurrency.** `parallelize` / `sync_parallelize`
  (now `std.algorithm.backend.cpu.parallelize`) is a **CPU-only fork-join thread
  pool**: it runs `func(0)…func(n-1)` and **blocks until all complete**. It is a
  compute construct, not an I/O/coordination API.
- **Immature task model.** `sync_parallelize` **cannot propagate exceptions** across
  the parallel boundary — a raised error calls `abort()` and terminates the
  process (acknowledged TODO in Modular's own source).
- **An internal async runtime exists but isn't general-purpose.**
  `stdlib/runtime/asyncrt` has `create_task` / `Task` / `TaskGroup` (coroutine-based,
  `await`-able), but it is **device/GPU-oriented** (used by MAX), not a sanctioned
  user-facing concurrency/networking API. `_create_task` is intentionally private;
  `Coroutine` has known limits (not copyable).
- **No usable `async`/`await` surface.** Coroutine internals exist at the compiler
  level, but the **wrappers to await async functions are missing**. Chris Lattner
  (June 2025) confirmed async is still unfinished foundational work.
- **No built-in data-race safety.** Cross-thread sharing is on you. The structured
  async proposal (PR #3945) would add Rust-style `Send`/`Sync`, but it was an
  **open, unmerged proposal Jan–Nov 2025**.

## Is CSP a good fit / buildable without compiler support?

- **Go-style CSP (lightweight green-threaded processes + channels): NO.** M:N green
  threads need a runtime scheduler you can't add in library code, and Modular's
  async-design lead (Owen Hilyard) **explicitly ruled green threads out** — they
  can't be offered cleanly given Mojo's no-GC (GPU/FPGA targets) + borrow-checker
  (memory-safety) constraints. The chosen direction is zero-cost Rust-style async.
- **CSP-style channels over real OS threads: buildable, but a poor fit.** You can
  FFI `libc` `pthread_create` + mutex/condvar queues to get channels — but each
  "process" is a **heavyweight OS thread** (not a cheap goroutine), and **safety is
  manual** (no `Send`/`Sync`). A **thread-pool + work-queue / fork-join** model maps
  to what the language actually provides far better than CSP does.

## Networking server scaling (the millfolio case)

- **Feasible today:** multiple single-threaded reactors, **thread-** or
  **process-per-core via `SO_REUSEPORT`**, using `libc` pthreads over FFI.
  **Demonstrated in `flare`** (millfolio's own networking lib).
- **Not feasible in pure Mojo without FFI threading:** frameworks like *Lightbug*
  list "multiple simultaneous connections" / parallelization as **unimplemented**
  roadmap items, not features.

## Open questions (worth a forum check before committing)

- Does `asyncrt.TaskGroup`/`create_task` actually run user coroutines across CPU
  threads for I/O concurrency today, or is it device-dispatch / single-threaded only?
- Has any `Send`/`Sync` or structured-async work landed in nightly after Nov 2025?
- Is there a sanctioned stdlib OS-thread/pthread wrapper, or is FFI to
  `pthread_create` still the only path — and what are the borrow-checker
  ownership/lifetime rules for data captured by such threads?
- What scheduler backs `parallelize`/`asyncrt` (work-stealing vs blocking queue),
  and does `asyncrt` expose any usable cross-thread channel/queue primitive?

## References

Primary (Modular docs / forum / GitHub):

- Modular docs — `algorithm.parallelize`: https://docs.modular.com/mojo/stdlib/algorithm/functional/parallelize/
- Modular docs — `runtime/asyncrt`: https://docs.modular.com/mojo/stdlib/runtime/asyncrt/
- Modular docs — roadmap: https://docs.modular.com/mojo/roadmap/
- Modular docs — nightly changelog: https://docs.modular.com/mojo/nightly-changelog/
- Forum — "Concurrency support": https://forum.modular.com/t/concurrency-support/1616
- Forum — "How to write async code in Mojo": https://forum.modular.com/t/how-to-write-async-code-in-mojo/473
- Forum — "Green threads and runtime" (green-threads rejection): https://forum.modular.com/t/green-threads-and-runtime/576
- Forum — "Help with parallelize() (CPU only for now)": https://forum.modular.com/t/help-with-parallelize-cpu-only-for-now/1743
- GitHub — structured async proposal PR #3945: https://github.com/modular/modular/pull/3945
- GitHub — async issue #3906: https://github.com/modularml/mojo/issues/3906
- GitHub — `ehsanmok/flare` (SO_REUSEPORT thread-per-core): https://github.com/ehsanmok/flare
- GitHub — `Lightbug-HQ/lightbug_http` (pure-Mojo, no concurrent conns): https://github.com/Lightbug-HQ/lightbug_http
- GitHub — discussion #1745: https://github.com/modular/modular/discussions/1745
