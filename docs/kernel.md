# The trylobite kernel

How trylobite works, for someone writing a program or a server for it:
its memory map, its system calls, and the servers that do what a larger
kernel would do itself. The [README](../README.md) gives the overview;
[`docs/filesystem.md`](filesystem.md) the filesystem's format and the
file server's protocol; [`include/layout.s`](../include/layout.s) every
number named here.

## Booting

A build's image is everything in pages 1 and up, and a jump to the
firmware at address 0. detrytus either loads the image as a file
(`detrytus run shell.s`) and starts at the jump, or boots it from a
disk: `make` (`tools/fs.py new --boot shell.s`) puts the image's pages
in consecutive blocks named by the boot record in block 0
([`docs/filesystem.md`](filesystem.md)), and `detrytus run --disk
disk.img` with no program runs detrytus' boot ROM, which loads them into
pages 1 and up and jumps to `FW_BOOT`. The boot page is the ROM's then,
so the firmware lives in RAM, in the last `FW_ROOM` (243) trytes of
the kernel's last code page, labelled at its physical addresses, and
the image is the same either way.

The firmware enters the kernel on hart 0, which sets up its page
allocator and then says what it found, on its log, before it starts
init (`kernel/rust/trykern/src/boot.rs`). This is the boot of the `shell.s` build, with
a disk of 100 blocks:

```text
trylobite: version 0.1.0, a microkernel for detrytus, the balanced-ternary machine
trylobite: memory: 59049 pages (1162261467 trytes), 59030 free
trylobite: harts: 1
trylobite: irq0: interrupt controller, 3 sources, at page -13
trylobite: cons0: console, at page -1
trylobite: disk0: block device, 100 blocks, at page -14
trylobite: net0: network device, no link, at page -16
trylobite: process table: 27 slots, 9 programs in the image
trylobite: starting init
```

Memory is the RAM the machine has, read at boot from the platform's
RAM size register (detrytus platform.md; `V_POWER + POWER_RAM`) up to
`MEM_MAX`, the last page the direct map reaches, and free what is
left after the kernel, the program images and the kernel's log (a page,
System tools below), before init has any.
Harts counts those present among the middle nine, which the kernel
starts once init exists. The interrupt controller, the disk and the
network device are read from the devices themselves (their `SOURCES`,
`BLOCKS`, `LINK` and `MAC_HI`/`MAC_LO` registers, detrytus
platform.md); a machine without `--disk` has `no disk`, and one without
`--net` has `no link`, where one with a link shows the interface's
address (`02:00:00:00:00:01` unless `--mac` sets another). Each
line starts `trylobite: `, as all the kernel's lines do, so a reader
of the log can tell them from a program's. Init then says each server
it starts (The shell, below).


Every address space has three regions, all in root entry 0's mid table,
so that every kernel address lies within ±2³¹ and can be a Rust
pointer (detrytus docs/rust.md, Pointers):

