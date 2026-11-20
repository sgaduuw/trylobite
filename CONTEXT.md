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
