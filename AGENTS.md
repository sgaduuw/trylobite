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
uv sync
uv run pytest
uv run ruff check tests
uv run ruff format --check tests
uv run detrytus run demo.s --ram-pages 20
```

detrytus comes from its `main` branch, pinned to a commit in `uv.lock`.
Move the pin with `uv lock --upgrade-package detrytus`, in its own
commit, and run the tests.

Judge each check by its exit status, run on its own, never through a
pipe.

## Conventions

- **Every shared number is in `include/layout.s`**: addresses, page
  numbers, page-table flags, system-call numbers, process-record offsets.
  The firmware, the kernel, user programs and tests all read them from
  there; never repeat one as a literal.
- **Labels are run addresses.** Each kernel and user section is loaded
  at a physical address and runs at a virtual one
  (`.section NAME, LOAD, RUN`), so every label is the address the code
  sees at run time: `li label`, `la label` and the debugger all agree.
  Keep that true for any new section.
- **Register discipline in the kernel**: `s0` is the current process's
  record from trap entry to `resume`, `s1` another process's. Helpers in
  `kernel/console.s` clobber only `a0` and `t0`..`t5`.
- **User memory is only read with `SUA` on, and only after checking the
  address lies in the process's page.**
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
