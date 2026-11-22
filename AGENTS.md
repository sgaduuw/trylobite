# AGENTS.md

Instructions for AI coding agents working on trylobite. Read this before
your first change; [`CONTEXT.md`](CONTEXT.md) records why things are the
way they are, and gets a new entry when you make a decision of the same
weight.

## What this is

A microkernel in detrytus assembly. The machine, its specification
(`docs/isa.md` in the detrytus repository) and its emulator, assembler
and debugger live in [sgaduuw/detrytus](https://github.com/sgaduuw/detrytus).
When the kernel needs something the machine lacks, or a spec rule is
unclear, that is a detrytus change, made there, not worked around here.

## Tooling

```sh
tools/install-detrytus
uv sync
uv run pytest
uv run ruff check tests tools
uv run ruff format --check tests tools
detrytus run demo.s --ram-pages 40
```

The `detrytus` command is detrytus' Rust tool, installed with cargo at
the commit `detrytus.rev` pins. Move the pin by writing a newer commit
of detrytus' `main` there, in its own commit, reinstall, and run the
tests. The tests are Python but drive the binary as a subprocess
(`tests/kernel.py`): `asm` builds a kernel, `run` runs it, and a
`debug` script reads memory afterwards with `xp`. If something about
the machine looks wrong, that is a detrytus change, made there.

Judge each check by its exit status, run on its own, never through a
pipe.

## Conventions

- **Every shared number is in `include/layout.s`**: addresses, page
  numbers, page-table flags, system-call numbers, process-record offsets.
  The firmware, the kernel, user programs and tests all read them from
  there; never repeat one as a literal.
- **Failures are negative, and tested by sign or by name.** A system
  call whose result is a status or a non-negative value reports failure
  with a negative number named in `include/layout.s` (`E_...`,
  `GETC_NONE`). Return those names, and compare with them or test the
  sign; never write a bare −1, which on a balanced machine is an
  ordinary value. A call whose result can be any word (`recv`, an exit
  code) cannot also carry a failure in it: give it a separate status, or
  no failure at all.
- **Labels are run addresses.** Each kernel and user section is loaded
  at a physical address and runs at a virtual one
  (`.section NAME, LOAD, RUN`), so every label is the address the code
  sees at run time: `li label`, `la label` and the debugger all agree.
  Keep that true for any new section.
- **gp reaches the globals.** Every section that addresses data sets
  `.gp` (`include/kernel.s` for the kernel, the top of each program),
  so `la` is one instruction and `lw rd, name` / `sw rs, name` reach a
  global with no address register. The kernel's `gp` is `kgp`, loaded
  at entry and in `ktrap` right after the process's `gp` is saved; a
  process starts with `gp` at `USER_GP`, which `spawn` sets. Never
  change `gp` anywhere else.
- **Register discipline in the kernel**: `s0` is the current process's
  record from trap entry to `resume`, `s1` another process's, and `tp`
  this hart's number (the kernel cannot read `hartid`, a ring +1 CSR).
  Each helper says what it clobbers in its header comment; helpers that
  call others save `ra` on the kernel stack.
- **An ended process keeps its record until its parent waits.** Its
  pages go back at once, but its slot stays `ST_ZOMBIE`, with how it
  ended in its saved `a0` and `a1`, until `wait` reaps it or the parent
  ends. A program that spawns in a loop must wait for its children, or
  run out of the table's 9 slots.
- **Hart 0 handles hot-plug.** It is the hart controller's event hart and
  can never be removed. A hart asked to go only stops itself in `pick`,
  where it holds no process: anything it ran is back in the table.
- **One kernel lock.** Every path from trap entry to `resume` runs
  holding it (`kernel/lock.s`), and so may touch any kernel data,
  including the one kernel stack. Code before `klock_take` touches only
  the trapping process's own record.
- **Physical memory is reached through the direct map**
  (`physical + DMAP`). Never free a page while it is part of the active
  address space: switch `ptbr` away first, as `release` does.
- **A reused ASID needs a `fence.vm` on every hart.** A process's ASID
  is its slot number plus 1. Spawning into a slot starts a new epoch for
  it, and each hart flushes the ASID in `resume` the first time it runs
  that slot in the new epoch.
- **`RAM_PAGES` and `NPROG` belong to the build**, not to
  `include/layout.s`: each top-level file (demo, shell, tests) states the
  machine it targets and how many programs it adds. Program images sit
  in pages from `P_PROG0`, and the free pages start after the last.
- **A new program goes in `bin/`, on the disk**, unless another program
  spawns it by number (ping and pong) or the kernel starts it (init,
  sh). A disk program is assembled on its own, including
  `include/layout.s` and loading where it runs, at `V_USER`
  (docs/filesystem.md, Program files); `include/layout.s` must
  therefore assemble without `NPROG` or `RAM_PAGES`.
- **Servers are found by name** (`kernel/names.s`): a server calls
  `register` once it is ready, and a client calls `lookup`, with
  `LOOKUP_WAIT` when it may start before its server, and checks the
  version. Never give a server a fixed process number.
- **Files are the file server's, not the kernel's.** `user/fsd.s` is
  a program that registers as `fs`; a file call is a `SYS_CALL` to the
  process `lookup` gives (the shell keeps it in `sh_fs`; tests write
  `CALL_FS`, which `tests/kernel.py` expands, and pass `files=True` to
  `run`). The server shares its build's symbol
  table, so its labels all start with `fs_`. Each call starts on a fresh
  stack, so a failure anywhere just jumps to a reply tail. A call that
  changes the disk gathers and checks everything first, then changes
  its windows and marks them dirty; `fs_reply` writes them back before
  replying, so a window is never left dirty between calls.
- **Devices are their drivers', not the kernel's.** The disk server,
  `user/diskd.s` (labels `dk_`), drives the block device: `SYS_DRIVE` maps its registers at `V_DEVICE`, `SYS_ARM` lets
  it interrupt once, and the interrupt reaches the server as a
  `NOTE_IRQ` notice (`kernel/devices.s`). Arm only when an interrupt is
  due: an armed source keeps `pick` waiting instead of reporting a
  deadlock. Blocks reach other processes as disk calls (`DK_READ`,
  `DK_WRITE`, tests write `CALL_DISK` and pass `disk_server=True`),
  copied between windows; only a program in the kernel image may drive
  a device, since DMA can write any page.
- **The console is the console server's**, `user/consd.s` (labels
  `cn_`): programs read and print through it (`CN_GETC`, `CN_WRITE`;
  tests write `CALL_CONSOLE` or `GETC` and pass `console=True`), and it
  keeps the foreground that Ctrl-C ends, killing on behalf of the
  process that named it (`kill(pid, for)`, drivers only). The kernel's
  own messages, `SYS_PUTC` and `SYS_PUTS`, still go straight to the
  console's output, as its log; tests print with them.
