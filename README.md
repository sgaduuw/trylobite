# trylobite

A microkernel for [detrytus](https://github.com/sgaduuw/detrytus), the
balanced-ternary machine. The name is trilobite with a tryte in it: an
ancient creature of the sea floor, living among the detritus.

It is written in detrytus assembly and runs on the detrytus emulator.

## Status

Milestone 2 works. Firmware hands every exception to the kernel and
starts it in ring 0. The kernel manages physical memory with a page
allocator, builds each process's page tables at run time, and starts
only `init`, which spawns the other programs. Processes run in their own
address spaces, are switched on the timer, pass messages through system
calls, and give their memory back when they exit.

```text
trylobite: booting
init: starting pong and ping
trylobite: process 0 exited with code 0
ping: sending 1
ping: sending 2
pong: got 1
ping: sending 3
pong: got 2
trylobite: process 2 exited with code 0
pong: got 3
trylobite: process 1 exited with code 0
trylobite: all processes exited after 27 timer interrupts
```

## Running it

Requires the `detrytus` command, built with a Rust toolchain (1.88 or
later): this installs it at the commit `detrytus.rev` pins.

```bash
tools/install-detrytus
```

```bash
detrytus run demo.s --ram-pages 40
```

```bash
detrytus debug demo.s --ram-pages 40
```

`--ram-pages` must match the `RAM_PAGES` the build declares (`demo.s`
says 40): the kernel hands out the pages it was told exist.

The tests need [uv](https://docs.astral.sh/uv/) as well. They build the
kernel with small test programs and check isolation, preemption,
faults, messages, process creation, memory reclamation and every system
call, in about 2 seconds:

```bash
uv sync
```

```bash
uv run pytest
```

They drive the `detrytus` binary (`tests/kernel.py`): `DETRYTUS` names
it, or else the one on the PATH is used.

## Layout

| Path | Contents |
|------|----------|
| `include/layout.s` | every shared constant: memory map, page-table flags, system calls, the process record |
| `firmware/boot.s` | ring +1: delegate exceptions, enter the kernel |
| `kernel/entry.s` | kernel start: traps, process table, timer |
| `kernel/trap.s` | trap entry and exit, faults, panics |
| `kernel/syscall.s` | the system calls |
| `kernel/sched.s` | round-robin scheduling, halting |
| `kernel/mm.s` | the page allocator, spawning and releasing processes |
| `kernel/console.s` | kernel console output |
| `kernel/data.s` | the process table, buffers, messages |
| `kernel/pagetables.s` | the boot address space and the kernel's shared leaf table |
| `kernel.s` | firmware and kernel together, without programs |
| `user/` | `init` (program 0), `ping` (1) and `pong` (2) |
| `demo.s` | the kernel for a 40-page machine, with the three programs |
| `tests/` | the tests, and a harness that builds the kernel with test programs |

## Memory

Every address space has three regions, one per mid-table entry:

| Region | Virtual pages | Contents |
|--------|---------------|----------|
| direct map | around −6561 | all of physical memory, kernel only: kernel virtual = physical − 3¹⁷ |
| kernel | −5 to −2 | power off, console, kernel code, kernel data and stack; page 0 unmapped |
| process | 6561 (`V_USER`) | the process's code, data and stack |

The first two regions are shared by every address space. A new process
costs four pages: a root, a mid and a leaf table, and its own page,
into which `spawn` copies the program image loaded at boot.

| Physical page | Contents |
|---------------|----------|
| 0 | firmware |
| 1, 2 | kernel code; kernel data |
| 3, 4, 5 | the boot address space; the kernel's shared leaf table |
| 6, 7, 8 | program images 0, 1 and 2 |
| 9 .. `RAM_PAGES` | free pages, handed out by the allocator |

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
| 7 | `spawn(program)` | the new process's number; −1 no free slot, −2 no such program, −3 not enough memory |

Process numbers are handed out round-robin, so a number is not reused
until the table of 6 wraps around.

## License

MIT, see [`LICENSE`](LICENSE).
