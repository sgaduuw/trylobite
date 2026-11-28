# CONTEXT.md

The decisions behind trylobite and why they were made. Add an entry at
the end when you make one someone might later want to undo.

---

### 2026-11-18 · A separate repository, with detrytus pinned

The kernel lives apart from the machine so each can move at its own
pace. detrytus is a git dependency pinned in `uv.lock`, so a detrytus
change never breaks the kernel until the pin is moved on purpose.

### 2026-11-18 · The kernel lives in negative addresses, entered translated

Following the detrytus convention, the kernel runs in negative virtual
addresses (`physical - 4 pages`) and user programs in positive ones,
with page 0 unmapped. The firmware runs untranslated in ring +1, so it
sets `ptbr` before its `tret` and the kernel's first instruction already
runs through the page table. No identity mapping is needed for the
switch, which an identity map would otherwise force into the kernel's
address range.

### 2026-11-18 · Page tables built at assembly time, for now

Milestone 1 has a fixed set of processes, so their page tables are
assembled as data (`kernel/pagetables.s`). Superseded in milestone 2:
only the boot address space is assembled now; processes get their
tables at run time.

### 2026-11-18 · Process records and the zero-sscratch convention

Each process has a record holding its registers (register `r` at
`3 * (r + 13)`), pc, `ptbr`, state and mailbox. While a process runs,
`sscratch` holds its record; in the kernel it holds 0. A trap swaps `sp`
with `sscratch`, so it gets the record to save into, or 0 for a trap
inside the kernel, which panics. The kernel is not preemptible: traps
leave interrupts off in ring 0, and there is one kernel stack.

### 2026-11-18 · Messages: one slot per process, non-blocking send

`send` places a value in the receiver's one-slot mailbox, or hands it
straight to a receiver already blocked in `recv`. A full mailbox makes
`send` return −1 rather than block the sender, which kept the kernel's
first scheduler simple; the sender yields and retries. `recv` blocks. If
every live process is blocked in `recv`, the kernel reports deadlock and
powers off with exit code 1.

### 2026-11-18 · `puts` exists because preemption splits `putc` output

With one system call per character, a timer interrupt mid-line
interleaves two processes' output character by character. `puts` prints
a whole string in one call. It reads user memory with `SUA` on, and only
after checking the address lies in the caller's page, so a process can
neither make the kernel print kernel memory nor make it fault.

### 2026-11-18 · Every exception goes to the kernel

The firmware delegates causes +1 to +9. Anything that still reaches ring
+1 powers the machine off with the cause as the exit code, so a missing
delegation cannot pass silently.

### 2026-11-19 · Labels are virtual, through section run addresses

