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
  descriptors, and nothing else. The console, the disk, the filesystem,
  pipes and the network are each a server process; drivers run outside the kernel,
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
- **A network stack:** a driver for the network device and an IP
  server that speaks ARP, ICMP echo, UDP and TCP, so two machines
  linked over UDP can `ping` each other, pass datagrams and hold TCP
  connections with `nc`.

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

You need a Rust toolchain (1.97 or later) for the `detrytus` command;
this installs it at the commit [`detrytus.rev`](detrytus.rev) pins:

```bash
tools/install-detrytus
```

Part of the kernel is Rust, which needs the same toolchain with
`rust-src` and the `riscv32imac-unknown-none-elf` target (`rustup
component add rust-src`, `rustup target add
riscv32imac-unknown-none-elf`). Build it once, and again after
changing it:

```bash
make kernel
```

The demo boots the kernel on three harts and starts two processes that
pass messages:

```bash
detrytus run demo.s --ram-pages 40 --harts 3
```

```text
trylobite: version 0.1.0, a microkernel for detrytus, the balanced-ternary machine
trylobite: memory: 40 pages (787320 trytes), 29 free
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

The shell build boots from a disk. `make` builds `disk.img`, 100
blocks with the kernel in its boot blocks and every program of `bin/`
(assembly, Trice and Rust) in `/bin`; add a note to it and give the
shell a session to read:

```bash
make
printf 'Ternary computers count in trits.\n' > notes.txt
tools/fs.py put disk.img notes.txt
printf 'ls\ncat notes.txt\nfail\necho "one   arg" two\nhello | upper | wc\ncat notes.txt | upper > shout\ncat shout\nmkdir docs\ncd docs\npwd\nexit\n' > session.txt
detrytus run --input session.txt --disk disk.img
```

Given a disk and no program, detrytus' boot ROM reads the boot record
in block 0, loads the kernel's pages from the blocks it names and starts
the firmware (docs/filesystem.md, Block 0; detrytus platform.md, Booting
from a disk). `tools/fs.py boot disk.img shell.s` puts a rebuilt kernel
on a disk without touching its files. Naming the build instead,
`detrytus run shell.s --disk disk.img`, loads the same
kernel as a file and runs the same disk.

```text
trylobite: version 0.1.0, a microkernel for detrytus, the balanced-ternary machine
trylobite: memory: 59049 pages (1162261467 trytes), 59030 free
trylobite: harts: 1
trylobite: irq0: interrupt controller, 3 sources, at page -13
trylobite: cons0: console, at page -1
trylobite: disk0: block device, 100 blocks, at page -14
trylobite: net0: network device, no link, at page -16
trylobite: process table: 27 slots, 11 programs in the image
trylobite: starting init
init: started console, process 1
init: started disk, process 2
init: started fs, process 3
init: started pipe, process 4
init: started net, process 5
init: started ip, process 6
init: starting sh
$ ls
34 notes.txt
bin/
$ cat notes.txt
Ternary computers count in trits.
$ fail
trylobite: process 8 exited with code 3
sh: exit 3
$ echo "one   arg" two
one   arg two
trylobite: process 9 exited with code 0
$ hello | upper | wc
trylobite: process 10 exited with code 0
trylobite: process 11 exited with code 0
1 5 38
trylobite: process 12 exited with code 0
$ cat notes.txt | upper > shout
trylobite: process 13 exited with code 0
$ cat shout
TERNARY COMPUTERS COUNT IN TRITS.
$ mkdir docs
$ cd docs
$ pwd
/docs
$ exit
trylobite: process 7 exited with code 0
trylobite: process 0 exited with code 0
trylobite: all processes exited after 139 timer interrupts
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
detrytus run --disk disk.img
```

(`make run` does the same with `--net user`, the network below,
building `disk.img` first if a program changed; `make run NET=` leaves
the network out. A rebuilt disk starts afresh, without what earlier
sessions wrote to it. `make benchmark` times the emulator on a fixed
job, `rsort < words | tee sorted | rsort -r -u | wc` over 10,000 lines,
and prints the step count, which only changes if what the machine does
changes, and the steps a second; `BENCH=--no-jit` passes options on.)

```text
trylobite: version 0.1.0, a microkernel for detrytus, the balanced-ternary machine
trylobite: memory: 59049 pages (1162261467 trytes), 59030 free
trylobite: harts: 1
trylobite: irq0: interrupt controller, 3 sources, at page -13
trylobite: cons0: console, at page -1
trylobite: disk0: block device, 100 blocks, at page -14
trylobite: net0: network device, no link, at page -16
trylobite: process table: 27 slots, 11 programs in the image
trylobite: starting init
init: started console, process 1
init: started disk, process 2
init: started fs, process 3
init: started pipe, process 4
init: started net, process 5
init: started ip, process 6
init: starting sh
$ ls
34 notes.txt
bin/
$ echo typed live
typed live
trylobite: process 8 exited with code 0
$ spin
trylobite: process 9 killed
sh: killed
$ exit
trylobite: process 7 exited with code 0
trylobite: process 0 exited with code 0
trylobite: all processes exited after 4020 timer interrupts
```

Every key goes to the machine, as on a serial line: the shell echoes
what you type, backspace erases (there is no history or cursor
movement yet, so arrow keys do nothing), and Ctrl-C ends the program the shell
waits for (here the runaway `spin`). `exit` or Ctrl-D (the end of
input) ends the shell, and init and the machine with it; Ctrl-] stops
the machine from outside. The terminal is put back as it was afterwards.

### Two machines on a network

With `--net`, the machine has a network link, and the shell can `ping`.
Each machine boots as 10.0.0.2; give the second another Ethernet
address with `--mac`, and another IP address with `ifconfig`. Run both
live, so their clocks keep to real time, in two terminals, each on its
own copy of the disk:

```bash
cp disk.img a.img && cp disk.img b.img
```

```bash
detrytus run shell.s --disk a.img --net udp:127.0.0.1:9101,127.0.0.1:9102
```

```bash
detrytus run shell.s --disk b.img --net udp:127.0.0.1:9102,127.0.0.1:9101 --mac 02:00:00:00:00:02
```

```text
$ ifconfig 10.0.0.3/24
$ ifconfig
inet 10.0.0.3/24 gateway 10.0.0.1
$ ping 10.0.0.2
reply from 10.0.0.2: seq 1, 36213 ticks
reply from 10.0.0.2: seq 2, 35248 ticks
reply from 10.0.0.2: seq 3, 35046 ticks
$ ping 10.0.0.4 1
no reply from 10.0.0.4: seq 1
sh: exit 1
$ echo and back | nc -u 10.0.0.2 7
and back
$ echo over tcp | nc 10.0.0.2 7
over tcp
$ echo hello from B | nc 10.0.0.2 9000
```

Port 7 is the IP server's echo service, for UDP and TCP. The last line
goes over a TCP connection to the first machine, if it is listening
there:

```text
$ nc -l 9000
hello from B
```

(The kernel's `process N exited` lines are left out.) `--net loop`
instead hands every frame straight back, so one machine can ping its
own address.

### Out to the host's network

`--net user` puts the machine behind a gateway that detrytus plays at
10.0.0.1, the machine's default gateway, translating its traffic to
the host's own sockets: no root, no TAP device. 10.0.0.1 is also the
host, so a server on the host's 127.0.0.1 answers there, and a name
server at 10.0.0.3 answers names from the host's resolver:

```bash
detrytus run shell.s --disk disk.img --net user
```

```text
$ ping 10.0.0.1 1
reply from 10.0.0.1: seq 1, 13576 ticks
$ echo hello host | nc 10.0.0.1 9009
HELLO HOST
$ cat get | nc 10.0.0.1 8080 | head -n 1
HTTP/1.0 200 OK
$ host localhost
localhost has address 127.0.0.1
```

(Here the host runs a TCP server that answers in capitals on port
9009 and a web server on 8080, and `get` is a file holding an HTTP
request.) Other addresses are reached the same way; a ping past the
gateway needs a host that allows unprivileged ping sockets, or root.
`ping`, `nc` and `host` take a name wherever they take an address.

The programs on the disk are `hello`, `fail` (exits with 3), `spin`
(loops for ever, for Ctrl-C), `echo`, `upper` (standard input to output
in capitals) and `wc` (lines, words and code points), system tools
as on Unix: `ps`, `top`, `kill`, `free`, `uptime`, `uname`, `dmesg`,
`sleep`, `df` and `date` (docs/kernel.md, System tools), and `ping`,
`ifconfig`, `host` and `nc` for the network. `rhello`, `recho`,
`rfact` (a table of factorials up to 34!, with `println!` and 128-bit
integers), `rmandel` (the Mandelbrot set in characters, in `f32`
floating point on detrytus's binary coprocessor), `rsqrt` (square
roots printed with `{}`, a program of two blocks for core's float
formatting) and `rsort` (standard input's lines sorted, as Unix's
`sort`, in `Vec`s and `String`s on the heap) are written in Rust, and
so are `date`, `top`, `tee`, `xargs`, `fetch` and `httpd`, an HTTP/1.0 client and
server (`httpd -n 1 notes | fetch -` serves a file to itself), and `vi`, a
screen editor in the manner of Unix's (`vi notes`, then `:wq` to write and quit). They
are translated from rustc's LLVM IR by `detrytus ll` (detrytus
docs/rust.md) and built on trystd (`lib/rust/trystd`), the system
library: files, standard I/O, processes, sockets and the time of day with std's names,
over the kernel's calls, in Rust alone. Building them needs `rustup component add
rust-src` and `rustup target add riscv32imac-unknown-none-elf`.

The kernel asks the machine how much RAM it has (detrytus' RAM size
register), so `--ram-pages` can be anything from enough for the
programs (about 40 pages for `demo.s`, 81 for a few programs at a time
in `shell.s`) up to 101,695, the most its direct map reaches; boot
touches none of the free pages, so a large machine starts at once and
costs the emulator only the pages programs use. Without `--ram-pages`
detrytus gives the machine 59,049 pages, room for eighteen programs
with full heaps at once; `make run RAM_PAGES=N` picks another size. Without `--harts` the machine has one hart;
`--plug TIME:HART` and `--unplug TIME:HART` add one or ask one to go
while it runs, and the kernel reports each.

## How it fits together

```text
          ┌──▶ fsd (files) ──▶ diskd (disk) ──▶ block device
          ├──▶ consd (console) ──▶ console
  sh ─────┼──▶ piped (pipes)
          └──▶ ipd (ARP, ping, UDP, TCP) ──▶ netd (frames) ──▶ network device

  every arrow is a call through the kernel: call / receive / reply
  init, program 0, starts the servers, those /etc/init names, and then sh
