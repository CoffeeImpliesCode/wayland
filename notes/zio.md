# zio — async I/O framework for Zig

Research note. Date: 2026-08-07. Facts verified from GitHub API + raw README + local Zig 0.16.0 std source (see Sources).

## What it is

zio is an async runtime for Zig. It schedules lightweight coroutines onto a pool of OS threads. Network, file, and process I/O look blocking but are backed by non-blocking, event-driven OS APIs. It also implements the std library `std.Io` interface, so Zig 0.16+ code written against `std.Io` runs on zio unmodified (README, https://github.com/lalinsky/zio).

Repo home is NOT ziglibs/zio (404 on GitHub and codeberg). The real repo: https://github.com/lalinsky/zio. Homepage/docs (mkdocs): https://lalinsky.github.io/zio/. Identified via GitHub search: https://api.github.com/search/repositories?q=zio+zig (top hit).

## Facts (GitHub API + README, 2026-08-07)

- "Async I/O framework for Zig". Zig. Not archived. License: README badge says MIT; API reports `NOASSERTION` for the LICENSE file.
- Created 2025-09-16. Last push 2026-08-05 — 2 days before this note. Very active. 575 stars, 32 forks, 17 open issues. Topics: async, coroutines, epoll, fibers, green-threads, io, io-uring, iocp, kqueue, networking, poll, zig-package.
- main branch targets Zig 0.16.0 (README badge); `zig-0.17` branch for Zig master. Install: `zig fetch --save "git+https://github.com/lalinsky/zio#v0.17.0"`, then `b.dependency("zio", ...)` and `exe.root_module.addImport("zio", zio.module("zio"))`.
- Tests: `zig build test -Dtest-filter="foo" -Dbackend=epoll`. Examples: `zig build examples` (16: tcp/udp echo, http server/client, ntp, ping, parallel_grep, producer_consumer, signal, sleep, coro_demo, ev_demo, etc.).

## Architecture (three layers, each usable alone — confirmed from source tree)

1. `zio.ev` (`src/ev/`) — cross-platform, callback-based event loop. Backends in `src/ev/backends/`: `linux.zig` (io_uring + epoll fallback), `iocp.zig`, `kqueue.zig`, `poll.zig`, plus `blocking.zig` (thread-pool blocking ops). Same space as libuv or libxev. Usable without coroutines, or to embed zio I/O into an existing callback-driven loop. Example: blazio, a CPython asyncio loop built on zio.ev (https://github.com/lalinsky/blazio).
2. `zio.coro` (`src/coro/`) — stackful coroutine primitives (context switching, growable stacks), no I/O or scheduler attached.
3. `zio.Runtime` (`src/runtime.zig` + `src/io.zig`) — the full runtime. Schedules coroutines across executor threads, drives I/O through zio.ev, adds structured concurrency (task groups), cancellation, sync primitives, and the `std.Io` implementation (`io.zig`, 168 KB). Other modules: `net.zig` (TCP/UDP/Unix/raw IP), `fs.zig`, `dns/`, `select.zig` (wait on mixed ops), `process.zig`.

Runtime modes: single-threaded or multi-threaded. Multi-threaded default is work-stealing; pinned scheduling keeps a task on its spawn executor (no migration, no cross-executor sync), at the cost of no rebalancing.

## API surface

Two entry points, both shown in the README.

1. Native API — direct, more features, ties you to the zio runtime:

```zig
const rt = try zio.Runtime.init(std.heap.smp_allocator, .{});
defer rt.deinit();
const server = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080).listen(.{});
defer server.close();
var group: zio.Group = .init;                  // structured concurrency
defer group.cancel();
while (true) {
    const stream = try server.accept(.{});
    errdefer stream.close();
    try group.spawn(handleClient, .{stream});  // coroutine per connection
}
```

A handler reads lines via `stream.reader(&buf)` / `stream.writer(&buf)`, then `reader.interface.takeDelimiterInclusive('\n')` and `writer.interface.writeAll(line)` / `flush()` — see `examples/tcp_echo_server.zig` (which uses `pub fn main(init: std.process.Init)` with `init.gpa` instead of `smp_allocator`).

2. `std.Io` interface — recommended by the README for libraries; same server written portably. `rt.io()` yields the `Io` instance; every call takes it explicitly:

```zig
const rt = try zio.Runtime.init(std.heap.smp_allocator, .{});
defer rt.deinit();
const io = rt.io();
var server = try Io.net.IpAddress.parseIp4("127.0.0.1", 8080).listen(io, .{});
defer server.deinit(io);
var group: Io.Group = .init;
defer group.cancel(io);
while (true) {
    const stream = try server.accept(io);
    errdefer stream.close(io);
    try group.concurrent(io, handleClient, .{ io, stream });
}
```

The handler (`Io.Cancelable!void`, reading via `stream.reader(io, &buf)`) then compiles against any `std.Io` implementation — the portability argument for a future companion service (see Fit below).

3. `zio.ev` standalone — callback style: register fd interests on an `ev.Loop`, get completion callbacks, no coroutines. See `examples/ev_demo.zig`.

## Features (README list)

- Backends: Linux io_uring with automatic epoll fallback, Windows iocp, macOS/FreeBSD/NetBSD/OpenBSD kqueue, poll fallback elsewhere. Context switch for x86_64, x86, aarch64, arm, thumb, riscv32/64, loongarch64, powerpc64.
- Growable stacks via auto-extending virtual memory reservations. Fully async network I/O: TCP, UDP, Unix sockets, raw IP sockets.
- File I/O: fully async on Linux, partial (read/write) on Windows, blocking syscalls in a thread pool elsewhere. DNS: fully async on Linux/Windows/macOS, getaddrinfo in a thread pool elsewhere.
- Channels, cancellation, timeouts, task groups, waiting on a mix of ops.
- `debug_io` integration so `std.log` / `std.debug.print` do not block the loop.

## Name collision

Unrelated to Scala ZIO (https://zio.dev), a functional-effects library for Scala. Also unrelated to TheWaWaR/zio ("Zig io from tigerbeetle/src/io", a different project found in the same search). In Zig contexts, "zio" means lalinsky/zio.

## Alternatives

1. Zig std — verified against the local 0.16.0 std source (`/nix/store/...-zig-0.16.0/lib/zig/std`):
   - `std.posix.poll(fds: []pollfd, timeout: i32)` EXISTS (posix.zig:1003).
   - `std.posix.epoll_*` does NOT exist in 0.16.0; the raw syscall wrappers live in `std.os.linux` (`epoll_create1`, `epoll_ctl`, `epoll_wait` at os/linux.zig:2617-2633; `epoll_event` type at :6171). [Correction: an earlier draft said "std.posix.epoll_*"; that API name is wrong — it is `std.os.linux.epoll_*` on Linux.]
   - `std.Io` EXISTS (std.zig:19). `std.Io.Evented` maps to `Uring` on Linux when fiber context-switching code is compiled (`Io.zig:31`); `Io/Threaded.zig` is the thread-pool variant. The zio README FAQ calls `std.Io.Evented` "very far from finished", "missing essential functionality, if it even builds" — std.Io exists but its async backends are immature; zio is a competing, more complete `std.Io` implementation.
2. zig-libuv — https://github.com/mitchellh/zig-libuv. ARCHIVED (API `archived: true`), last push 2023-02-06, 20 stars, 8 forks. Dead; do not use. A maintained libuv-with-zig-build alternative exists: https://github.com/allyourcodebase/libuv (pushed 2026-06-19, not archived, 12 stars, 5 forks, ISC) but has low traction.
3. libxev — https://github.com/mitchellh/libxev. Cross-platform event loop (io_uring/epoll/kqueue/WASI), Zig and C API. 3554 stars, 181 forks, pushed 2026-07-17, not archived, MIT, 55 open issues — active. The main maintained "libuv-like" for Zig; zio README names it as the peer of zio.ev. Callback-based only, no coroutine runtime.
4. Hand-rolled epoll loop — `std.posix.poll` + `std.os.linux.epoll_*`. Zero deps, full control. The default for compositors.

## Fit for this compositor (zig, jj repo)

Core loop reality: wayland socket fd, libinput fd, DRM fds — a small fixed fd set driven by poll/epoll, handled synchronously, one thread. That is exactly what wlroots/Smithay-style compositors do, and it is not a workload that needs green threads or a coroutine scheduler. The zio layers would add a dependency and a foreign loop without improving the core loop. The compositor must own its loop because libinput and DRM want direct fd registration and frame timing control.

zio is genuinely useful only for companion services: HTTP status/control server, WebSocket remote control, network file watch, remote display forwarding, telemetry upload. Those are socket-heavy and benefit from async I/O. If that work happens, zio is the strongest candidate: it is the only option that is (a) actively maintained, (b) Zig 0.16-native, and (c) a drop-in `std.Io` implementation, so a future backend written against `std.Io` stays portable. libxev is the alternative if a pure callback loop is preferred; zig-libuv is dead.

## Verdict

DO NOT adopt zio for the compositor core loop. Keep the hand-rolled poll/epoll loop.

Consider zio later, only when network companion services become a requirement. Re-evaluate then. (Consistent with notes/README.md section (c).)

## Spike (if/when revisited) — three concrete steps

1. Day 0 — toolchain fit, in a scratch dir (NOT this repo): `zig fetch --save "git+https://github.com/lalinsky/zio#v0.17.0"` in a fresh project, then `zig build examples` and `zig build test -Dbackend=epoll`. Proves: fetches cleanly on this machine's Zig 0.16.0, tests pass, io_uring path works on this kernel (7.1.4-zen).
2. Day 1 — API stability: `src/zio_echo.zig` in this repo's future `src/`, standalone binary (NOT linked into the compositor): `Runtime.init` → `IpAddress.parseIp4` → `listen` → accept loop with one `group.spawn` per connection, echoing lines back (copy `examples/tcp_echo_server.zig`, then port it to the `std.Io` interface). Wire it as its own `exe` in `build.zig` so the compositor never imports zio. Assesses: README examples compile verbatim, docs quality, compile times, whether the `std.Io` layer is drop-in.
3. Day 2 (optional) — loop interop: `src/zio_ev_spike.zig` using only `zio.ev`, registering the compositor's real fds (wayland socket + libinput + DRM, bridged through an eventfd) in a scratch program, proving a foreign loop can coexist with the compositor's own loop. Abandon if integration friction exceeds one day. This is the risk item named in notes/README.md's open questions.

## Sources

- https://github.com/lalinsky/zio (README via raw.githubusercontent.com/lalinsky/zio/main/README.md)
- https://api.github.com/repos/lalinsky/zio (metadata: stars, dates, archived flag, topics)
- https://api.github.com/repos/lalinsky/zio/contents/ and .../contents/src, .../contents/src/ev/backends, .../contents/src/coro, .../contents/examples (source tree: confirms ev/coro/runtime layering and backend files)
- https://raw.githubusercontent.com/lalinsky/zio/main/examples/tcp_echo_server.zig
- https://api.github.com/search/repositories?q=zio+zig (repo identity; searched 2026-08-07)
- https://api.github.com/repos/mitchellh/zig-libuv (archived=true, pushed 2023-02-06)
- https://api.github.com/repos/mitchellh/libxev (pushed 2026-07-17, 3554 stars, 181 forks)
- https://api.github.com/repos/allyourcodebase/libuv (pushed 2026-06-19, 12 stars)
- Local Zig 0.16.0 std source: `std/posix.zig` (poll at :1003), `std/os/linux.zig` (epoll_create1/epoll_ctl/epoll_wait at :2617-2633), `std/std.zig` (Io at :19), `std/Io.zig` (Evented at :31)
- https://zio.dev (Scala ZIO, name-collision note)
