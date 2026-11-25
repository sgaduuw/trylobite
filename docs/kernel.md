# The trylobite kernel

How trylobite works, for someone writing a program or a server for it:
its memory map, its system calls, and the servers that do what a larger
kernel would do itself. The [README](../README.md) gives the overview;
[`docs/filesystem.md`](filesystem.md) the filesystem's format and the
file server's protocol; [`include/layout.s`](../include/layout.s) every
number named here.

## Booting

The firmware enters the kernel on hart 0, which sets up its page
allocator and then says what it found, on its log, before it starts
init (`kernel/boot.s`). This is the boot of the `shell.s` build, with
a disk of 100 blocks:

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
```

Memory is the RAM the build is for (`RAM_PAGES`), and free what is
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


Every address space has three regions, one per mid-table entry:

| Region | Virtual pages | Contents |
|--------|---------------|----------|
| direct map | around −6561 | all of physical memory, kernel only: kernel virtual = physical − 3¹⁷ |
| kernel | −15, −7 to −2 | the binary floating point coprocessor, which every process may use; the hart controller (its slots, and this hart's own), power off, console, kernel code, kernel data and stack; page 0 unmapped |
| process | 6561 (`V_USER`) | the process's code, data and stack |

The first two regions are shared by every address space. A new process
costs four pages: a root, a mid and a leaf table, and its own page,
into which `spawn` copies the program image loaded at boot, or
`spawnw` a program file read from the disk. Block windows take up to
nine more, as a process asks for them; a driver also has its device's
registers mapped past them, at `V_DEVICE`.

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
| 0 | firmware |
| 1, 2 | kernel code; kernel data |
| 3, 4, 5 | the boot address space; the kernel's shared leaf table |
| 6 .. 5 + `NPROG` | program images 0 to `NPROG` − 1, at most 27 (`NPROG_MAX`; the demo has 3, the shell build 8) |
| 6 + `NPROG` .. `RAM_PAGES` | free pages, handed out by the allocator |

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
| 5 | `getpid()` | this process's number |
| 6 | `puts(address)` | 0; −2 if the string is outside the process's page and block windows |
| 7 | `spawn(program)` | the new process's number; −1 no free slot, −2 no such program, −3 not enough memory |
| 8 | `hart()` | the number of the hart running the caller, −4 to +4 |
| 10 | `wait(pid)` | how child `pid` ended, once it has: `a0` 0 exited, 1 faulted or 2 killed, `a1` its exit code, trap cause, or 0 when killed; `a0` −2 if `pid` is not the caller's child |
| 13 | `kill(pid, for)` | ends `pid` before it runs again, a child of the caller when `for` is `FOR_SELF` (−1), or, for a driver, a child of process `for`: 0; 1 (`KILL_ENDED`) if it had ended already; −2 if `pid` is not that process's child, −21 `for` from a process that drives nothing. With `for` `KILL_ANY` (−2), any process but init: 0; −2 none, or it has ended; −21 for init |
| 15 | `spawnw(window, for, args, n)` | starts the program file whose first block is in block window `window` (docs/filesystem.md), as the caller's child when `for` is `FOR_SELF` (−1), or as the child of process `for`, whose call the caller holds, with the `n` trytes of arguments at `args` in that parent's memory (docs/filesystem.md, Program arguments): as `spawn`, with −2 when there is no window or no program in it, or `for` is not waiting for the caller, −10 (`E_INVAL`) for `n` below 0 or above `ARG_MAX`, −12 (`E_FAULT`) for arguments not all in the parent's memory |
| 16 | `close(fd)` | empties descriptor `fd`: 0; −8 if it names nothing |
| 17 | `give(pid, handle)` | puts the caller's `handle`, 0 to 26, in the lowest free descriptor of process `pid`, whose call the caller holds: the descriptor; −9 none free, −2 `pid` is not waiting for the caller, −10 no such handle |
| 18 | `dup2(fd, to)` | makes descriptor `to` a copy of `fd`, closing what `to` held: `to`; −8 if `fd` names nothing or `to` is not 0 to 8 |
| 19 | `iocall(fd, op, x, y)` | a call to the server descriptor `fd` names, with `op`, an `IO_` operation (negative), its handle, `x` and `y`: the server's answer; −8 if `fd` names nothing, −10 if `op` is not an `IO_` operation. Leaves `a1` to `a5` as `call` does |
| 20 | `read(fd, buffer, n)` | `iocall` with `IO_READ`: at least one and at most `n` trytes, 0 at the end |
| 21 | `write(fd, buffer, n)` | `iocall` with `IO_WRITE`: how many were written |
| 22 | `fdflags(fd, flags)` | sets descriptor `fd`'s flags: `FD_NOINHERIT` (1), a child does not get a copy, or 0: 0; −8 if `fd` names nothing, −10 another flag |
| 23 | `call(pid, w1, w2, w3, w4)` | sends four words to process `pid` and waits for its reply: the reply's four words in `a0` to `a3`; `a0` −2 if there is no such process or it ends first, −3 if `pid` is the caller, −10 if `w1` is negative (an `IO_` operation, which only a descriptor sends) |
| 24 | `receive()` | waits for a call: `a0` the caller, `a1` to `a4` its words; or `a0` `FROM_KERNEL` (−1) and `a1` `NOTE_ENDED` (0), `a2` a process that ended, or `a1` `NOTE_IRQ` (1), `a2` a device source the caller drives that interrupted, or `a1` `NOTE_CLOSED` (2), `a2` a handle of the caller's that no descriptor names any more, or `a1` `NOTE_SIGNAL` (3), `a2` a process that notified the caller, or `a1` `NOTE_ALARM` (4), the caller's alarm went off |
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
| 40 | `alarm(until)` | when the `time` CSR reaches `until`, the caller's `receive` gives a `NOTE_ALARM` notice; a later alarm replaces an earlier one, and `NO_ALARM` (−1) cancels it: 0 |

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
`kill`, `free`, `uptime`, `uname`, `dmesg`, `sleep` and `df`. The kernel
only reports; the tools read it with a few calls and format it
(`kernel/info.s`, `kernel/proc.s`), and `df` asks the file server
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
memory in pages and in trytes. The machine has no seconds: its clock,
the `time` CSR, counts one tick per step (detrytus platform.md, Time),
so times are in ticks.

**Processes.** `proc` fills, for one process, `PI_STATE` (an `ST_`
value), `PI_PARENT` (`NO_PARENT`, −1, for none), `PI_PAGES` (its four
and its block windows; 0 once ended), `PI_CPU` (the ticks it has run in
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

`top [-n COUNT]` clears the terminal and shows the same table with each
process's share of the clock since the last screen (`CPU%`), every
million ticks, until Ctrl-C or COUNT screens; it waits with `sleep`,
whose time is absolute, so the screens keep step. A sleeper is woken
by the hart that next schedules, and a hart with nothing to run sets
its timer for the earliest sleeper, so sleeping is neither a busy wait
nor, with nothing else running, a deadlock.

`kill PID...` ends any process but init (`KILL_ANY`): there are no users
to tell apart, so this is Unix's root. A server killed this way is
started again by init, with what needs it, the shell included.

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

## The disk

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
is kept, in one of twelve slots in the server's block window, for its
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

Each connection holds 1,460 octets each way, one segment (the MSS the
server asks for), in two more block windows of the server's. One
segment is in flight at a time: the next goes once the last is
acknowledged, and it is sent again after 300,000 ticks without, six
times before the connection gives up. A closed window is probed one
octet at a time, and probing does not count as a try. Sequence numbers
start from the clock. There is no TIME-WAIT: a connection is forgotten
once both ends have closed, so a late copy of the other end's FIN
gets a reset.

`bin/ping ADDRESS [COUNT]`, `bin/ifconfig [ADDRESS/PREFIX [GATEWAY]]`
and `bin/nc` are its tools in the shell. `nc ADDRESS PORT` connects,
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
host itself (detrytus `docs/platform.md`). The tests start the servers with
`run(..., net=True, link="loop")`, or `ip=True` for both.

## Files

The disk can hold a filesystem, shaped like a Unix one: inodes, nested
directories with `.` and `..`, and files reached by path through file
descriptors ([`docs/filesystem.md`](filesystem.md)). The kernel knows
nothing of it: a process, the **file server** (`user/fsd.s`), reads it
into its block windows and answers `call`s to open files and to make and
remove files and directories, and descriptor calls to read, write and
list what was opened, keeping each open file and each process's current
directory; it writes what a call changed before it replies. It registers
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
console, pipe, disk and file servers in that order, waiting for each to
register its name before the next, then the shell (`user/sh.s`), and
then waits in `receive` for its children to end:

- When the shell exits, init exits with its code, and the machine
  powers off once only servers asleep in `receive` are left. A shell
  that faults or is killed is started again.
- When a server ends, init ends what needs it (the file server needs the
  disk server, and the shell needs them all, since it holds their
  process numbers and handles), then starts them again, the server
  first: `init: disk ended, starting it again`.
- Each server and the shell is started again at most 3 times
  (`INIT_RETRIES`). Then init gives up on it (`init: disk ended too
  often, giving up on it`): a server stays down with what needs it, and
  the shell runs without them; giving up on the shell, init exits with
  code 1.

A server that cannot start, or registers another protocol version than
init expects, is said on the kernel's log (`init: no server named
disk`) and so is every server that needs it. As each server
registers, init says so with its process number (`init: started disk,
process 3`), and it says `init: starting sh` before each start of the
shell, which prints its prompt at once. Init waits for each name with
`LOOKUP_WHILE`, so a server that ends before it registers ends the
wait: it counts as a start, as if it had ended later, and init starts
it again until it gives up on it.

The shell finds the console, pipe and file servers by name, does
without any that is missing, opens the console as descriptor 0 and
copies it to 1 and 2, then reads a line at a time.

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

**Ctrl-C** ends the program the shell is waiting for (in a pipeline the
line's first program first), and at the prompt drops the line typed so
far.

```bash
tools/fs.py new disk.img 100 notes.txt bin/*.s bin/*.tc
tools/fs.py mkdir disk.img docs
tools/fs.py put disk.img README.md docs
printf 'ls\nls bin\ncat docs/README.md\nwrite docs/motd hello\nhello > docs/hi\n' > session.txt
detrytus run shell.s --ram-pages 81 --input session.txt --disk disk.img
```
