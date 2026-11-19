"""Build the kernel with chosen programs and run it."""

import re
from dataclasses import dataclass
from pathlib import Path

from detrytus.asm import Image, assemble
from detrytus.machine import Machine, StepLimit

ROOT = Path(__file__).parent.parent
RAM_PAGES = 40

EXIT = "li a0, SYS_EXIT\n        sys"
DONE = f"li a1, 0\n        {EXIT}"

# An init that starts programs 1 and 2 and leaves: they get process
# numbers 1 and 2, and init's slot, 0, is free again.
SPAWN_BOTH = f"""
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        li    a0, SYS_SPAWN
        li    a1, 2
        sys
        {DONE}
"""


def send_to_2(value: int) -> str:
    """Send value to process 2, waiting for it to exist: init may be
    preempted between its two spawns, so process 1 can run first."""
    return f"""
1:      li    a0, SYS_SEND
        li    a1, 2
        li    a2, {value}
        sys
        li    t0, -2
        bne   a0, t0, 2f
        li    a0, SYS_YIELD
        sys
        j     1b
2:"""


def exit_with(register: str) -> str:
    return f"mv a1, {register}\n        {EXIT}"


def build(
    init: str, prog1: str = DONE, prog2: str = DONE, ram_pages: int = RAM_PAGES
) -> Image:
    """The kernel with init as program 0 and prog1, prog2 to spawn."""
    source = f"""
        .equ  RAM_PAGES, {ram_pages}
        .include "kernel.s"
        .section prog0, P_PROG0 * PAGE, V_USER
{init}
        .section prog1, P_PROG1 * PAGE, V_USER
{prog1}
        .section prog2, P_PROG2 * PAGE, V_USER
{prog2}
"""
    # The file name only sets where .include starts looking: the repo root.
    return assemble(source, str(ROOT / "test-build.s"))


@dataclass
class Run:
    console: str
    exit_code: int | None  # None if it was still running at the step limit
    machine: Machine

    def exits(self) -> list[tuple[int, int]]:
        """(process, exit code) from the kernel's messages, in order."""
        found = re.findall(r"process (\d+) exited with code (-?\d+)", self.console)
        return [(int(p), int(c)) for p, c in found]

    def code_of(self, pid: int) -> int:
        codes = [c for p, c in self.exits() if p == pid]
        assert len(codes) == 1, (pid, self.console)
        return codes[0]

    def ticks(self) -> int:
        m = re.search(r"after (\d+) timer interrupts", self.console)
        assert m, self.console
        return int(m.group(1))


def run_image(
    image: Image, ram_pages: int = RAM_PAGES, max_steps: int = 2_000_000
) -> Run:
    m = Machine(ram_pages=ram_pages, seed=1)
    m.load(image)
    try:
        code: int | None = m.run(max_steps).exit_code
    except StepLimit:
        code = None
    return Run(m.console.text, code, m)


def run(
    init: str,
    prog1: str = DONE,
    prog2: str = DONE,
    ram_pages: int = RAM_PAGES,
    max_steps: int = 2_000_000,
) -> Run:
    return run_image(build(init, prog1, prog2, ram_pages), ram_pages, max_steps)
