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
`hello`, `fail` (which exits with 3), `spin` (a runaway that loops
for ever), `echo` (says its arguments), and two filters for pipelines,
`upper` (standard input to output in capitals) and `wc` (counts lines,
words and code points of the files it is given, or of standard input).
It also has the built-in `exit` and the file built-ins further down,
and stops at the end of its input. Ctrl-C ends the program the shell is
waiting for, and at the prompt drops the line typed so far:

```bash
tools/fs.py new disk.img 20 bin/*.s
printf 'hello\nfail\nhello | upper | wc\nexit\n' > session.txt
detrytus run shell.s --ram-pages 81 --input session.txt --disk disk.img
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
| `kernel/console.s` | kernel console output: the kernel's log |
| `kernel/data.s` | the process table, buffers, messages |
| `kernel/pagetables.s` | the boot address space and the kernel's shared leaf table |
| `kernel/lock.s` | the kernel lock |
| `kernel/harts.s` | starting the other harts, waking an idle one |
| `kernel/ipc.s` | messages for servers: `call`, `receive`, `reply`, `copyin`, `copyout` |
| `kernel/desc.s` | descriptors: `read`, `write`, `iocall`, `close`, `dup2` and `give`, routed to servers, and the notice when a handle's last descriptor goes |
| `include/kernel.s` | firmware and kernel together, without programs: included by a build such as `demo.s`, not run on its own |
| `user/` | programs built into the kernel image: `init` (program 0 of the demo), `ping` (1) and `pong` (2); `sh` (program 0 of the shell build), `pingpong` (3), `fsd`, the file server (4), `diskd`, the disk server (5), `consd`, the console server (6), and `piped`, the pipe server (7) |
| `bin/` | programs for the disk, each assembled on its own: `hello`, `fail`, `spin`, `echo`, `upper` and `wc` |
| `demo.s` | the kernel for a 40-page machine, with init, ping and pong |
| `shell.s` | the same machine, starting the shell, with sh, ping, pong, pingpong, the file, disk, console and pipe servers |
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
`spawnw` a program file read from the disk. Block windows take up to
nine more, as a process asks for them; a driver also has its device's
registers mapped past them, at `V_DEVICE`.

| Physical page | Contents |
|---------------|----------|
| 0 | firmware |
| 1, 2 | kernel code; kernel data |
| 3, 4, 5 | the boot address space; the kernel's shared leaf table |
| 6 .. 5 + `NPROG` | program images 0 to `NPROG` − 1 (the demo has 3, the shell build 8) |
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
| 10 | `wait(pid)` | how child `pid` ended, once it has: `a0` 0 exited, 1 faulted or 2 killed, `a1` its exit code, trap cause, or 0 when killed; `a0` −2 if `pid` is not the caller's child |
| 13 | `kill(pid, for)` | ends `pid` before it runs again, a child of the caller when `for` is `FOR_SELF` (−1), or, for a driver, a child of process `for`: 0; 1 (`KILL_ENDED`) if it had ended already; −2 if `pid` is not that process's child, −21 `for` from a process that drives nothing |
| 15 | `spawnw(window, for, args, n)` | starts the program file whose first block is in block window `window` (docs/filesystem.md), as the caller's child when `for` is `FOR_SELF` (−1), or as the child of process `for`, whose call the caller holds, with the `n` trytes of arguments at `args` in that parent's memory (docs/filesystem.md, Program arguments): as `spawn`, with −2 when there is no window or no program in it, or `for` is not waiting for the caller, −10 (`E_INVAL`) for `n` below 0 or above `ARG_MAX`, −12 (`E_FAULT`) for arguments not all in the parent's memory |
| 16 | `close(fd)` | empties descriptor `fd`: 0; −8 if it names nothing |
| 17 | `give(pid, handle)` | puts the caller's `handle`, 0 to 26, in the lowest free descriptor of process `pid`, whose call the caller holds: the descriptor; −9 none free, −2 `pid` is not waiting for the caller, −10 no such handle |
| 18 | `dup2(fd, to)` | makes descriptor `to` a copy of `fd`, closing what `to` held: `to`; −8 if `fd` names nothing or `to` is not 0 to 8 |
| 19 | `iocall(fd, op, x, y)` | a call to the server descriptor `fd` names, with `op`, an `IO_` operation (negative), its handle, `x` and `y`: the server's answer; −8 if `fd` names nothing, −10 if `op` is not an `IO_` operation. Leaves `a1` to `a5` as `call` does |
| 20 | `read(fd, buffer, n)` | `iocall` with `IO_READ`: at least one and at most `n` trytes, 0 at the end |
| 21 | `write(fd, buffer, n)` | `iocall` with `IO_WRITE`: how many were written |
| 22 | `fdflags(fd, flags)` | sets descriptor `fd`'s flags: `FD_NOINHERIT` (1), a child does not get a copy, or 0: 0; −8 if `fd` names nothing, −10 another flag |
| 23 | `call(pid, w1, w2, w3, w4)` | sends four words to process `pid` and waits for its reply: the reply's four words in `a0` to `a3`; `a0` −2 if there is no such process or it ends first, −3 if `pid` is the caller, −10 if `w1` is negative (an `IO_` operation, which only a descriptor sends) |
| 24 | `receive()` | waits for a call: `a0` the caller, `a1` to `a4` its words; or `a0` `FROM_KERNEL` (−1) and `a1` `NOTE_ENDED` (0), `a2` a process that ended, or `a1` `NOTE_IRQ` (1), `a2` a device source the caller drives that interrupted, or `a1` `NOTE_CLOSED` (2), `a2` a handle of the caller's that no descriptor names any more |
| 25 | `reply(pid, w1, w2, w3, w4)` | ends the call of process `pid`, which this process received: 0; −2 if `pid` is not waiting for its reply |
| 26 | `copyin(pid, from, to, n)` | copies `n` trytes from `from` in process `pid`, whose call this process holds, to its own `to`: 0; −2 as `reply`, −12 if either range is not all mapped, when nothing is copied |
| 27 | `copyout(pid, from, to, n)` | copies `n` trytes from its own `from` to `to` in process `pid`: as `copyin` |
| 28 | `register(name, version)` | gives the caller the server name at `name` (a string of 1 to 8 code points) with protocol version `version`: 0; −15 another process has it, −16 all 9 names are taken, −10 `version` below 1 or an empty name, −11 a name too long, −12 not in the caller's memory. Registering a name it has again changes the version |
| 29 | `lookup(name, how)` | `a0` the process that registered `name`, `a1` its version; −5 nobody has it (`how` `LOOKUP_NOW`, 0), or with `LOOKUP_WAIT` (1) waits until somebody registers it; −10, −11 and −12 as `register` |
| 30 | `window(k)` | makes block window `k`, 0 to 8, a zeroed page at `V_BLOCK + PAGE × k`, unless the caller has it already: 0; −10 no such window, −3 no memory |
| 31 | `drive(source)` | makes the caller the driver of device source `source` (`SRC_CONSOLE`, 1, or `SRC_DISK`, 2), its registers mapped at `V_DEVICE + PAGE × (source − 1)` until it ends: 0; −19 it has a driver, −10 no such source, −21 the caller runs a program file |
| 32 | `arm(source)` | lets the source the caller drives interrupt once: 0; −21 it does not drive it |
| 33 | `phys(address)` | the physical address of the caller's `address`, for a device to use: −12 nothing there, −21 the caller drives no device |

Numbers 9, 11, 12 and 14 are free: console input, blocks and
files are not system calls but calls to the console server, the disk
server and the file server (below and docs/filesystem.md), which fail with their own negative numbers, −2 and
−4 to −14: no filesystem, no such file, not a
directory, a bad descriptor and so on, each named in `include/layout.s`
(`E_NOENT`, `E_BADF`, ...).

A call whose result is a status, or a value that is never negative,
reports failure with a negative number; `include/layout.s` names each
one (`E_FULL`, `E_NOPROC`, `GETC_NONE`, ...). Programs test the sign or
use those names, never a bare −1, which is an ordinary value on a
balanced machine. `recv` and `hart` can return negative values that are
not failures, and so can an exit code: `wait` returns it in `a1`, apart
from its status in `a0`. A process that ends keeps its slot until its
parent waits for it, or until the parent ends too.

The console belongs to a process, the **console server**
(`user/consd.s`), which drives it and registers as `console`, protocol
`CONSOLE_PROTOCOL`. A call to it with `CN_WRITE`, a buffer and a count
prints that many trytes; with `CN_GETC` it answers with the next code
point typed, holding the call until there is one, and `GETC_NONE` once
the console has closed. The reader takes no hart while it waits: input
reaches the server as an interrupt notice. `detrytus run --input FILE`
closes the console behind the file; in `detrytus debug` the console
stays open, `input TEXT` types more while a program waits, and `eof`
closes it. The kernel still writes its own messages, and `putc` and
`puts`, to the console's output directly: they are its log.

**Descriptors.** Each process has nine, 0 to 8, in its record, and
each names a server and a handle that server gave out. Only the server
puts one there, with `give`, into a process whose call it holds: the
console server's `CN_OPEN` gives `CONSOLE_HANDLE`, and the file server's
`open` gives a handle for the open file. `read`, `write` and `iocall` on
a descriptor are calls to its server with an `IO_` operation and the
handle. `call` refuses those operations, so a server that gets one
knows the kernel brought it from a descriptor it gave out: a handle
cannot be forged. A process can copy its descriptors (`dup2`) and close
them, and a child starts with copies of its parent's, but those marked
`FD_NOINHERIT` (`fdflags`; `dup2` makes an unmarked copy); copies share the
open file, and its position, as after Unix's `dup`. When the last
descriptor naming a handle goes (closed, overwritten by `dup2`, or its
process ending), the kernel tells the server with a `NOTE_CLOSED`
notice, so a server never has to know who holds its handles; a server
that ends takes its handles with it. The shell opens the console as 0
and copies it to 1 and 2 (`STDIN`, `STDOUT`, `STDERR`), and every
program it runs reads and prints through them: `bin/hello` is a single
`write(STDOUT, ...)`. A console `read` gives what has been typed, at
least one code point and at most `n`, one to a tryte; `getc` is still
there for a code point too large for a tryte.

Ctrl-C (code point 3) kills the console's **foreground process**, which
`CN_FOREGROUND` names; the shell gives it each program it runs and takes
the console back after, and the server lets go of a foreground process
that ends. The server ends it with `kill` on behalf of the process that
named it, which the kernel allows a driver, so it can end only that
process's children. To see a Ctrl-C while nobody reads, the server reads
console input into a buffer of its own, but only while a reader waits
(as much as the readers need) or a foreground process runs (all of it).
Ctrl-C throws away what was typed before it, as a terminal does; with no
foreground process it is an ordinary code point, and one that ended
nothing (the process had ended already) waits in the buffer for the next
foreground process.

A block is one page, and a process's own page holds its code, so blocks
travel through **block windows**: up to nine pages, window `k` at
`V_BLOCK + PAGE × k` just above the process's own, each made by
`window` and freed when the process ends. The disk belongs to a
process, the **disk server** (`user/diskd.s`), which registers as
`disk`, protocol `DISK_PROTOCOL`: a call to it with `DK_READ` or
`DK_WRITE`, a block and a buffer (a window's address) fills the buffer
from the block or writes it to the block. The server has the disk move
the block into or out of a window of its own, by DMA, and copies it to
or from the caller with `copyout` or `copyin`; it takes other calls
while the disk works, and starts them in turn. Run with `detrytus run
--disk FILE --disk-blocks N`; the file keeps what was written for the
next run.

The disk can hold a filesystem, shaped like a Unix one: inodes, nested
directories with `.` and `..`, and files reached by path through file
descriptors (`docs/filesystem.md`). The kernel knows nothing of it: a
process, the **file server** (`user/fsd.s`), reads it into its block
windows and answers `call`s to open files and to make and remove files
and directories, and descriptor calls to read, write and list what was
opened, keeping each open file and each process's current directory;
it writes what a call changed
before it replies. It registers as `fs`, protocol `FS_PROTOCOL`, and
clients find it by that name. `tools/fs.py` makes and
changes filesystems on the host, and the shell's built-ins `ls [DIR]`,
`cat [PATH]` (standard input without one), `write PATH TEXT`, `rm PATH`, `mkdir PATH`, `rmdir PATH`,
`cd [DIR]` and `pwd` use them. A word the shell
does not know as a built-in or a program in the kernel image names a
program file: a path if it holds a slash, else a file in `/bin`, which
the file server starts as the shell's child, with the line's words as
its arguments, the command first (`wc notes more`, `echo hi`). After the command, `> PATH`
sends standard output to a file, made empty or new, `>> PATH` to its
end, and `< PATH` takes standard input from one, for that command alone,
built-in or program: `hello > out`, `ls >>list`, `cat < notes`. The
shell's own complaints go to standard error, the console, whatever is
redirected. Quotes work as in a Unix shell: `echo "hello   world"` and
`echo 'a | b'` give one argument each, keeping the spaces and the `|`,
`\` makes the next character itself, and `""` is an empty argument.

A `|` between commands makes a **pipeline**: `hello | upper | wc`, up to
four commands. Pipes come from a process, the **pipe server**
(`user/piped.s`, registered as `pipe`): `PP_PIPE` gives the caller a
read end and a write end as descriptors. A read waits for something
to read and gives 0 once no write end is left; a write waits until all
of it is in (a pipe holds 729 trytes) and is `E_PIPE` once no read end
is left. The shell starts every program of the line, each with its
pipe ends as standard input and output, before it waits for any, and
marks its own ends `FD_NOINHERIT` so that a reader sees the end when its
writer goes. A built-in takes one place in a pipeline (`ls | wc`,
`hello | cat`) and runs in the shell once the programs have started;
two would wait for each other. Ctrl-C ends the program the shell is
waiting for, the line's first first. `tools/fs.py` stores a `.s` or `.dti` file as a
program, in `/bin`:

```bash
tools/fs.py new disk.img 100 notes.txt bin/*.s
tools/fs.py mkdir disk.img docs
tools/fs.py put disk.img README.md docs
printf 'ls\nls bin\ncat docs/README.md\nwrite docs/motd hello\nhello > docs/hi\n' > session.txt
detrytus run shell.s --ram-pages 81 --input session.txt --disk disk.img
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

**Drivers.** The kernel keeps no device. A process
from the kernel image may `drive` a device source: the device's
registers are mapped into it, and the kernel only passes its interrupts
on. The driver `arm`s the source when it expects an interrupt, such as
after starting a command; the interrupt masks it again and reaches the
driver as a `NOTE_IRQ` notice from `receive`. While a source is armed
the kernel waits for it, rather than call a client stuck whose server
waits on the device. A device like the disk moves memory by physical
address, which `phys` gives; it could write any page, which is why a
program file read from the disk may not drive one.

**Names.** A server makes itself known with `register(name, version)`
once it is ready for calls, and a client finds it with `lookup(name)`,
which gives the server's process number and its protocol version, so
the client can refuse a version it would misread. With `LOOKUP_WAIT`, a
client that starts before its server sleeps until the name is there.
The kernel keeps the names and drops a server's the moment it ends, so
a name that is found belongs to a live process; there is no separate
status.

Process numbers are handed out round-robin, so a number is not reused
until the table of 6 wraps around.

## License

MIT, see [`LICENSE`](LICENSE).