```

| Process | Name | Job |
|---------|------|-----|
| `user/init.s` | | program 0: starts the console, disk and file servers, then the servers and programs `/etc/init` names, then the shell |
| `user/sh.s` | | the shell |
| `user/fsd.s` | `fs` | the file server: paths, directories, open files, starting programs from the disk |
| `user/diskd.s` | `disk` | drives the block device, moving blocks by DMA |
| `user/consd.s` | `console` | drives the console: input, output, Ctrl-C for the foreground program |
| `user/piped.s` | `pipe` | pipes |
| `user/netd.s` | `net` | drives the network device: Ethernet frames, moved by DMA |
| `user/ipd.s` | `ip` | IPv4: answers ARP and pings, sends pings for `bin/ping`, UDP, and TCP connections as descriptors |

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
| `firmware/boot.s` | ring +1, at the end of the kernel's last code page: delegate exceptions, enter the kernel; and the boot page's jump to it |
| `kernel/entry.s` | kernel start: traps, process table, timer |
| `kernel/trap.s` | trap entry and exit, faults, kills, panics |
| `kernel/syscall.s` | the system-call trap: the Rust picks the routine (`syscall.rs`), then resume, schedule or release |
| `kernel/sched.s` | round-robin scheduling (picking in Rust), idling, halting |
| `kernel/harts.s` | a hart leaving; starting harts, hot-plug and waking an idle one are Rust |
| `kernel/console.s` | the kernel's own log on the console, kept in a page for `dmesg` |
| `kernel/rust/trykern` | the kernel's Rust part, a crate with a module per subsystem (the boot report is its `boot`); `tools/kernel.py` builds it into `kernel/trykern.s` |
| `kernel/rt.s` | what the Rust part calls that Rust does not write: `abort`, `memcpy` (a word at a time where it can) and the rest |
| `kernel/lock.s` | the kernel lock |
| `kernel/data.s` | the process table, buffers, messages |
| `kernel/pagetables.s` | the boot address space and the kernel's shared leaf table |
| `user/` | programs built into the kernel image: `demo-init`, `ping` and `pong` for the demo; `init`, `sh`, `pingpong` and the servers `fsd`, `diskd`, `consd`, `piped`, `netd` and `ipd` for the shell |
| `bin/` | programs for the disk, each assembled on its own: `hello`, `fail`, `spin`, `echo`, `upper`, `wc`, the file tools `head`, `grep`, `cp`, `mv`, `touch`, the system tools `ps`, `kill`, `free`, `uptime`, `uname`, `dmesg`, `sleep`, `df`, and `ping`, `ifconfig`, `host` and `nc` for the network; and in Rust, `rhello`, `recho`, `rfact`, `rmandel`, `rsqrt`, `rsort`, `date`, `top`, `tee`, `xargs`, `fetch`, `httpd` and `vi` |
| `demo.s` | the kernel for a 40-page machine, with init, ping and pong |
| `shell.s` | an 81-page machine starting the shell and its servers |
| `docs/` | the kernel and the filesystem, described |
| `Makefile` | `make` builds `disk.img` with the kernel in its boot blocks and the programs of `bin/`, and the kernel's Rust part; `make run` boots it; `make benchmark` times the emulator |
| `tools/fs.py` | makes and reads filesystem images on the host |
| `tools/kernel.py` | builds the kernel's Rust part (`make kernel`) |
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