The kernel used to be assembled at physical addresses, so its labels
were physical: code reached its own data pc-relatively, the firmware
entered it with `kentry - KOFF`, and the debugger could not name kernel
addresses. detrytus now lets a section load at one address and run at
another (sgaduuw/detrytus#7), so the kernel and user sections carry
their virtual run addresses and every label is what the code sees. The
same change brought `.words`, which replaced a `+1` adjustment that the
process table needed because `.zero` starts one tryte below a word's
centre.

### 2026-11-19 · Three regions, so address spaces share almost everything

Every address space has a direct map of physical memory (mid entry −1,
one superpage), the kernel (mid entry 0, a leaf table shared by all),
and the process (mid entry +1). Moving user programs to their own
mid-level region, at 3¹⁷, is what lets the kernel's leaf table be shared
instead of copied: a new address space differs from the boot one only in
its root, its mid table's entry +1, and the leaf table under it. A
process costs four pages.

### 2026-11-19 · The page allocator is a free list in the free pages

Each free page's centre word holds the next free page's number, reached
through the direct map; page 0, the boot page, means "none". A count of
free pages lets `spawn` check it has all four before taking any, so it
never has to undo a half-built process. Tables are zeroed when allocated;
the process's own page is not, since the program copy overwrites it.

Freeing a page writes its centre word, which in a root table is entry 0.
The first version freed a process's pages while still running on its
address space, corrupting the live table; `release` now switches to the
boot address space first.

### 2026-11-19 · spawn copies program images loaded at boot

There is no file system, so programs are images the loader places in
fixed physical pages. `spawn(n)` copies image `n` into a fresh page, so
the same program can run several times, each copy with its own data. The
kernel starts only program 0, `init`, which starts the rest.

### 2026-11-19 · Process numbers are handed out round-robin

`spawn` searches for a free slot starting after the last one it used.
Taking the lowest free slot reused a number at once: a spawn is slow
enough that a child could exit before its parent's next spawn, which
then got the same number, so a message meant for the old process could
reach the new one. A process's ASID is its number plus 1, and spawning
into a slot runs `fence.vm` for that ASID; the emulator's never-evicting
TLB makes a missing fence visible at once, and a test checks it.

### 2026-11-19 · RAM size is a build parameter

The kernel cannot probe how much memory the machine has, so each build
states it (`.equ RAM_PAGES, 40` in `demo.s`) and the emulator must be
run with at least that many pages. Tests use small values to exhaust
memory on purpose.

### 2026-11-19 · Paging makes the emulator slow; noted for detrytus

With translation on, detrytus runs about 100,000 instructions a second
against about 600,000 without (measured on `demo.s`: 293,517 steps in
3.1 s). Every access rebuilds a `Ptbr` object and rechecks the leaf's
permission trits. A spawn costs 92,499 instructions (measured: the
difference between an init that spawns once and one that spawns twice),
mostly zeroing three tables and copying a page, so the test suite takes
about a minute. A
faster translation path in detrytus is the fix, rather than fewer tests.

### 2026-11-19 · The detrytus speed-up arrived

sgaduuw/detrytus#8 made translation about 2.5 times faster. With the pin
moved to it, the 21 tests take 23.1 s instead of about 60 s (measured on
the same machine). A Rust emulator core is planned in detrytus for the
next big step.

### 2026-11-19 · Tests run on detrytus' Rust core too

detrytus now has a Rust core, reached from Python through an optional
package (`detrytus-rs`). The test helper builds machines with
`detrytus.machine.create`, so `DETRYTUS_BACKEND=rust` runs the suite on
it: 21 tests in 1.5 s against 17.3 s on the Python core (measured on
the same machine). `tools/install-rust-backend` installs the package at
the detrytus commit `uv.lock` pins, so the two cores never come from
different versions. CI runs the tests on both cores; the Python job
stays, as detrytus' reference.

### 2026-11-20 · The tests drive the detrytus binary

detrytus is retiring its Python tools (its rust-plan, phase 6), so the
tests no longer import a Python package. They stay in Python and pytest,
as the owner preferred, but call the `detrytus` command: `asm -` with
the source on stdin builds a kernel (the image's labels and symbols are
read from its metadata), `run --stats` runs it (the exit code is read
from the stats line, since the process status is only its low byte),
and the one test that inspects memory afterwards runs a `debug` script
using `xp`, which reads physical memory untranslated. The binary is
installed with `cargo install` at the commit `detrytus.rev` pins,
replacing the `uv.lock` pin. The 21 tests take about 2 seconds,
against about 17 on detrytus' Python core.


### 2026-11-20 · Several harts, under one kernel lock

detrytus gained several harts (its isa.md 5.6), so the kernel runs on up
to nine, harts −4 to +4: enough for a triad or the middle nine, with
per-hart tables of fixed size. Hart 0 boots and starts the others
through the hart controller; each enters the firmware like hart 0, with
the kernel entry in `a0`, and the firmware passes the hart's number in
`a1`, because `hartid` is a ring +1 CSR. The kernel keeps it in `tp`,
and in the process record while a process runs, so a trap can reload it.

- **One lock for the whole kernel.** Taken after a trap has saved the
  process's registers, given back just before `resume` restores them.
  The kernel is small and its paths are short, so this costs little and
  makes every structure safe at once; finer locks can come if a
  measurement asks for them. It also keeps a `puts` line whole. With the
  lock held whenever the kernel stack is used, one stack serves every
  hart.
- **`ST_RUNNING`.** A process on a hart is no longer marked ready, so
  two harts cannot pick it. Preemption and `yield` turn it back to ready.
- **Idle harts wait on their mailbox.** A hart with nothing to run, while
  something runs elsewhere, marks itself idle, gives the lock back and
  waits in `wfi` with only the doorbell enabled. `spawn` and a `send`
  that wakes a receiver ring one idle hart's doorbell. The doorbell stays
  rung while a word waits, so a wake-up just before the `wfi` is not
  lost; the woken hart empties its mailbox under the lock. The firmware
  delegates the doorbell to ring 0 (`ideleg`). Deadlock is now "every
  live process waits and none runs anywhere"; "all exited" is unchanged.
- **Reused ASIDs are flushed lazily.** A `fence.vm` in `spawn` only
  cleared the spawning hart's TLB, and another hart may have run the
  slot's last tenant. Rather than interrupting every hart, each slot
  counts its tenants (an epoch), and a hart flushes the ASID in `resume`
  when it first runs a slot in a new epoch. Stale entries for an ASID
  can only matter once that ASID runs again, and the kernel's own
  mappings never change, so this is enough.
- **`SYS_HART`** returns the running hart's number: useful to programs,
  and how the tests show work really ran on several harts.

The cost on one hart: each trap now takes and gives the lock and checks
the slot's epoch, so the demo runs about 5% more kernel instructions.
The tests run every case on one hart and on three.

### 2026-11-20 · kernel.s moved to include/, and says how to build it

Running `kernel.s` on its own failed with "undefined symbol
'RAM_PAGES'" from deep inside `kernel/mm.s`, which reads as a bug rather
than "this is not the file to run". It now lives at `include/kernel.s`,
beside the other files meant only to be included, and its first line
uses `RAM_PAGES` with a comment saying what to run instead: the
assembler prints the failing line, comment and all. A real `.error`
directive would need a detrytus assembler change; this needs none.

### 2026-11-21 · Hot-plug: hart 0 hears it, a leaving hart stops itself

The hart controller announces a hart added or asked to go with an
external interrupt on its event hart, hart 0 by default. Hart 0 suits
the job: the platform never removes it, so the events always have
somewhere to go. The firmware delegates the external interrupt to ring
0 as well as the doorbell, and hart 0 enables it while running and
while idle; idle, it takes the events as soon as it wakes.

- **Added:** a hart in the middle nine is started as at boot. Others
  stay stopped, as at boot.
- **Asked to go:** hart 0 marks it leaving and rings its doorbell if it
  waits for work. The hart checks the mark at `pick`, the one point where
  it holds no process (whatever it ran is already back in the table as
  ready, waiting or exited), wakes another hart for any work it left,
  gives the lock up and stops itself; the platform then removes it. A
  running hart reaches `pick` within a timer slice.
- **Starting clears the mark.** A hart added and asked to go before hart
  0 sees either event is gone by then, but would keep the mark; plugged
  in again, it would leave at once.
- The kernel prints `trylobite: hart N joined` and `... left`, so a run
  shows what the platform did and the tests can check it.

The tests schedule events with `--plug` and `--unplug` at times after
the kernel has booted (user code starts at about time 93000).

### 2026-11-21 · Lock waiters sleep in `wrs`, and CSR writes from zero

`klock_take` waits with `lr` and `wrs` (detrytus 81b2b5a) instead of
spinning on `amoswap`: a hart that finds the lock held sleeps until the
holder's release breaks its reservation, then takes it with `sc.aq`. It
clears `sie` while waiting, because a pending enabled interrupt ends a
`wrs` at once, and a hart entering on a timer trap has its timer pending
until `on_timer` moves `stimecmp`, under the lock; an idle hart coming
back from `wfi` has its doorbell pending until it empties its mailbox,
also under the lock. With the demo's workload on three harts the kernel
runs 594,000 instructions instead of 677,000; the lock itself 18,000
instead of 106,000. On one hart the longer lock costs under 2%. Steps
barely change: the machine counts rounds, and a sleeping hart still sits
through them.

Getting there found a mistake older than the lock. `csrw X, zero` reads
X and writes nothing, since a CSR instruction whose source is `r0` only
reads. Trap entry meant to zero `sscratch` that way, so in the kernel it
still held the user's stack pointer, and a trap inside the kernel would
have saved registers there instead of reaching `kpanic`. `puts` meant to
turn SUA off the same way (harmless: `resume` rewrites `ststatus`). Each
now writes from a register holding 0, and AGENTS.md says so.

### 2026-11-21 · getc, and failures that are negative by name

Milestone 3 is a shell, and a shell reads what is typed. `getc` (9)
returns the next code point from the console, which detrytus now feeds
from `run --input FILE` (pin 3aa4f85).

- **Negative means no character.** A code point is never negative, so
  the sign alone tells a character from none, and one `br3` separates
  none, NUL and a character. The owner asked whether returning −1 would
  confuse anyone on a machine where −1 is as ordinary a value as 0 or
  1: it would, as a magic number. So the rule is the sign, and the value
  has a name, `GETC_NONE`. The kernel returns that name rather than
  whatever negative value the device used.
- **It does not wait.** Nothing tells the kernel that input arrived, so
  a blocking `getc` would have to poll the console on every timer tick,
  and deadlock detection would need to know about it. With all input
  fed up front, none now means none ever. A blocking `getc` can come
  with a console interrupt from detrytus, and may then add a second
  negative value for "would block".
- **Every error code has a name.** The kernel wrote failures as bare
  literals, and −1 meant three things: no such call, mailbox full, no
  free slot. They are now `E_NOCALL`, `E_FULL`, `E_NOSLOT` and so on in
  `include/layout.s`, with the same values, so nothing a program sees
  changes. The rule, in AGENTS.md: a result that is a status or never
  negative reports failure as a negative name; a result that can be any
  word (`recv`, and soon `wait`'s exit code) carries no failure in it.

### 2026-11-21 · wait, and exit codes that outlive their process

A shell runs a program and then needs to know how it went, so `wait`
(10) blocks until a given child has ended and says how.

- **Two results.** An exit code can be any word, negative ones included
  (the tests exit with −1), so it cannot share a register with "not
  your child". `wait` returns the status in `a0`, as every call does,
  and the code in `a1`. The status is three-way: negative a failure
  (`E_NOCHILD`), 0 the child exited (`a1` its code), +1 it faulted (`a1`
  the trap cause). One `br3` takes it apart.
- **Zombies.** A process's pages go back the moment it ends, as before,
  but its record stays as `ST_ZOMBIE`, holding how it ended in its saved
  `a0` and `a1`, the very registers its parent's `wait` returns. Those
  were dead anyway, so the record needed only one new field,
  `PCB_PARENT`.
- **Orphans go at once.** A parent that ends unlinks its children and
  frees those already ended, since nobody can wait for them now. `init`
  has no parent. This keeps the demo, whose `init` leaves right after
  spawning, exactly as it was.
- **The cost:** a program that spawns in a loop must now wait for its
  children, or a slot is lost with each one. Two tests spawned until a
  slot came round again; they now wait, which is also what their
  comments said they meant ("let this B finish, freeing its slot").
- **Deadlock detection is unchanged.** The plan was to count `ST_WAIT`
  beside `ST_RECV`, but it adds nothing: a wait only blocks on a live
  child, and a chain of waits ends in a process that is running, ready
  or in `recv`. So when nothing can run, someone is in `recv`, and the
  existing check finds it. A test covers a parent waiting on a child
  stuck in `recv`.

### 2026-11-21 · A shell, in a build of its own

Milestone 3's goal: a person types at trylobite. `shell.s` builds the
kernel with `sh` as program 0. It reads a line with `getc`, echoing it,
runs the program the first word names, `wait`s for it, and reports a
nonzero exit code or a fault. It stops at the end of input, so a
session is a file fed with `detrytus run --input`, the same every run.

- **A build of its own.** `demo.s` stays as it was, the multi-hart
  showcase the README describes; the owner chose that over making
  `init` start the shell everywhere. `pingpong` is the demo's `init`
  as a program the shell runs, except that it waits for ping and pong,
  so the prompt comes back once they are done.
- **`NPROG` belongs to the build**, like `RAM_PAGES`: the shell needs
  six programs and the demo three, and fixing six for both would take
  three pages from the demo's free memory for nothing. The kernel finds
  image `n` at page `P_PROG0 + n`, so the table of image pages went.
- **Names are looked up in `sh` itself**, in a table of name and program
  number. `spawn` takes a number, and there is no file system to look a
  name up in.
- **No arguments yet.** Only the first word counts. Passing the rest
  needs `spawn` to copy a string into the child's page.
- **Backspace and delete erase**, echoed as back, blank, back. The
  assembler has no `\b` escape and turns one into a plain `b` without a
  word, so the rubout string is written with `.tryte`; detrytus should
  refuse escapes it does not know.
- **Not tested:** the shell's report of a faulting program, since none
  of the six programs faults. The kernel side, `wait` returning
  `WAIT_FAULTED`, has its own test.

### 2026-11-21 · getc waits for input

detrytus now has an interrupt controller and tells "nothing yet"
(`CONSOLE_EMPTY`) from "nothing ever" (`CONSOLE_CLOSED`), the two things
the first `getc` lacked (see above). `getc` now sleeps on the first and
returns `GETC_NONE` only on the second.

- **A reader blocks as `ST_GETC`** and the console source is enabled; it
  is level-triggered, so input that came in between is not lost. The
  source is masked again once nobody waits, so a closed console (which
  stays pending) does not interrupt for ever.
- **Hart 0 serves every device source**, as it serves hot-plug events:
  the controller routes to hart 0 at reset, and hart 0 already takes the
  external interrupt, in user mode (`on_external`) and in `idle`. One
  place to look, and no routing to change when harts come and go.
- **On an interrupt, the reader goes to the ready queue** and the
  interrupted process carries on, as for hot-plug events. Each waiting
  reader gets one code point, in table order; once the console is
  closed, all of them get `GETC_NONE`.
- **Waiting readers are not a deadlock**, and not "all exited": while one
  waits, a hart with nothing to run idles for an interrupt. Under `run`
  this never happens, since the console is closed behind the input.
- **Tested in the debugger**, which keeps the console open: a session
  steps until the program waits, types with `input`, and ends with `eof`.
  `Run.words` reruns in the debugger, so it closes the console first, as
  `run` does.

### 2026-11-21 · A disk driver with a block window per process

detrytus's block device moves whole pages; a process has one page, which
holds its code and stack. The owner chose a **block window**: a second
page per process, at `V_BLOCK` (leaf entry +1, just above its own), made
on its first `bread` or `bwrite` and freed when it ends.

- **DMA straight into the process**, with no kernel copy: the window's
  physical page is the command's one list entry. Rejected: byte ranges
  copied through a kernel buffer (a copy on every call), and a
  kernel-only driver until the file system (nothing to test it with).
- **One command at a time.** A process asking while another's command is
  in flight sleeps as `ST_DISK` with its request in its saved a1 and a2;
  when a command finishes, `disk_irq` starts the next waiting one in table
  order after it, so nobody waits for ever. A single list word in kernel
  data serves every command.
- **Checked before the disk sees it.** A block outside the disk, or no
  disk at all, is `E_NOBLOCK` at once; `E_IO` stays for a command the
  device refuses anyway, which the checks make unreachable today.
- **One block per call for now.** The device can move a run of blocks in
  one command; calls for runs can come with a file system that wants
  them, along with a window that can hold more than one block.
- **`puts` reaches the window**, once there is one, so a program can
  print what it read.

### 2026-11-21 · kernel.s checks what it needs with `.assert`

detrytus gained `.assert E, "MESSAGE"` with `defined(NAME)`, so
`include/kernel.s` now says in its own words that it is included by a
build rather than run, instead of relying on the first undefined symbol
and the comment beside it. It also checks that `NPROG` is 1 to 6.

### 2026-11-21 · The kernel and programs are built with bundles

detrytus (ISA 0.10) runs compressed bundles and its assembler pairs
neighbouring instructions under `.compress`. Every code file now turns
it on; data and page tables stay out. Code in `shell.s` went from 1,261
words to 977 (22% smaller; the image from 1,598 words to 1,314), a
little better than the 21% detrytus' `asm --mix` had estimated.

The one kernel change it needed: a system call returned to `stpc + 3`,
which is wrong when the `sys` sits in a bundle, so it returns to
`stval`, which `sys` now sets to the instruction after it. One test
looked for the letter c in a debugger session to find echoed input;
the debugger's lines now show `c.` instructions, so it looks for a line
that starts with c.

### 2026-11-21 · Globals through gp

detrytus (ISA 0.11) gave `gp` a meaning: set once, then `la` is one
`addi` from it and a global is one `lw` or `sw`, each fitting a slot
(`c.lagp`, `c.lwgp`, `c.swgp`) within 363 trytes. Code in `shell.s`
went from 977 words to 880 (10% smaller).

The kernel points `gp` at `kgp`, 363 trytes above its first global,
and keeps its small globals ahead of the process table so that all of
them and the table's start are in a slot's reach; an `.assert` in
`kernel/data.s` holds the table there. `ktrap` saves the process's `gp`
before loading the kernel's, as it already saved the register.

A process starts with `gp` at `USER_GP` (its page's centre, where its
code begins), set by `spawn` in its saved registers, rather than each
program setting it: a program with one `la` would spend two words to
save one. Programs only say `.gp USER_GP`. The address-then-access
pairs on kernel globals became `lw rd, name` / `sw rs, name`, except
where the address is used again (the disk command's list, whose
physical address is computed from it).

### 2026-11-21 · A bootstrap filesystem: a FAT in block 0, in user space

The shell should list, read and write files on the disk. Three places
for the code were weighed: the kernel (open, read, write as system
calls), a file-server process, and the programs themselves over `bread`
and `bwrite`. The driver runs one command per call and cannot pause a
system call halfway through a multi-block operation, and messages are
one word with no sender, so the first two each need kernel work before
any filesystem. The programs' own code needs none, so that comes first.

The layout is the simplest that lets files grow: block 0 holds a
header, a flat directory of 64 entries and a FAT, one word per block,
chaining each file's blocks and marking free ones (docs/filesystem.md).
One block per file was simpler but capped a file at 19,683 trytes;
inodes and directories as files bring subdirectories at several times
the code. The owner chose to start simple and move to a POSIX-shaped
filesystem later, so this format is expected to be replaced, not
extended.

`tools/fs.py` builds and reads images on the host. It reads the format's
numbers from `include/layout.s`, and a test checks it agrees with the
assembler about each of them.

### 2026-11-21 · Ctrl-C and kill, rather than pre-emption

The owner asked for pre-emptive scheduling so that a runaway process
cannot freeze the others. The kernel had it already (`on_timer`, and a
test with a spinner that never makes a system call), so what a runaway
still froze was the shell, waiting for it with no way to end it. The
owner picked Ctrl-C from a short list (with fairer scheduling and
stopping there).

- **A killed process ends the next time the kernel would run it**:
  `kill_pid` sets `PCB_KILLED`, and `ktrap` and `resume` end a marked
  process (`on_kill`, then `release` as for a fault). A process running
  on another hart cannot be freed under it, and a timer slice bounds
  the wait. One blocked in `recv`, `wait` or `getc` is made ready so it
  gets there; one in the disk queue keeps its place, since the disk may
  be writing its block window. `wait` reports `WAIT_KILLED`.
- **Only a parent can kill**, the same rule as `wait`: no permissions
  exist yet, and a child is what a parent can name.
- **The console has a foreground process**, set by `foreground`, a
  child of the caller; the kernel clears it when that process ends. An
  ended child is not accepted: its number may come back as another
  process's before the foreground is cleared.
- **Input goes through a kernel buffer**, because the shell is in
  `wait`, not `getc`, while its program runs, and someone must read the
  console to see a Ctrl-C. The kernel reads only while there is a
  foreground process (all of it, looking for Ctrl-C) or readers wait (no
  more than they need). Reading eagerly would pull input queued with
  `--input` into the buffer before the program it was typed for starts,
  and a Ctrl-C with it.
- **Ctrl-C flushes what came before it**, as a terminal does, and is an
  ordinary code point with no foreground process: the shell uses that at
  its prompt to drop a line.

### 2026-11-21 · A timer slice starts when a process is resumed

`on_timer` used to be the only place that armed the next slice, so the
kernel's time between that interrupt and the next `resume` (other
processes' system calls on the same hart) came out of the next
process's slice. With a busy neighbour making a system call after every
step, a process could be resumed with its slice already over, take the
timer at once and never advance. `resume` now gives every process a
whole `QUANTUM` from the moment it runs.

### 2026-11-21 · Programs from files: spawnw and a magic word

The owner chose running programs from disk next, so that programs need
not all be built into the kernel image. The filesystem lives in user
space (the shell), so the kernel should not have to read it.

- **spawnw starts the block window.** A program finds the file, reads
  its first block into its window and calls `spawnw` (15), which copies
  the image into a fresh page. The kernel learns nothing about the FAT
  or the directory, which are expected to be replaced; the cost is one
  `bread` the caller does itself. Rejected: an `exec NAME` call that
  reads the filesystem in the kernel.
- **No relocation.** Every process runs from `V_USER`, so a program is
  assembled to run there, exactly like a built-in one, and its image is
  copied as it is. A relocatable format pays off only once programs
  load at different addresses. The image is limited to what fits from
  `V_USER` to the top of the page, `EXEC_MAX` trytes with its stack,
  the room a built-in program has too, so a program file is one block.
- **A magic word, checked by the kernel.** A program file starts with
  `EXEC_MAGIC`, whose first tryte is negative, which no text file's
  first tryte can be. Running a text file, or calling with no window,
  then fails with `E_NOPROG` instead of faulting in the new process. The
  word lives only in the file: images in memory are unchanged.
- **The rest of the page is cleared.** A built-in image is copied as a
  whole page; a program file brings only the upper half, so the lower
  half is zeroed rather than left with an old tenant's data.
- **`P_FREE` moved to `include/kernel.s`.** It needs `NPROG`, which only
  a kernel build defines, and `include/layout.s` must assemble on its
  own for a program built for the disk.

### 2026-11-21 · The shell runs files, and most programs moved to the disk

With `spawnw` in place, `sh` looks a word up on the disk once it is
neither a built-in nor in its table of image programs, and runs the
program file of that name. Unix shells find programs by searching for
a file too; an explicit `exec NAME` built-in was the alternative, but
typing the name is what a shell user expects.

- **hello, fail and spin moved to `bin/`**, as programs for the disk.
  Keeping them in the image as well would have meant two copies of
  each; the point of the change is that a program need not be built
  into the kernel. pingpong stays, since it spawns ping and pong by
  program number, and those can only be image programs. The shell build
  went from 7 programs to 4, which frees three pages.
- **The shell needs a disk to run them**: `tools/fs.py new disk.img 20
  bin/*.s`, which assembles each `.s` with `detrytus`. The tests build
  such a disk (`tests/kernel.py: bin_disk`).
- **Not a program, or not there.** No filesystem or no such file reads
  as `sh: no such program`, as before; a text or empty file is `sh: not
  a program`, from `spawnw`'s `E_NOPROG` (an empty file has no block to
  read, so the shell says so itself).

### 2026-11-22 · A POSIX-shaped filesystem, read in the kernel

The owner asked to move from the bootstrap filesystem to a POSIX-shaped
one: descriptors, paths, nested directories. Full POSIX is not the aim
(there is no C compiler to need it), but the shape is. Three places for
the code were weighed again: the kernel, a file-server process, and a
library in each program. The kernel was the recommendation, and is
what this change builds.

- **System calls that run again**, rather than a driver that can pause.
  The obstacle the bootstrap ran into was that a system call cannot
  wait halfway: one kernel stack, one disk command per call. So a file
  call reads blocks through a cache (`kernel/cache.s`), and a miss
  starts the read, sleeps the caller and abandons the call; once the
  block is in, `resume` runs the whole call again (`PCB_RETRY`), finding
  it and the earlier blocks in the cache. The price is a rule: a file
  call changes nothing before its last block read. Nothing in this
  first step writes, so the rule costs nothing yet; a call that writes
  will gather its blocks first and change them all at once, under the
  kernel lock, which also makes each change atomic.
- **Rejected: a file server.** It is the microkernel's way, but needed
  new IPC first (messages are one word with no sender), copying between
  address spaces, a way to hear that a client died, and the whole
  filesystem in one page beside its tables. **Rejected: a library** in
  each program: descriptors no other process could share or inherit,
  nothing stopping two writers, and its code in every program's page.
- **The cache is up to 8 pages, taken when first needed**, so a build
  that never touches files loses no memory, and tests that use up
  memory on purpose see no change. A call needs every block it touches
  in the cache at once, which bounds a path to `PATH_DEPTH` (6) names
  and a directory to one block for now. A call never evicts a block it
  used itself (`PCB_BSTART`): with too little memory it fails with
  `E_NOMEM` rather than evicting and refilling for ever, which the
  first version did. Two processes could still keep evicting each
  other's blocks with a tiny cache; with 8 pages and 6 processes that
  needs paths far deeper than anything uses.
- **Layout**: block 0 a header and a map of free blocks, one tryte per
  block (simplest to address); block 1 729 inodes of nine words (type,
  links, size, 5 direct blocks, one indirect); directories as files of
  21-tryte entries with `.` and `..`. Blocks are pages, so 5 direct
  blocks already hold 98,415 trytes, and one indirect block reaches
  6,566 blocks.
- **read stops at a block's end.** A short read is POSIX, and moving at
  most one block per call keeps each call to the blocks one cache fill
  at a time can give. Callers loop until 0, as POSIX callers must.
- **Descriptors live in the process record**, eight of them, lowest
  free first, so 0, 1 and 2 can become the console later, opened before
  a program starts, as Unix does it.
- **Errors are new names from −4 down**, so a call that both reads a
  path and spawns (`spawnf`) never gives one number two meanings.
  `E_IO` moved from −1 to −14 for the same reason: −1 is `E_NOSLOT`.
- **`spawnf(path)` starts a program file**, and the shell uses it,
  looking a bare word up in `/bin`, as a shell searches its `PATH`.
  `spawnw` stays for programs that read raw blocks.
- **The shell lost `write` and `rm`** for now: they wrote the old format
  through the block window. They come back over `write` and `unlink`
  system calls in the next step.

### 2026-11-22 · Messages for a file server: call, receive, reply

The filesystem moves out of the kernel into a server process, so the
kernel gains what a server needs, before the server itself:

- **Call and reply, synchronous.** `call` sends four words and sleeps
  until the reply's four words come back; `receive` says who called.
  This is the QNX and L4 shape: no queues to size, a caller can only
  have one call outstanding, and the server sees one call at a time.
  The one-word `send`/`recv` mailbox stays for what already uses it.
- **Copying, not bigger messages.** A path or a block of file data is
  far bigger than four words, so the server copies to and from the
  caller's memory with `copyin`/`copyout`, only while it holds that
  caller's call. The call names addresses; the kernel checks each range
  lies in the caller's page or a block window it has, and copies all or
  nothing. A caller trusts a server it calls with its whole memory for
  the length of the call, rather than granting one buffer: simpler, and
  the only server yet is the filesystem.
- **Notices of processes that end.** A process that has called
  `receive` is told of every process that ends, from `FROM_KERNEL`,
  before any later call, so a server drops a dead client's descriptors
  before a new process with the same number can reach it. A process
  that ends fails the calls made to it, so a client never waits for a
  dead server.
- **Waking a server reruns its receive** (`PCB_RETRY`, from the
  filesystem's cache), so the call and the notice paths share the code
  that finds work.
- **Nine block windows.** A server holds block 0, the inode table and a
  directory at once, and a few more as its cache; window `k` is a page
  at `V_BLOCK + PAGE × k`, made when first used. `bread` and `bwrite`
  take the window in `a2`.
- **A server asleep in `receive` does not count as deadlock**: with
  nothing else left, the machine powers off as when all have exited.

### 2026-11-22 · The filesystem moves into a file server

The in-kernel filesystem of #26 goes; a process, `user/fsd.s`, reads
the same on-disk format and answers calls (the messages of the entry
above). Eelco chose this over files in the kernel.

- **No library: a file call is a `call`.** The assembler has one symbol
  table per build and no macros, so a library included by two programs
  of one build would define its labels twice. A file call is instead
  `SYS_CALL` to `FS_PID` with an `FS_` operation in `a2`, written out
  where it is made, as system calls are.
- **The server is process 1 by convention**: init starts it first (the
  shell does, the test harness's `files=True` does), so nothing needs a
  name service yet.
- **The same operations, errors and limits**, so the shell's output and
  most tests did not change, except process numbers: every program the
  shell starts is one higher. `PATH_DEPTH` went with the kernel's cache,
  which needed every directory of a path at once; the server walks a
  path a block at a time, so a path is limited by length instead,
  `PATH_MAX` (243), the buffer it is copied into.
- **The server caches blocks in its nine windows**, least recently used
  going first, and blocks while it reads one: one call at a time is
  simple and nothing yet needs more.
- **Programs start through the server.** `FS_SPAWN` reads a program
  file's first block into a window and calls `spawnw(window, client)`,
  which makes the new process the client's child, not the server's, so
  the shell can still wait for it and give it the console.
- **The restartable-call machinery stays only for `receive`**, and the
  kernel's block cache, its dirty states and `ST_BUF` are gone.

### 2026-11-22 · The file server writes

The write side of #27, written for the kernel's cache, moves into the
server: `FS_WRITE`, `FS_UNLINK`, `FS_MKDIR` and `FS_RMDIR`, and `open`
with `O_CREAT`, `O_TRUNC` and `O_APPEND`, with the same errors and
flags as #27, and the shell's `write`, `rm`, `mkdir` and `rmdir`.

- **Write-through, before the reply.** A call marks the windows it
  changes dirty, and `fs_reply` writes them all with `bwrite` before
  it replies. #27's cache wrote back when the disk was idle and at
  power-off; the server cannot see power-off, and writing first means a
  caller that has its reply has its change on the disk.
- **Gather, then commit.** Each call reads every block it needs and
  checks what can fail (a free block, a free inode, the name, the
  copyin of the data) before changing any, so a failing call changes
  nothing and no call leaves the disk half done.
- **Open files cannot be removed**: `unlink` and `rmdir` of an inode
  some descriptor holds is `E_BUSY`, as in #27, rather than Unix's
  keeping it until the last close.

### 2026-11-22 · A current directory and relative paths

- **The server keeps each process's current directory**, next to its
  descriptors (`fs_cwd`, 0 meaning the root so a cleared slot is right),
  and forgets it with the process's end notice. New calls `FS_CHDIR`
  (11) and `FS_GETCWD` (12); a path not starting with `/` starts there.
  Before, every path started at the root; that is still so while a
  process's directory is `/`, so programs that never call `chdir` see
  no change.
- **Inherited through `spawnf` only.** The server knows the parent of a
  program it starts from a file, so it copies the parent's directory;
  the kernel's `spawn` knows nothing of directories, so those start at
  the root. A slot freed by another hart while `spawnf` runs can send
  the child to the root (the old holder's notice comes after); rare,
  since slots are handed out round the table, and harmless.
- **`getcwd` climbs `..`**, finding each directory's name in its
  parent, rather than the server storing path strings, which `rename`
  or a long path would make stale or overflow.
- **A current directory is busy**: `rmdir` of one is `E_BUSY`, as for
  an open file, so a current directory always exists.
- **`E_NOROOM` (-20)** is getcwd's Unix `ERANGE`: `E_RANGE` was already
  `puts`' -2, which a file call cannot use since -2 is `E_NOPROC` (no
  server).
- **An empty path is `E_NOENT`**, as in POSIX; it used to name the root.
  The shell's `ls` with no argument lists `.`.

### 2026-11-22 · Servers are found by name, in the kernel

The file server worked only because init started it first, as process
1. Before a second server (a disk or console driver), servers register
a name with a protocol version, and clients look the name up.

- **Kernel calls, not a naming server.** `register(name, version)` and
  `lookup(name, how)` are system calls over a table of `NSRV` (9)
  names (`kernel/names.s`). A naming server would itself need a fixed
  process number, the problem this removes; it would take one of the
  table's 6 slots; and every lookup would be a call and a reply. QNX
  keeps names in its process manager for much the same reasons; L4
  puts them in a server whose number is handed out at boot. If names
  grow policy (who may claim which), a server can take them over.
- **A name goes with its server.** `bury` drops the names of a process
  that ends, where the kernel already tells servers of it, so a name
  that is found is a live process: no notice to act on, no stale entry.
- **A version, no status.** A server registers once it is ready, so
  being there means ready; a client compares the version with the one
  it speaks (`FS_PROTOCOL`) and treats another as no server. A health
  field would only be work to keep current.
- **`LOOKUP_WAIT` sleeps until the name comes**, woken by every
  `register` to run the call again (`PCB_RETRY`), as `receive` is. The
  shell spawns the file server and waits for its name, so it no longer
  depends on the order processes run in. A lookup nobody will answer
  counts toward deadlock.
- **Names are strings of up to 8 code points**, compared whole, so a
  name reads as one in source (`.string "fs"`). A second process
  registering a taken name gets `E_EXIST`; a second file server leaves
  with it. `FS_PID` is gone.

### 2026-11-22 · The disk driver is a process

The kernel's disk code (`bread`, `bwrite`, a queue of processes in
`ST_DISK`) moved into the disk server, `user/diskd.s`, which registers
as `disk`. The kernel now offers drivers four generic calls instead:
`window` (block windows used to appear on the first `bread`), `drive`
(own a device source and have its register page mapped), `arm` (let it
interrupt once, as a `NOTE_IRQ` notice from `receive`) and `phys` (a
physical address, for DMA). The console stays in the kernel for now,
since `getc` and Ctrl-C are built on it; `drive` refuses it.

- **No detrytus change.** The block device takes physical page numbers
  and the interrupt controller masks per source, which is all a
  user-space driver needs. The price is trust: DMA can write any page,
  so a driver can too. Only programs from the kernel image may drive a
  device (`PCB_FILE`); a program file read from the disk may not. An
  IOMMU-like check in detrytus would remove that trust, if it is ever
  wanted.
- **Copy, not zero-copy.** The disk moves blocks into the server's own
  window, and the server copies them to or from the client with
  `copyout`/`copyin`. Letting the disk write straight into a client's
  window would save the copy, but a client killed mid-command would
  have its page freed while the disk still writes it. `copy_mem` moves
  nine words at a time when both sides are word-aligned, so a block
  costs about 16,000 steps; a shell session reading a few files takes
  roughly 40% more steps than with the kernel driver.
- **Arm, don't enable.** A source is masked again by each interrupt, and
  only armed while the driver expects one. That keeps the deadlock check
  honest: while a source is armed, `pick` waits rather than calling a
  client stuck whose server waits on the disk, and once it is not, a
  driver asleep in `receive` is just a server with nobody to serve.
- **One block per command.** The server could gather consecutive
  blocks into one command (the device allows a list); the file server
  asks for one at a time, so it would not help yet.
- Process slots: the shell build now starts two servers, leaving four
  slots for the shell and its programs.

### 2026-11-22 · The console is a process

The kernel's console input (`kernel/input.s`: a buffer, `getc`, the
foreground process and Ctrl-C) moved into the console server,
`user/consd.s`, which drives `SRC_CONSOLE` and registers as `console`.
`getc` (9) and `foreground` (14) are gone as system calls; programs call
the server with `CN_GETC`, `CN_WRITE` and `CN_FOREGROUND`. The input
policy is the kernel's old one, unchanged: read only what waiting
readers need, or everything while a foreground process runs, so input
typed ahead waits in the device for whoever comes to read it.

- **The kernel keeps its log.** Kernel messages ("process 3 exited",
  panics), `SYS_PUTC` and `SYS_PUTS` still write the console's output
  register directly. A kernel needs a way to speak that does not depend
  on a process being alive, and every test reads its results that way.
  The shell and `bin/hello` print through the server; retiring `putc`
  and `puts` for programs belongs with descriptors 0 to 2, later.
- **The foreground is the server's, the authority the shell's.** A
  terminal owns its foreground (POSIX `tcsetpgrp` is a terminal call),
  so `CN_FOREGROUND` is a console call. Ending the process at Ctrl-C is
  the namer's right, not the server's: `kill(pid, for)` lets a driver
  end a child of process `for`, which the server passes as whoever
  named the foreground. A driver could do worse already through DMA, so
  this adds no trust, and the server cannot end anything the shell could
  not. The shell gives the console back (`NO_FOREGROUND`) after `wait`,
  so a number that has ended and come back is never left named.
- **`KILL_ENDED`.** A child that has ended but not been waited for is
  still a child, so `kill` used to say 0 for it. It now says
  `KILL_ENDED` (1), so the server can tell that a Ctrl-C ended nothing:
  it keeps that Ctrl-C in its buffer, and the next process named the
  foreground gets it. Otherwise a Ctrl-C typed ahead while a quick
  program had just ended would throw away the next line instead.
- **The console's register page is mapped like the disk's**: `drive`
  takes either source and maps `dev_pages[s]` (`P_CONSOLE` −1, `P_DISK`
  −14) at `V_DEVICE + PAGE × (s − 1)`.
- **Nine process slots, not six.** The shell build now starts three
  servers; with six slots `pingpong` (itself, ping and pong) no longer
  fit beside the shell. `NPROC` is 9 (`PCB_NOTES` needs 9 trytes, so
  `PCB_TURN` and `PCB_SIZE` moved by a word), and the shell build's
  machine grew from 40 to 81 pages, since four processes of servers and
  the shell take 17 pages before any program runs. Test harness runs now
  take the build's `RAM_PAGES` unless told otherwise.
- **Each code point typed is a round trip** to the server, and so is
  each string the shell prints. Typing was never the hot path: a short
  session (hello, spin stopped with Ctrl-C, hello, exit) takes about 20%
  more steps than with the kernel's console (857,000 to 1,033,000).

### 2026-11-22 · Descriptors, and 0, 1 and 2 on the console

Programs had to look the console server up and speak its protocol to
print. Now each process has `NDESC` (9) descriptors in its record, each a
server and a handle; `read(fd, buf, n)` and `write(fd, buf, n)` are calls
to that server with `IO_READ`/`IO_WRITE`, and `desc(fd, server, handle)`
sets one. The shell points 0 to 2 at the console server, and children
inherit them, so `bin/hello` is one `write(STDOUT, ...)`.

- **The kernel routes, the servers decide.** A descriptor is not a
  capability the kernel checks: any process may point one anywhere with
  `desc`, and the call reaches the server as the process's own, which
  judges handle and caller as it would any call. That keeps the kernel
  out of each server's notion of an open object, as QNX's connections
  and Plan 9's channels do. Chosen over a console-only convention (fds
  0 to 2 mean "call the console"), which would need reworking for
  redirection.