| Region | Virtual pages | Contents |
|--------|---------------|----------|
| direct map | mid entries −16 to −1, pages −108,256 to −3,281 | physical memory up to `MEM_MAX`, kernel only: kernel virtual = physical + `DMAP` (−16·3¹⁷) |
| kernel | −19 to −15, −9 to −4 | kernel data and stack (−19), kernel code (−18 to −16, `NKCODE` pages), the binary floating point coprocessor, which every process may use; the block device, the interrupt controller, the hart controller (its slots, and this hart's own), power off, console; page 0 unmapped |
| process | 6561 (`V_USER`) and up | the process's code, data and stack; the pages above its own that a large program's image takes; its block windows |

The first two regions are shared by every address space. A new process
costs four pages: a root, a mid and a leaf table, and its own page,
into which `spawn` copies the program image loaded at boot, or
`spawnw` a program file read from the disk. A program runs from
`V_USER − 1` up and its stack from `V_USER` down, through the lower
half of its page (below its arguments, for a program file). A program
file's image may go on past its own page, through up to `NXPAGE` (9)
pages above it, which `spawnw` makes as it needs them: `rsqrt`, whose
float formatting comes to about 22,000 trytes, takes one. A program
of the kernel image may take more than its page the same way: its first
word, at `V_USER + IMAGE_PAGES` (the far end of the stack's half of its
page), says how many pages its image takes in all, and `spawn` copies
them all. Block
windows take up to nine more pages, as a process asks for them, from
`V_BLOCK`, past those; a driver also has its device's registers mapped
past them, at `V_DEVICE`. Past the devices' pages is the **heap**, from
`HEAP_START` (the first tryte of page `V_HEAP`): `brk` maps zeroed pages
there, up to `HEAP_MAX` (3,259, the rest of the process's leaf table), as the process asks, never takes one back
before the process ends, and records only how many it has
(`PCB_HEAP`); the leaf table says which they are. trystd's heap
(`lib/rust/trystd/src/heap.rs`) is Rust's allocator over it.

The binary floating point coprocessor (detrytus platform.md, page −15)
is mapped for every process at its physical address, `V_FPU`, where
`detrytus ll`'s code for Rust's `f32` and `f64` reaches it. Each hart
has its own bank of operands and result, which is process state like
the registers: `ktrap` saves the bank into the process record
(`PCB_FPU`) on every trap, since the process may have been stopped
between an operation and its result, and `resume` restores it unless
the hart's bank is still that process's (`fpu_owner`).

| Physical page | Contents |
|---------------|----------|
| 0 | the boot page: a jump to the firmware, or detrytus' boot ROM when the kernel boots from a disk |
| 1 | kernel data and stack |
| 2, 3, 4 | kernel code (`NKCODE` pages from `P_KCODE`); the firmware in the last `FW_ROOM` trytes of page 4, from `FW_BOOT` |
| 5, 6, 7 | the boot address space; the kernel's shared leaf table |
| 8 and on | program images 0 to `NPROG` − 1, at most 27 (`NPROG_MAX`; the demo has 3, the shell build 11), one after another, a page each unless an image's `IMAGE_PAGES` word says more |
| after the last image .. the machine's last | free pages, handed out by the allocator |

No kernel structure grows with memory. Free pages are those never yet
handed out, counted by `fresh_page` up to `ram_pages`, plus a list of
pages given back, threaded through their centre words; `take_page`
(`kernel/rust/trykern/src/mm.rs`) uses the list first. So boot writes no free page, and any amount of RAM
costs nothing until it is used.

The kernel reaches physical pages through the **direct map**, kernel
virtual address = physical + `DMAP`: mid entries −16 to −1 of every
address space are mid-level superpages (3⁸ = 6,561 pages each) of
physical pages centred on 0, 3⁸, … 15·3⁸. That reaches page 101,695
(`MEM_MAX`), about 2 × 10⁹ trytes. detrytus allows far more RAM, up to
page 193,710,244, but the direct map is kept within ±2³¹ so that a
kernel written in Rust can point at any of it (detrytus' Rust
pointers are signed 32-bit addresses), and the rest stays out of reach
and goes unused (a 32-bit Linux's "high memory" problem). Using it
would take mapping it in on demand rather than all the time.

## System calls

`sys` with the call number in `a0` and arguments from `a1` on (as many
as the call takes); the result comes back in `a0`. A call changes only
`a0` to `a5` (some answer in `a1` and on as well); every other register
is as it was, since the trap entry saves them all. Trice relies on this
(detrytus `docs/trice.md` 8).

| Number | Call | Result |
|--------|------|--------|
| 0 | `putc(c)` | 0 |
| 1 | `send(pid, value)` | 0 sent; −1 mailbox full; −2 no such process |
| 2 | `recv()` | the value; waits until one arrives |
| 3 | `yield()` | 0 |
| 4 | `exit(code)` | does not return |
| 5 | `getpid()` | this process's number; in a thread, its process's (`gettid`) |
| 6 | `puts(address)` | 0; −2 if the string is outside the process's page and block windows |
| 7 | `spawn(program)` | the new process's number; −1 no free slot, −2 no such program, −3 not enough memory |
| 8 | `hart()` | the number of the hart running the caller, −4 to +4 |
| 10 | `wait(pid)` | how child `pid` ended, once it has: `a0` 0 exited, 1 faulted or 2 killed, `a1` its exit code, trap cause, or the signal that ended it; `a0` −2 if `pid` is not the caller's child |
| 13 | `kill(pid, for, sig)` | sends signal `sig` (Signals; 0 only checks) to `pid`'s process, a child of the caller when `for` is `FOR_SELF` (−1), or, for a driver, a child of process `for`: 0, and it ends before it runs again; 2 (`KILL_CAUGHT`) it goes on, catching, ignoring or blocking the signal; 1 (`KILL_ENDED`) if it had ended already; −2 if `pid` is not that process's child, −10 no such signal, −21 `for` from a process that drives nothing. With `for` `KILL_ANY` (−2), any process but init: as before, or −2 none, or it has ended; −21 for init |
| 15 | `spawnw(window, for, args, n)` | starts the program file whose first block is in block window `window`, and each next block in the next window (docs/filesystem.md), as the caller's child when `for` is `FOR_SELF` (−1), or as the child of process `for`, whose call the caller holds, with the `n` trytes of arguments at `args` in that parent's memory (docs/filesystem.md, Program arguments): as `spawn`, with −2 when there is no window or no program in it, its image is larger than `EXEC_MAX` or runs past the windows the caller has, or `for` is not waiting for the caller, −10 (`E_INVAL`) for `n` below 0 or above `ARG_MAX`, −12 (`E_FAULT`) for arguments not all in the parent's memory |
| 16 | `close(fd)` | empties descriptor `fd`: 0; −8 if it names nothing |
| 17 | `give(pid, handle)` | puts the caller's `handle`, 0 to 26, in the lowest free descriptor of process `pid`, whose call the caller holds: the descriptor; −9 none free, −2 `pid` is not waiting for the caller, −10 no such handle |
| 18 | `dup2(fd, to)` | makes descriptor `to` a copy of `fd`, closing what `to` held: `to`; −8 if `fd` names nothing or `to` is not 0 to 8 |
| 19 | `iocall(fd, op, x, y)` | a call to the server descriptor `fd` names, with `op`, an `IO_` operation (negative), its handle, `x` and `y`: the server's answer; −8 if `fd` names nothing, −10 if `op` is not an `IO_` operation. Leaves `a1` to `a5` as `call` does |
| 20 | `read(fd, buffer, n)` | `iocall` with `IO_READ`: at least one and at most `n` trytes, 0 at the end |
| 21 | `write(fd, buffer, n)` | `iocall` with `IO_WRITE`: how many were written |
| 22 | `fdflags(fd, flags)` | sets descriptor `fd`'s flags: `FD_NOINHERIT` (1), a child does not get a copy, or 0: 0; −8 if `fd` names nothing, −10 another flag |
| 23 | `call(pid, w1, w2, w3, w4)` | sends four words to process `pid` and waits for its reply: the reply's four words in `a0` to `a3`; `a0` −2 if there is no such process or it ends first, −3 if `pid` is the caller, −10 if `w1` is negative (an `IO_` operation, which only a descriptor sends) |
| 24 | `receive()` | waits for a call: `a0` the caller, `a1` to `a4` its words, `a5` its process (the caller's own number, unless it is a thread); or `a0` `FROM_KERNEL` (−1) and `a1` `NOTE_ENDED` (0), `a2` a process that ended, or `a1` `NOTE_IRQ` (1), `a2` a device source the caller drives that interrupted, or `a1` `NOTE_CLOSED` (2), `a2` a handle of the caller's that no descriptor names any more, or `a1` `NOTE_SIGNAL` (3), `a2` a process that notified the caller, or `a1` `NOTE_ALARM` (4), the caller's alarm went off |
| 25 | `reply(pid, w1, w2, w3, w4)` | ends the call of process `pid`, which this process received: 0; −2 if `pid` is not waiting for its reply |
| 26 | `copyin(pid, from, to, n)` | copies `n` trytes from `from` in process `pid`, whose call this process holds, to its own `to`: 0; −2 as `reply`, −12 if either range is not all mapped, when nothing is copied |
| 27 | `copyout(pid, from, to, n)` | copies `n` trytes from its own `from` to `to` in process `pid`: as `copyin` |
| 28 | `register(name, version)` | gives the caller the server name at `name` (a string of 1 to 8 code points) with protocol version `version`: 0; −15 another process has it, −16 all 9 names are taken, −10 `version` below 1 or an empty name, −11 a name too long, −12 not in the caller's memory. Registering a name it has again changes the version |
| 29 | `lookup(name, how, pid)` | `a0` the process that registered `name`, `a1` its version; −5 nobody has it (`how` `LOOKUP_NOW`, 0), or with `LOOKUP_WAIT` (1) waits until somebody registers it, or with `LOOKUP_WHILE` (2) waits only while process `pid` lives: −2 once it has ended (or if it never was); −10, −11 and −12 as `register` |
| 30 | `window(k)` | makes block window `k`, 0 to 8, a zeroed page at `V_BLOCK + PAGE × k`, unless the caller has it already: 0; −10 no such window, −3 no memory |
| 31 | `drive(source)` | makes the caller the driver of device source `source` (`SRC_CONSOLE`, 1, `SRC_DISK`, 2, or `SRC_NET`, 3), its registers mapped at `V_DEVICE + PAGE × (source − 1)` until it ends: 0; −19 it has a driver, −10 no such source, −21 the caller runs a program file |
| 32 | `arm(source)` | lets the source the caller drives interrupt once: 0; −21 it does not drive it |
| 33 | `phys(address)` | the physical address of the caller's `address`, for a device to use: −12 nothing there, −21 the caller drives no device |
| 34 | `log(buffer, n, from)` | copies the kernel's log from the `from`-th code point it ever printed (the oldest it keeps, if that one is gone) to `buffer`, at most `n`, and as many as fit in its page: `a0` how many, 0 once there are no more, `a1` where the next read starts; −10 `n` below 0, −12 not in the caller's memory |
| 35 | `info(buffer)` | the `SI_` words at the word-aligned `buffer` (System tools): 0; −12 not all in one page of the caller's |
| 36 | `proc(pid, buffer)` | the `PI_` words of process `pid` at the word-aligned `buffer`: 0; −2 no such process (a free slot), −12 as `info` |
| 37 | `name(string)` | names the caller after the string: its part after the last `/`, at most 8 code points: 0; −12 not in the caller's memory |
| 38 | `sleep(until)` | waits until the `time` CSR reaches `until`: 0 |
| 39 | `notify(pid)` | tells process `pid`, without waiting, that the caller wants its attention: its `receive` gives a `NOTE_SIGNAL` notice naming the caller, once however often it was notified since: 0; −2 no such process, −3 `pid` is the caller |
| 40 | `alarm(until, how)` | when the `time` CSR reaches `until`, the caller's `receive` gives a `NOTE_ALARM` notice (`how` `ALARM_NOTICE`, 0), or its process gets `SIGALRM` (`ALARM_SIGNAL`, 1); a later alarm replaces an earlier one, and `NO_ALARM` (−1) cancels it: 0; −10 another `how` |
| 41 | `brk(end)` | makes the caller's heap reach `end`, in whole zeroed pages from `HEAP_START`: the break, the first address past the heap; an `end` inside the heap, or `BRK_QUERY` (0), only asks, since the heap never shrinks; −10 (`E_INVAL`) for an `end` below `HEAP_START` or past `HEAP_MAX` pages, −3 (`E_NOMEM`) when the pages are not there, and then it maps none |
| 42 | `clock()` | the time of day, from the machine's real-time clock: `a0` whole seconds since 1970-01-01 00:00:00 UTC (Unix time, negative before 1970), `a1` the microseconds past that second, 0 to 999,999; it cannot fail (System tools, The time of day) |
| 43 | `stepclock(seconds, micros)` | moves the time of day `clock` gives by `seconds` and `micros` (−999,999 to 999,999, of the seconds' sign when they are not 0): 0; −10 (`E_INVAL`) for micros out of range or of the other sign, −21 (`E_PERM`) for a caller that is not init's child: only the servers and the programs `/etc/init` names may (The time of day) |
| 44 | `thread(entry, stack, arg, tp)` | starts a thread of the caller's process at `entry`, with `sp` = `stack`, `a0` = `arg`, `tp` = `tp` and the caller's `gp` (Threads): its number; −1 (`E_NOSLOT`) |
| 45 | `thread_exit(code)` | ends the calling thread alone, its code kept for `join`; −21 (`E_PERM`) in a process's first thread |
| 46 | `join(tid, how)` | `a0` 0 and `a1` the code thread `tid` gave `thread_exit`, once it has: `JOIN_WAIT` (0) waits, `JOIN_POLL` (1) gives −19 (`E_BUSY`) while it runs; −2 (`E_NOCHILD`) for what is not another thread of the caller's process, or was joined, −10 (`E_INVAL`) for the caller itself or another `how` |
| 47 | `futex(address, op, value)` | `FUTEX_WAIT` (0): sleeps while the `u32` at `address` (four trytes, low byte first) is `value`, until a `FUTEX_WAKE`: 0, or −27 (`E_AGAIN`) at once if it is not; `FUTEX_WAKE` (1): wakes at most `value` threads of the caller's process sleeping at `address`: how many; −12 (`E_FAULT`), −10 (`E_INVAL`) |
| 48 | `gettid()` | the calling thread's number; a process's first thread's is the process's (`getpid`) |
| 50 | `sigaction(sig, action, entry)` | what signal `sig` does to the caller's process from now: `SIG_DFL` (0) its default, `SIG_IGN` (1) nothing, `SIG_CATCH` (2) run `entry`, which becomes the process's signal entry (Signals): the action it had; −10 (`E_INVAL`) no such signal or action, or any but `SIG_DFL` for `SIGKILL` |
| 51 | `sigmask(how, set)` | changes the calling thread's set of blocked signals, a bit 2^`sig` for each: `SIG_BLOCK` (0) adds `set`, `SIG_UNBLOCK` (1) takes it away, `SIG_SETMASK` (2) makes it `set`: the set it had; −10 another `how`, or `set` outside 0 to 2^`NSIG` − 1. `SIGKILL` is never blocked, and a signal it lets in is taken before the call returns |
| 52 | `sigreturn(frame)` | goes back from a signal's handler to where the thread was, with the registers, coprocessor bank and mask the frame at `frame` keeps; does not return, but −12 if the frame is not all in the caller's memory |

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

Process numbers are handed out round-robin, so a number is not reused
until the table of `NPROC` (27) wraps around.

## System tools

`bin/` has tools that look at the system as Unix's do: `ps`, `top`,
`kill`, `free`, `uptime`, `uname`, `dmesg`, `sleep`, `df` and `date`. The kernel
only reports; the tools read it with a few calls and format it
(`kernel/rust/trykern/src/info.rs` and `procinfo.rs`; trystd's `os` module reads
the calls' words for the Rust tools), and `df` asks the file server
(`FS_STATFS`, docs/filesystem.md).

**The log.** Everything the kernel prints (its own lines, and `putc` and
`puts`, which programs use as the log) also goes into a page of its
own, which keeps the last `LOG_SIZE` (19,683) code points; `log` reads
it back by position, so a reader that loops until it gets 0 has all of
it. `dmesg` prints it: the boot report, init's lines, and how each
process ended.

**The machine.** `info` fills `SI_TIME` (the clock), `SI_TICKS` (timer
interrupts taken), `SI_PAGES` and `SI_FREE` (memory, in pages),
`SI_NPROC` and `SI_PROCS` (the process table and the slots in use,
zombies included), `SI_HARTS` (harts present) and the kernel's version
as a string from `SI_RELEASE`: `uname -a` says `trylobite 0.1.0
detrytus`, `uptime` `up 1171367 ticks, 9 processes, 1 hart`, and `free`
memory in pages and in trytes. It also gives `SI_BOOTED`, the real-time
clock at boot in Unix seconds (so uptime in seconds is `clock()` less
it), and the load averages `SI_LOAD1`, `SI_LOAD5` and `SI_LOAD15`:
the processes ready or running, averaged as Unix's `calc_load` does,
in `LOAD_ONE` (19,683) parts of one process. `pick` samples them every
`LOAD_PERIOD` (5,000,000) ticks, which is Unix's 5 seconds at a
microsecond a tick. A busy hart picks every quantum, so periods that
passed with no pick were ones every hart idled through: they count as
no load, and only the last as what is runnable at the late pick. The `time` CSR counts one tick per step
(detrytus platform.md, Time), so times since boot (`uptime`, `ps`,
`top`, `sleep`) are in ticks.

**Harts.** `hartinfo(hart, buffer)` fills, for one of the middle nine
harts, `HI_TIME` (the clock as it read the rest), `HI_STARTED` (when
the kernel started the hart, 0 for hart 0), `HI_USER` (ticks it has run
processes in user mode: `ktrap` adds each stretch from `resume`, as it
does to the process's `PI_CPU`) and `HI_IDLE` (ticks it has waited for
work in `idle`); the rest of `HI_TIME - HI_STARTED` it spent in the
kernel or waiting for the kernel lock. A stretch still under way counts
up to `HI_TIME`, so a tool that subtracts two readings gets each hart's
shares of the time between them; an absent hart is `E_NOHART`. Each
hart writes only its own counters, `ktrap` before it takes the lock.

**The time of day.** `clock` reads the machine's real-time clock
(detrytus platform.md, The real-time clock): Unix seconds and
microseconds, in UTC, with no time zones. It is a system call rather
than a server's: it is two loads from the power page, which the kernel
maps anyway, with no state to keep and nothing to wait for. trystd's
`time::SystemTime::now()` calls it, and `time::Utc` turns seconds into
a date; `bin/date` prints it (`date`, `date +%F_%T`, `date -d
@SECONDS`). The clock is the host's, unless detrytus runs with
`--clock SECONDS` (as the tests do), which starts it at a fixed time
and moves it a microsecond a tick. Ticks stay the clock for intervals:
how fast ticks pass in real time depends on how the machine runs, and
the time of day is not steady either.

`stepclock` moves it. The machine's clock cannot be set, so the kernel
keeps an offset from it, which `clock` adds, and a step changes the
offset; it is gone at power off, as the machine has no battery to keep
it. Only init's children may step it, the servers and the programs
`/etc/init` names, which the person who wrote that file chose: what
the shell runs may not (`E_PERM`), as on Unix only root may. `bin/ntpd`
keeps the clock right over the network (SNTP, RFC 4330): started from
`/etc/init` (the repository's starts it), it asks
`pool.ntp.org`, or the server it is given, steps the clock by the
offset it finds, says so on the console the first time and for a step
of 128 ms or more, and asks again every 1,024,000,000 ticks (about 17
minutes on a live machine; 64,000,000 after a failure, which it reports
once three have come in a row). `ntpd -q SERVER`
steps the clock once and exits, and `ntpd -n SERVER`, which anyone may
run, only prints the offset, the round trip and the server's stratum.
It steps rather than slews: the clock jumps, and may go back. Files
keep no times yet.

**Processes.** `proc` fills, for one process, `PI_STATE` (an `ST_`
value), `PI_PARENT` (`NO_PARENT`, −1, for none), `PI_PAGES` (its four,
its image's pages above its own, its block windows and its heap; 0
once ended), `PI_CPU` (the ticks it has run in
user mode: the kernel adds the time from `resume` to the next trap) and
its name, 8 code points and a 0 from `PI_NAME`. A process's name is the
last part of the first argument `spawnw` gave it (`/bin/ps` is `ps`), or
for a program of the kernel image what it gave `name` as it started:
`init`, `consd`, `piped`, `diskd`, `fsd`, `sh`.

```text
$ ps
  PID  PPID STATE    PAGES       TIME NAME
    0     - receive     4       2515 init
    1     0 receive     4       7976 consd
    2     0 receive     4        253 piped
    3     0 receive     5       5840 diskd
    4     0 receive     9       2785 fsd
    5     0 wait        4       1939 sh
    6     5 run         4       3502 ps
```

`top [-n COUNT]` clears the terminal and shows a header in the shape
of GNU top's, then the same table with each process's share of the
clock since the last screen (`CPU%`), every million ticks, until Ctrl-C
or COUNT screens (here `spin | top` on three harts):

```
top - 00:41:47 up 00:01:47, trylobite 0.1.0, load average: 0.24, 0.06, 0.02
Tasks:  10 total,   2 running,   0 ready,   8 waiting,   0 zombie
%Cpu-1:  64.8 us,  35.2 sy,   0.0 id
%Cpu0 :   0.4 us,   1.9 sy,  97.7 id
%Cpu1 :   7.8 us,   9.1 sy,  83.1 id
Mem   :  59049 pages total,  58971 free,     78 used  (19,683 trytes a page)
```

The time of day and the uptime are the real-time clock's (`SI_BOOTED`),
the load averages the kernel's, and a `%Cpu` line gives each hart's
shares of the ticks since the last screen in user mode, in the kernel
and idle (`hartinfo`). It is in Rust, and writes each screen by hand
into one buffer with 32-bit arithmetic: on detrytus a 64-bit division
is a helper of some 3,000 steps and core's formatting costs over a
thousand a number, which made a first version cost a quarter of a hart
to watch. It waits with `sleep`,
whose time is absolute, so the screens keep step. A sleeper is woken
by the hart that next schedules, and a hart with nothing to run sets
its timer for the earliest sleeper, so sleeping is neither a busy wait
nor, with nothing else running, a deadlock.

`kill [-SIGNAL] PID...` sends each process `SIGTERM`, or the signal
named (`-INT`, `-SIGUSR1`, `-s HUP`, `-9`), to any process but init
(`KILL_ANY`): there are no users to tell apart, so this is Unix's root.
`kill -l` lists the signals. A server ended this way is started again
by init, with what needs it, the shell included. `bin/kill` is Rust,
over trystd's `signal`.

## Messages for servers

A server is a process that serves others'
calls, as the file, disk, console and pipe servers do: `call` sends it four words and sleeps
until it replies with four of its own. The server takes calls one at a
time with `receive`, which says who called; while it holds a call, it
may copy to and from the caller's memory with `copyin` and `copyout`,
which is how a path or a buffer named in the call travels. A process
that has called `receive` is told of every process that ends, before
any later call, so it can forget what it kept for one; a parent is told
of its own children ending even before it first calls `receive`, which
is how init learns of a server that ends while init waits for another
to register. A call to a
process that ends fails. A server asleep in `receive` with nobody left
to call it does not keep the machine from powering off.

Two notices let a server hear of things without a call, so it never
has to block anywhere but in `receive`. `notify(pid)` marks the caller
in process `pid`'s notices and returns at once; the next `receive`
there gives `NOTE_SIGNAL` naming the caller, once, however often it was
notified since. A server may notify a client that is calling it, and a
client a server it calls, without either waiting on the other: this is
how the network server tells the IP server a frame has come. `alarm(until)`
gives a `NOTE_ALARM` from `receive` once the clock reaches `until`, for
timeouts; a process has one alarm, and setting it again replaces it.
A process waiting for an alarm keeps the machine on, as a sleeper
does.

## Names

A server makes itself known with `register(name, version)`
once it is ready for calls, and a client finds it with `lookup(name)`,
which gives the server's process number and its protocol version, so
the client can refuse a version it would misread. With `LOOKUP_WAIT`, a
client that starts before its server sleeps until the name is there;
with `LOOKUP_WHILE`, only while a given process lives, which is how init
waits for a server it has just started without hanging on one that ends
first.
The kernel keeps the names and drops a server's the moment it ends, so
a name that is found belongs to a live process; there is no separate
status.

## Drivers

The kernel keeps no device. A process
from the kernel image may `drive` a device source: the device's
registers are mapped into it, and the kernel only passes its interrupts
on. The driver `arm`s the source when it expects an interrupt, such as
after starting a command; the interrupt masks it again and reaches the
driver as a `NOTE_IRQ` notice from `receive`. While a source is armed
and some process waits on something (a call, a child, a name), the
kernel waits for the device, rather than call a client stuck whose
server waits on it. Once every process is asleep in `receive`, an
armed source does not keep the machine on: a frame or a key could only
reach servers with nobody left to serve. A device like the disk moves memory by physical
address, which `phys` gives; it could write any page, which is why a
program file read from the disk may not drive one.

## Descriptors

Each process has nine, 0 to 8, in its record, and
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

## Threads

A process may run more than one thread: `thread(entry, stack, arg,
tp)` starts one at `entry`, with `sp` = `stack`, `a0` = `arg`, `tp` =
`tp` and the caller's `gp`. A thread is a slot of the process table of
its own, so its registers, state, coprocessor bank, messages, alarm and
name are its own, every call that blocks blocks it alone, and two
threads run on two harts at once. Its number is its slot's, so calls,
sends and kills reach it by that number; `gettid` gives it, while
`getpid` gives its process's. What a process has as a whole, its threads
share through the record's `PCB_SPACE` (`kernel/rust/trykern/src/thread.rs`):
its memory (its pages, block windows and heap, which `brk` grows for all
of them), its descriptors, its children (a thread's `spawn` makes a
child of the process, and any thread may `wait` for it) and its end. A
server's `receive` gives a caller's process in `a5`, so the file server
keeps one current directory per process, whichever thread asks.

`exit`, a fault or a kill in any thread ends the whole process, as on
Unix: every thread is killed, and goes the next time the kernel would
run it, as a killed process does; the process waits as `ST_DYING` until
the last has gone, so no hart still runs in its address space when its
pages go back, and only then does its parent's `wait` see it end (with
the status the end began with). Killing a thread's number kills its
process. `thread_exit(code)` ends one thread alone, though not a
process's first, which owns the pages; the thread stays as a zombie
until another thread of its process collects its code with
`join(tid, JOIN_WAIT)` (or `JOIN_POLL`, which says `E_BUSY` while it
runs), or the process ends.

Threads wait for each other with `futex(address, op, value)`, under the
locks Rust's atomics make (detrytus docs/rust.md, Atomics): the word
at `address` is a `u32` as Rust lays one out, four trytes low byte
first. `FUTEX_WAIT` sleeps there while it holds `value` (`E_AGAIN` at
once if it does not), and `FUTEX_WAKE` wakes at most `value` of the
process's threads sleeping there. The kernel lock makes the test and the
sleep one step, so a wake after the holder's store is never missed.
Threads asleep on futexes or in `join` with nothing left to wake them
are a deadlock. trystd's `thread` and `sync` (`spawn`, `JoinHandle`,
`Mutex`, `Condvar`, `Arc`) are built on these, and `bin/rthreads` counts
primes in threads on two harts.

## Signals

Signals are POSIX's, kept small (`kernel/rust/trykern/src/signal.rs`),
and numbered as Linux numbers them: `SIGHUP` 1, `SIGINT` 2, `SIGQUIT` 3,
`SIGKILL` 9, `SIGUSR1` 10, `SIGUSR2` 12, `SIGPIPE` 13, `SIGALRM` 14,
`SIGTERM` 15 and `SIGCHLD` 17, any of 1 to `NSIG` − 1 (30) being one. A
set of signals is a word with the bit 2^`sig` for each. `kill(pid, for,
sig)` sends one to a whole process; who may send to whom is as `kill`
always allowed.

Each signal does one of three things to a process, which `sigaction`
sets: its **default**, which ends the process (and its parent's `wait`
says `WAIT_KILLED` with the signal in `a1`), or for `SIGCHLD` nothing;
**nothing** (`SIG_IGN`); or it is **caught** (`SIG_CATCH`). `SIGKILL`
always ends the process. The kernel keeps, in the process's record,
the signals sent and not yet taken (`PCB_SIGPEND`), the sets it catches
and ignores, and one **signal entry** for every caught signal, the
address the last `SIG_CATCH` gave: which handler runs for which signal
is the program's own business (trystd keeps a table). A child starts
with what its parent ignores and blocks, and every other signal at its
default, as across Unix's `fork` and `exec`; a thread starts with the
mask of the thread that started it.

Each **thread** has its own mask of blocked signals (`sigmask`); a
signal goes to the process, and is taken by whichever of its threads
does not block it. One every thread blocks waits, pending, until a
thread lets it in. Sending marks the signal pending and sets
`PCB_SIGNOTE` in each thread that lets it in; `resume`, on its way back
to user mode, looks at that one word and calls `rk_signal`, which takes
the lowest signal waiting and acts on it. A signal that ends the process
ends it at once, as `kill` always has, when some thread lets it in.

A caught signal runs the entry in that thread, between two of its
instructions: the kernel pushes a **signal frame** (`SIGFRAME` trytes)
below the thread's `sp`, holding its registers as the record keeps them
(`PCB_SP` to `PCB_T6`), its `pc` (`SF_PC`), coprocessor bank (`SF_FPU`),
mask (`SF_MASK`) and the signal (`SF_SIG`); blocks the signal; and
starts the entry with `a0` = the signal, `a1` = the frame and `sp` just
below it. The entry ends with `sigreturn(frame)`, which puts everything
back, the mask too, so the thread carries on as if nothing had happened.
A stack with no room for the frame ends the process instead.

A thread waiting in a system call when a caught signal comes is woken
to run its handler at once, and the call then returns −28 (`E_INTR`):
any wait but a call a server has received (`ST_REPLY`), whose reply is
still to come. Such a call had not happened yet, so calling again is
always right, and trystd's system-call entry does, as Unix's
`SA_RESTART`; nothing else ever sees `E_INTR`, since only a process that
catches a signal is interrupted. A held read of the console is the
console server's to end: it answers it with `E_INTR` at Ctrl-C (The
console).

Where the signals come from: Ctrl-C is `SIGINT` to the console's
foreground process; the pipe server sends `SIGPIPE` to a process
writing to a pipe nobody can read, as well as failing the write with
`E_PIPE`; `alarm(until, ALARM_SIGNAL)` sends `SIGALRM`; a child's end
sends its parent `SIGCHLD`; `bin/kill` sends any. A fault is not a
signal: it ends the process as `WAIT_FAULTED`. There is no `SIGSTOP` or
`SIGCONT`, and no signal reaches one thread alone.

The shell catches `SIGPIPE`, so that a built-in writing into a pipeline
whose reader has gone gets `E_PIPE` and the shell lives on; catching
rather than ignoring leaves its children `SIGPIPE`'s default. It says
nothing of a program `SIGPIPE` ended, as Unix shells do not.

trystd's `signal` module has it for Rust: `signal(sig,
Handler::Catch(f))` (or `Ignore`, `Default`), `kill(pid, sig)`,
`raise`, `block`, `unblock` and `set_mask` over a `SigSet`, `alarm`,
and `Child::signal` and `ExitStatus::signal` in `process`. A handler
should only set an atomic or end the process: printing or allocating
can wait forever on a lock the interrupted code holds. `tests/rsig.rs`
tries each.

## The console

The console belongs to a process, the **console server**
(`user/consd.s`), which drives it and registers as `console`, protocol
`CONSOLE_PROTOCOL`. A call to it with `CN_WRITE`, a buffer and a count
prints that many trytes; with `CN_GETC` it answers with the next code
point typed, holding the call until there is one, and `GETC_NONE` once
the console has closed. The reader takes no hart while it waits: input
reaches the server as an interrupt notice. `detrytus run --input FILE`
closes the console behind the file; `detrytus run` at a terminal
without `--input` passes each key as it is typed and closes at Ctrl-D;
in `detrytus debug` the console stays open, `input TEXT` types more
while a program waits, and `eof` closes it. The kernel still writes its own messages, and `putc` and
`puts`, to the console's output directly: they are its log.

Ctrl-C (code point 3) sends `SIGINT` to the console's **foreground
process**, which `CN_FOREGROUND` names; the shell gives it each program
it runs and takes the console back after, and the server lets go of a
foreground process that ends. The server sends it with `kill` on behalf
of the process that named it, which the kernel allows a driver, so it
can reach only that process's children. `SIGINT`'s default ends the
process, and the console is nobody's after; a process that catches or
ignores it (`KILL_CAUGHT`) keeps the console, and a read of its that
the server holds is answered with `E_INTR`, so its handler runs at once
and trystd reads again. To see a Ctrl-C while nobody reads, the server reads
console input into a buffer of its own, but only while a reader waits
(as much as the readers need) or a foreground process runs (all of it).
Ctrl-C throws away what was typed before it, as a terminal does; with no
foreground process it is an ordinary code point, and one that ended
nothing (the process had ended already) waits in the buffer for the next
foreground process.

Input reaches a reader as typed, one code point per key, unechoed: the
server cooks nothing, so a program that edits a screen, as `vi` does,
reads keys straight from standard input and draws with ANSI sequences on
standard output. Any process may name `NO_FOREGROUND`; `vi` does, so
that a Ctrl-C reaches it as a key instead of ending it with a file
unsaved, and the shell names the next program it runs as usual.

**The console's size.** `iocall(fd, IO_WINSIZE)` on a console
descriptor answers 0, with the terminal's rows and columns in the
reply's next two words (a1 and a2 after the call), as the machine's
console registers say them: detrytus keeps them the size of the
terminal a live console runs in, following a resized window, and
`detrytus run --console-size ROWSxCOLUMNS` sets them; otherwise both are
0, not known. Asked of a file, a pipe or a connection, the call is
`E_INVAL`, so it also says whether a descriptor is the console, as
Unix's `isatty`. trystd's `io::terminal_size()` asks it of standard
output; `vi` asks before each screen and fills the console (24 by 80
when the size is not known), the shell's Tab list fills its width,
and `stty size` says it as `ROWS COLUMNS`.

## The disk

A block is one page, and a process's own page holds its code, so blocks
travel through **block windows**: up to nine pages, window `k` at
`V_BLOCK + PAGE × k`, above the process's own and the `NXPAGE` a large
program's image may take, each made by
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

## The network

The network device (detrytus `docs/platform.md`, page −16) belongs to a
process, the **network server** (`user/netd.s`), which drives source
`SRC_NET` and registers as `net`, protocol `NET_PROTOCOL`. It moves
Ethernet frames, octets one to a tryte from the header on, and nothing
above them: ARP, IP and TCP are for a network stack to build on it. A
call with `NT_SEND`, a frame and its length puts the frame on the wire
and answers once it has left; with `NT_RECEIVE`, a buffer and its size,
it answers with the length of the next frame to arrive, holding the call
until there is one; `NT_ADDRESS` gives the interface's address, 24 bits
in each of the reply's next two words. Frames pass through two block
windows of the server's, by DMA, and are copied to and from the caller,
as the disk server's blocks are. Sends wait their turn one per process,
and so do readers; a frame that arrives while nobody reads waits in the
server, and the device keeps nine more behind it. A network stack,
which must keep taking calls of its own, calls `NT_LISTEN` instead of
waiting in a receive: the server then notifies it (`notify`) once for
each frame that waits with nobody reading, and its `NT_RECEIVE` takes
the frame at once. The server arms the device only while somebody waits
on it or listens, and an armed device keeps the machine on only while
some process waits on something, so a machine whose processes have all
finished still stops. Without a link, sends and receives fail with
`E_IO`.

Above it, the **IP server** (`user/ipd.s`) registers as `ip`, protocol
`IP_PROTOCOL`: the TCP/IP stack. It speaks ARP and ICMP
echo over IPv4. It answers ARP requests for its address and keeps what
ARP tells it in an eight-entry cache, and answers pings. `IP_PING`, an
address, a sequence number and a time limit in ticks sends an echo
request, asking ARP for the next hop first if the cache lacks it, and
answers with the ticks the reply took, or `E_TIMEDOUT` (its `alarm`
ran out), `E_NOROUTE` (off the network with no gateway), or `E_BUSY`
(one ping is under way at a time). `IP_ADDRESS` gives its address,
prefix length and gateway, `10.0.0.2/24` and `10.0.0.1` at boot, and
`IP_CONFIG` sets them. An address is a word, a.b.c.d being
a × 2²⁴ + b × 2¹⁶ + c × 2⁸ + d.

It carries UDP too. A process binds one port with `IP_BIND` (0 picks a
free one from 49152 up). `IP_SEND` takes a buffer that starts with the
address and port it goes to, four octets and two, then the data, up to
1,472 octets. `IP_RECEIVE` fills a buffer the same way with the
sender's address and port, waiting up to a time limit in ticks, or for
ever with 0. A datagram that comes while its process is not receiving
is kept, in one of ten slots in the server's block window, for its
next receive; when the slots are full it is dropped, as UDP may. A
datagram to port 7 that nobody has bound is sent straight back: the
echo service. A port goes with its process. A send to a host whose
Ethernet address is not known waits for ARP, one at a time, and fails
with `E_TIMEDOUT` if nobody answers.

And it carries TCP. A connection is a descriptor, given with `give`:
`IP_CONNECT`, an address and a port, answers with one once the
handshake is done, or with `E_REFUSED` (the other end reset it: nothing
listens there), `E_TIMEDOUT` or `E_NOROUTE`. A process listens on one
port with `IP_LISTEN` (0 stops), and `IP_ACCEPT` waits for a connection
to it: the descriptor, then the other end's address and port. The
handshake does not wait for accept: up to eight connections at once,
in use or waiting to be accepted. `read` on a connection waits for
data and gives 0 once the other end has closed; `write` waits until all
of it is queued; either fails with `E_RESET` once the other end reset
the connection, or `E_TIMEDOUT` once it stopped answering.
`iocall(fd, IO_SHUTDOWN)` ends writing, so the other end reads to its
end while this one still reads, and closing the last descriptor closes
the connection once what was written has been delivered. A listener
that ends resets what it had not accepted. A connection to port 7 that
nobody listens on is the echo service.

Each connection holds 4,380 octets each way, three segments of 1,460
(the MSS the server asks for), in four more block windows of the
server's, and that is the window it offers. The window slides: as many
segments go as the other end's window takes, and each acknowledgement
makes room for more. If the oldest octet out is not acknowledged in
time, everything from it is sent again (go-back-N: segments that come
out of order are dropped, and a segment partly received before keeps
only its new part), the timeout doubles, and after six tries the
connection gives up. The timeout comes from measured round trips, as
RFC 6298 has it: 1,000,000 ticks until one is measured, then the
smoothed round trip plus four times its variation, from 100,000 to
2,400,000 ticks; one segment at a time is timed, and never one sent
again. A closed window is waited for, since the other end says when it
opens; if it stays closed past the timeout, one octet probes it, and
probing does not count as a try. Sequence numbers start from the
clock. There is no TIME-WAIT: a connection is forgotten
once both ends have closed, so a late copy of the other end's FIN
gets a reset.

Names come from a name server, whose address the IP server keeps for
programs but never asks itself: `IP_NAMESERVER` with an address sets
it (0 for none) and with `NS_KEEP` only reads it; either way the answer
is the one it was, 10.0.0.3 at boot, where detrytus's `--net user`
plays one. trystd's `net::lookup_host` is the resolver, a stub as on Unix: it
binds a free UDP port, sends one query for the name's A records with
recursion desired, and waits 200,000 ticks for the answer, three times
before `E_TIMEDOUT`; it gives up to as many addresses as asked for, or
`E_NOENT` (NotFound) for a name that does not exist or has none. `net::host_address`
takes a.b.c.d as it stands and resolves anything else, which is how
the tools take names.

`bin/ping HOST [COUNT]`, `bin/ifconfig [ADDRESS/PREFIX [GATEWAY]]`
(`ifconfig nameserver ADDRESS` sets the name server), `bin/host NAME
[SERVER]` and `bin/nc` are its tools in the shell; a HOST is an address
or a name. `nc HOST PORT` connects,
sends its standard input, shuts down writing and prints what comes
back until the other end closes; `nc -l PORT` accepts one connection
and prints what it sends; `-u` before either does the same with UDP
datagrams. One direction at a time: there is no waiting on two
descriptors at once, so a peer that sends a lot back before it has
read everything waits for nc as nc waits for it.

Run with `detrytus run --net loop` for a link that hands every frame
back, where pinging the machine's own address runs the whole exchange,
or `--net udp:LOCAL,PEER` to carry frames over UDP to another machine
(detrytus `README.md`): give the second one another `--mac` and
another address with `ifconfig`, and run both with `--live` so that
their clocks keep to real time. `--net user` reaches the host's
network through a gateway detrytus plays at 10.0.0.1, the default
gateway, which translates to the host's sockets and stands for the
host itself, and answers names at 10.0.0.3 from the host's resolver
(detrytus `docs/platform.md`). The tests start the servers with
`run(..., net=True, link="loop")`, or `ip=True` for both.

## Files

The disk can hold a filesystem, shaped like a Unix one: inodes with
permissions, owners and times, nested directories with `.` and `..`,
and files reached by path through file descriptors, all kept in one
copy-on-write B-tree ([`docs/filesystem.md`](filesystem.md)). The
kernel knows nothing of it: a process, the **file server**
(`user/rust/fsd`, in Rust on the `lib/rust/tryfs` crate that the host's
disk tool shares, with `user/fsd.s` its start), reads it into its block
windows and answers `call`s to open files and to make and
remove files and directories, and descriptor calls to read, write and
list what was opened, keeping each open file and each process's current
directory; each call that changes something is a transaction, on the
disk before the reply or not at all. It registers
as `fs`, protocol `FS_PROTOCOL`, and clients find it by that name. It
also starts program files: a program from the disk is the file server's
doing, not the kernel's (`spawnw`). `tools/fs.py` makes and changes
filesystems on the host, and stores a `.s` or `.dti` file as a program,
in `/bin`.

## Pipes

Pipes come from a process, the **pipe server** (`user/piped.s`,
registered as `pipe`): `PP_PIPE` gives the caller a read end and a write
end as descriptors. A read waits for something to read and gives 0 once
no write end is left; a write waits until all of it is in (a pipe holds
729 trytes) and is `E_PIPE` once no read end is left.

## The shell

Program 0 of the `shell.s` build is `user/init.s`. It starts the
console, disk and file servers in that order, waiting for each to
register its name before the next, then reads **`/etc/init`**, which
says what else to start, then starts that, then the shell
(`user/sh.s`), and then waits in `receive` for its children to end.

`/etc/init` is text, a line at a time; an empty line, or one that
starts with `#`, says nothing. A line names either

- one of init's other servers, `pipe`, `net` or `ip`, by the name it
  registers: init starts it, and what it needs (`ip` needs `net`), in
  init's order (pipe, net, ip) whatever the file's, waiting for each to
  register; or
- a program file, by a path that starts with `/`, and its arguments,
  words split at spaces (no quoting): init has the file server start
  it, after the servers and in the file's order, with the console as
  its standard output and error and no standard input, and says
  `init: started /bin/httpd, process 7`.

Init reads at most 729 characters of it (`INIT_TAB`) and keeps at most
9 programs (`INIT_PROGS`), and says on the kernel's log a line it
cannot follow (`init: /etc/init: no server named www`, `init: cannot
start /bin/nothing`). Without `/etc/init`, or without a file server to
read it, init starts every server and no program, so a disk with no
`/etc` starts the same servers as the `etc/init` that `make` puts on
`disk.img`, which also starts `bin/ntpd`:

```text
pipe
net
ip
/bin/ntpd
```

Then:

- When the shell exits, init exits with its code, and the machine
  powers off once only servers asleep in `receive` are left. A shell
  that faults or is killed is started again.
  Init ends the programs from `/etc/init` first, so that only servers
  are left.
- When a server ends, init ends what needs it (the file server needs the
  disk server, and the programs and the shell need them all, since they
  hold their process numbers and handles), then starts them again, the
  server first: `init: disk ended, starting it again`.
- A program from `/etc/init` that exits is done, and is not started
  again: a one-off job. One that faults or is killed is, as a server
  is: `init: /bin/httpd ended, starting it again`.
- Each server, program and the shell is started again at most 3 times
  (`INIT_RETRIES`). Then init gives up on it (`init: disk ended too
  often, giving up on it`): a server stays down with what needs it, and
  the shell runs without them; giving up on the shell, init exits with
  code 1.

A server that cannot start, or registers another protocol version than
init expects, is said on the kernel's log (`init: no server named
disk`) and so is every server that needs it. As each server
registers, init says so with its process number (`init: started disk,
process 2`), and it says `init: starting sh` before each start of the
shell, which prints its prompt at once. Init waits for each name with
`LOOKUP_WHILE`, so a server that ends before it registers ends the
wait: it counts as a start, as if it had ended later, and init starts
it again until it gives up on it.

The shell finds the console, pipe and file servers by name, does
without any that is missing, opens the console as descriptor 0 and
copies it to 1 and 2, then reads a line at a time.

**Line editing.** The shell echoes what is typed and edits the line
(up to 60 characters) as a Unix shell's line editor does, telling the
terminal with backspaces, which move left, and characters printed over
what is there, so any terminal follows:

| Key | Does |
|-----|------|
| left, right (Ctrl-B, Ctrl-F) | move the cursor; typing inserts at it |
| Home, End (Ctrl-A, Ctrl-E) | to the start or end of the line |
| Backspace; Delete | erase before the cursor; under it (Ctrl-D is not Delete: a live console's Ctrl-D ends its input) |
| Ctrl-U, Ctrl-K | erase to the start of the line; to its end |
| Ctrl-W | erase the word before the cursor |
| up, down (Ctrl-P, Ctrl-N) | the last 16 lines typed, a repeat kept once; down past the newest gives back the line being typed |
| Tab | complete the word before the cursor |
| Ctrl-L | clear the screen and print the line again |
| Ctrl-C | drop the line |

The keys arrive as ANSI sequences (`ESC [ A`, `ESC O H`, `ESC [ 3 ~`,
...); any other sequence, and other control characters, do nothing.
Tab completes the first word of a command (at the start of the line or
after `|`) from the built-ins, `pingpong` and the files of `/bin`, and
any other word, or one holding a slash, as a path, from its
directory. One name is typed out, with a space after it, or a slash
after a directory. Several are typed as far as they agree; when that
adds nothing the shell rings the bell, and a second Tab lists them in
columns, then prints the line again. Names starting with a dot are
left out unless the word starts with one.

**Built-ins:** `exit`, `ls [DIR]`, `cat [PATH]` (standard input without
one), `write PATH TEXT`, `rm PATH`, `mkdir PATH`, `rmdir PATH`,
`cd [DIR]` and `pwd`. The system tools are programs (System tools,
above).

**Programs.** `pingpong` is in the kernel image. Any other word names a
program file: a path if it holds a slash, else a file in `/bin`, which
the file server starts as the shell's child, with the line's words as
its arguments, the command first (`wc notes more`, `echo hi`). A program
finds them as `argc` and `argv` at `V_ARGV` (docs/filesystem.md,
Program arguments). Those in `bin/` behave as their Unix namesakes, in
a small way, and say what fails on standard error as `NAME: why`:

- `echo [WORD]...` says its arguments; `upper` copies standard input
  with a to z made capitals.
- `wc [FILE]...` counts lines, words and code points; `head [-n N]
  [FILE]...` says the first N lines (10); `grep [-v] TEXT [FILE]...`
  says the lines holding TEXT, or with `-v` those that do not, as a
  fixed string (Unix's `grep -F`), and exits with 1 when none did. Each
  reads standard input when no file is named, so it works in a pipe:
  `ls bin | grep e | head -n 2`.
- `cp FROM TO` copies a file, and `mv FROM TO` renames one, or a
  directory (`FS_RENAME`), replacing a file of that name; both take
  several names and a directory last (`cp a b dir`) to copy or move
  them into it. `touch FILE...` makes the files that are not there,
  empty.
- The system tools, `ps`, `top`, `kill` and the rest (System tools,
  above).
- `hello`, `fail` (exits with 3) and `spin` (never ends) are for
  tests.

**Redirection.** After the command, `> PATH` sends standard output to a
file, made empty or new, `>> PATH` to its end, and `< PATH` takes
standard input from one, for that command alone, built-in or program:
`hello > out`, `ls >>list`, `cat < notes`. The shell's own complaints go
to standard error, the console, whatever is redirected.

**Quoting** works as in a Unix shell: `echo "hello   world"` and
`echo 'a | b'` give one argument each, keeping the spaces and the `|`,
`\` makes the next character itself, and `""` is an empty argument.

**Pipelines.** A `|` between commands makes one: `hello | upper | wc`,
up to four commands. The shell starts every program of the line, each
with its pipe ends as standard input and output, before it waits for
any, and marks its own ends `FD_NOINHERIT` so that a reader sees the end
when its writer goes. A built-in takes one place in a pipeline
(`ls | wc`, `hello | cat`) and runs in the shell once the programs have
started; two would wait for each other.

**Ctrl-C** sends `SIGINT` to the program the shell is waiting for (in a
pipeline the line's first program first), which ends it unless it
catches the signal, and at the prompt drops the line typed so far.

```bash
tools/fs.py new disk.img 100 notes.txt bin/*.rs
tools/fs.py mkdir disk.img docs
tools/fs.py put disk.img README.md docs
printf 'ls\nls bin\ncat docs/README.md\nwrite docs/motd hello\nhello > docs/hi\n' > session.txt
detrytus run shell.s --input session.txt --disk disk.img
```

## Rust in the kernel

The kernel was moved from assembly to Rust a subsystem at a time,
with every test passing at each step; what stays assembly is the
machine's edge (entry, the trap entry and exit, `schedule` and `idle`,
the lock, the console, page tables and data). The Rust part is one
crate, [`kernel/rust/trykern`](../kernel/rust/trykern), a module per
subsystem: `syscall` (the dispatch, a table of every call's routine,
and the small calls `putc`, `puts`, `getpid`, `hart`, `yield` and
`exit`), `info` (the
`log` and `info` calls above), `names` (`register` and `lookup`),
`desc` (descriptors), `procinfo` (`proc`, `name`, `sleep`, `alarm`),
`wait` (`wait`, `kill`, and burying a process), `signal` (`sigaction`, `sigmask`, `sigreturn`, sending and taking signals), `sched` (which
process runs next, and the sleepers the clock wakes) and `ipc` (`send`,
`recv`, `call`, `receive`, `reply`, `copyin`, `copyout`, `notify`, and
what servers hear when a process ends) and `mm` (the page allocator,
`spawn`, `spawnw`, `window`, `brk`, `phys`, and giving a process's
pages back), `devices` (`drive`, `arm` and device interrupts), `harts`
(starting harts, hot-plug, waking an idle one) and `boot` (the boot
report), with `console` (the kernel's messages, through
kernel/console.s), `mem` (where a process's address is in the kernel), `proc` (a process's record), `kdata` (the kernel's globals),
`trytes` (strings of trytes, which Rust's bytes are not) and `word`
under them. `make kernel` (`tools/kernel.py`) builds
it with cargo for detrytus' Rust target and translates it with `detrytus
ll` (detrytus docs/rust.md) into `kernel/trykern.s`, which
`include/kernel.s` includes: its code in the kernel's code page, its
data after the kernel's own data. It is a build product, not kept in
the repository; the tests build it before they start.

Three things make kernel Rust different from a program's:

- **Its addresses are below 0.** The kernel runs near −364,000, its
  devices from page −9 to −1 and the direct map from `DMAP`, all within
  ±2³¹; `ll --signed-pointers` makes Rust's pointers signed addresses
  that reach them.
- **It works in words.** Saved registers, records, page-table entries
  and system-call arguments are 27-trit words, which Rust has no type
  for. A word is an `i64` on the Rust side, read and written with
  detrytus' `lw` and `sw` builtins (`word.rs`); records are reached by
  their `PCB_` offsets, which stay defined in `include/layout.s`, and
  every number comes from that file (trystd's `build.rs`).
- **It has no `main`.** The assembly calls functions named `rk_*`, which
  are the roots `ll` keeps with what they reach. The system-call trap
  passes the caller's record to `rk_syscall`, `mv a0, s0; call
  rk_syscall`, and the Rust leaves the result in the record for
  `resume` to return; its own result says whether to resume, schedule
  or release the caller.
  Rust keeps `s0` to `s8`, `gp` and `tp`, so the kernel's registers
  survive, and calls the assembly routines it still needs, such as
  `harts_present`, by name. A panic ends in `abort` (`kernel/rt.s`), a
  kernel panic.

Rust costs room: `info.s`'s two calls were about 180 trytes of
assembly and are about 3,100 of Rust, mostly 64-bit arithmetic on words
done 32 bits at a time (the 64-bit division and multiplication helpers
among them, which later modules share). The kernel's code grew from
about 5,900 trytes to 9,000; it has `NKCODE` (3) pages, 59,049 trytes,
and `include/kernel.s` checks that it fits. Speed and size are
left for a pass after the port.
