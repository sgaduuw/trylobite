# trylobite

A small operating system for [detrytus](https://github.com/sgaduuw/detrytus),
a balanced-ternary computer. If you came here because of the Soviet
**Setun** (1958) or **Setun-70** (1970), the ternary computers built at
Moscow State University, this is software in their line: a multitasking
microkernel, a filesystem and a Unix-like shell, all counting in trits
of −1, 0 and +1.

It is **not** Setun software. detrytus is a modern design of its own (a
27-trit RISC machine with paging, interrupts and several cores), and
trylobite is an operating system for that machine, written in detrytus
assembly and run on the detrytus emulator. What it shares with the
Setun is the number system, and the question of what it is like to
build on it.

The name is trilobite with a tryte in it: an ancient creature of the
sea floor, living among the detritus.

## What it does

- **Processes** in their own paged address spaces, preempted by the
  timer, scheduled round-robin, on up to nine harts (cores) that can be
  plugged in and removed while it runs.
- **A microkernel.** The kernel keeps processes, memory, messages and
  descriptors, and nothing else. The console, the disk, the filesystem
  and pipes are each a server process; drivers run outside the kernel,
  which only passes their interrupts on.
- **Point-to-point messages:** `call`, `receive` and `reply`, with
  `copyin` and `copyout` to move a buffer between a server and its
  caller, and a **name registry** where servers announce themselves
  with a protocol version.
- **Descriptors as capabilities.** Each process has descriptors 0 to 8,
  inherited by its children. Only a server can hand one out, and the
  kernel routes `read` and `write` on it to that server, so a handle
  cannot be forged.
- **A Unix-shaped filesystem** on the block device: inodes, nested
  directories, a current directory per process, and a host tool to make
  disk images.
- **A shell** with built-ins (`ls`, `cat`, `cd`, `pwd`, `mkdir`, ...),
  programs run from `/bin` on the disk with arguments, `<`, `>` and
  `>>` redirection, `|` pipelines, quoting, and Ctrl-C to end a program.

## Ternary all the way down

Nothing here is binary underneath. A tryte is 9 trits and a word 27; a
character is a Unicode code point, one to a tryte. A few things look
different because of it:

- **−1 is an ordinary value**, so no call uses it to mean "failed".
  Failures are negative numbers with names (`E_NOENT`, `E_BADF`, ...),
  and code tests the sign or the name.
- **Flags are ternary digits.** `open`'s `O_CREAT`, `O_TRUNC` and
  `O_APPEND` are 3, 9 and 27, and add together the way Unix flags OR.
- **The kernel lives in negative addresses** and programs in positive
  ones, with page 0 unmapped between them; harts are numbered −4 to +4.
- **Code is dense.** The kernel and programs are assembled into
  compressed bundles (two short instructions to a word), and reach
  their globals relative to a global pointer.

## Try it

You need a Rust toolchain (1.88 or later) for the `detrytus` command;
this installs it at the commit [`detrytus.rev`](detrytus.rev) pins:

```bash
tools/install-detrytus
```

The demo boots the kernel on three harts and starts two processes that
pass messages:

```bash
detrytus run demo.s --ram-pages 40 --harts 3
```

```text
trylobite: version 0.1.0, a microkernel for detrytus, the balanced-ternary machine
trylobite: memory: 40 pages (787320 trytes), 31 free
trylobite: harts: 3
trylobite: irq0: interrupt controller, 3 sources, at page -13
trylobite: cons0: console, at page -1
trylobite: disk0: block device, no disk, at page -14
trylobite: net0: network device, no link, at page -16
trylobite: process table: 27 slots, 3 programs in the image
trylobite: starting init
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
trylobite: all processes exited after 9 timer interrupts
```

The shell build needs a disk. Make one with the programs from `bin/`
and a note, and give the shell a session to read:

```bash
printf 'Ternary computers count in trits.\n' > notes.txt
tools/fs.py new disk.img 100 notes.txt bin/*.s bin/*.tc
printf 'ls\ncat notes.txt\nfail\necho "one   arg" two\nhello | upper | wc\ncat notes.txt | upper > shout\ncat shout\nmkdir docs\ncd docs\npwd\nexit\n' > session.txt
detrytus run shell.s --ram-pages 81 --input session.txt --disk disk.img
```

```text
trylobite: version 0.1.0, a microkernel for detrytus, the balanced-ternary machine
trylobite: memory: 81 pages (1594323 trytes), 66 free
trylobite: harts: 1
trylobite: irq0: interrupt controller, 3 sources, at page -13
trylobite: cons0: console, at page -1
trylobite: disk0: block device, 100 blocks, at page -14
trylobite: net0: network device, no link, at page -16
trylobite: process table: 27 slots, 9 programs in the image
trylobite: starting init
init: started console, process 1
init: started pipe, process 2
init: started disk, process 3
init: started fs, process 4
init: starting sh
$ ls
34 notes.txt
bin/
$ cat notes.txt
Ternary computers count in trits.
$ fail
trylobite: process 6 exited with code 3
sh: exit 3
$ echo "one   arg" two
one   arg two
trylobite: process 7 exited with code 0
$ hello | upper | wc
trylobite: process 8 exited with code 0
trylobite: process 9 exited with code 0
1 5 38
trylobite: process 10 exited with code 0
$ cat notes.txt | upper > shout
trylobite: process 11 exited with code 0
$ cat shout
TERNARY COMPUTERS COUNT IN TRITS.
$ mkdir docs
$ cd docs
$ pwd
/docs
$ exit
trylobite: process 5 exited with code 0
trylobite: process 0 exited with code 0
trylobite: all processes exited after 132 timer interrupts
```

The lines starting `trylobite:` are the kernel's log. It opens with
the boot report, what the kernel found (memory, harts, devices, the
process table) before it starts init, and init then says each server
it starts, with its process number, and the shell. The disk image
keeps what the session wrote (`tools/fs.py cat disk.img shout`). Input
is read from the file up front, so a run is the same every time;
`detrytus debug shell.s ...` runs the same machine in the debugger,
where `input TEXT` types more by hand.

### A live session

Leave out `--input` and run it at a terminal, and the shell stays up
for you to type at:

```bash
detrytus run shell.s --ram-pages 81 --disk disk.img
```

```text
trylobite: version 0.1.0, a microkernel for detrytus, the balanced-ternary machine
trylobite: memory: 81 pages (1594323 trytes), 66 free
trylobite: harts: 1
trylobite: irq0: interrupt controller, 3 sources, at page -13
trylobite: cons0: console, at page -1
trylobite: disk0: block device, 100 blocks, at page -14
trylobite: net0: network device, no link, at page -16
trylobite: process table: 27 slots, 9 programs in the image
trylobite: starting init
init: started console, process 1
init: started pipe, process 2
init: started disk, process 3
init: started fs, process 4
init: starting sh
$ ls
34 notes.txt
bin/
$ echo typed live
typed live
trylobite: process 6 exited with code 0
$ spin
trylobite: process 7 killed
sh: killed
$ exit
trylobite: process 5 exited with code 0
trylobite: process 0 exited with code 0
trylobite: all processes exited after 4020 timer interrupts
```

Every key goes to the machine, as on a serial line: the shell echoes
what you type, backspace erases, and Ctrl-C ends the program the shell
waits for (here the runaway `spin`). `exit` or Ctrl-D (the end of
input) ends the shell, and init and the machine with it; Ctrl-] stops
the machine from outside. The terminal is put back as it was afterwards.