- **Rewriting the call.** `read` and `write` rewrite the saved `a1`..`a5`
  into a call (server; op, handle, buffer, n) and jump to `sys_call`, so
  they block, fail and return exactly as a call does, `a1`..`a5`
  included. No second path through the IPC code.
- **Descriptor operations are negative** (`IO_READ` −1, `IO_WRITE` −2),
  so every server's own operation numbers, from 0, stay as they are.
- **Children copy the whole table** at spawn (`spawnw` included: the
  parent there is the file server's client, not the file server), as
  POSIX does. Closing (`desc(fd, NO_DESC)`) only clears the caller's
  entry and tells no server: the console keeps nothing per handle.
  A server that does (files) will need a close and a dup it is told of.
- **A console read gives what is there**, at least one code point and
  at most n, one to a tryte, with the same lazy policy as `getc`: raw
  mode, since the shell does its own echo and editing. A code point too
  big for a tryte needs `getc`.
- **Files keep the file server's numbers for now.** Moving them into the
  table needs the file server to hand out handles per open, close and
  dup notices, and inheritance of a handle the server keys by process.

### 2026-11-22 · Files in the kernel's descriptors, and redirection

Eelco asked for open files in the same table as 0, 1 and 2, then shell
redirection with `<`, `>` (and `>>`). Files were the file server's own
numbers, per process, so a child could not inherit one and the shell
could not hand one to a program.

- **Descriptors became capabilities.** With `desc`, any process could
  point a descriptor at any (server, handle). For the console that did
  not matter; for files, handle 4 would be somebody else's open file.
  Now only the server puts a descriptor in a table, with `give(pid,
  handle)`, and only into a process whose call it holds; `desc` is gone.
  A user `call` with a negative (`IO_`) operation is refused, so an
  `IO_` call always comes from a descriptor the server gave, and the
  handle in it is trusted. Copying (`dup2`) and closing stay the
  holder's. This is the Mach port / seL4 capability shape, kept as
  small as two words per descriptor.
- **The kernel says when a handle is free** (`NOTE_CLOSED`, a tryte
  per handle in the server's record, `PCB_CLOSED`), when the last
  descriptor naming it goes: close, `dup2` over it, or its process
  ending. The check scans all 81 descriptors; at this size that is
  cheaper than reference counts the kernel would have to keep right.
  So the file server keeps one record per open file (`fs_files`,
  `NFILE` 27, the handle its index), with no idea who holds it, and
  copies share the position, as after Unix's `dup`. `give` clears a
  notice not yet taken for the handle, since it is named again.
- **A server that ends takes its handles with it**: the kernel clears
  every descriptor naming it, so a later process with its number never
  sees calls for handles it did not give, and a holder gets `E_BADF`.
- **`open` with `O_CREAT` and no free descriptor** makes the file and
  then fails with `E_MFILE`: the server learns the descriptor only by
  giving it. Taking a descriptor first would need a way to take one
  back. Accepted as an edge.
- **`FS_PROTOCOL` 2**: `close`, `read`, `lseek`, `readdir` and `write`
  left the file protocol for `close`, `read`, `write` and `iocall(fd,
  IO_LSEEK or IO_READDIR, x, y)`. The console server gained `CN_OPEN`;
  the shell opens it as 0 and `dup2`s it to 1 and 2.
- **Redirection in the shell.** A word after the command starting with
  `<` or `>` (path attached or next) is taken out of the line, its file
  opened and `dup2`ed onto 0 or 1, after keeping the shell's own in
  descriptors 7 and 8; the next prompt puts them back. It applies to
  built-ins as to programs, so `cat` without a path reads standard
  input. The shell's complaints go to standard error, so `cat nope >
  out` still says why on the console. `cat>out`, with no space after
  the command, is not split: the command is the first word.

### 2026-11-22 · Pipes

Eelco asked for pipes, on the descriptors of #35 and #36.

- **A pipe server, not a kernel pipe** (`user/piped.s`, "pipe"),
  following the microkernel direction: `PP_PIPE` gives two descriptors,
  read end 2k and write end 2k + 1, and reads and writes are descriptor
  calls held until they can be answered, one per process, as the
  console server holds readers. The kernel's `NOTE_CLOSED` gives the
  end of file (no write end left) and `E_PIPE` (no read end left) with
  no bookkeeping of holders. 13 pipes of 729 trytes.
- **A write waits until all of it is in**, rather than answering with a
  short count: the shell's `puts` and `bin/hello` write once and do not
  loop, and POSIX promises whole writes for small ones anyway.
- **`FD_NOINHERIT` (`fdflags`, 22)**, Unix's close-on-exec: without it
  every child inherits the shell's copies of the pipe ends, and a reader
  holding a write end itself never sees the end. Descriptors grew a
  flags word (`DESC` 9, `PCB_SIZE` 282). `dup2` makes an unmarked copy,
  as POSIX's does; the shell's saved 0 and 1 are marked too now.
- **The shell starts every program of a line before waiting**, waiting
  then in order with each as the console's foreground, so Ctrl-C ends
  them one at a time. A built-in runs in the shell, after the programs
  start, with its descriptors put aside (marked) meanwhile; only one per
  line, since two built-ins would run one after the other and the first
  could fill a pipe nobody reads. Up to four commands: the shell build
  has nine process slots, five of them the shell and its servers.
- **`bin/upper` and `bin/wc`** are filters to pipe into, since programs
  take no arguments yet.

### 2026-11-22 · Program arguments

Programs started from the disk took no arguments, so `wc` could only
count standard input. Now a program starts as a C program does, with
`a0` = argc and `a1` = argv.

- **The kernel copies them, at spawn.** `spawnw` takes a block of
  strings (`args`, `n`), at most `ARG_MAX` (243) trytes, and copies it
  into the child before it first runs, with the pointer list built
  beside it. Nobody else can write the new process's page: the file
  server holds its client's call, not the child's, and a library in
  the child would need the parent to keep the block until it had read
  it.
- **Read in the parent's memory, whoever calls.** The file server
  starts programs for its clients; were the block read in the caller's
  memory, the server would have to copy each block in first. The
  kernel already lets the server reach its client's memory while it
  holds the call, so `spawnw` reads there, and `spawnf(path, args, n)`
  passes its client's two words straight through. `FS_PROTOCOL` became
  3, since a client of 2 would leave garbage in `n`.
- **The lower half of the page.** A program's image starts at
  `V_USER − 1` and its stack is at the top, so the 9,841 trytes below
  `V_USER` were always zero and unused. The list sits at the page's
  first word (`V_ARGV`, `ARG_MAX` + 1 words, room for the most
  arguments a block can hold) and the strings after it (`V_ARGS`):
  fixed addresses, nothing for a program to make room for, and the
  page's zeros end the last string and the list whatever the block
  holds.
- **The shell splits at spaces** and gives the command first, as
  typed, without the redirections, which it takes out of the line
  before. No quoting yet, so no argument holds a space.
- **`wc FILE...`** opens each file through the file server, which it
  looks up itself, as Unix's `wc` names each and totals two or more;
  `echo` is new, the smallest use of argv. The test disks grew a block
  for it.

### 2026-11-22 · Quoting in the shell

- **Unix's three quotes, and no more.** `'...'` keeps everything, `"..."`
  everything but `\"` and `\\`, and `\` the one character after it, so
  an argument can hold a space and a quoted `|`, `<` or `>` neither
  pipes nor redirects. With no variables, globs or command substitution
  there is nothing else for `"..."` to let through. An unclosed quote is
  refused rather than read as more lines, since the shell reads one
  line at a time; a `\` at the line's end is itself.
- **One pass over the line, before anything splits it.** Quotes can span
  a `|`, so they are undone first, in place (nothing grows). What the
  splitting, pipe and redirection code look for is a space, `|`, `<` or
  `>`, so a quoted one is stored negated, which no typed character is,
  and that code is unchanged; `word`, which every built-in and argument
  goes through, negates it back, as do the redirection path and
  `write`'s text. A word of quotes alone becomes `SH_EMPTY` so that it is
  still a word, an empty argument, as `echo a "" b` gives in Unix.

### 2026-11-22 · The README is the front page; the reference is docs/kernel.md

The README had grown into the whole kernel manual, with the overview
lost in it. It now says what trylobite is (with a pointer for readers
who came looking for the Setun, and plainly that this is not Setun
software), how to try it, and how the pieces fit; the memory map, the
system calls and each server's description moved to `docs/kernel.md`,
which the comments in `include/layout.s` and `docs/filesystem.md` now
point to.

### 2026-11-22 · 27 process slots and up to 27 programs in the image

- **Room for an init and for networking.** A separate init (program 0,
  starting and restarting the servers) takes a slot of its own, which
  with 9 would leave 3 for programs, one fewer than a four-command
  pipeline. A network driver and a TCP/IP server are expected too, so
  `NPROC` went from 9 to 27, not to 12. A slot costs 300 trytes of
  kernel data (27 take 8,100 of the 19,683-tryte data page, which now
  asserts it leaves the stack 2,187) and a few words in each server;
  pages are only used by processes that run.
- **The image limit moved with it.** A driver has to come from the
  image, and with init the shell build would fill all 9 image pages.
  Program `n` was already at page `P_PROG0 + n`; the named pages
  `P_PROG1` to `P_PROG8` went and `NPROG_MAX` is 27.
- **Scans that grew with the table were trimmed.** `receive` looks for
  pending notices a word (three processes or handles) at a time and walks
  the table for callers by pointer. What remains linear in `NPROC` (the
  scheduler's pick, the console server's reader scans) costs a shell
  session about 3% more steps, and some IPC-heavy tests got larger step
  limits.

### 2026-11-22 · init starts the servers; the shell only runs commands

- **A separate program 0.** The shell used to be init and start the
  servers itself, so the boot order lived in shell code and nothing
  outlived a shell that faulted. `user/init.s` now starts them from a
  table (program, name, protocol version, the row it needs), waiting
  for each name with `LOOKUP_WAIT`, then the shell, and exits with the
  shell's code when the shell exits, which keeps "end of input powers
  off" and every session test as it was. Restarting what dies is the
  next step (design: restart the dead server and whatever needs it,
  the shell last, at most 3 times).
- **The table is assembled in.** Drivers have to come from the kernel
  image anyway; a startup file on disk can come later, for disk
  programs only.
- **Quiet unless something is wrong.** Init logs a server it could not
  bring up, and every row that needs it, on the kernel's log; when all
  is well it prints nothing, so sessions read as before.
- **The shell looks up, it does not wait.** Init starts it only once the
  servers are registered, so `LOOKUP_NOW` finds them, and a missing one
  leaves the shell running without it, as before.
- The demo's starter became `user/demo-init.s`, so `init` names one
  program.

### 2026-11-22 · init starts again what ends

- **What needs a server goes with it.** A server started again has a new
  process number and none of the old one's state, so its clients hold a
  dead number and dead handles. Rather than teach every client to look
  the name up again and reopen what it had, init ends whatever needs the
  server (the rows below it that name it, and the shell) and starts the
  lot again in table order. Open files are lost either way.
- **Three times each, then give up.** A server or shell that keeps
  ending would otherwise loop forever. The count never resets; there is
  no clock worth using for "too often" yet. A shell that exits (end of
  input, `exit`) is not restarted: init exits too, so sessions still
  power off.
- **A parent hears of its children from the start.** `receive` only told
  a process of endings once it had called `receive`, so a server that
  ended while init was still starting the others went unnoticed. The
  kernel now also notes a child's ending for its parent before that.
  Other parents (the shell) collect notes they never read, which costs
  nothing.
- **init's lines are one `puts` each**, so another hart's kernel line
  cannot land inside one. Its own tests use stand-in servers and a
  stand-in shell that print nothing, since output through the console
  server is not ordered against the kernel's log.
- Still open: a server that ends before it registers leaves init in
  `LOOKUP_WAIT`, and the kernel reports a deadlock if nothing else runs.

### 2026-11-22 · a boot report

- **The kernel says what it found, as BSD and Linux do.** Before it
  starts init, hart 0 prints the version, memory (pages, trytes, free),
  the harts present, each device with its page (the interrupt
  controller's source count and the disk's size read from the devices),
  and the process table (`kernel/boot.s`). It replaces the one line
  `trylobite: booting`. Every line starts `trylobite: `, so a reader can
  still strip the kernel's lines with one pattern.
- **Init is no longer quiet when all is well.** It says each server once
  it has registered, with its process number, and `starting sh` before
  each start of the shell: after the spawn the shell may already have
  printed its prompt on another hart, so the shell's line comes first.
  Restarts say the new process numbers the same way.
- **No quiet switch: tests take the boot as it is.** The machine has no
  boot command line, and a build constant would mean the tests no longer
  boot the way a person sees it. Tests that compare a session use
  `after_boot` (`tests/kernel.py`), which drops everything up to
  `trylobite: starting init` and, in the shell build, init's lines up to
  `init: starting sh`; `tests/test_boot.py` checks the report itself.
- **The version is written in `kernel/data.s`**, as `0.1.0`, the
  package's version in `pyproject.toml`; a test keeps the two equal.

### 2026-11-23 · system tools

- **ps, top, kill, free, uptime, uname, dmesg, sleep and df are disk
  programs; the kernel only reports.** Eelco asked for "basic tools: ps,
  df, top, dmesg or equivalents", and agreed to free, kill, uname and
  uptime alongside. Five small calls give them what they need
  (`SYS_LOG`, `SYS_INFO`, `SYS_PROC`, `SYS_NAME`, `SYS_SLEEP`), each
  filling a buffer or waiting; all formatting is in the programs. A
  "proc server" would only have relayed the same kernel data through
  one more call, so the process table stays the kernel's to describe.
  df asks the file server (`FS_STATFS`), as the disk is its business.
- **The log is a page of its own, kept as the kernel prints.** dmesg
  needs the boot report after the fact. Everything printed through the
  kernel (its lines, `putc`, `puts`) is kept, the last page's worth,
  read back by position so a reader can loop until it has all. The page
  is taken at boot before the report, so the report counts it (one page
  less free) and is in it. It is not cleared: `SYS_LOG` never reads past
  what was written, and clearing a page costs boot thirteen thousand
  steps, enough to move the hot-plug tests' timing.
- **A name per process, like Unix's comm.** spawnw names a child after
  the last part of its argv[0]; a program of the kernel image has no
  argv, so it names itself with `SYS_NAME` as it starts. `SYS_SPAWN`
  could have taken a name instead, but every caller of it (tests
  included) would then have to set an extra register.
- **CPU time is user-mode ticks of the `time` CSR**, added at each trap
  from when `resume` last ran the process, so time in the kernel is not
  counted. The machine has no seconds: one tick per step, and times are
  said in ticks.
- **sleep is absolute** (until a time, not for a while), so top's
  screens keep step however long each takes to draw. Sleepers are woken
  in `pick`, and an idle hart sets its timer for the earliest one; a
  sleeper is not a deadlock.
- **kill ends any process but init.** `kill(pid, FOR_SELF)` only ends a
  child, and the shell runs one command at a time, so a kill program
  could have ended nothing. With no users to tell apart, `KILL_ANY` is
  Unix's root; init is refused, since everything else depends on it. A
  server killed this way is started again by init, as when it faults.
- **Adding `FS_STATFS` did not move `FS_PROTOCOL`**: no older client
  sends it, so none can misread it.
- **`bin_disk` and CI's disk grew to 27 blocks**: fifteen programs no
  longer fit in 13 or 20.

### 2026-11-22 · cp, mv, head, grep and touch

- **Programs on the disk, not built-ins.** Each is a `bin/` program over
  the file server, taking its operands as arguments, and `head` and
  `grep` read standard input when no file is named, so pipes and
  redirection work without the shell knowing them. The shell's
  built-ins stay the ones that must run in the shell (`cd`) or came
  before programs could have arguments.
- **`mv` is a rename in the file server** (`FS_RENAME`; like `FS_STATFS`
  it leaves `FS_PROTOCOL` alone, since an older client never sends it,
  and `mv` on an older server just fails), not a copy and an unlink: it moves directories too, nothing is
  copied, and like every call that changes the filesystem it gathers and
  checks every block before changing one, so a refused rename leaves the
  disk as it was. It keeps the server's rule of never pulling an open
  file from under a process (`E_BUSY` to replace one), and never
  replaces a directory, where Unix lets one replace an empty directory:
  `mv` into a directory is what people mean, and the program does that
  by joining the name itself.
- **`grep` matches a fixed string.** A regular-expression engine would be
  most of the program for little use yet; the name stays `grep`, as
  Unix's `grep -F` behaves, and `-v` was cheap. Lines longer than
  729 code points are looked at in pieces.
- **`touch` only makes files**: inodes have no times to bring up to
  date. It opens with `O_CREAT` for reading, which a directory allows,
  so `touch DIR` succeeds as on Unix.
- **No shared library for the programs.** Each repeats its few helpers
  (length, write to standard error, joining a directory and a name),
  since a disk program is assembled on its own and the tools have no
  linker yet.

### 2026-11-23 · a server that ends before it registers

- **The wait ends in the kernel, with `LOOKUP_WHILE`.** Init used
  `LOOKUP_WAIT` for each server it started, so one that ended before
  registering left init asleep for good, and the kernel halted with a
  deadlock. `lookup(name, LOOKUP_WHILE, pid)` waits only while `pid`
  lives and then fails with `E_NOPROC`. The alternatives were worse:
  init polling `LOOKUP_NOW` busy-waits, and waking every `LOOKUP_WAIT`
  sleeper with a failure when any child ends would change the call for
  clients such as the file server, which wait for a name with no
  process of their own to watch.
- **Every process that ends wakes the lookups**, as every register does,
  and each looks again; a `LOOKUP_WAIT` one just sleeps again. Ends are
  rare enough that tracking which sleeper watches which process is not
  worth a field in each record.
- **Ending before registering is ending.** Init reaps the server and
  counts a start against `INIT_RETRIES`, as for one that ends later, so
  a server that dies at once is tried four times and then given up on,
  with what needs it, instead of being given up on the first time.

### 2026-11-23 · The first program in Trice

- **`bin/echo` is Trice now** (`bin/echo.tc`), compiled by detrytus'
  `detrytus tc` (detrytus `docs/trice.md`): the first milestone of the
  compiler's design, chosen because the echo tests already pin its
  behaviour down, so they pass unchanged.
- **Start code is the OS's, not the compiler's.** `lib/start.s` opens
  the program's section at `V_USER`, says `gp` holds `USER_GP`, and
  turns spawnw's start (a0 = argc, a1 = argv) into `main(argc, argv)`,
  exiting with its result. A program imports `include/layout.s` and
  then it; the compiler knows no system call, and `sys(...)` is the
  only way out. There is no libc: helpers live in the programs, as for
  assembly ones, until a few are shared through `lib/`.
- **Size.** The compiled echo is about 80 words against the
  hand-written 21. The compiler's later register allocation is what
  shrinks it; a program still has the upper half of its page.
- **Building.** `tools/fs.py` and `bin_disk` compile `.tc` files as
  they assemble `.s` ones, so `bin/*.s bin/*.tc` is the disk's set.

### 2026-11-23 · Porting tools to Trice

- **wc, grep, head and upper are Trice now**, with echo: ports chosen
  because their tests already pin their behaviour, so they pass
  unchanged, and because they show which compiler features real
  programs need first.
- **Shared helpers, not a libc.** `lib/io.tc` holds what the programs
  repeated in assembly (length, put, read, open, close, decimal), and
  `lib/fs.s` the file server lookup, in assembly because `lookup`
  answers in two registers and `sys(...)` gives only `a0`. A program
  imports what it uses; the compiler builds the whole program.
- **A fresh `bool` is unknown.** `lib/io.tc` first wrote `bool
  fs_known;` and tested `!fs_known`, which is unknown and so never
  true: the flag needs `= false`. The language works as designed, but
  it is the first trap the third truth value set.
- **What the ports asked of the compiler**: dropping functions nothing
  calls (upper carries all of `lib/io.tc`), and smaller code in
  general (wc is 1,618 trytes against 659 hand-written). Structs,
  array initialisers and long argument lists were not needed yet.

### 2026-11-24 · Trice programs are linked

- **`tools/fs.py` links a `.tc` program** with the Trice files it
  imports, found by following `import "....tc"` lines, each compiled
  on its own (`detrytus link bin/wc.tc lib/io.tc`), instead of
  compiling the program whole. The program comes first, since it
  imports `lib/start.s`, which places it at `V_USER`. Assembly
  programs are unchanged, and `bin_disk` uses the same function.
- **Why**: a library compiled once, as programs written in other
  languages (a Rust target is planned) will need, and the linker now
  leaves out the library functions a program does not call, the cost
  the 2026-11-23 ports noted.
- **Size**: linked programs are 6 to 23% larger than whole ones (echo
  189 trytes against 154, wc 1,005 against 901, grep 1,776 against
  1,663), because calls between functions are finished by the linker
  and so are not put in compressed bundles. Relaxation in the linker
  would win that back; every program still fits its page.

### 2026-11-24 · lib/io.tc knows gp

- **`lib/gp.s` holds `.gp USER_GP`**, imported by `lib/io.tc`. Compiled
  on its own, the library did not see the `.gp` in `lib/start.s`, so
  every global it touched took a two-word `la` (`auipc` + `addi`)
  instead of one gp-relative instruction. spawnw sets gp for every
  process, so library code linked into any program can use it. Linked
  wc drops from 1,005 to 978 trytes.
- **With detrytus' relaxation** (detrytus#53, #54; pinned 2026-11-24),
  linked programs are close to whole ones and sometimes smaller: echo
  147 trytes (154 whole), upper 360 (375), wc 933 (901), grep 1,689
  (1,663), head 864 (851).

### 2026-11-24 · Programs in Rust

detrytus can now translate rustc's LLVM IR (`detrytus ll`, detrytus
`docs/rust.md`), so programs on the disk may be `no_std` Rust:
`bin/rhello.rs` and `bin/recho.rs` are the first. Choices:

- **A runtime in assembly, a module in Rust.** `lib/rust/start.s` is
  the start code and what LLVM and the programs call: `memcpy` and its
  kin, `strlen`, `abort`, and `write`, `read` and `exit` over the
  system calls. `lib/rust/sys.rs`, brought in with `#[path]`, declares
  them for Rust and wraps them, with the panic handler. No crate is
  published or vendored.
- **argv is copied.** spawnw's argument block is words, and Rust reads
  an array of 4-byte pointers, so the start code lays one out on the
  stack before calling `main`. The kernel is unchanged.
- **Errors keep their meaning.** A system call's negative error comes
  back as Rust's `isize`, held as its unsigned 32-bit value, so Rust
  sees the same negative number; a panic exits with 101, as Rust's do.
- **tools/fs.py builds with cargo.** One cargo project per program in
  the temporary directory, sharing a target directory so core is built
  once; `-Zbuild-std` and immediate-abort panics through
  `RUSTC_BOOTSTRAP=1` on stable, at opt-level "s" (half the size of
  "z" for recho). CI installs `rust-src` and the target.
- Sizes: rhello 370 trytes with its runtime, recho 671 against 147 for
  the Trice echo; the cost is bytes kept faithfully as four trytes per
  `u32` and a wrap after arithmetic.

### 2026-11-25 · println! in Rust programs

detrytus can now translate `core::fmt` (64-bit integers, long calls,
binary alignment: detrytus docs/rust.md), so `lib/rust/sys.rs` gives
Rust programs `print!`, `println!` and `eprintln!`, writing through
`core::fmt::Write` on a descriptor (`sys::Out`). `bin/rfact.rs` shows
it with a table of factorials up to 20!, the largest that fits a u64.
It was 5 715 trytes, against 668 for recho: formatting is the cost.
With detrytus's load and store helpers and the rest of its size work
(detrytus docs/rust.md, Size) it is 3 960, recho 596 and rhello 367.

### 2026-11-25 · 128-bit integers and floating point in Rust programs

detrytus's translator now handles atomics, 128-bit integers and
floating point (detrytus docs/rust.md). Here:

- **`rfact` goes to 34!**, the last factorial that fits a u128, so it
  shows 128-bit arithmetic and formatting. It grew from 3 960 to
  7 230 trytes: core formats a u128 with a 256-bit multiply.
- **`rmandel` draws the Mandelbrot set in `f32`.** Floating point is
  done in software, with compiler_builtins' routines, about 3 900
  trytes in all.
- **No demo prints a float with `{}`.** Core's float formatting
  (Grisu and Dragon) is about 20 000 trytes, and a program file holds
  at most `EXEC_MAX` (9 843): a program is one block. Lifting that
  limit (programs over several blocks and pages) is a kernel change
  of its own. An f64 demo that only used `+ - * /` and `sqrt` was
  still 11 000 trytes, as `__divdf3`, `__adddf3` and `__muldf3` are
  large on detrytus, so `rmandel` uses `f32` and no division in its
  loop.
- Atomics have no demo: a trylobite process has one thread.

### 2026-11-25 · The binary floating point coprocessor in every process

detrytus now has a binary floating point coprocessor, a device on page
−15 with a bank of registers per hart, and `detrytus ll` runs Rust's
`f32` and `f64` on it (detrytus platform.md, docs/rust.md). Here:

- **Mapped for every process, at its physical address.** The kernel's
  shared leaf table maps page −15 user-accessible, so one entry serves
  every address space and `detrytus ll` can use the physical address.
  Unlike the disk it moves no memory, so any process may use it; no
  `drive` is needed. Rejected: mapping it per process on first use,
  which would need a fault path and a table entry outside the shared
  region for little gain.
- **The bank is saved on every trap and restored when it changed
  hands.** A process can be interrupted between writing an operation
  and reading its result, and may resume on another hart, so `ktrap`
  saves the eight words into `PCB_FPU` each time (16 instructions).
  `resume` restores them only when `fpu_owner` says another process
  used this hart's bank since. `spawn` forgets a reused slot's
  ownership, so a new process never sees its predecessor's operands.
  Rejected: saving lazily, which cannot follow a process that moves to
  another hart, as a hart can read only its own bank.
- **`rmandel` went from 3 908 to 754 trytes**, its `f32` arithmetic
  now a few stores and loads instead of compiler_builtins calls.

### 2026-11-25 · The network server

detrytus has a network device (page −16, source 3): Ethernet frames,
octets one to a tryte, moved by DMA through a send and a receive
channel, with a loopback link and a UDP link to the outside. The first
step toward TCP/IP is its driver, `user/netd.s`, registered as `net`:

- **A server like the disk's.** It drives the source, has the device
  move frames through two windows of its own (one to send from, one to
  receive into) and copies them to and from callers, so the device
  never writes a page a client could free. Calls wait their turn one
  per process, as the disk server's do.
- **Frames, not packets.** `NT_SEND`, `NT_RECEIVE` and `NT_ADDRESS`
  are the whole protocol. ARP, IP and TCP go in a stack server above
  it, which will be netd's one real client; until then, readers are
  served in turn, and a frame waits in the server for the next one.
- **The interrupt is armed only while somebody waits on the device.**
  An armed source keeps the kernel waiting rather than stopping a
  machine whose processes all sleep, so a server that always listened
  would keep every run alive. A network stack keeps a receive waiting
  when it wants to listen.
- **Not in `shell.s` yet.** Starting it there renumbers the shell and
  every program after it, for a server nothing in the shell uses; it
  joins init's rows with the stack that needs it. `NSRC` is 3, which
  still fits `PCB_IRQS` in one word.

### 2026-11-25 · The IP server: ARP and ping

The second step toward TCP/IP is an IP server, `user/ipd.s`, registered
as `ip`, with ARP and ICMP echo; `bin/ping` and `bin/ifconfig` use it.

- **A separate server, so the stack needed two kernel calls.** A
  server that both serves calls and waits for frames cannot block in
  the network server's `NT_RECEIVE`, as calls are synchronous. Rather
  than poll or fold the stack into the driver, the kernel gained
  `notify(pid)`, a nudge that does not wait and arrives in the target's
  `receive` as `NOTE_SIGNAL` (once, however often it came, as an seL4
  notification), and `alarm(until)`, a `NOTE_ALARM` from `receive` for
  timeouts. With both, every server still waits in one place only.
  Rejected: a `receive` with a timeout (the alarm is the same thing,
  and a later TCP needs one timer whatever it is waiting for); a thread
  in the stack (no threads yet).
- **`NT_LISTEN`.** The stack listens rather than reads: the network
  server notifies the listener once for each frame that waits with no
  reader, and the listener's `NT_RECEIVE` then takes it at once. One
  process listens; a reader waiting still gets frames first.
- **An armed device keeps the machine on only while somebody waits.**
  A listening stack keeps the network interrupt armed, and an armed
  source used to keep `pick` waiting for ever, so every run with the
  stack would never power off. Now `pick` waits for a device only if
  some process waits on something other than `receive` (a call, a
  child, a name): servers all asleep in `receive` have nobody to serve,
  whatever arrives. A process with an alarm set keeps the machine on as
  a sleeper does.
- **One ping at a time,** in two states (waiting for ARP, waiting for
  the echo), with the caller's process number as the ICMP identifier; a
  second caller gets `E_BUSY`. The ARP cache has eight entries,
  replaced oldest first, and never expires. Addresses are words, since
  2³² fits easily in 27 trits. Ticks are measured from the echo
  request, not the ARP, as Unix's ping does.
- **Its address is fixed at boot** (10.0.0.2/24, gateway 10.0.0.1) and
  set with `IP_CONFIG`; there is no DHCP or configuration file yet.
- **A round trip takes about 30,000 ticks** on a loopback link: two
  frames, each waiting up to 1,000 for the link, and the rest system
  calls (each frame passes the network server and the IP server, with
  copies) and checksums done an octet at a time.
- **Two machines over UDP need `--live`.** Without it the emulator
  skips idle time to the next deadline, so a ping's alarm goes off
  before the other machine, running in real time, could answer.
- **`shell.s` starts both now,** as init rows 4 and 5 after the file
  server, so the earlier servers keep their process numbers; the shell
  is process 7. 19 of 81 pages stay free in a session.

### 2026-11-25 · UDP

The IP server carries UDP, and `bin/nc` uses it.

- **One port per process,** bound with `IP_BIND`, so send and receive
  need not name it: three words of arguments is all a call has, and an
  address (32 bits) and a port (16) do not fit in one 27-trit word
  together. For the same reason the other end's address and port
  travel in the buffer, six octets before the data, both ways. Several
  ports, or sockets as descriptors, can come with TCP.
- **Datagrams wait in twelve slots of a block window,** shared by every
  process, oldest given first; with none free one is dropped, as UDP
  allows. A receive waits for ever or up to a time limit, and every time
  limit (the ping's, ARP's for a send, each receive's) shares the
  server's one alarm, set for the earliest (`ip_rearm`).
- **A send that needs ARP is held**, one at a time, and finished from
  the top of the server's loop once the cache knows the hop, as a ping
  waiting for ARP now is too.
- **An echo service on port 7** in the server, while nobody binds it:
  something to talk to on a loopback link, and between machines.
- **Checksums** are sent always and checked when present, with the
  pseudo-header's sum fed to `ip_sum` as its start.
- **No fragments**: a datagram fits one frame, 1,472 octets of data.

### 2026-11-25 · TCP

The IP server carries TCP, and `bin/nc` uses it by default.

- **A connection is a descriptor,** given by the IP server, so `read`,
  `write`, `close`, `dup2` and inheritance work on it as on a file or a
  pipe, and the shell can redirect a program onto one. The handle is
  the connection's number. Connect and accept answer with a descriptor;
  closing the last one closes the connection (`NOTE_CLOSED`).
- **`IO_SHUTDOWN` is a new descriptor operation** (−5, now `IO_FIRST`),
  for a half-close: `nc` sends its input, shuts down writing and reads
  the answer, which a request-and-reply peer such as the echo service
  needs. Other servers refuse it with `E_INVAL`.
- **Stop-and-wait, one segment in flight:** simple, and a receive
  window the size of one segment (1,460 octets, our MSS) keeps the
  buffers in two block windows, eight connections each way. A fixed
  retransmission time (300,000 ticks) and six tries; probing a closed
  window does not count as a try, or two peers waiting on each other
  would reset after six probes. Sliding windows and a measured RTT can
  come when throughput matters.
- **The handshake does not wait for accept,** as on Unix: a listener's
  connections queue in the eight records until accepted, and are reset
  if it ends first.
- **No TIME-WAIT**: a connection is forgotten once both FINs are
  acknowledged (or, after our FIN, a while later without theirs). A
  late copy of the other end's FIN then gets a reset, which harms
  nothing it was waiting for.
- **ip_tx and ip_rx moved to window 1,** beside the transmit buffers:
  the server's code and data had grown to two thirds of its page, and
  frames were 3,028 trytes of it.
- **Tested over loss:** two machines over UDP through a proxy that
  drops a quarter of the datagrams pass 4,000 octets through the echo
  service whole; that found the two retransmission bugs fixed before
  it went in (a SYN+ACK sent again after the handshake was
  answered with a SYN, and probes counting as tries).

### 2026-11-25 · Names: a resolver and `bin/host`

Eelco wanted name resolution. detrytus's `--net user` now plays a
name server at 10.0.0.3 that answers from the host's resolver.

- **The name server is a setting of the IP server** (`IP_NAMESERVER`,
  protocol 4), not a file such as `/etc/resolv.conf`: there is no
  `/etc` yet, and `ifconfig` already shows and sets what the network
  is. The IP server keeps the address and asks nothing itself.
- **The resolver is a library, `lib/dns.tc`, linked into each program,**
  as Unix's stub resolver is in libc: no server process, no cache. It
  asks for A records only, over UDP, three tries of 200,000 ticks, and
  reads any answer layout (compressed or written-out names, CNAMEs
  before the addresses).
- **Digits and dots alone are never a name** (`ping 10.0.0` is
  `E_INVAL`, "not a host name"), since no top-level domain is numeric;
  that keeps a mistyped address from becoming a query.
- **The test name server (`tests/dnsd.tc`) runs in the machine:** on a
  loopback link it serves on the machine's own address while the
  program after it in a pipe resolves (`dnsd | host example.test`).
  `bin_disk(programs=...)` puts test-only programs on the disk.

### 2026-11-25 · Programs of several blocks

A program file was one block, so a program had at most 9,843 trytes,
stack included, and core's float formatting (about 20,000) did not
fit. Now:

- **The image runs on into the pages above the process's own.**
  Programs are still assembled to run from `V_USER − 1` up, with no
  relocation; `spawnw` maps up to `NXPAGE` (9) more pages above
  `V_USER`'s, as many as the image reaches, recorded in the process
  record (`PCB_XPAGES`, followed by `PCB_WINS` so that `uva` reads both
  as one list). The block windows moved up past them, to
  `V_USER + PAGE × 10`, and the device registers with them; programs
  name both by `V_BLOCK` and `V_DEVICE`, so only a rebuild noticed.
- **The stack moved below `V_USER`.** It used to start at the top of
  the page, above the image; a larger image would run over it. `USER_SP`
  is now `V_USER`, and the stack grows down through the lower half of
  the page, which held only the arguments at its bottom: about 8,800
  trytes, for every program, built-in ones too, where a one-block
  program had what its image left.
- **The caller reads every block, into consecutive windows.** `spawnw`
  keeps its arguments: window `a1` holds the first block, and the
  following windows the rest. They are consecutive in the caller's
  memory, so the kernel copies the image with `copy_mem` as from any
  buffer and checks with `uva` that it is all there. The file server
  reads a program's blocks into consecutive windows, from the one its
  cache already read the first into when the rest fit after it (so a
  one-block program costs no extra read), else from window 0, dropping
  any other copy of the same block from its cache; it has no dirty window between
  calls, so nothing is lost. Nine windows make the limit: `EXEC_MAX`
  is 9 × `PAGE` less the header, 177,141 trytes. Rejected: a call per
  block into a process not yet started (more kernel states for no gain
  while nine blocks is plenty), and the kernel reading the filesystem
  itself (rejected for `spawnw` already).
- **The file says its size.** A program file is now `EXEC_MAGIC`, the
  image's size in trytes (`EXEC_SIZE`), then the image. The kernel
  copies exactly that much; the file server checks it against the
  file's size, so a file cannot make the kernel copy whatever else
  is in the server's windows. The magic word changed (−20261125), so
  a program file of the old format is refused rather than misread.
- **`rsqrt` prints floats with `{}`**: square roots by Newton's method
  in `f64`, each as Rust's shortest round-trip decimal and as an
  `f32`. It is 21,755 trytes, two blocks, and its image takes one
  page above the process's own.

### 2026-11-26 · A heap, and Rust's alloc

Eelco asked for a heap allocator, so that Rust programs can use
`Vec`, `String` and `Box`.

- **`brk` (41), Unix's oldest heap call, in whole pages.** The heap
  sits past the devices' pages, from `HEAP_START`, so nothing that is
  there now moves. It grows only: nothing a Rust allocator does needs
  pages back before the process ends, and unmapping would need every
  hart that ran the process to drop its translations. `mmap` can come
  if a program ever wants memory back.
- **The kernel keeps only a count** (`PCB_HEAP`, in the word the old
  `PCB_WINS` left free); the pages are in the leaf table, which `uva`
  and `release` read, so the record did not grow by `HEAP_MAX` words.
- **The allocator is Rust, in `lib/rust/heap.rs`, not the kernel's:**
  a free list in address order, first fit, merged on free, units of 8
  bytes (a free block's size and link), with `realloc` in place when
  the block ends the heap or a free block follows it, so a `Vec`
  growing at the top is never copied. A program brings it in with
  `#[path]`, as `sys.rs`; a program without it carries none of it.
- **`rsort`** is the demo: Unix's `sort` with `-r` and `-u`. On the
  81-page shell build it sorts 3,000 lines; past that the machine runs
  out of pages, and the file server cannot make a window to write the
  answer, which `rsort` now reports.
- **Two bugs it found on the way:** `memcmp` in `lib/rust/start.s`
  gave a negative `i32` as it was, so core's sort, which tests the
  sign bit, ran off the slice (detrytus's `bare.s` had it too); and
  `sys::put` wrote once, so a line that crossed a block's end in a file
  lost its tail. `put` now writes until all is taken.

### 2026-11-26 · A sliding TCP window

Eelco picked a sliding window as the next network step, after names.

- **Three segments each way per connection (4,380 octets).** The
  buffers moved to four block windows of their own (1 and 2 send, 3
  and 4 receive, four connections to a window); the frames moved into
  window 0 beside the UDP slots, which went from twelve to ten to make
  room. The IP server now has five windows, two pages more than before.
- **Go-back-N, not selective repeat.** The receiver still drops what
  comes out of order, so the sender sends everything from the oldest
  octet out again on a timeout. With a three-segment window that
  costs little, keeps the receiver simple, and matches detrytus's
  `--net user`, which does the same. No fast retransmit: three
  duplicate acknowledgements cannot happen in a window of three.
- **Measured timeouts (RFC 6298, Karn's rule).** The fixed 300,000
  ticks was shorter than a full window's round trip on the emulated
  link, where one segment costs the IP server about 50,000 rounds
  (checksums and copies in software), so a burst timed out before its
  acknowledgements came. Now 1,000,000 until measured, then SRTT +
  4 x RTTVAR, between 100,000 and 2,400,000, doubling on each timeout.
- **A persist timer instead of probing at once.** Probing a closed
  window the moment it closed raced the receiver's own window update:
  the receiver took the probe octet, the sender sent it again, and
  the receiver dropped the overlap as a repeat. Now the sender waits
  for the update and probes only after a timeout, a probe the other
  end did not take goes again with what follows it, and a segment
  that is partly a repeat keeps its new part.
- **Measured over `--net user --live`** against a host server: 60,000
  octets down took 11.5 s (22.8 s before), 32,000 up 2.2 s (2.9 s,
  where `cat` and the pipe are most of it). Through a proxy dropping a
  quarter of the frames between two machines, 11,400 octets through
  the echo service arrived whole. On the loopback link it is no
  faster, as one CPU plays both ends.

### 2026-11-26 · trystd, a system library in Rust

Eelco asked for std-style bindings for Rust programs, after the heap:
"the aim is to go rust-only once everything is fully bootstrapped".

- **Rust alone, no shared C library.** A libc that Trice and a future
  C compiler could share was the other choice; with userland meant to
  end up Rust, it would be a layer to keep and then throw away. trystd
  wraps the kernel's calls and servers directly. Trice keeps
  `lib/io.tc` for as long as it is used.
- **A crate, not a `#[path]` module.** `lib/rust/trystd` is a cargo
  package that `tools/fs.py` gives every Rust program as a dependency,
  and its IR goes to `detrytus ll` with the program's, core's and
  alloc's. `lib/rust/sys.rs` and `heap.rs` went into it, and the six
  Rust programs moved over.
- **std's names and shapes**, so a program reads as one for std does:
  `fs::File`, `OpenOptions`, `read_dir`, `metadata`; `io::Read`,
  `Write`, `BufRead`, `Seek`, `BufReader`, `stdin().lines()`;
  `env::args`, `current_dir`; `process::Command` with `Stdio::piped()`
  and files, `Child::wait`, `exit`; `net::TcpStream`, `TcpListener`,
  `UdpSocket`, `Ipv4Addr`. Where trylobite differs the item says so:
  `env::args` gives `&'static str` without copying; paths are any
  `AsRef<[u8]>`, as there is no `Path`; IPv4 only, one address from
  `ToSocketAddrs`; a UDP read timeout in ticks; the IP server's one
  UDP port and one listening port per process.
- **The kernel's numbers from `include/layout.s`.** trystd's `build.rs`
  reads each `.equ` it can work out and writes Rust constants
  (`trystd::sys::E_NOENT`), so nothing is repeated, as AGENTS.md
  asks. Errors are `io::Error`s holding the E_ number, with a kind and
  a message.
- **One entry for every call.** `sys(n, a..e)` in `lib/rust/start.s`
  takes each argument as a signed i32 (Rust holds an i32 as its
  unsigned value, so -1 would arrive as 2^32 - 1), `sysu` takes them
  unsigned for an IPv4 address of 2^31 or more, and both keep a1..a3
  for `sys_more`, for calls that answer in several registers.
- **`main!(run)`** makes the `main` start.s calls; `run` may return
  `()`, an exit code or a `Result`, whose error is said as
  "PROGRAM: ERROR" with exit code 1, as std's `Termination`. Standard
  output is line buffered and flushed when `run` returns, before a
  child starts and in `process::exit`.
- **Redirecting a child's standard I/O** keeps this program's
  descriptor in a spare one marked FD_NOINHERIT, `dup2`s the child's in
  its place, starts the child and puts it back. Whether a descriptor
  is open is asked with `dup2(fd, fd)`: `fdflags` would also clear its
  flags, which at first let a child inherit the parent's end of its
  own pipe and never see its input end.
- **Tools that prove it:** `tee` (files), `xargs` (processes, batches
  under ARG_MAX), `fetch` (HTTP/1.0 client, names through a resolver
  in Rust) and `httpd` (a TcpListener serving files and directories).
  `httpd -n 1 notes | fetch -` serves a file to itself: httpd says its
  URL and closes standard output, and `fetch -` reads it, as wget's
  `-i -`. That pair, not `httpd | xargs fetch`, because three Rust
  processes with heaps do not fit the 81-page machine's 15 free
  pages: a program with a heap takes six pages.
- **A translator bug it found:** `detrytus ll` loaded an `i24` as 4
  bytes, so collecting `io::Result<String>` lines saw a `String`'s
  capacity as an enum's niche and gave an empty `Vec`. Fixed in
  detrytus (store sizes), which `detrytus.rev` pins.
- **Sizes:** the library costs a small program about 3,000 trytes
  (`rhello` 442 to 3,261, mostly core's formatting and the stdio
  buffers); `fetch` and `httpd` take two blocks. The test disk grew
  from 40 blocks to 56.

### 2026-11-26 · RAM of any size: the machine says, the kernel listens

Eelco wanted the amount of memory to be arbitrary instead of the
shell build's 81 pages, which three Rust programs at once, or sorting
4,000 lines, ran out of. Three things fixed the size, none of them the
ISA's (a physical page number is 18 trits: every positive page up to
193,710,244 may be RAM):

- **`RAM_PAGES` was built in** (2026-11-19's "RAM size is a build
  parameter"), because the kernel could not ask. detrytus now has a
  read-only RAM size register beside power off (`V_POWER + POWER_RAM`),
  and `page_init` reads it. Builds no longer name a size; tests pass
  `ram_pages=` to the emulator, which is all they ever varied.
- **The direct map was one mid-level superpage**, physical pages
  −3,280 to 3,280, so the kernel could never have used more than 3,280
  pages whatever the build said. It is now four root-level superpages in
  root entries −4 to −1 (`DMAP = −4·3²⁵`), reaching page 150,663,523
  (`MEM_MAX`). Root entry 0 keeps the kernel (mid 0) and the process
  (mid +1), and mid −1 is free. RAM past `MEM_MAX` goes unused, said
  in docs/kernel.md: the negative half of the address space is no
  bigger than positive physical memory, so not all of it can be mapped
  at once. 150 million pages is about 6 TB of host memory in detrytus,
  so it is not a limit anyone will meet in the emulator.
- **`page_init` wrote every free page**, threading the free list
  through them, which in detrytus allocates each page's host memory at
  boot (40 KB a page). Free pages are now a counter of pages never used
  (`fresh_page`) plus the list of pages given back; `take_page` takes
  from the list first. Boot on 150 million pages is as quick as on 81.

`HEAP_MAX` grew from 243 to 3,259 pages, the rest of the process's leaf
table, since the machine's memory was the limit before and is not now.
A process bigger than that needs more leaf tables (mid entries +2 on),
a separate change. `make run` gives the shell 6,561 pages; there, a
pipeline of three Rust programs (`rsort < words | tee sorted | rsort -r
-u | wc`) over 10,000 lines works, which fails on 81 (about 837 million
steps, 4.5 minutes: the emulator's speed, not memory, is now what such
a job waits for).

### 2026-11-26 · The direct map moves within ±2³¹

The kernel is to be ported to Rust, and detrytus' Rust pointers are
signed 32-bit addresses (detrytus `ll --signed-pointers`), so every
address the kernel uses must lie within ±2³¹. Its code, data and device
pages already did (mid entry 0); the direct map, four root-level
superpages at −3.4 × 10¹², did not. It is now mid entries −16 to −1 of
root entry 0, sixteen mid-level superpages, `DMAP` = −16·3¹⁷.

That lowers `MEM_MAX` from 150,663,523 pages to 101,695 (about
2 × 10⁹ trytes): RAM past it goes unused, as before past the old limit.
Eelco chose this over pointers a whole word wide, which every Rust
program would pay for; reaching more RAM later means mapping it in on
demand. Spawn writes sixteen mid entries instead of four root ones.


### 2026-11-27 · The first Rust in the kernel

The port to Rust (stage 2 of its plan) starts with the plumbing and one
leaf: `log` and `info` (`kernel/info.s`) are now Rust, in
`kernel/rust/trykern`, and `kernel/info.s` keeps only their stubs.
What was decided along the way:

- **One crate, a module per subsystem** (Eelco): subsystems call each
  other in cycles, which crates cannot, and calls between crates are
  not inlined.
- **A word is an `i64`** in Rust (Eelco chose a word type), loaded and
  stored with detrytus' `lw`/`sw` builtins; pointers are signed 32-bit
  addresses (`ll --signed-pointers`, Eelco's option (c)), which reach
  everything the kernel uses since the direct map moved within ±2³¹.
- **The record layout stays in assembly.** Rust reads `PCB_` fields by
  offset, so the assembly and the tests keep using the same numbers
  while both languages share the record.
- **The Rust leaves the result in the record.** A stub passes `s0`,
  calls `rk_*` and jumps to `resume`, so no word has to cross back in
  two 32-bit halves.
- **`kernel/trykern.s` is built, not committed.** Its text depends on
  the rustc version (CI installs the latest stable), so a committed
  copy would go stale with every toolchain; `make kernel` and the tests
  build it, and building the kernel now needs the Rust toolchain the
  programs already did.
- **`uva` exists twice for now.** The assembly callers keep values in
  `t3`..`t5` across it, which a Rust function may change, so Rust has
  its own (`mem.rs`) until `ipc.s` is ported.
- **Small over fast** (`opt-level = "z"`): Rust code is about 17 times
  the size of the assembly it replaces (180 trytes became 3,100), and
  the kernel's code has one page; `include/kernel.s` now checks that it
  fits. No speed budget during the port (Eelco); the benchmark, which
  makes neither call, is unchanged at 810,004,668 steps.

### 2026-11-27 · Kernel code over several pages

Rust code is many times the size of the assembly it replaces, and the
kernel's code had one page, 9,000 of its 19,683 trytes already used
after the first module. The code now has `NKCODE` (3) physical pages
from `P_KCODE`, with the data page moved first (page 1), and `KOFF`
chosen so that they run just below the coprocessor's page: data at
virtual page −19, code at −18 to −16. The boot tables, the program
images and the free pages each start two pages later, so a 40-page
machine has 29 free pages instead of 31. Kernel addresses stay well
within ±2³¹ (code near −364,000). Three pages should hold the port for
a while; raising `NKCODE` later means remapping the kernel's leaf table,
which `kernel/pagetables.s` asserts.

### 2026-11-27 · Names and descriptors in Rust

Stage 3 of the port: `register` and `lookup` (`names.rs`) and the
descriptor calls (`desc.rs`: read, write, iocall, close, dup2, give,
fdflags, and what spawn and bury do with descriptors) are Rust;
`kernel/names.s` and `kernel/desc.s` keep stubs. Along the way:

- **Calls from assembly with their own rules get wrappers.** bury keeps
  `t4` and spawn most registers across `srv_ended`, `desc_ended` and
  `desc_inherit`, which Rust would change; each wrapper saves them and
  ends in `rk_restore`. A negative argument is tested in the wrapper,
  since Rust reads an `i32` held in a register as its unsigned value.
- **A call that does not resume says so.** `lookup` that sleeps returns
  1 and the stub jumps to `schedule`; `read`, `write` and `iocall`
  rewrite the saved registers and return 1 for the stub to go on as
  `sys_call`, which stays assembly until `ipc.s` is ported.
- **Names are trytes.** A name's code points go up to 9,841, which a Rust
  `u8` cannot hold, so names are copied and compared by `kernel/rt.s`'s
  `memcpy` and `memcmp`, which move trytes untouched, and a single tryte
  only through a volatile access, which `ll` makes one `lt` or `st`.
  `srv_key` in kernel/data.s went: the name is on the Rust stack.
- **`rouse` and `proc_of` exist twice**, as `uva` does, until `ipc.s`
  is ported (`Proc::retry_if`, `Proc::alive`).
- **No `match` on a word** at first: LLVM makes it a 64-bit `switch`,
  which `detrytus ll` did not translate, and `word::small` narrowed it.
  detrytus#78 taught `ll` wide switches, and stage 4 dropped `small`.

- **Plain loops over `flat_map`.** Written as
  `Proc::table().flat_map(Desc::all).any(...)`, the scan for a handle
  still named never found the server's notice due: closed files were
  never closed in the file server. The same scan as nested loops works.
  That points at a translation bug in `detrytus ll` for the flattening
  iterator, not yet found; until it is, kernel Rust avoids `flat_map`.
  (Later found to be wrong: see "flat_map was slow, not wrong".)

The kernel's code grew from about 9,000 trytes to 13,000. Descriptor
calls cost more steps: fifteen shell pipelines take 12.0 million steps
instead of 8.3 million (the test's budget went from 10 to 15 million),
and the benchmark 819.8 million instead of 810.0 million (+1.2%), left for the
speed pass after the port (Eelco).

## Scheduling, waiting and processes in Rust (2026-11-27)

Stage 4 of the port moved kernel/sched.s's pick, kernel/wait.s's
`wait`, `kill` and bury, and kernel/proc.s's `proc`, `name`, `sleep` and
`alarm` into trykern's `sched`, `wait` and `procinfo` modules.

- **Assembly keeps the shape of the path.** `pick` is still entered and
  left in assembly: the leaving check, the jump to `resume`, `idle` and
  `halt` stay there, and `rk_pick` only chooses the next process (or
  none). `rk_stuck` tells idle from all-done and deadlock, and the
  assembly prints the message and halts. bury still calls the IPC,
  server, driver and descriptor endings itself, then `rk_bury`.
- **Indices in `i32`, not words.** A pid times the PCB size, or a pointer
  divided back into a pid, is an `i64` multiply or divide in Rust, which
  `ll` makes a helper call over two limbs. In pick, called on every
  switch, that made a shell session take 6 to 14 times the steps. Table
  arithmetic is done in `i32` and widened at the end.
- **The sleepers are scanned only when one is due.** The assembly
  walked the table for sleepers and alarms on every switch, at about 8
  steps a slot. In Rust each slot's words are joined from limbs, and the
  walk on every switch took most of a 500-tick quantum: a spinning
  process got 35,000 of 300,000 ticks instead of 158,000. pick now walks
  only once `time` reaches `next_wake`, which `sleep` and `alarm` keep
  as the earliest time (`sched::sleeps_until`); it gets 129,000.
- **States are read as small words.** A word comes into Rust split into
  two limbs, five instructions, and every comparison looks at both.
  pick's walk of the table did that 27 times on every switch with
  nobody ready, and the benchmark took 1,105 million steps.
  `detrytus.lw32` (detrytus#78) reads a word known to fit an `i32` as one
  limb, and `Proc::is` compares a state with it: 1,012 million. pick
  then walked the table as two plain pointer loops, the records after
  the current one and those up to it, instead of one that wraps and
  counts: 870 million.
- **`proc_name` keeps registers.** ps's caller in assembly passes the
  process in `s1`; the wrapper moves the arguments, calls
  `rk_proc_name` and ends in `rk_restore`, like stage 3's wrappers.

The kernel's code grew from 13,000 trytes to 15,500. The benchmark
takes 870.3 million steps instead of stage 3's 819.8 million (+6.2%),
left for the speed pass after the port. Test sessions take about as
many steps as before: a shell session 1.84 million on one hart and 1.87
million on three, and no test budget changed.

## Messages in Rust (2026-11-27)

Stage 5 of the port moved kernel/ipc.s into trykern's `ipc` module:
`send` and `recv`, `call`, `receive`, `reply`, `copyin`, `copyout` and
`notify`, what servers hear when a process ends (`rk_ipc_ended`, which
bury now calls first), and copying between processes (`copy_mem`).

- **A descriptor call no longer goes back through the assembly.** read,
  write and iocall rewrite the saved registers and call `ipc::call`
  themselves; their stubs schedule when it says the caller sleeps.
- **What the assembly still calls stays where its callers are.** `uva`
  moved to kernel/mm.s (spawnw and phys use it) and `rouse` to
  kernel/devices.s (interrupts), each until its file is ported; `mem::uva`
  and `Proc::retry_if` are the Rust's. mm.s's `copy_mem` and syscall.s's
  `client_of` are now small wrappers around `rk_copy_mem` and
  `rk_client_of`.
- **The dispatch stays assembly.** syscall.s still chooses the routine
  for each number: most are stubs into Rust, and the rest (putc, puts,
  exit, spawn, spawnw, the device calls, brk) are mm, console and device
  work for the later stages. A Rust dispatch can come when every call
  is Rust.
- **Copies are the hot path.** The first version took a 15-command
  pipeline session from 7.0 million steps to 23.8 million. What fixed it:
  `memcpy` in kernel/rt.s copies nine words at a time when both ends are
  at a word's first tryte, as copy_mem did in assembly; a copy that fits
  in one page on each side is one look and one copy; `mem::user_at`
  returns only the address (an `Option` of an address and a length comes
  back through memory, a limb at a time), with `page_left` beside it and
  the process's own page found without a division; `client_of` compares
  records instead of dividing for a process number; receive's flag scans
  return an `i32` with NONE, not an `Option<Word>`, and walk pointers,
  as pick does.

The kernel's code grew from 15,500 trytes to 18,700. The benchmark takes
895.9 million steps instead of stage 4's 870.3 million (+2.9%). Reading
two files at once, which copies a few trytes at a time, takes 29.8
million steps instead of 25.0 million, under its test's 30 million; the
word copies of `reply` and `receive` are the rest of it, each word split
into limbs and joined again, for the speed pass after the port. No test
budget changed.

## Memory in Rust (2026-11-27)

Stage 6 of the port moved kernel/mm.s into trykern's `mm` module: the
page allocator (`page_init`, `take_page`, `alloc_page`, `free_page`),
`spawn` and `spawnw` with their arguments, `window`, `brk`, `phys`, and
giving a process's pages back when it ends (`rk_release`).

- **What stays assembly is small.** mm.s keeps the stubs, `release`
  (which leaves the dying process's address space before the Rust frees
  its root table, then buries it), `kva` for devices.s's `drive`, and
  `uva` for `puts`. syscall.s lost spawn, spawnw and the `client_of`
  wrapper; devices.s lost `phys` and `drives_any`; ipc.rs lost
  `rk_copy_mem` and `rk_client_of`, which only the assembly called.
- **NPROG is a word now.** It is each build's (demo.s 3, shell.s 8), so
  layout.rs cannot have it; kernel/data.s keeps it in `nprog` for
  spawn's range check and the first free page.
- **A 32-bit product that may wrap is ten instructions.** `ll` splits a
  wrapping `mul i32` into 16-bit halves unless a factor is below 2⁹, and
  page × `PAGE` is neither, which `mem::user_at` paid on every page it
  looked at. `mem::pages` multiplies with `unchecked_mul` on `u32`, which
  LLVM marks `nuw`, and `ll` makes that one `mul`.
- **Clearing goes a word at a time.** `memset` in kernel/rt.s clears nine
  words at a time from a word's first tryte, for pages and records.
- **Page-table entries cost limbs.** Entries are words and so i64s; the
  table-filling in `spawn` is most of its 600 instructions. A `sw32`
  builtin for words that fit an i32 is a candidate for the speed pass.

The kernel's code grew from 18,700 trytes to 22,700. The benchmark takes
892.6 million steps instead of stage 5's 895.9 million (−0.4%, the
cheaper `user_at`). No test budget changed.

## Devices, harts and boot in Rust (2026-11-27)

Stage 7 of the port, the last of its plan, moved kernel/devices.s,
kernel/harts.s and kernel/boot.s into trykern's `devices` (`drive`,
`arm`, passing interrupts to drivers, forgetting a driver that ends),
`harts` (starting harts, hot-plug events, `wake_one`) and `boot` (the
boot report) modules, with `console` for printing through
kernel/console.s.

- **What stays assembly is the machine's edge.** firmware, entry, the
  trap entry and exit, the dispatch, `schedule`/`idle`/`halt`, the lock,
  the console and log, `hart_leave` (which stops the hart), page tables,
  data, and a stub per system call. `putc`, `puts`, `getpid`, `hart`,
  `yield` and `exit` are still assembly in syscall.s; a Rust dispatch
  can come with the speed pass.
- **No `..=` loops.** An inclusive range is an iterator `ll` calls,
  through memory, for every step: `wake_one` over the nine harts made
  the benchmark 8% slower until it walked a pointer instead.
- **The device pages are constants.** Each source's leaf entry is worked
  out at compile time (`DEV_PTE`), as the pages are below 0 and
  `mem::pages` takes only pages from 0.
- **A hot-plug test was a race.** `test_a_leaving_hart_wakes_another_for_its_process`
  wanted the child on hart 1, which hart -1 wakes as it leaves. But hart
  0's slice ends at about the same moment (the harts' timers run in
  step), and hart 0 is already asleep on the lock while hart 1 is still
  waking, so hart 0 wins; the assembly's `wake_one` was a few steps
  shorter and let hart 1 get there first. The test now accepts either.
  A setup with hart 0 idle does not tell a wake-up apart either: the
  platform's removal event wakes hart 0 anyway.

The kernel's code grew from 22,700 trytes to 24,300. The benchmark takes
895.1 million steps instead of stage 6's 892.6 million (+0.3%). No step
budget changed.

## The speed pass (2026-11-27)

After the port, the remaining system calls (`putc`, `puts`, `getpid`,
`hart`, `yield`, `exit`) and the dispatch moved to trykern's `syscall`
module, and the hot paths the profile showed got cheaper. syscall.s is
now only the trap: it calls `rk_syscall`, whose result says resume,
schedule or release; the per-call stubs and the wrapper files (mm.s,
wait.s, ipc.s, names.s, desc.s, devices.s, info.s, proc.s) are gone.

- **The dispatch is a table of function pointers.** A `match` on the
  call number becomes a chain of comparisons in `ll`; a table indexed
  by number is one load (`ll$ldp`) and a call.
- **Counts instead of walks.** The profile (the benchmark's 300-line
  run, traced instruction by instruction) had the scheduler's pick and
  receive walking the 27-slot table on most switches. Now `nready`
  (ready processes) lets pick skip its walk when none is ready, or only
  the process that stopped; `PCB_CALLERS` (processes waiting in a call
  to a server) lets receive go to sleep without looking;
  `PCB_PENDING` (a notice may wait: `Proc::rouse` sets it) lets receive
  skip its notice scans; and `nidle` (harts waiting for work) lets
  `wake_one` skip its walk. Each count is kept where the state changes
  (`Proc::ready`, `schedule`, `call`, `receive`, `idle`); pick falls back
  to "none ready" if a walk ever finds nothing, which no test did.
- **memcpy moves 27 words a step**, then words, then trytes. Copies
  between processes (`copy_mem`) are about a fifth of all steps in the
  benchmark: the data a pipeline moves, each block copied by the file
  server, the pipe server and the kernel.
- **Smaller things.** The kernel globals' accessors are inlined (each
  was a call that split a word into halves); `unref` walks descriptors
  by pointer rather than through a `Map<Range>` iterator, comparing
  them as small numbers.

The benchmark takes 731.1 million steps instead of stage 7's 895.1
million (−18%), and below the 810 million of the assembly kernel
before the port. The kernel's code is 25,100 trytes (24,300 before).
No test budget changed.

## flat_map was slow, not wrong (2026-11-28)

Stage 3 blamed `detrytus ll` for a `flat_map` scan in `desc::unref` that
seemed never to find a handle closed. Rebuilding stage 3 with it, on
the `ll` it pinned and on today's, fails the same test,
`test_descriptors_go_with_their_process`. But the scan's answer matches
the nested loops on every call, and the run simply stops: the test ran
out of its 2 million steps. With a larger budget it passes, taking 2.46
million steps where the loops take 1.66 million (+49%), and each
`unref` scan costs tens of thousands of steps. The flattening iterator
keeps its inner range in memory, behind a pointer, so every step stores
two 32-bit halves through `ll$st4`, and stage 3 still multiplied indices
as 64-bit words. Today's kernel with the same `flat_map` passes all 712
tests and the benchmark moves by 0.07%, as `unref` is rare there. A new
`ll` test of a `flat_map` scan (records of descriptors, as here) also
gives the right answers. So there is no translation bug to find. The
lesson is to read a step-limit failure as one: "no power-off after N
steps" in the run, not a wrong result. Plain loops stay the rule on hot
paths for speed.

## init reads what to start from /etc/init (2026-11-28)

init's list of servers was a table in `user/init.s`; which ones run,
and any program to start at boot, is now a file on the disk.

- **Bootstrap rows stay built in.** Reading a file needs the console
  (to say what goes wrong), disk and file servers, so those three always
  start, first. That moved the pipe server after them: the boot is now
  console 1, disk 2, fs 3, pipe 4, net 5, ip 6, and the shell is still
  process 7 with the default list.
- **The file chooses among init's servers; it does not describe them.**
  A server line is just a name, `pipe`, `net` or `ip`: the program
  number, the protocol version to expect and what it needs stay in
  `init_rows`, since the servers are programs of the image and their
  protocol versions are `include/layout.s`'s numbers, which a text file
  would repeat and fall out of step with. A named server brings what it
  needs, and init's order holds whatever the file's order.
- **Programs from the disk too**, the way a Unix rc or inittab starts
  daemons: a line starting with `/` is a program file and its
  arguments, started by the file server as init's child after the
  servers. It gets the console as standard output and error and no
  standard input, which stays the shell's. One that exits is done (a
  one-off job); one that faults or is killed starts again, as a server
  does, up to `INIT_RETRIES`; and since it may hold servers' handles, it
  is ended and started again with any server that ends, as the shell
  is. When the shell exits, init ends the programs before it exits, so
  only servers asleep in `receive` are left and the machine still
  powers off.
- **No file is the old behaviour.** Without `/etc/init`, or without a
  file server (a machine with no disk), init starts every server, so
  test disks and old images boot as before. `make` puts the
  repository's `etc/init` on `disk.img`.
- Bounds: 729 characters read (`INIT_TAB`), 9 programs (`INIT_PROGS`),
  and `init_say` now cuts a line short instead of trusting its length,
  as names from the file can be any length. No quoting in arguments.
- Still in assembly: init is a program of the image, which the Rust
  toolchain does not build yet. Moving it to Rust over trystd fits the
  Rust-only direction once image programs can be Rust.

### 2026-11-28 · The kernel boots from the disk

detrytus gained a boot ROM: given a disk and no program, it reads a
boot record in block 0 (words 3 to 8), loads the blocks it names into
consecutive RAM pages and jumps to its entry (detrytus platform.md,
Booting from a disk). trylobite's side:

- **The firmware moved from page 0 into RAM**, to the last `FW_ROOM`
  (243) trytes of the kernel's last code page, labelled at their
  physical addresses (`FW_BOOT`). The ROM owns the boot page and cannot
  write it, so whatever it loads must live in RAM. Page 0 of the image
  keeps two instructions that jump to the firmware, so the same image
  still runs loaded as a file. A page of its own was tried first: one
  page fewer for programs made shell sessions on 81 pages run out of
  memory (xargs), and the code pages have room to spare.
- **The record lives in the filesystem's header**, in words the header
  left unused, and the kernel's blocks are a run of ordinary blocks the
  map marks used, owned by the record as a file's blocks are by its
  inode. The file server needs no change: it never frees a block it did
  not allocate, and `rm` cannot reach them. Rejected: the kernel as a
  file in `/boot`, which the ROM would have to find through inodes, or
  could lose to `rm`.
- **`make` puts `shell.s`'s pages 1 and up on `disk.img`** and `make
  run` boots it. Loading `shell.s` as a file stays for tests and the
  benchmark, so their step counts do not include the ROM's.

### 2026-11-28 · The time of day: a system call over the real-time clock

detrytus gained a real-time clock (platform.md, The real-time clock),
and the kernel passes it on with one call, `clock()`: seconds since
1970 in `a0`, microseconds in `a1`.

- **A system call, not a time server.** A microkernel moves drivers
  out, and Minix does keep its clock driver in user space, but there it
  only sets the kernel's time at boot; the kernel still answers "what
  time is it". Here there is nothing to drive: the clock is two loads
  from the power page the kernel already maps for RAM size and power
  off, it cannot block and keeps no state, and a server would cost every
  reader a call and a reply for it. Rejected: a "time" server (an IPC
  round trip per read, and one more process at boot), and mapping the
  power page into every process (it also holds power off).
- **Unix time, UTC.** Calendars and formats are the library's
  (`trystd::time::Utc`, Hinnant's day algorithms), as on Unix, and
  there are no time zones yet: `date` says UTC.
- **Ticks stay the clock for intervals.** `sleep`, `alarm`, `uptime`
  and CPU times keep counting the `time` CSR: it is steady and is what
  the scheduler runs on. So trystd has `SystemTime` and no `Instant`.
- **The seconds reach Rust whole.** Rust's `i32` results from
  `lib/rust/start.s` would end in 2038 (signed) or 2106 (unsigned), so
  the `clock` stub hands over the low 32 bits and the high part
  separately, and trystd joins them into an `i64`.
- **Later:** setting the clock (an offset the kernel keeps, for a
  `date -s`), file modification times in the filesystem, and time zones.


### 2026-11-28 · Threads: slots of the process table that share a space

Rust programs wanted threads (std's `thread::spawn`) and the machine has
harts to run them on, so the kernel grew them.

- **A thread is a slot of the process table**, with a record of its
  own, not a second set of registers inside a process's record. All the
  per-run state (registers, state, `PCB_HART`, the coprocessor bank,
  IPC, alarms, sleeping) was already per record, and the scheduler,
  `call`, `receive` and `kill` already work on records, so threads get
  all of it unchanged; a thread's number is its slot's, so a server
  answers each thread's call to that thread. What is the process's is
  reached through `PCB_SPACE`. Rejected: a separate thread table (every
  wait, wake and switch would need a second kind of record), and copying
  the page fields into each thread (brk and window change them).
- **Each thread has its own ASID** (its slot's) over the shared page
  tables: nothing is ever unmapped while a process lives, so no other
  thread's translations go stale, and the epoch scheme stays as it is.
- **The whole process ends together**, as on Unix and as Rust's main
  returning expects: exit, a fault or a kill in any thread kills all of
  them, and the pages go back only once the last has gone (`ST_DYING`
  until then), since a thread may be running on another hart when the
  end begins. `thread_exit` and `join` are for threads that end alone.
- **futex for waiting**, the Linux shape: the lock is a Rust atomic in
  user memory, and the kernel only sleeps and wakes on its address.
  It reads the word as Rust's `u32`, four trytes low byte first.
- **trystd keeps per-thread words at `tp`** (what `sys` leaves in
  a1..a3), and locks its heap and standard I/O. A dropped `JoinHandle`
  lets its thread run on; its slot and stack are taken back at the next
  spawn or join (`JOIN_POLL`), so the kernel needs no detach.
- **Receive gives the caller's process in `a5`**, so the file server
  keys current directories by process: a thread's relative paths are
  its process's.
- **Later:** threads in `ps` marked as such (they show their process's
  name now, with no pages of their own), futex with a timeout (for
  `Condvar::wait_timeout`), thread-local storage beyond `tp`'s words.

### 2026-11-28 · top gets a modern header, and the kernel three more numbers

Eelco asked for a top header like modern BSD and GNU tops. The header
needs numbers the kernel did not keep, so it gained three, each the
smallest that serves:

- **Per-hart time, `hartinfo` (49, past the numbers NTP and kernel
  threads take).** Each hart counts the ticks it
  ran processes (`ktrap`, beside `PCB_CPU`) and waited in `idle`; the
  rest is kernel. A stretch under way is counted up to the reading, or
  a hart idle across two screens would put its whole wait in the second
  and show more than 100%. The reading carries its own time (`HI_TIME`),
  so shares do not depend on when the tool got round to asking. Rejected:
  a whole user/nice/system/interrupt split as Linux has (no nice, and
  interrupts are short and few), and putting the harts in `info` (its
  buffer would grow by nine records for every caller).
- **Load averages in `info`.** Unix's `calc_load`, rounding up while
  climbing, sampled in `pick` every 5,000,000 ticks, in `LOAD_ONE`
  (3^9) parts: the 15-minute product stays inside a word.
- **Boot time in `info` (`SI_BOOTED`).** Uptime in seconds from the
  real-time clock, the same clock as the time of day, rather than ticks
  read as microseconds, which they are only with `--clock` or a paced
  live console.

top itself moved to Rust over trystd, as userland is meant to. Its first
Rust version cost 25 times the assembly's steps a screen, and three
causes were worth knowing for any Rust program here: a 64-bit division
is a bit-at-a-time helper (`ll$sdiv64`, ~3,000 steps), a `u32` kept in a
struct is four trytes loaded and stored by helpers (`ll$ld4`, `ll$st4`)
on every use, and `String::push`/`core::fmt` cost ~150 steps a byte and
~1,000 a number. Written into one buffer, with the length read once a
call and 32-bit arithmetic, a screen costs about 70,000 steps, against
the assembly's 9,000 and the first version's 250,000. trystd gained
`sys::ticks`, `sys::sleep_until` and `Words::word_i64`/`tryte` for it:
a tick count passes 2^31 after half an hour of a live console.

### 2026-11-28 · vi, a screen editor, with no console changes

Eelco asked for a vi-like editor. `bin/vi.rs` is Rust over trystd: the
file is read whole into a `Vec` of lines and written back whole with
`:w`, through the file server as any program's files are. It has core
vi (normal, insert and `:` modes; hjkl and arrows, words, `gg`/`G`,
`x`, `dd`, `D`, `yy`/`p`, `J`, `r`, `i a I A o O`, a one-level `u`
that redoes when pressed again, counts, `:w [FILE]`, `:q`, `:q!`,
`:wq`, `:x`, `ZZ`, `:N`), not ex's ranges, searches or registers.

- **No raw mode was needed.** The console server already hands each
  key over as typed, without echo (the shell echoes for itself), and
  passes ANSI sequences out untouched; detrytus' live console puts the
  host terminal in raw mode. So the editor needs nothing new from the
  console server or the kernel.
- **Ctrl-C.** The shell makes each program the console's foreground,
  and Ctrl-C would kill the editor with its file unsaved. The editor
  names `NO_FOREGROUND` itself, which any process may, and reads Ctrl-C
  as a key that cancels. A dedicated "raw" call was rejected as more
  protocol for the same effect.
- **Keys are read a byte at a time.** Whatever the editor reads past
  `:wq` would be lost to the shell (tests type a whole session ahead).
  With no way to ask whether more input waits, an escape is the Escape
  key at once; if `[` or `O` follows, the bytes were an arrow's
  sequence, and the editor takes back what the Escape did (insert mode
  resumes where it was). Nothing in normal mode starts with `[`.
- **Size.** The console has no size to ask, so the screen is 24 by 80.
  Asking the terminal (ESC [ 6 n after moving to the far corner) would
  hang when input is a file, as in the tests.
- **Drawing.** Every key redraws the screen into one buffer, written at
  once, numbers formatted by hand, not with core::fmt (top's lesson).
- **Later:** search (`/`), `cw`/`dw` and other operator-motion pairs,
  multi-level undo, asking the terminal its size in a live session.