- **Descriptors are capabilities** (`kernel/desc.s`). A descriptor is
  (server, handle) in the process record, put there only by that server
  (`SYS_GIVE`, to a process whose call it holds); `SYS_READ`,
  `SYS_WRITE` and `SYS_IOCALL` become a `SYS_CALL` with an `IO_`
  operation from the rewritten saved registers, and children copy their
  parent's table at spawn. `IO_` operations are negative, and a user
  `SYS_CALL` with a negative operation is `E_INVAL`, so a handle in one
  is always one the server gave. The server keeps no list of holders:
  the kernel posts `NOTE_CLOSED` (`PCB_CLOSED`) when the last
  descriptor naming a handle goes, and clears every descriptor naming a
  server that ends.
- **A server asleep in `receive` runs it again when woken**
  (`PCB_RETRY`, `kernel/ipc.s`), so `receive` must change nothing
  before it finds work. Arguments are read from the saved registers,
  `a3` to `a5` included (`PCB_A3`..`PCB_A5`).
- **Writing zero to a CSR needs a register holding 0.** A CSR
  instruction whose source is `r0` only reads (detrytus isa.md 7.12), so
  `csrw sie, zero` changes nothing: `li t0, 0` first.
- **User memory is only read with `SUA` on, and only after checking the
  address lies in the process's page.**
- **Code is bundled.** Each kernel and user code file sits between
  `.compress` and `.nocompress`, so the assembler pairs neighbouring
  instructions into compressed bundles (detrytus isa.md 6.1). Labels
  move when code changes size, so never count instructions to reach an
  address; keep anything whose layout matters (data, page tables, a
  vectored trap table) outside. A system call resumes at `stval`, the
  instruction after the `sys`, since `stpc + 3` is wrong inside a bundle.
- **Comments explain why.** No em-dashes or double hyphens in prose.
- One concern per file, as in `kernel/`.

## Tests

Tests build the kernel with purpose-made user programs
(`tests/kernel.py`: `run(prog0, prog1)`) and read the kernel's console
output. When you change the kernel, add a test that fails without your
change, and see it fail: break the code it guards, run it, restore.

## Git

`main` holds merged, CI-green work. Branch from it, open a pull request,
and leave the merge to the owner.
