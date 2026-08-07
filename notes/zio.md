# zio — async I/O framework for Zig

Research note. Date: 2026-08-07. Sources fetched directly via read tool (GitHub API + raw README).

## What it is

zio is an async runtime for Zig. It schedules lightweight coroutines onto a pool of OS threads. Network, file, and process I/O look blocking but are backed by non-blocking, event-driven OS APIs. It also implements the std library `std.Io` interface, so Zig 0.16+ code written against `std.Io` runs on zio unmodified. (Source: README, https://github.com/lalinsky/zio)

Repo home is NOT ziglibs/zio. That path is 404 on GitHub and on codeberg. The real repo:

- Repo: https://github.com/lalinsky/zio
- Homepage/docs: https://lalinsky.github.io/zio/
- Identified via GitHub search: https://api.github.com/search/repositories?q=zio+zig (top hit)

## Facts (from GitHub API + README, 2026-08-07)

- Description: "Async I/O framework for Zig". Language: Zig. License: MIT (README badge; API reports NOASSERTION for the license file).
- Created 2025-09-16. Last push 2026-08-05 — 2 days before this note. Very active.
- 575 stars, 32 forks, 17 open issues. Topics: async, coroutines, epoll, fibers, green-threads, io, io-uring, iocp, kqueue, networking, poll, zig-package.
- Zig version support: main branch targets Zig 0.16.0 (README badge). Separate `zig-0.17` branch for Zig master (0.17+).
- Install: `zig fetch --save "git+https://github.com/lalinsky/zio#v0.17.0"`, then `b.dependency("zio", ...)` and `exe.root_module.addImport("zio", zio.module("zio"))`.
- Tests: `zig build test -Dtest-filter="foo" -Dbackend=epoll` — backend selectable.

## Architecture (three layers, each usable alone)

1. `zio.ev` — cross-platform, callback-based event loop (io_uring / epoll / kqueue / iocp / poll). Same space as libuv or libxev. Usable without coroutines, or to embed zio I/O into an existing callback-driven loop. Example: blazio, a CPython asyncio loop built on zio.ev.
2. `zio.coro` — stackful coroutine primitives (context switching, growable stacks, manual scheduling). No I/O or scheduler attached.
3. `zio.Runtime` — the full runtime. Schedules coroutines across executor threads, drives I/O through zio.ev, adds structured concurrency (task groups), cancellation, sync primitives, and the `std.Io` implementation.

Runtime modes: single-threaded or multi-threaded. Multi-threaded default is work-stealing; pinned scheduling also exists (task stays on its spawn executor, no migration).

## Features (README list)

- Backends: Linux io_uring with automatic epoll fallback, Windows iocp, macOS/FreeBSD/NetBSD/OpenBSD kqueue, poll fallback elsewhere.
- Coroutine context switch for x86_64, x86, aarch64, arm, thumb, riscv32, riscv64, loongarch64, powerpc64.
- Growable stacks via auto-extending virtual memory reservations.
- Fully async network I/O: TCP, UDP, Unix sockets, raw IP sockets.
- File I/O: fully async on Linux, partial (read/write) on Windows, blocking syscalls in a thread pool elsewhere.
- DNS: fully async on Linux/Windows/macOS; getaddrinfo in a thread pool elsewhere.
- Channels, cancellation, timeouts, task groups, waiting on a mix of ops.
- `debug_io` integration so `std.log` / `std.debug.print` do not block the event loop.

## Name collision

Unrelated to Scala ZIO (https://zio.dev), a functional-effects library for Scala. Also unrelated to TheWaWaR/zio ("Zig io from tigerbeetle/src/io", a different project found in the same search). In Zig contexts, "zio" means lalinsky/zio.

## Alternatives

1. Zig std — `std.Io` (0.16+) and `std.posix` epoll/poll primitives. Docs: https://ziglang.org/documentation/0.16.0/std/#std.Io — [UNVERIFIED]: the docs page is a JS-rendered single-page app; fetched HTML contains only the shell. Secondary confirmation: zio README links it and its FAQ compares zio against `std.Io.Evented`, calling Evented "very far from finished", "missing essential functionality, if it even builds". Implies std.Io/Evented exists but is immature.
2. zig-libuv — https://github.com/mitchellh/zig-libuv. Found via https://api.github.com/search/repositories?q=zig-libuv. ARCHIVED, last push 2023-02-06, 20 stars. Dead; do not use. A maintained libuv-with-zig-build alternative exists: https://github.com/allyourcodebase/libuv (pushed 2026-06-19) but low traction (12 stars).
3. libxev — https://github.com/mitchellh/libxev. Cross-platform event loop (io_uring/epoll/kqueue/WASI), Zig and C API. 3554 stars, pushed 2026-07-17, MIT, active. The main maintained "libuv-like" for Zig; zio README names it as the peer of zio.ev. Callback-based only, no coroutine runtime.
4. Hand-rolled epoll loop — std.posix.epoll_* + poll. Zero deps, full control. The default for compositors.

## Fit for this compositor (zig, jj repo)

Core loop reality: wayland socket fd, libinput fd, DRM fds — a small fixed fd set driven by poll/epoll, handled synchronously, one thread. That is exactly what wlroots/Smithay-style compositors do, and it is not a workload that needs green threads or a coroutine scheduler. The zio layers would add a dependency and a foreign loop without improving the core loop. The compositor must own its loop because libinput and DRM want direct fd registration and frame timing control.

zio is genuinely useful only for companion services: HTTP status/control server, WebSocket remote control, network file watch, remote display forwarding, telemetry upload. Those are socket-heavy and benefit from async I/O. If that work happens, zio is the strongest candidate: it is the only option that is (a) actively maintained, (b) Zig 0.16-native, and (c) a drop-in `std.Io` implementation, so a future backend written against `std.Io` stays portable. libxev is the alternative if a pure callback loop is preferred; zig-libuv is dead.

## Verdict

DO NOT adopt zio for the compositor core loop. Keep the hand-rolled poll/epoll loop.

Consider zio later, only when network companion services become a requirement. Re-evaluate then.

## Minimal spike (if/when revisited)

1. Day 0: clone lalinsky/zio at the v0.17.0 tag, `zig build examples` and `zig build test -Dbackend=epoll` with the repo's zig 0.16.0. Confirms toolchain fit.
2. Day 1: standalone binary (NOT linked into the compositor) — a WebSocket/HTTP echo server on zio.Runtime against `std.Io`. Assesses API stability, docs quality, compile times.
3. Day 2 (optional): embed `zio.ev` in a scratch program that registers the compositor's real fds (wayland socket + libinput + DRM via eventfd bridge) to prove loop interop. Abandon if integration friction exceeds one day.

## Sources

- https://github.com/lalinsky/zio (README, fetched via raw.githubusercontent.com/lalinsky/zio/main/README.md)
- https://api.github.com/search/repositories?q=zio+zig (repo identity; searched 2026-08-07)
- https://api.github.com/search/repositories?q=zig-libuv (zig-libuv alternatives)
- https://api.github.com/repos/mitchellh/libxev (libxev activity)
- https://zio.dev (Scala ZIO, name-collision note)
- https://ziglang.org/documentation/0.16.0/std/#std.Io [UNVERIFIED — page is JS shell; see Alternatives §1]