The programs on the disk are `hello`, `fail` (exits with 3), `spin`
(loops for ever, for Ctrl-C), `echo`, `upper` (standard input to output
in capitals) and `wc` (lines, words and code points), and system tools
as on Unix: `ps`, `top`, `kill`, `free`, `uptime`, `uname`, `dmesg`,
`sleep` and `df` (docs/kernel.md, System tools). `rhello`, `recho`,
`rfact` (a table of factorials up to 34!, with `println!` and 128-bit
integers) and `rmandel` (the Mandelbrot set in characters, in `f32`
floating point on detrytus's binary coprocessor) are written in Rust, translated from rustc's LLVM IR by `detrytus ll`
(detrytus docs/rust.md); building them needs `rustup component add
rust-src` and `rustup target add riscv32imac-unknown-none-elf`.

`--ram-pages` must match the `RAM_PAGES` the build declares (40 for
`demo.s`, 81 for `shell.s`). Without `--harts` the machine has one hart;
`--plug TIME:HART` and `--unplug TIME:HART` add one or ask one to go
while it runs, and the kernel reports each.

## How it fits together

```text
          ┌──▶ fsd (files) ──▶ diskd (disk) ──▶ block device
  sh ─────┼──▶ consd (console) ──▶ console
          └──▶ piped (pipes)

  every arrow is a call through the kernel: call / receive / reply
  init, program 0, starts the servers and then sh
```

| Process | Name | Job |
|---------|------|-----|
| `user/init.s` | | program 0: starts the servers below in order, then the shell |
| `user/sh.s` | | the shell |
| `user/fsd.s` | `fs` | the file server: paths, directories, open files, starting programs from the disk |
| `user/diskd.s` | `disk` | drives the block device, moving blocks by DMA |
| `user/consd.s` | `console` | drives the console: input, output, Ctrl-C for the foreground program |
| `user/piped.s` | `pipe` | pipes |

A client finds a server by name (`lookup("fs")`), and talks to it with
`call`, or through a descriptor the server gave it. The kernel copies no
file data and knows no filesystem; it schedules, maps memory, delivers
messages and interrupts, and keeps the descriptor tables.

[`docs/kernel.md`](docs/kernel.md) describes it in full: the memory map,
every system call, messages, names, drivers, descriptors, and each
server.

## Status

It works, and is growing. Everything is written in detrytus assembly:
there is no compiler for the machine yet, so there is no C library and
no ported software. The machine exists only as a specification and an
emulator, so trylobite has never run on hardware.

## Documentation

- [`docs/kernel.md`](docs/kernel.md): how the kernel and its servers
  work, and the system calls.
- [`docs/filesystem.md`](docs/filesystem.md): the on-disk format, the
  file server's protocol and how a program gets its arguments.
- [`CONTEXT.md`](CONTEXT.md): the decisions behind the design and why
  they were made.
- [`AGENTS.md`](AGENTS.md): how changes are made, and the conventions.
- The machine itself: detrytus's
  [README](https://github.com/sgaduuw/detrytus#readme) and its
  instruction set, [`docs/isa.md`](https://github.com/sgaduuw/detrytus/blob/main/docs/isa.md).

## Layout

| Path | Contents |
|------|----------|
| `include/layout.s` | every shared constant: memory map, system calls, error numbers, server protocols, the process record |
| `include/kernel.s` | firmware and kernel together, without programs: included by a build such as `demo.s` |
| `firmware/boot.s` | ring +1: delegate exceptions, enter the kernel |
| `kernel/entry.s` | kernel start: traps, process table, timer |
| `kernel/boot.s` | the boot report: what the kernel found, before init starts |
| `kernel/trap.s` | trap entry and exit, faults, kills, panics |
| `kernel/syscall.s` | the system calls |
| `kernel/sched.s` | round-robin scheduling, halting |
| `kernel/mm.s` | the page allocator, spawning and releasing processes |
| `kernel/wait.s` | `wait`, `kill`, and what happens to a process once it has ended |
| `kernel/ipc.s` | messages for servers: `call`, `receive`, `reply`, `copyin`, `copyout` |
| `kernel/names.s` | the server name registry: `register`, `lookup` |
| `kernel/desc.s` | descriptors: `read`, `write`, `iocall`, `close`, `dup2`, `give` |
| `kernel/devices.s` | device interrupts, and the drivers that take them |
| `kernel/harts.s` | starting the other harts, waking an idle one |
| `kernel/console.s` | the kernel's own log on the console, kept in a page for `dmesg` |
| `kernel/info.s` | the log and the machine, for system tools: `log`, `info` |
| `kernel/proc.s` | processes, for system tools: `proc`, `name`, `sleep` |
| `kernel/lock.s` | the kernel lock |
| `kernel/data.s` | the process table, buffers, messages |
| `kernel/pagetables.s` | the boot address space and the kernel's shared leaf table |
| `user/` | programs built into the kernel image: `demo-init`, `ping` and `pong` for the demo; `init`, `sh`, `pingpong` and the servers `fsd`, `diskd`, `consd` and `piped` for the shell |
| `bin/` | programs for the disk, each assembled on its own: `hello`, `fail`, `spin`, `echo`, `upper`, `wc`, the file tools `head`, `grep`, `cp`, `mv`, `touch`, and the system tools `ps`, `top`, `kill`, `free`, `uptime`, `uname`, `dmesg`, `sleep`, `df`; and in Rust, `rhello`, `recho`, `rfact` and `rmandel` |
| `demo.s` | the kernel for a 40-page machine, with init, ping and pong |
| `shell.s` | an 81-page machine starting the shell and its servers |
| `docs/` | the kernel and the filesystem, described |
| `tools/fs.py` | makes and reads filesystem images on the host |
| `tools/install-detrytus` | installs the pinned `detrytus` command |
| `tests/` | the tests, and a harness that builds the kernel with test programs |

## Development

The tests need [uv](https://docs.astral.sh/uv/). They build the kernel
with small test programs and check isolation, preemption, faults,
messages, every system call, the servers, the shell and running on
several harts; each runs on a machine with one hart and on one with
three, which takes a few minutes. They drive the `detrytus` binary
(`tests/kernel.py`): `DETRYTUS` names it, or else the one on the PATH is
used. These checks all run in CI:

```bash
uv sync
```

```bash
uv run pytest
```

```bash
uv run ruff check tests tools
```

```bash
uv run ruff format --check tests tools
```

## License

MIT, see [`LICENSE`](LICENSE).
