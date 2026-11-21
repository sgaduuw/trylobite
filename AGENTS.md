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
uv run ruff check tests
uv run ruff format --check tests
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
- **Register discipline in the kernel**: `s0` is the current process's
  record from trap entry to `resume`, `s1` another process's, and `tp`
  this hart's number (the kernel cannot read `hartid`, a ring +1 CSR).
  Each helper says what it clobbers in its header comment; helpers that
  call others save `ra` on the kernel stack.
- **An ended process keeps its record until its parent waits.** Its
  pages go back at once, but its slot stays `ST_ZOMBIE`, with how it
  ended in its saved `a0` and `a1`, until `wait` reaps it or the parent
  ends. A program that spawns in a loop must wait for its children, or
  run out of the table's 6 slots.
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
