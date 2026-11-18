# trylobite

A microkernel for [detrytus](https://github.com/sgaduuw/detrytus), the
balanced-ternary machine. The name is trilobite with a tryte in it: an
ancient creature of the sea floor, living among the detritus.

It is written in detrytus assembly and runs on the detrytus emulator.

## Status

Milestone 1 works. Firmware hands every exception to the kernel and
starts it in ring 0. The kernel runs two user processes, each in its own
address space, switches between them on the timer, and lets them pass
messages through system calls.

```text
trylobite: booting
ping: sending 1
ping: sending 2
ping: sending 3
pong: got 1
trylobite: process 0 exited with code 0
pong: got 2
pong: got 3
trylobite: process 1 exited with code 0
trylobite: all processes exited after 24 timer interrupts
```

## Running it

Requires [uv](https://docs.astral.sh/uv/), which also fetches detrytus.

```bash
uv sync
```

```bash
uv run detrytus run demo.s --ram-pages 20
```

```bash
uv run detrytus debug demo.s --ram-pages 20
```

`uv run pytest` runs the tests, which build the kernel with small test
programs and check isolation, preemption, faults, messages and every
system call.

## Layout

| Path | Contents |
|------|----------|
| `include/layout.s` | every shared constant: memory map, page-table flags, system calls, the process record |
| `firmware/boot.s` | ring +1: delegate exceptions, enter the kernel |
| `kernel/entry.s` | kernel start: traps, process table, timer |
| `kernel/trap.s` | trap entry and exit, faults, panics |
| `kernel/syscall.s` | the system calls |
| `kernel/sched.s` | round-robin scheduling, halting |
| `kernel/console.s` | kernel console output |
| `kernel/data.s` | the process table, buffers, messages |
| `kernel/pagetables.s` | each process's page tables, built at assembly time |
| `kernel.s` | firmware and kernel together, without user programs |
| `demo.s` | the kernel with `user/ping.s` and `user/pong.s` |
| `tests/` | the tests, and a harness that builds the kernel with test programs |

## Memory

| Virtual page | Contents |
|--------------|----------|
| −5 | power-off register (kernel only) |
| −4 | console (kernel only) |
| −3 | kernel code |
| −2 | kernel data and stack |
| 0 | unmapped, so null pointers fault |
| 1 | the process: code, data and stack |

Kernel pages are global and identical in every address space. Both
processes run at virtual page 1, backed by different physical pages.

## System calls

`sys` with the call number in `a0` and arguments in `a1` and `a2`; the
result comes back in `a0`.

| Number | Call | Result |
|--------|------|--------|
| 0 | `putc(c)` | 0 |
| 1 | `send(pid, value)` | 0 sent; −1 mailbox full; −2 no such process |
| 2 | `recv()` | the value; waits until one arrives |
| 3 | `yield()` | 0 |
| 4 | `exit(code)` | does not return |
| 5 | `getpid()` | this process's number |
| 6 | `puts(address)` | 0; −2 if the string is outside the process |

## License

MIT, see [`LICENSE`](LICENSE).
