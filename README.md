# trylobite

A microkernel for [detrytus](https://github.com/sgaduuw/detrytus), the
balanced-ternary machine. The name is trilobite with a tryte in it: an
ancient creature of the sea floor, living among the detritus.

It is written in detrytus assembly and runs on the detrytus emulator.

## Status

Milestone 2 works, and milestone 3 (below). Firmware hands every exception to the kernel and
starts it in ring 0. The kernel manages physical memory with a page
allocator, builds each process's page tables at run time, and starts
only `init`, which spawns the other programs. Processes run in their own
address spaces, are switched on the timer, pass messages through system
calls, and give their memory back when they exit.

The kernel runs on several harts at once: up to nine, detrytus harts
−4 to +4. Hart 0 boots and starts the others; processes run on whichever
hart is free, and a hart with nothing to do waits until another wakes it
through its mailbox. Harts can be plugged in and removed while it runs:
a new one joins in, and one the platform asks to go hands its process
back and stops. On three harts:

```text
trylobite: booting
init: starting pong and ping
ping: sending 1
trylobite: process 0 exited with code 0
ping: sending 2
pong: got 1
ping: sending 3
pong: got 2
trylobite: process 2 exited with code 0
pong: got 3
trylobite: process 1 exited with code 0
trylobite: all processes exited after 28 timer interrupts
```

Milestone 3 works too: the kernel can start a shell instead. `shell.s`
builds it with `sh` as program 0, which reads a line from the console,
runs the program it names, waits for it and says how it ended. Only
`pingpong` (the demo above, as a program) is built into the kernel
image; other programs are files in `/bin` on the disk, from `bin/`:
`hello`, `fail` (which exits with 3) and `spin` (a runaway that loops
for ever).
It also has the built-in `exit` and the file built-ins further down,
and stops at the end of its input. Ctrl-C ends the program the shell is
waiting for, and at the prompt drops the line typed so far:

```bash
tools/fs.py new disk.img 20 bin/*.s
printf 'hello\nfail\nexit\n' > session.txt
detrytus run shell.s --ram-pages 40 --input session.txt --disk disk.img
```

```text
trylobite: booting
$ hello
hello from a balanced-ternary machine
trylobite: process 1 exited with code 0
$ fail
trylobite: process 2 exited with code 3
sh: exit 3
$ exit
trylobite: process 0 exited with code 0
trylobite: all processes exited after 17 timer interrupts
```

Input is read from the file up front, so a run is the same every time;
the debugger's `input` command adds more by hand.

## Running it

Requires the `detrytus` command, built with a Rust toolchain (1.88 or
later): this installs it at the commit `detrytus.rev` pins.

```bash
tools/install-detrytus
```

```bash
detrytus run demo.s --ram-pages 40 --harts 3
```

```bash
detrytus debug demo.s --ram-pages 40 --harts 3
```

Without `--harts` the machine has one hart, and everything runs on it.
`--plug TIME:HART` and `--unplug TIME:HART` add a hart, or ask one to
go, when the machine's clock reaches TIME; the kernel reports each
(`trylobite: hart 1 joined`, `... left`). User code starts at about time
93000, once the kernel has booted:

```bash
detrytus run demo.s --ram-pages 40 --plug 150000:1 --unplug 200000:1
```

`--ram-pages` must match the `RAM_PAGES` the build declares (`demo.s`
says 40): the kernel hands out the pages it was told exist.

The tests need [uv](https://docs.astral.sh/uv/) as well. They build the
kernel with small test programs and check isolation, preemption,
faults, messages, process creation, memory reclamation, every system
call and running on several harts. Each runs on a machine with one hart
and on one with three, in about 10 seconds:

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
| `kernel/trap.s` | trap entry and exit, faults, kills, panics |
| `kernel/syscall.s` | the system calls |
| `kernel/sched.s` | round-robin scheduling, halting |
| `kernel/mm.s` | the page allocator, spawning and releasing processes |
| `kernel/wait.s` | `wait`, `kill`, and what happens to a process once it has ended |
| `kernel/input.s` | console input: the kernel's buffer, `getc`, the foreground process and Ctrl-C |
| `kernel/console.s` | kernel console output |
| `kernel/data.s` | the process table, buffers, messages |
| `kernel/pagetables.s` | the boot address space and the kernel's shared leaf table |
| `kernel/lock.s` | the kernel lock |
| `kernel/harts.s` | starting the other harts, waking an idle one |
| `include/kernel.s` | firmware and kernel together, without programs: included by a build such as `demo.s`, not run on its own |
| `user/` | programs built into the kernel image: `init` (program 0 of the demo), `ping` (1) and `pong` (2); `sh` (program 0 of the shell build) and `pingpong` (3) |
| `bin/` | programs for the disk, each assembled on its own: `hello`, `fail` and `spin` |
| `demo.s` | the kernel for a 40-page machine, with init, ping and pong |
| `shell.s` | the same machine, starting the shell, with sh, ping, pong and pingpong |
| `docs/filesystem.md` | the on-disk format of the filesystem |
| `tools/fs.py` | builds and reads filesystem images on the host |
| `tests/` | the tests, and a harness that builds the kernel with test programs |

## Memory

Every address space has three regions, one per mid-table entry:

| Region | Virtual pages | Contents |
|--------|---------------|----------|
| direct map | around −6561 | all of physical memory, kernel only: kernel virtual = physical − 3¹⁷ |
| kernel | −7 to −2 | the hart controller (its slots, and this hart's own), power off, console, kernel code, kernel data and stack; page 0 unmapped |
| process | 6561 (`V_USER`) | the process's code, data and stack |

The first two regions are shared by every address space. A new process
costs four pages: a root, a mid and a leaf table, and its own page,
into which `spawn` copies the program image loaded at boot, or
`spawnf` and `spawnw` a program file read from the disk. The kernel's
block cache takes up to 8 more pages, as it needs them.

| Physical page | Contents |
|---------------|----------|
| 0 | firmware |
| 1, 2 | kernel code; kernel data |
| 3, 4, 5 | the boot address space; the kernel's shared leaf table |
| 6 .. 5 + `NPROG` | program images 0 to `NPROG` − 1 (the demo has 3, the shell build 4) |
| 6 + `NPROG` .. `RAM_PAGES` | free pages, handed out by the allocator |

## System calls

`sys` with the call number in `a0` and arguments in `a1`, `a2` and
`a3`; the result comes back in `a0`.

| Number | Call | Result |
|--------|------|--------|
| 0 | `putc(c)` | 0 |
| 1 | `send(pid, value)` | 0 sent; −1 mailbox full; −2 no such process |
| 2 | `recv()` | the value; waits until one arrives |
| 3 | `yield()` | 0 |
| 4 | `exit(code)` | does not return |
| 5 | `getpid()` | this process's number |
| 6 | `puts(address)` | 0; −2 if the string is outside the process's page and block windows |
| 7 | `spawn(program)` | the new process's number; −1 no free slot, −2 no such program, −3 not enough memory |
| 8 | `hart()` | the number of the hart running the caller, −4 to +4 |
| 9 | `getc()` | the next code point of console input, waiting for one; negative once no more will come |
| 10 | `wait(pid)` | how child `pid` ended, once it has: `a0` 0 exited, 1 faulted or 2 killed, `a1` its exit code, trap cause, or 0 when killed; `a0` −2 if `pid` is not the caller's child |
| 11 | `bread(block, window)` | reads the block into block window `window`, 0 to 8: 0; −14 the disk failed, −2 no such block or window (or no disk), −3 no memory for the window |
| 12 | `bwrite(block, window)` | writes the block window to the block: as `bread` |
| 13 | `kill(pid)` | ends child `pid` before it runs again: 0; −2 if `pid` is not the caller's child |
| 14 | `foreground(pid)` | gives the console to child `pid`, so that Ctrl-C kills it, or to nobody with `NO_FOREGROUND` (−1): 0; −2 if `pid` is not the caller's child |
| 15 | `spawnw()` | starts the program file whose first block is in block window 0 (docs/filesystem.md): as `spawn`, with −2 when there is no window or no program in it |
| 16 | `open(path, flags)` | the lowest free file descriptor, for reading (`O_RDONLY`, the only flag yet) |
| 17 | `close(fd)` | 0 |
| 18 | `read(fd, buffer, n)` | how many trytes it copied, at most `n` and never past the end of the file or of a block; 0 at the end |
| 19 | `lseek(fd, offset, whence)` | the new position, from the start, where it is, or the end (`SEEK_SET`, `SEEK_CUR`, `SEEK_END`) |
| 20 | `readdir(fd, buffer)` | the inode of the directory's next entry, its name in the buffer; 0 at the end |
| 21 | `stat(path, buffer)` | 0, with the inode, type, links and size in four words at the buffer |
| 22 | `spawnf(path)` | starts the program file at the path: as `spawn` |
| 23 | `call(pid, w1, w2, w3, w4)` | sends four words to process `pid` and waits for its reply: the reply's four words in `a0` to `a3`; `a0` −2 if there is no such process or it ends first, −3 if `pid` is the caller |
| 24 | `receive()` | waits for a call: `a0` the caller, `a1` to `a4` its words; or `a0` `FROM_KERNEL` (−1), `a1` `NOTE_ENDED`, `a2` a process that ended |
| 25 | `reply(pid, w1, w2, w3, w4)` | ends the call of process `pid`, which this process received: 0; −2 if `pid` is not waiting for its reply |
| 26 | `copyin(pid, from, to, n)` | copies `n` trytes from `from` in process `pid`, whose call this process holds, to its own `to`: 0; −2 as `reply`, −12 if either range is not all mapped, when nothing is copied |
| 27 | `copyout(pid, from, to, n)` | copies `n` trytes from its own `from` to `to` in process `pid`: as `copyin` |

The file calls (16 to 22) fail with their own negative numbers, −4 to
−14: no filesystem, no such file, not a directory, a bad descriptor and
so on, each named in `include/layout.s` (`E_NOENT`, `E_BADF`, ...).

A call whose result is a status, or a value that is never negative,
reports failure with a negative number; `include/layout.s` names each
one (`E_FULL`, `E_NOPROC`, `GETC_NONE`, ...). Programs test the sign or
use those names, never a bare −1, which is an ordinary value on a
balanced machine. `recv` and `hart` can return negative values that are
not failures, and so can an exit code: `wait` returns it in `a1`, apart
from its status in `a0`. A process that ends keeps its slot until its
parent waits for it, or until the parent ends too.

`getc` sleeps until input comes: console input wakes the reader through
detrytus's interrupt controller, routed to hart 0, and the reader takes no
hart while it waits. `detrytus run --input FILE` closes the console behind
the file, so `getc` returns `GETC_NONE` at its end; in `detrytus debug`
the console stays open, `input TEXT` types more while a program waits, and
`eof` closes it.

Ctrl-C (code point 3) kills the console's **foreground process**, which
`foreground` names; the shell gives it each program it runs, and the
kernel takes the console back when that process ends. To see a Ctrl-C
while nobody reads, the kernel reads console input into a buffer of its
own, but only while a reader waits (as much as the readers need) or a
foreground process runs (all of it). Ctrl-C throws away what was typed
before it, as a terminal does; with no foreground process it is an
ordinary code point.

A block is one page, and a process's own page holds its code, so the disk
is reached through **block windows**: up to nine pages, window `k` at
`V_BLOCK + PAGE × k` just above the process's own, each made on the
first `bread` or `bwrite` through it and freed when the process ends.
`bread` fills one from a block and `bwrite` copies one to a block,
by DMA, sleeping until the disk interrupts; one command runs at a time and
the rest wait their turn. Run with `detrytus run --disk FILE --disk-blocks
N`; the file keeps what was written for the next run.

The disk can hold a filesystem, shaped like a Unix one: inodes, nested
directories with `.` and `..`, and files reached by path through file
descriptors (`docs/filesystem.md`). The kernel reads it through a cache
of blocks; a call that needs a block not in the cache sleeps until the
disk has read it, then runs again from the start. It is read-only for
now. `tools/fs.py` makes and changes filesystems on the host, and the
shell's built-ins `ls [DIR]` and `cat PATH` read them. A word the shell
does not know as a built-in or a program in the kernel image names a
program file: a path if it holds a slash, else a file in `/bin`, which
`spawnf` starts. `tools/fs.py` stores a `.s` or `.dti` file as a
program, in `/bin`:

```bash
tools/fs.py new disk.img 100 notes.txt bin/*.s
tools/fs.py mkdir disk.img docs
tools/fs.py put disk.img README.md docs
printf 'ls\nls bin\ncat docs/README.md\n' > session.txt
detrytus run shell.s --ram-pages 40 --input session.txt --disk disk.img
```

**Messages for servers.** A server is a process that serves others'
calls, as the filesystem will: `call` sends it four words and sleeps
until it replies with four of its own. The server takes calls one at a
time with `receive`, which says who called; while it holds a call, it
may copy to and from the caller's memory with `copyin` and `copyout`,
which is how a path or a buffer named in the call travels. A process
that has called `receive` is told of every process that ends, before
any later call, so it can forget what it kept for one; a call to a
process that ends fails. A server asleep in `receive` with nobody left
to call it does not keep the machine from powering off.

Process numbers are handed out round-robin, so a number is not reused
until the table of 6 wraps around.

## License

MIT, see [`LICENSE`](LICENSE).
